import Foundation

/// The always-on half of Parasite.
///
/// Two cadences, because the two jobs conflict. Catching a spike needs frequent
/// sampling; staying out of the way needs infrequent sampling. So a fast loop
/// reads only the near-free counters and watches for thresholds, while the
/// expensive per-process pass runs once a minute and one row is written from the
/// aggregate. Nothing here forks a process.
final class MonitorDaemon {

    struct Tuning {
        /// Threshold watching. Each tick is a handful of syscalls.
        var fastInterval: TimeInterval = 5
        /// How often a row reaches disk, aggregated from the fast ticks.
        var sampleInterval: TimeInterval = 60
        /// powermetrics is the one expensive collector, so it runs rarely and
        /// only to anchor real power and thermal numbers.
        var powerInterval: TimeInterval = 600
        /// No more than one event of a given kind inside this window.
        var spikeCooldown: TimeInterval = 900
        /// A threshold must hold this long to count — ignores momentary peaks.
        var spikeSustain: TimeInterval = 15

        /// Lets the cadence be overridden on the command line, for testing and
        /// for trading resolution against overhead.
        static func fromArguments(_ args: [String] = CommandLine.arguments) -> Tuning {
            var t = Tuning()
            func value(_ flag: String) -> Double? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return Double(args[i + 1])
            }
            if let v = value("--fast-interval"), v >= 1 { t.fastInterval = v }
            if let v = value("--sample-interval"), v >= 5 { t.sampleInterval = v }
            if let v = value("--power-interval"), v >= 60 { t.powerInterval = v }
            if let v = value("--spike-sustain"), v >= 0 { t.spikeSustain = v }
            if let v = value("--spike-cooldown"), v >= 10 { t.spikeCooldown = v }
            return t
        }
    }

    private let tuning: Tuning
    private var state: MonitorState
    private let machine: MachineProfile
    private let coreCount: Double

    // Aggregation window, reset each time a row is written.
    private var windowCPU: [Double] = []
    private var windowGPU: [Double] = []
    private var windowFootprint: [UInt64] = []
    private var windowTopProcess: Double = 0
    private var windowStart = Date()

    // Hourly per-app accumulation.
    private var currentHour: Date
    private var appAccumulator: [String: AppUsage] = [:]

    private var lastPowerSampleAt: Date?
    private var cachedPower: (watts: Double?, at: Date)?
    private var lastSpikeAt: [SpikeKind: Date] = [:]
    private var sustainedSince: [SpikeKind: Date] = [:]
    private var lastSwapUsed: UInt64?
    /// The most recent per-process reading, reused by spike captures so they do
    /// not re-sample and disturb the delta baseline.
    private var lastProcesses: [FastCollectors.ProcessReading] = []

    init(tuning: Tuning = .fromArguments()) {
        self.tuning = tuning
        self.machine = MachineCollector.profile()
        self.coreCount = Double(max(1, machine.totalCores))
        self.currentHour = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        var loaded = UsageStore.loadState() ?? MonitorState(startedAt: Date())
        loaded.fastIntervalSeconds = tuning.fastInterval
        self.state = loaded
    }

    // MARK: - Run loop

    func run() -> Never {
        do { try UsageStore.prepare() } catch {
            FileHandle.standardError.write(Data("parasite monitor: cannot create store: \(error)\n".utf8))
            exit(1)
        }

        log("monitor started — machine: \(machine.summary)")
        log("sampling every \(Int(tuning.fastInterval))s, writing every \(Int(tuning.sampleInterval))s")

        // Prime the delta-based counters; their first read is meaningless.
        _ = FastCollectors.totalCPU()
        _ = FastCollectors.processes()

        var lastWrite = Date()
        while true {
            let tickStarted = Date()
            autoreleasepool { tick(now: tickStarted, lastWrite: &lastWrite) }

            // Drift-free pacing: sleep for what is left of the interval rather
            // than a fixed amount, so the work's own duration does not accumulate.
            let spent = Date().timeIntervalSince(tickStarted)
            let remaining = tuning.fastInterval - spent
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        }
    }

    private func tick(now: Date, lastWrite: inout Date) {
        guard let cpu = FastCollectors.totalCPU() else { return }
        let (memory, _) = MemoryCollector.read()
        let gpu = FastCollectors.gpu()

        windowCPU.append(cpu)
        windowGPU.append(gpu?.busy ?? 0)
        windowFootprint.append(memory.footprintBytes)

        let swapRate = lastSwapUsed.map { before -> Double in
            memory.swapUsedBytes > before
                ? Double(memory.swapUsedBytes - before) / tuning.fastInterval
                : 0
        } ?? 0
        lastSwapUsed = memory.swapUsedBytes

        let thermal = SystemCollector.thermalStateDescription()
        let smc = SMCCollector.read()

        // Per-process sampling runs on the fast loop, not the write loop.
        // A process that lives entirely between two polls is invisible to
        // proc_listallpids, so polling once a minute would drop every short-lived
        // compiler or script process from per-app attribution. At roughly 4ms a
        // pass this costs about a tenth of one percent of a core.
        let processes = FastCollectors.processes()
        lastProcesses = processes
        let frontmost = FastCollectors.frontmostApp()
        accumulateApps(processes, frontmost: frontmost, span: tuning.fastInterval,
                       gpuMem: gpu?.memoryInUse ?? 0)
        let tickTopProcess = processes.map(\.cpuFraction).max() ?? 0
        windowTopProcess = max(windowTopProcess, tickTopProcess)

        checkSpikes(now: now, cpu: cpu, memory: memory, gpu: gpu?.busy ?? 0,
                    thermal: thermal, fanLoad: smc?.maxFanLoad, swapRate: swapRate)

        guard now.timeIntervalSince(lastWrite) >= tuning.sampleInterval else { return }
        writeSample(now: now, memory: memory, gpu: gpu, thermal: thermal, smc: smc,
                    span: now.timeIntervalSince(lastWrite), frontmost: frontmost)
        lastWrite = now
    }

    // MARK: - Writing a row

    private func writeSample(now: Date, memory: MemoryState,
                             gpu: FastCollectors.GPUReading?, thermal: String,
                             smc: SMCCollector.Reading?, span: Double,
                             frontmost: String?) {
        let idle = FastCollectors.sessionIsIdle()
        let displays = FastCollectors.displayCount()
        let battery = SystemCollector.batteryState()

        let sample = UsageSample(
            t: now,
            // A span far longer than the interval means the machine slept. It is
            // recorded rather than smoothed over, so gaps stay visible.
            span: min(span, tuning.sampleInterval * 3),
            cpu: mean(windowCPU), cpuPeak: windowCPU.max() ?? 0, cpu1: windowTopProcess,
            // NB: `.map(Double.init)` on [UInt64] silently binds to Double(bitPattern:),
            // reinterpreting the bytes as an IEEE double. The explicit closure is required.
            memFootprint: UInt64(mean(windowFootprint.map { Double($0) })),
            memPeak: windowFootprint.max() ?? 0,
            memWired: memory.wiredBytes, memCompressed: memory.compressedBytes,
            swapUsed: memory.swapUsedBytes,
            swapOutRate: memory.swapOutsPerSec ?? 0,
            gpu: mean(windowGPU), gpuPeak: windowGPU.max() ?? 0,
            gpuMemInUse: gpu?.memoryInUse ?? 0,
            thermal: thermal, fanLoad: smc?.maxFanLoad, cpuDieC: smc?.cpuDieC,
            packageWatts: powerIfDue(now: now),
            displays: displays.total, externalPixels: displays.externalPixels,
            onBattery: battery.onBattery, frontmostApp: frontmost, idle: idle
        )
        UsageStore.append(sample)

        state.lastSampleAt = now
        state.totalSamples += 1
        state.observedSeconds += sample.span
        UsageStore.save(state)

        windowCPU.removeAll(keepingCapacity: true)
        windowGPU.removeAll(keepingCapacity: true)
        windowFootprint.removeAll(keepingCapacity: true)
        windowTopProcess = 0
        windowStart = now

        rolloverHourIfNeeded(now: now)
    }

    /// powermetrics is the only collector here that forks and needs root, so it
    /// runs on a long cadence and its last value is reused in between.
    private func powerIfDue(now: Date) -> Double? {
        if let last = lastPowerSampleAt, now.timeIntervalSince(last) < tuning.powerInterval {
            return cachedPower?.watts
        }
        lastPowerSampleAt = now
        guard PowerMetricsCollector.isAvailable,
              case .success(let reading) = PowerMetricsCollector.read(samples: 1, intervalMs: 500)
        else { cachedPower = (nil, now); return nil }
        let watts = reading.instants.compactMap { $0.power?.packageWatts }.max()
        cachedPower = (watts, now)
        return watts
    }

    // MARK: - Per-app accumulation

    private func accumulateApps(_ processes: [FastCollectors.ProcessReading],
                                frontmost: String?, span: Double, gpuMem: UInt64) {
        var grouped: [String: (cpu: Double, rss: UInt64, count: Int)] = [:]
        for p in processes {
            // Kernel and launchd noise would swamp the list without adding anything
            // to a buying decision.
            guard p.rss > 4_194_304 || p.cpuFraction > 0.01 else { continue }
            var entry = grouped[p.app] ?? (0, 0, 0)
            entry.cpu += p.cpuFraction
            entry.rss &+= p.rss
            entry.count += 1
            grouped[p.app] = entry
        }

        for (app, entry) in grouped {
            var usage = appAccumulator[app] ?? AppUsage()
            usage.coreSeconds += entry.cpu * span
            usage.peakRSS = max(usage.peakRSS, entry.rss)
            usage.rssSum += Double(entry.rss)
            usage.samples += 1
            usage.peakProcessCount = max(usage.peakProcessCount, entry.count)
            if app == frontmost {
                usage.foregroundSamples += 1
                usage.peakGPUMem = max(usage.peakGPUMem, gpuMem)
            }
            appAccumulator[app] = usage
        }
    }

    private func rolloverHourIfNeeded(now: Date) {
        let hour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        guard hour != currentHour else {
            // Flush in place so a crash loses at most the current hour's tail.
            if !appAccumulator.isEmpty {
                UsageStore.writeAppHour(AppHour(hour: currentHour, apps: appAccumulator))
            }
            return
        }
        if !appAccumulator.isEmpty {
            UsageStore.writeAppHour(AppHour(hour: currentHour, apps: appAccumulator))
        }
        appAccumulator.removeAll(keepingCapacity: true)
        currentHour = hour
    }

    // MARK: - Spike detection

    private func checkSpikes(now: Date, cpu: Double, memory: MemoryState, gpu: Double,
                             thermal: String, fanLoad: Double?, swapRate: Double) {
        var triggered: [(SpikeKind, Severity, String)] = []

        if cpu > 0.7 {
            triggered.append((.cpuSaturation, cpu > 0.88 ? .high : .elevated,
                              "CPU at \(Fmt.pct(cpu)) of all \(Int(coreCount)) cores"))
        }
        // Deliberately NOT a spike trigger any more. A single pinned core while
        // the machine is otherwise quiet is the normal shape of most desktop work,
        // not an incident: it fired 439 times in six days and drowned out
        // everything worth looking at. The characteristic is already captured
        // properly by the cpu1 percentile distribution, which is where it belongs.
        if memory.footprintFraction > 0.88 {
            triggered.append((.memoryPressure, memory.footprintFraction > 0.95 ? .high : .elevated,
                              "Memory at \(Fmt.pct(memory.footprintFraction)) of \(Fmt.bytes(memory.totalBytes))"))
        }
        if swapRate > 10_485_760 {   // swap grew by >10 MB/s
            triggered.append((.swapGrowth, .high,
                              "Swap grew \(Fmt.bytes(UInt64(swapRate)))/s"))
        }
        if thermal != "Nominal" {
            triggered.append((.thermal, thermal == "Serious" || thermal == "Critical" ? .high : .elevated,
                              "Thermal state: \(thermal)"))
        }
        if let fanLoad, fanLoad > 0.35 {
            triggered.append((.fanRamp, fanLoad > 0.6 ? .high : .elevated,
                              "Fans at \(Fmt.pct(fanLoad)) of their range"))
        }
        if gpu > 0.8 {
            triggered.append((.gpuSaturation, gpu > 0.93 ? .high : .elevated,
                              "GPU at \(Fmt.pct(gpu))"))
        }

        let firing = Set(triggered.map(\.0))
        for kind in SpikeKind.allCases where !firing.contains(kind) {
            sustainedSince[kind] = nil
        }

        for (kind, severity, headline) in triggered {
            // Require the condition to persist, so a compile or a page load does
            // not become an "event".
            let since = sustainedSince[kind] ?? now
            if sustainedSince[kind] == nil { sustainedSince[kind] = now }
            guard now.timeIntervalSince(since) >= tuning.spikeSustain else { continue }
            if let last = lastSpikeAt[kind], now.timeIntervalSince(last) < tuning.spikeCooldown { continue }

            lastSpikeAt[kind] = now
            capture(kind: kind, severity: severity, headline: headline, now: now,
                    cpu: cpu, memory: memory, gpu: gpu, thermal: thermal, fanLoad: fanLoad)
        }
    }

    private func capture(kind: SpikeKind, severity: Severity, headline: String, now: Date,
                         cpu: Double, memory: MemoryState, gpu: Double,
                         thermal: String, fanLoad: Double?) {
        let processes = lastProcesses
            .filter { $0.cpuFraction > 0.02 || $0.rss > 268_435_456 }
            .sorted { $0.cpuFraction > $1.cpuFraction }
            .prefix(15)
            .map { ProcessSlice(name: $0.name, app: $0.app, cpuFraction: $0.cpuFraction, rss: $0.rss) }

        let displays = FastCollectors.displayCount()
        let battery = SystemCollector.batteryState()
        let smc = SMCCollector.read()

        let sample = UsageSample(
            t: now, span: tuning.fastInterval,
            cpu: cpu, cpuPeak: cpu, cpu1: windowTopProcess,
            memFootprint: memory.footprintBytes, memPeak: memory.footprintBytes,
            memWired: memory.wiredBytes, memCompressed: memory.compressedBytes,
            swapUsed: memory.swapUsedBytes, swapOutRate: memory.swapOutsPerSec ?? 0,
            gpu: gpu, gpuPeak: gpu, gpuMemInUse: FastCollectors.gpu()?.memoryInUse ?? 0,
            thermal: thermal, fanLoad: fanLoad, cpuDieC: smc?.cpuDieC,
            packageWatts: cachedPower?.watts,
            displays: displays.total, externalPixels: displays.externalPixels,
            onBattery: battery.onBattery,
            frontmostApp: FastCollectors.frontmostApp(), idle: FastCollectors.sessionIsIdle()
        )

        let event = SpikeEvent(
            id: UUID(), at: now, kind: kind, severity: severity, headline: headline,
            sample: sample, processes: Array(processes),
            frontmostApp: sample.frontmostApp,
            runningApps: AppCollector.read().filter { !$0.isHidden }.map(\.name),
            note: kind.buyingImplication
        )
        UsageStore.write(event)
        state.totalEvents += 1
        UsageStore.save(state)
        log("spike: \(kind.rawValue) — \(headline)")
    }

    // MARK: - Helpers

    private func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
    }
}
