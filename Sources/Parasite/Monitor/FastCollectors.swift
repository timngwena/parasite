import Foundation
import IOKit
import Darwin
import AppKit

/// Collectors that run entirely in-process: no forking, no `top`, no `ps`.
///
/// This matters because the monitor runs for two weeks. The existing diagnostic
/// collectors shell out and take seconds; these take single-digit milliseconds,
/// which is what makes continuous monitoring honest about "minimal impact".
enum FastCollectors {

    // MARK: - GPU

    struct GPUReading {
        var busy: Double          // 0...1
        var memoryInUse: UInt64
        var memoryAllocated: UInt64
    }

    /// Reads the accelerator's PerformanceStatistics out of the IORegistry
    /// directly. `ioreg | grep` does the same thing but costs a fork and ~50ms.
    static func gpu() -> GPUReading? {
        for matchName in ["AGXAccelerator", "IOAccelerator"] {
            guard let matching = IOServiceMatching(matchName) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
            else { continue }
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var properties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dict = properties?.takeRetainedValue() as? [String: Any],
                      let perf = dict["PerformanceStatistics"] as? [String: Any],
                      let utilisation = (perf["Device Utilization %"] as? NSNumber)?.doubleValue
                else { continue }
                return GPUReading(
                    busy: max(0, min(1, utilisation / 100)),
                    memoryInUse: (perf["In use system memory"] as? NSNumber)?.uint64Value ?? 0,
                    memoryAllocated: (perf["Alloc system memory"] as? NSNumber)?.uint64Value ?? 0
                )
            }
        }
        return nil
    }

    // MARK: - Whole-machine CPU

    private static var lastTicks: (user: Double, system: Double, idle: Double, nice: Double)?

    /// Total CPU as a fraction of all cores, from the host tick counters. These
    /// cover every process including the root-owned ones libproc cannot see, so
    /// the machine-wide figure stays correct even though per-app attribution
    /// only covers your own processes.
    static func totalCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let now = (Double(info.cpu_ticks.0), Double(info.cpu_ticks.1),
                   Double(info.cpu_ticks.2), Double(info.cpu_ticks.3))
        defer { lastTicks = now }
        guard let prev = lastTicks else { return nil }  // first call only primes

        let busy = (now.0 - prev.user) + (now.1 - prev.system) + (now.3 - prev.nice)
        let total = busy + (now.2 - prev.idle)
        guard total > 0 else { return nil }
        return max(0, min(1, busy / total))
    }

    // MARK: - Per-process

    struct ProcessReading {
        var pid: Int32
        var name: String
        var app: String
        var cpuFraction: Double     // of one core
        var rss: UInt64
        var threads: Int
    }

    /// Nanoseconds per unit of the CPU-time counters in proc_taskinfo.
    ///
    /// Those counters are in mach time units, NOT nanoseconds. On Intel the
    /// timebase is 1:1 so the distinction is invisible; on Apple Silicon it is
    /// 125/3, so treating ticks as nanoseconds under-reports every process's CPU
    /// by a factor of ~41.7 — a fully pinned core reads as 2.4%.
    private static let machTickNanos: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    private static var previousCPUTime: [Int32: UInt64] = [:]
    private static var previousAt: Date?
    /// pid -> resolved application name. Resolving costs a proc_pidpath syscall,
    /// and pids are stable for a process's life, so it is only done once each.
    private static var appNameCache: [Int32: String] = [:]

    /// Samples every visible process. Root-owned processes are not visible to a
    /// user-level agent, which is fine: this drives per-app attribution, and your
    /// applications are all yours.
    static func processes() -> [ProcessReading] {
        var capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        capacity += 256                       // room for processes started meanwhile
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let returned = proc_listallpids(&pids, Int32(Int(capacity) * MemoryLayout<pid_t>.size))
        guard returned > 0 else { return [] }

        let now = Date()
        let elapsed = previousAt.map { now.timeIntervalSince($0) } ?? 0
        var currentCPUTime: [Int32: UInt64] = [:]
        currentCPUTime.reserveCapacity(Int(returned))
        var live = Set<Int32>()
        var out: [ProcessReading] = []
        out.reserveCapacity(Int(returned))

        for index in 0..<Int(returned) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            // TASKALLINFO costs the same call as TASKINFO but also carries the
            // start time, which is what makes short-lived processes countable.
            var all = proc_taskallinfo()
            let size = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all,
                                    Int32(MemoryLayout<proc_taskallinfo>.size))
            guard size == Int32(MemoryLayout<proc_taskallinfo>.size) else { continue }
            let info = all.ptinfo

            live.insert(pid)
            let cpuTime = info.pti_total_user &+ info.pti_total_system
            currentCPUTime[pid] = cpuTime

            var fraction = 0.0
            if elapsed > 0, let before = previousCPUTime[pid], cpuTime >= before {
                let nanos = Double(cpuTime - before) * machTickNanos
                fraction = nanos / 1_000_000_000 / elapsed
            } else if elapsed > 0, previousCPUTime[pid] == nil {
                // First time seen. If it was born inside this window its whole
                // lifetime belongs here; otherwise it predates our baseline and
                // crediting it would invent work that happened before monitoring.
                // Without this, a build that spawns hundreds of short-lived
                // compiler processes would register as almost no CPU at all.
                let born = Double(all.pbsd.pbi_start_tvsec)
                let windowStart = now.timeIntervalSince1970 - elapsed
                if born >= windowStart - 1 {
                    let nanos = Double(cpuTime) * machTickNanos
                    fraction = min(nanos / 1_000_000_000 / elapsed, Double(ProcessInfo.processInfo.activeProcessorCount))
                }
            }

            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, 256)
            let name = String(cString: nameBuffer)

            out.append(ProcessReading(
                pid: pid, name: name, app: appName(for: pid, fallback: name),
                cpuFraction: fraction, rss: info.pti_resident_size,
                threads: Int(info.pti_threadnum)
            ))
        }

        previousCPUTime = currentCPUTime
        previousAt = now
        // Pids are recycled, so stale cache entries would eventually mislabel a
        // new process with a dead one's app.
        appNameCache = appNameCache.filter { live.contains($0.key) }
        return out
    }

    /// Groups helper processes under the application that owns them, so "Chrome"
    /// reads as one thing rather than fourteen.
    private static func appName(for pid: Int32, fallback: String) -> String {
        if let cached = appNameCache[pid] { return cached }
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        var resolved = fallback
        if length > 0 {
            let path = String(cString: pathBuffer)
            let parts = path.split(separator: "/").map(String.init)
            // The outermost .app wins: "Chrome.app/…/Chrome Helper.app" is Chrome.
            if let appIndex = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
                resolved = String(parts[appIndex].dropLast(4))
            } else if let last = parts.last {
                resolved = last
            }
        }
        appNameCache[pid] = resolved
        return resolved
    }

    // MARK: - Session state

    /// Total pids on the machine, including processes this user cannot inspect.
    /// Needed to say honestly how much of the picture is missing.
    static func totalProcessCount() -> Int {
        Int(proc_listallpids(nil, 0))
    }

    /// The frontmost application, which separates what you actually work in from
    /// what merely runs. Returns nil outside a GUI session.
    static func frontmostApp() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    /// True when the screen is locked or the session is not active, so idle time
    /// does not get averaged into "how you work".
    static func sessionIsIdle() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = info["CGSSessionScreenIsLocked"] as? Int, locked == 1 { return true }
        if let onConsole = info["kCGSSessionOnConsoleKey"] as? Bool, !onConsole { return true }
        return false
    }

    static func displayCount() -> (total: Int, externalPixels: Int) {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return (0, 0) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return (0, 0) }
        var externalPixels = 0
        for id in ids where CGDisplayIsBuiltin(id) == 0 {
            if let mode = CGDisplayCopyDisplayMode(id) {
                externalPixels += mode.pixelWidth * mode.pixelHeight
            }
        }
        return (Int(count), externalPixels)
    }
}
