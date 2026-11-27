import Foundation

enum CaptureDepth: String, CaseIterable, Codable {
    case quick, standard, deep

    var samples: Int {
        switch self {
        case .quick: 4
        case .standard: 10
        case .deep: 30
        }
    }
    var intervalMs: Int { 1000 }
    var seconds: Double { Double(samples * intervalMs) / 1000 }

    var label: String {
        switch self {
        case .quick: "Quick (4s)"
        case .standard: "Standard (10s)"
        case .deep: "Deep (30s)"
        }
    }
    var blurb: String {
        switch self {
        case .quick: "Enough to catch a runaway process or memory pressure."
        case .standard: "Long enough to see whether load is sustained or spiky."
        case .deep: "Best for fan ramps and intermittent stalls — watches trends build."
        }
    }
}

/// Assembles a full snapshot over a time window. A window rather than an instant,
/// because most of the symptoms worth diagnosing — fans ramping, a stall building,
/// swap filling — are only visible as a trend.
enum SnapshotCollector {

    static func capture(
        depth: CaptureDepth,
        progress: @escaping @Sendable (String, Double) -> Void
    ) async -> Snapshot {
        var degradations: [String] = []
        let machine = MachineCollector.profile()
        let window = depth.seconds

        progress("Reading thermal and power telemetry…", 0.05)

        // powermetrics blocks for the whole window, so it runs alongside the
        // lightweight sampling loop rather than after it.
        let pmTask = Task.detached(priority: .userInitiated) {
            PowerMetricsCollector.read(samples: depth.samples, intervalMs: depth.intervalMs)
        }

        // Prime the cumulative counters; the first CPU reading is otherwise
        // meaningless because it has nothing to diff against.
        _ = SystemCollector.cpuUsagePercent()
        var (_, previousCounters) = MemoryCollector.read()
        var previousAt = Date()

        var instants: [Instant] = []
        let battery = SystemCollector.batteryState()

        for i in 0..<depth.samples {
            try? await Task.sleep(nanoseconds: UInt64(depth.intervalMs) * 1_000_000)

            let now = Date()
            let elapsed = now.timeIntervalSince(previousAt)
            var (memory, counters) = MemoryCollector.read()
            let (pi, po, si, so) = MemoryCollector.rates(from: previousCounters, to: counters, seconds: elapsed)
            memory.pageInsPerSec = pi
            memory.pageOutsPerSec = po
            memory.swapInsPerSec = si
            memory.swapOutsPerSec = so
            previousCounters = counters
            previousAt = now

            instants.append(Instant(
                at: now,
                cpuUsagePercent: SystemCollector.cpuUsagePercent(),
                memory: memory,
                thermal: ThermalState(
                    systemThermalState: SystemCollector.thermalStateDescription(),
                    powermetricsPressure: nil,
                    smc: SMCCollector.read()
                ),
                power: PowerState(
                    cpuWatts: nil, gpuWatts: nil, aneWatts: nil, packageWatts: nil,
                    onBattery: battery.onBattery, batteryPercent: battery.percent,
                    adapterConnected: battery.adapter, lowPowerMode: battery.lowPower
                ),
                clusters: [], gpu: nil
            ))

            let fraction = 0.05 + 0.55 * (Double(i + 1) / Double(depth.samples))
            progress("Sampling… \(i + 1) of \(depth.samples)", fraction)
        }

        progress("Reading process table…", 0.68)
        let (scanned, processNote) = ProcessCollector.sample()
        if let processNote { degradations.append(processNote) }
        // Store the busiest few dozen, but run detection over everything scanned:
        // an idle-but-present daemon is a signal, and it would never make a
        // CPU-ranked top 40.
        var processes = Array(scanned.prefix(40))

        progress("Reading displays and applications…", 0.8)
        let (displays, displayNote) = DisplayCollector.read()
        if let displayNote { degradations.append(displayNote) }
        let apps = AppCollector.read()
        let storage = StorageCollector.read()
        let system = SystemCollector.read(processes: scanned)

        if instants.contains(where: { $0.thermal.smc == nil }) {
            degradations.append("SMC unreadable — no fan speed or die temperature")
        }

        progress("Correlating telemetry…", 0.9)
        switch await pmTask.value {
        case .success(let reading):
            // Align powermetrics samples onto the instants by index. Both loops run
            // at the same interval and start together, so index alignment is the
            // honest mapping; extra samples on either side are simply dropped.
            for (index, partial) in reading.instants.enumerated() where index < instants.count {
                instants[index].clusters = partial.clusters
                instants[index].gpu = partial.gpu
                instants[index].thermal.powermetricsPressure = partial.thermalPressure
                if let pmPower = partial.power {
                    instants[index].power?.cpuWatts = pmPower.cpuWatts
                    instants[index].power?.gpuWatts = pmPower.gpuWatts
                    instants[index].power?.aneWatts = pmPower.aneWatts
                    instants[index].power?.packageWatts = pmPower.packageWatts
                }
            }
            for i in processes.indices {
                if let task = reading.tasks[processes[i].pid] {
                    processes[i].energyImpact = task.energyImpact ?? processes[i].energyImpact
                    // powermetrics measures wakeups over its own sample window, which
                    // is a cleaner rate than differencing top's cumulative counters.
                    if let wakeups = task.idleWakeups { processes[i].idleWakeupsPerSec = wakeups }
                    processes[i].gpuMsPerSec = task.gpuMsPerSec
                    processes[i].diskReadBytes = task.diskReadBytes
                    processes[i].diskWriteBytes = task.diskWriteBytes
                }
            }
            if let samplers = reading.samplersUsed, samplers.contains("no per-process detail") {
                degradations.append("powermetrics ran without per-process detail (\(samplers))")
            }
        case .failure(let failure):
            degradations.append(failure.reason)
        }

        progress("Done", 1.0)
        return Snapshot(
            capturedAt: Date(),
            windowSeconds: window,
            machine: machine,
            instants: instants,
            processes: processes,
            apps: apps,
            displays: displays,
            storage: storage,
            system: system,
            degradations: degradations
        )
    }

    /// A single cheap read for the always-visible menu bar vitals. Deliberately
    /// avoids powermetrics and top so it can run every few seconds for free.
    static func vitals() -> Vitals {
        let (memory, _) = MemoryCollector.read()
        let smc = SMCCollector.read()
        return Vitals(
            memoryFootprintFraction: memory.footprintFraction,
            swapUsedBytes: memory.swapUsedBytes,
            swapFreeBytes: memory.swapFreeBytes,
            thermalState: SystemCollector.thermalStateDescription(),
            loadAverage1: {
                var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return l[0]
            }(),
            fanLoadFraction: smc?.maxFanLoad,
            fanRPM: smc?.fans.map(\.actualRPM).max(),
            cpuDieC: smc?.cpuDieC
        )
    }
}

struct Vitals: Equatable {
    var memoryFootprintFraction: Double
    var swapUsedBytes: UInt64
    var swapFreeBytes: UInt64
    var thermalState: String
    var loadAverage1: Double
    var fanLoadFraction: Double?
    var fanRPM: Double?
    var cpuDieC: Double?
}
