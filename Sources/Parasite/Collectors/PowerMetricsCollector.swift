import Foundation

/// Reads thermal, power, per-cluster residency and per-process energy from
/// powermetrics via the root-owned wrapper installed by scripts/install-privileges.sh.
///
/// Everything here is optional by design: if the grant is not installed the app
/// still works, it just says so instead of guessing.
enum PowerMetricsCollector {
    static let wrapperPath = "/usr/local/libexec/parasite-powermetrics"

    struct Reading {
        var instants: [PartialInstant] = []
        var tasks: [Int32: TaskEnergy] = [:]
        var samplersUsed: String?
    }

    struct PartialInstant {
        var at: Date
        var power: PowerState?
        var clusters: [ClusterResidency] = []
        var gpu: GPUState?
        var thermalPressure: String?
    }

    struct TaskEnergy {
        var pid: Int32
        var name: String
        var energyImpact: Double?
        var gpuMsPerSec: Double?
        var cpuMsPerSec: Double?
        var diskReadBytes: UInt64?
        var diskWriteBytes: UInt64?
        var idleWakeups: Double?
    }

    /// A reason the privileged read could not happen. Carried as a value rather
    /// than thrown, because a missing grant is an expected state to report in the
    /// UI, not an exceptional one.
    struct Unavailable: Error {
        var reason: String
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: wrapperPath)
    }

    /// Returns nil when the privileged grant is unavailable, with a reason the
    /// UI surfaces rather than swallowing.
    static func read(samples: Int, intervalMs: Int) -> Result<Reading, Unavailable> {
        guard isAvailable else {
            return .failure(Unavailable(reason: "powermetrics grant not installed — run scripts/install-privileges.sh for thermal, power and per-process GPU data"))
        }
        let r = Shell.run("/usr/bin/sudo",
                          ["-n", wrapperPath, "\(samples)", "\(intervalMs)"],
                          timeout: Double(samples * intervalMs) / 1000.0 + 25)
        if !r.ok {
            if r.stderr.contains("password is required") || r.stderr.contains("sudo:") {
                return .failure(Unavailable(reason: "sudo refused the powermetrics wrapper — re-run scripts/install-privileges.sh"))
            }
            return .failure(Unavailable(reason: "powermetrics failed (exit \(r.exitCode)): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }

        var reading = Reading()
        reading.samplersUsed = r.stderr
            .components(separatedBy: "\n")
            .first { !$0.isEmpty && !$0.contains("sudo") }?
            .trimmingCharacters(in: .whitespaces)

        // powermetrics emits one plist per sample, NUL-separated.
        let documents = r.stdout
            .components(separatedBy: "\0")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("<?xml") || $0.hasPrefix("<!DOCTYPE") || $0.hasPrefix("<plist") }

        if documents.isEmpty {
            return .failure(Unavailable(reason: "powermetrics returned no parseable plist documents"))
        }

        for doc in documents {
            guard let data = doc.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = plist as? [String: Any]
            else { continue }
            reading.instants.append(parseInstant(dict))
            // Later samples carry fresher per-process numbers, so let them win.
            for (pid, task) in parseTasks(dict) { reading.tasks[pid] = task }
        }

        if reading.instants.isEmpty {
            return .failure(Unavailable(reason: "powermetrics output could not be decoded as property lists"))
        }
        return .success(reading)
    }

    private static func parseInstant(_ dict: [String: Any]) -> PartialInstant {
        var out = PartialInstant(at: (dict["timestamp"] as? Date) ?? Date())
        out.thermalPressure = dict["thermal_pressure"] as? String

        if let processor = dict["processor"] as? [String: Any] {
            out.power = PowerState(
                cpuWatts: milliwatts(processor["cpu_power"]),
                gpuWatts: milliwatts(processor["gpu_power"]),
                aneWatts: milliwatts(processor["ane_power"]),
                packageWatts: milliwatts(processor["combined_power"]),
                onBattery: false, batteryPercent: nil,
                adapterConnected: true, lowPowerMode: false
            )
            if let clusters = processor["clusters"] as? [[String: Any]] {
                out.clusters = clusters.compactMap(parseCluster)
            }
        }

        // The GPU block is an array on Apple Silicon and a dict on some releases.
        let gpuAny = dict["GPU"] ?? dict["gpu"]
        if let gpuArray = gpuAny as? [[String: Any]], let g = gpuArray.first {
            out.gpu = parseGPU(g)
        } else if let g = gpuAny as? [String: Any] {
            out.gpu = parseGPU(g)
        }

        return out
    }

    private static func parseCluster(_ d: [String: Any]) -> ClusterResidency? {
        guard let name = d["name"] as? String else { return nil }
        let cpus = (d["cpus"] as? [[String: Any]]) ?? []

        // The cluster's own idle_ratio reads 0.000 even on a fully idle machine,
        // so it cannot be used. The per-core idle_ratio values are the real signal.
        var activeRatio: Double
        if !cpus.isEmpty {
            let actives = cpus.compactMap { double($0["idle_ratio"]).map { 1 - $0 } }
            activeRatio = actives.isEmpty ? 0 : actives.reduce(0, +) / Double(actives.count)
        } else {
            activeRatio = max(0, min(1, 1 - (double(d["idle_ratio"]) ?? 1)))
        }

        // A cluster can be powered down entirely; its cores then report plausible
        // idle ratios for the slice of time they were up. Scaling by online_ratio
        // stops a mostly-asleep cluster looking busy.
        if let online = double(d["online_ratio"]) {
            activeRatio *= max(0, min(1, online))
        }

        // Per-core frequency is the throttling signal. The cluster-level average
        // folds in powered-down time, which drags it below peak even when every
        // running core is at maximum clock.
        var averageMHz: Double?
        let coreFreqs = cpus.compactMap { double($0["freq_hz"]) }.filter { $0 > 0 }
        if !coreFreqs.isEmpty {
            averageMHz = (coreFreqs.reduce(0, +) / Double(coreFreqs.count)) / 1_000_000
        } else if let f = double(d["freq_hz"]), f > 0 {
            averageMHz = f / 1_000_000
        }

        // dvfm_states already reports frequencies in MHz.
        var maxMHz: Double?
        if let states = d["dvfm_states"] as? [[String: Any]] {
            let freqs = states.compactMap { double($0["freq"]) }
            if let m = freqs.max(), m > 0 { maxMHz = m }
        }

        return ClusterResidency(
            name: name,
            activeRatio: max(0, min(1, activeRatio)),
            averageFrequencyMHz: averageMHz,
            maxFrequencyMHz: maxMHz
        )
    }

    private static func parseGPU(_ d: [String: Any]) -> GPUState {
        // Unlike the CPU clusters, the GPU's own idle_ratio is meaningful.
        let idle = double(d["idle_ratio"]) ?? 0
        let freqHz = double(d["freq_hz"]) ?? 0
        var maxMHz: Double?
        if let states = d["dvfm_states"] as? [[String: Any]] {
            let freqs = states.compactMap { double($0["freq"]) }
            if let m = freqs.max(), m > 0 { maxMHz = m }
        }
        return GPUState(
            busyRatio: max(0, min(1, 1 - idle)),
            frequencyMHz: freqHz > 0 ? freqHz / 1_000_000 : nil,
            maxFrequencyMHz: maxMHz
        )
    }

    private static func parseTasks(_ dict: [String: Any]) -> [Int32: TaskEnergy] {
        guard let tasks = dict["tasks"] as? [[String: Any]] else { return [:] }
        var out: [Int32: TaskEnergy] = [:]
        for t in tasks {
            guard let pidRaw = double(t["pid"]) else { continue }
            let pid = Int32(pidRaw)
            out[pid] = TaskEnergy(
                pid: pid,
                name: (t["name"] as? String) ?? "pid \(pid)",
                energyImpact: double(t["energy_impact_per_s"]) ?? double(t["energy_impact"]),
                // Per-process GPU time is not reported on this OS even with
                // --show-process-gpu, so it stays nil rather than being faked.
                gpuMsPerSec: double(t["gputime_ms_per_s"]),
                cpuMsPerSec: double(t["cputime_ms_per_s"]),
                diskReadBytes: double(t["diskio_bytesread_per_s"]).map { UInt64(max(0, $0)) }
                    ?? double(t["diskio_bytesread"]).map { UInt64(max(0, $0)) },
                diskWriteBytes: double(t["diskio_byteswritten_per_s"]).map { UInt64(max(0, $0)) }
                    ?? double(t["diskio_byteswritten"]).map { UInt64(max(0, $0)) },
                idleWakeups: double(t["idle_wakeups_per_s"]) ?? double(t["idle_wakeups"])
            )
        }
        return out
    }

    private static func double(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// powermetrics reports SoC power in milliwatts on Apple Silicon.
    private static func milliwatts(_ any: Any?) -> Double? {
        guard let v = double(any) else { return nil }
        return v / 1000.0
    }
}
