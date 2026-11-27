import Foundation

struct Distribution: Codable, Equatable {
    var p50: Double = 0
    var p90: Double = 0
    var p95: Double = 0
    var p99: Double = 0
    var peak: Double = 0
    var mean: Double = 0

    static func of(_ values: [Double]) -> Distribution {
        guard !values.isEmpty else { return Distribution() }
        let sorted = values.sorted()
        func at(_ q: Double) -> Double {
            let index = Int((Double(sorted.count - 1) * q).rounded())
            return sorted[max(0, min(sorted.count - 1, index))]
        }
        return Distribution(
            p50: at(0.50), p90: at(0.90), p95: at(0.95), p99: at(0.99),
            peak: sorted.last ?? 0,
            mean: values.reduce(0, +) / Double(values.count)
        )
    }
}

struct AppProfile: Codable, Equatable, Identifiable {
    var id: String { app }
    var app: String
    var coreHours: Double
    var peakRSSBytes: UInt64
    var meanRSSBytes: UInt64
    var foregroundHours: Double
    var peakProcessCount: Int
}

/// What the evidence says the next machine must do. Expressed as requirements
/// rather than product names: specs are what the data can actually support, and
/// the model lineup changes faster than this file would.
struct HardwareRequirement: Codable, Equatable {
    var memoryGB: Int
    var memoryRationale: String
    var memoryConfidence: String

    var performanceCores: Int
    var cpuRationale: String
    var singleThreadBound: Bool

    var gpuTier: String
    var gpuRationale: String

    var externalDisplays: Int
    var displayRationale: String

    var chassisNote: String
    var storageGB: Int?
    var storageRationale: String?

    /// Things the data cannot settle, stated so they are not silently assumed.
    var caveats: [String]
}

struct UsageProfile: Codable, Equatable {
    var machine: MachineProfile
    var startedAt: Date
    var lastSampleAt: Date?
    var observedHours: Double
    var activeHours: Double
    var calendarDays: Int
    var sampleCount: Int
    var diskBytes: UInt64

    // All computed over active (non-idle) samples only.
    var coresBusy: Distribution          // in cores
    var singleCore: Distribution         // fraction of one core
    var memoryFootprintGB: Distribution
    var gpuBusy: Distribution
    var swapUsedGB: Distribution
    /// Footprint plus swap measured at the SAME instant: how much memory the
    /// machine would have needed at that moment to not swap at all. Summing peak
    /// footprint and peak swap separately would add demands from different days.
    var concurrentDemandGB: Distribution
    var packageWatts: Distribution

    var hoursAboveMemory85: Double
    var hoursAboveCPU70: Double
    var hoursGPUAbove50: Double
    var hoursThermalNonNominal: Double
    var hoursFansAudible: Double
    var hoursOnBattery: Double
    var hoursWithExternalDisplay: Double
    var maxExternalDisplays: Int
    var maxExternalPixels: Int
    var peakSwapGB: Double
    /// How much swap GREW while we were watching. Peak swap alone is misleading:
    /// macOS does not release swap when pressure ends, so a large static figure
    /// can be a scar from last week rather than evidence of demand today.
    var swapGrowthGB: Double
    var swapGrowthEvents: Int

    var apps: [AppProfile]
    var events: [SpikeEvent]
    var eventCountsByKind: [String: Int]

    var requirement: HardwareRequirement

    var daysCollected: Double { observedHours / 24 }
    var isReadyForRecommendation: Bool { activeHours >= 20 }
}

enum UsageAnalyzer {

    /// Standard Apple unified-memory tiers. Sizing picks from these rather than
    /// inventing a number you cannot buy.
    static let memoryTiers = [8, 16, 18, 24, 32, 36, 48, 64, 96, 128, 256, 512]

    static func profile(samples: [UsageSample], appHours: [AppHour],
                        events: [SpikeEvent], state: MonitorState?,
                        machine: MachineProfile) -> UsageProfile {
        let cores = Double(max(1, machine.totalCores))
        let memoryGB = machine.memoryGB

        // Idle samples describe the machine sitting locked, not how you work.
        let active = samples.filter { !$0.idle }
        func hours(_ matching: (UsageSample) -> Bool) -> Double {
            active.filter(matching).reduce(0) { $0 + $1.span } / 3600
        }

        let observedSeconds = samples.reduce(0) { $0 + $1.span }
        let activeSeconds = active.reduce(0) { $0 + $1.span }

        let coresBusy = Distribution.of(active.map { $0.cpu * cores })
        let memoryDist = Distribution.of(active.map { Double($0.memFootprint) / 1_073_741_824 })
        let gpuDist = Distribution.of(active.map(\.gpu))
        let swapDist = Distribution.of(active.map { Double($0.swapUsed) / 1_073_741_824 })
        let concurrentDist = Distribution.of(active.map {
            Double($0.memFootprint &+ $0.swapUsed) / 1_073_741_824
        })
        let wattsDist = Distribution.of(active.compactMap(\.packageWatts))
        let singleDist = Distribution.of(active.map(\.cpu1))

        var merged: [String: AppUsage] = [:]
        for hour in appHours {
            for (app, usage) in hour.apps {
                merged[app, default: AppUsage()].merge(usage)
            }
        }
        // Each app sample covers one fast tick, not one written row. Using the
        // write interval here overstated foreground time by the ratio between them.
        let sampleHours = (state?.fastIntervalSeconds ?? 5) / 3600
        let apps = merged.map { app, usage in
            AppProfile(
                app: app,
                coreHours: usage.coreSeconds / 3600,
                peakRSSBytes: usage.peakRSS,
                meanRSSBytes: usage.meanRSS,
                foregroundHours: Double(usage.foregroundSamples) * sampleHours,
                peakProcessCount: usage.peakProcessCount
            )
        }.sorted { $0.coreHours > $1.coreHours }

        var counts: [String: Int] = [:]
        for e in events { counts[e.kind.rawValue, default: 0] += 1 }

        // Growth is measured against a running minimum, so a drop and a later
        // climb counts, while a flat high plateau does not.
        var swapGrowthGB = 0.0
        var runningMinSwap = Double.greatestFiniteMagnitude
        for sample in active {
            let gb = Double(sample.swapUsed) / 1_073_741_824
            runningMinSwap = min(runningMinSwap, gb)
            swapGrowthGB = max(swapGrowthGB, gb - runningMinSwap)
        }

        let maxExternal = active.map { $0.displays - 1 }.max() ?? 0
        let calendarDays: Int = {
            guard let first = samples.first?.t, let last = samples.last?.t else { return 0 }
            return max(1, Calendar.current.dateComponents([.day], from: first, to: last).day.map { $0 + 1 } ?? 1)
        }()

        var profile = UsageProfile(
            machine: machine,
            startedAt: state?.startedAt ?? samples.first?.t ?? Date(),
            lastSampleAt: samples.last?.t,
            observedHours: observedSeconds / 3600,
            activeHours: activeSeconds / 3600,
            calendarDays: calendarDays,
            sampleCount: samples.count,
            diskBytes: UsageStore.diskUsage(),
            coresBusy: coresBusy,
            singleCore: singleDist,
            memoryFootprintGB: memoryDist,
            gpuBusy: gpuDist,
            swapUsedGB: swapDist,
            concurrentDemandGB: concurrentDist,
            packageWatts: wattsDist,
            hoursAboveMemory85: hours { Double($0.memFootprint) / 1_073_741_824 > memoryGB * 0.85 },
            hoursAboveCPU70: hours { $0.cpu > 0.7 },
            hoursGPUAbove50: hours { $0.gpu > 0.5 },
            hoursThermalNonNominal: hours { $0.thermal != "Nominal" },
            hoursFansAudible: hours { ($0.fanLoad ?? 0) > 0.25 },
            hoursOnBattery: hours(\.onBattery),
            hoursWithExternalDisplay: hours { $0.displays > 1 },
            maxExternalDisplays: max(0, maxExternal),
            maxExternalPixels: active.map(\.externalPixels).max() ?? 0,
            peakSwapGB: swapDist.peak,
            swapGrowthGB: swapGrowthGB,
            swapGrowthEvents: counts[SpikeKind.swapGrowth.rawValue] ?? 0,
            apps: apps,
            events: events,
            eventCountsByKind: counts,
            requirement: HardwareRequirement(
                memoryGB: 0, memoryRationale: "", memoryConfidence: "",
                performanceCores: 0, cpuRationale: "", singleThreadBound: false,
                gpuTier: "", gpuRationale: "",
                externalDisplays: 0, displayRationale: "",
                chassisNote: "", storageGB: nil, storageRationale: nil, caveats: []
            )
        )
        profile.requirement = requirement(for: profile)
        return profile
    }

    // MARK: - Sizing

    private static func requirement(for p: UsageProfile) -> HardwareRequirement {
        var caveats: [String] = []
        if staleSwapNeedsLongerRun(p) {
            caveats.append("Swap was already high when monitoring began and has not moved since. Whether that reflects real demand will only become clear once the study covers a full working day including whatever last filled it.")
        }
        if p.activeHours < 40 {
            caveats.append("Only \(Fmt.num(p.activeHours, 1)) active hours observed. Treat percentiles above the 90th as provisional until there are at least a few days of real work.")
        }

        // --- Memory ---
        // Sizing from the 99th percentile rather than the peak: a single
        // allocation spike should not dictate the configuration, but sustained
        // high-water use should. 25% headroom on top, because a machine kept at
        // its memory ceiling behaves badly long before it runs out.
        let currentGB = p.machine.memoryGB
        var neededGB = p.memoryFootprintGB.p99 / 0.75
        var memoryReasons: [String] = [
            "99th-percentile memory in use was \(Fmt.num(p.memoryFootprintGB.p99, 1)) GB of \(Fmt.num(currentGB, 0)) GB, peaking at \(Fmt.num(p.memoryFootprintGB.peak, 1)) GB"
        ]

        // Swap that GREW while we watched is demand physical memory could not hold.
        // Swap that merely sits there is not: macOS never shrinks the swap file, so
        // a large static figure may be left over from work done before monitoring
        // began, and sizing from it would over-buy on the strength of a scar.
        let swapGrew = p.swapGrowthGB > 1 || p.swapGrowthEvents > 0
        if swapGrew {
            // Size from demand measured at a single instant. Adding accumulated
            // swap growth to a peak footprint from some other day double-counts:
            // pages written out on Tuesday and never read again are not part of
            // Thursday's working set. The concurrent figure already includes
            // everything resident plus everything displaced, so it needs only a
            // little headroom rather than another 25% on top.
            neededGB = max(neededGB, p.concurrentDemandGB.p95 / 0.9)
            memoryReasons.append("Taking footprint and swap together at each moment, demand reached \(Fmt.num(p.concurrentDemandGB.p95, 1)) GB at the 95th percentile and \(Fmt.num(p.concurrentDemandGB.peak, 1)) GB at peak — that is how much would have been needed to avoid swapping at all")
            memoryReasons.append("Swap grew by \(Fmt.num(p.swapGrowthGB, 1)) GB while monitoring ran, so this is current demand rather than a leftover")
        } else if staleSwapNeedsLongerRun(p) {
            memoryReasons.append("Swap sat at \(Fmt.num(p.peakSwapGB, 1)) GB but did not grow while monitoring ran. macOS never shrinks the swap file, so this is most likely left over from before the study started rather than evidence of demand now — it is not used to size memory, only noted")
        }
        let swapPressure = swapGrew
        if p.hoursAboveMemory85 > 1 {
            memoryReasons.append("\(Fmt.num(p.hoursAboveMemory85, 1)) hours were spent above 85% memory use")
        }
        let memoryGB = tier(atLeast: neededGB, notBelow: swapPressure ? nextTier(above: currentGB) : Int(currentGB.rounded()))

        // --- CPU ---
        let coreCount = Double(p.machine.totalCores)
        let p99Cores = p.coresBusy.p99
        // Single-thread bound means one thread is saturated and nothing else can
        // take up the slack. The busiest-process figure is a fraction of ONE core,
        // so a value near 1.0 is a pinned thread — but a value ABOVE 1.0 means the
        // process is spreading work across several threads, which is the opposite
        // conclusion. Without the upper bound this fires on exactly the
        // multithreaded workloads that more cores would help.
        let pinnedThread = p.singleCore.p95 >= 0.85 && p.singleCore.p95 <= 1.15
        let singleBound = pinnedThread && p.coresBusy.p95 < coreCount * 0.45
        var cpuReasons = [
            "99th-percentile demand was \(Fmt.num(p99Cores, 1)) of \(Int(coreCount)) cores; the median was \(Fmt.num(p.coresBusy.p50, 1))"
        ]
        var recommendedCores = p.machine.performanceCores
        if p99Cores > coreCount * 0.8 {
            recommendedCores = Int((Double(p.machine.performanceCores) * 1.4).rounded())
            cpuReasons.append("Demand reached the limit of what this machine has, so more cores would shorten your longest waits")
        } else if singleBound {
            cpuReasons.append("The busiest process sat at \(Fmt.pct(p.singleCore.p95)) of a single core — a pinned thread — while the machine as a whole stayed under half busy. More cores will not help this; single-core speed will")
        } else if p99Cores < coreCount * 0.45 {
            recommendedCores = max(4, Int((Double(p.machine.performanceCores) * 0.7).rounded()))
            cpuReasons.append("Even at the 99th percentile you used under half the cores you have, so a lower CPU tier would not have slowed you down")
        } else {
            cpuReasons.append("Your current core count is well matched — occasionally stretched, rarely exhausted")
        }

        // --- GPU ---
        var gpuTier = "same as current"
        var gpuReasons = [
            "GPU was \(Fmt.pct(p.gpuBusy.p50)) busy at the median, \(Fmt.pct(p.gpuBusy.p95)) at the 95th percentile"
        ]
        if p.gpuBusy.p95 > 0.7 {
            gpuTier = "higher"
            gpuReasons.append("Sustained GPU load of this level is the main argument for a higher GPU core count")
        } else if p.gpuBusy.p95 < 0.25 {
            gpuTier = "lower would be fine"
            gpuReasons.append("The GPU was mostly idle — paying for a larger one would buy you nothing measurable")
        }
        if p.hoursGPUAbove50 > 2 {
            gpuReasons.append("\(Fmt.num(p.hoursGPUAbove50, 1)) hours above 50% GPU")
        }

        // --- Thermal / chassis ---
        var chassis: String
        if p.hoursThermalNonNominal > 2 {
            chassis = "Thermal pressure was present for \(Fmt.num(p.hoursThermalNonNominal, 1)) hours, which is the argument for the larger chassis — it sustains the same load with less throttling."
        } else if p.hoursFansAudible > 4 {
            chassis = "Fans were audible for \(Fmt.num(p.hoursFansAudible, 1)) hours without the system reporting thermal pressure. That is noise rather than a performance limit; a larger chassis would mainly buy quiet."
        } else {
            chassis = "Heat was never a limiting factor in this period, so chassis size is a preference rather than a performance decision."
        }

        if p.hoursOnBattery > p.activeHours * 0.3 {
            caveats.append("You were on battery for \(Fmt.pct(p.hoursOnBattery / max(p.activeHours, 0.01))) of active time. Apple Silicon does not throttle much on battery, but battery life is worth weighting in the decision and this data cannot measure it.")
        }
        if p.events.isEmpty {
            caveats.append("No spike events were recorded, so the extremes here come from the regular sampling and may have missed short bursts.")
        }

        return HardwareRequirement(
            memoryGB: memoryGB,
            memoryRationale: memoryReasons.joined(separator: ". ") + ".",
            memoryConfidence: p.activeHours >= 80 ? "high" : (p.activeHours >= 20 ? "medium" : "low"),
            performanceCores: recommendedCores,
            cpuRationale: cpuReasons.joined(separator: ". ") + ".",
            singleThreadBound: singleBound,
            gpuTier: gpuTier,
            gpuRationale: gpuReasons.joined(separator: ". ") + ".",
            externalDisplays: p.maxExternalDisplays,
            displayRationale: p.maxExternalDisplays == 0
                ? "No external display was attached, so display support does not constrain the choice."
                : p.maxExternalDisplays == 1
                    ? "You drove one external display (up to \(Fmt.num(Double(p.maxExternalPixels) / 1_000_000, 1))M pixels) for \(Fmt.num(p.hoursWithExternalDisplay, 1)) hours. Every current Apple Silicon laptop drives one external display, so this does not constrain the chip tier."
                    : "You drove \(p.maxExternalDisplays) external displays (up to \(Fmt.num(Double(p.maxExternalPixels) / 1_000_000, 1))M pixels) for \(Fmt.num(p.hoursWithExternalDisplay, 1)) hours. Base-tier chips cap the number of external displays, so this does set a floor on the chip tier.",
            chassisNote: chassis,
            storageGB: nil,
            storageRationale: nil,
            caveats: caveats
        )
    }

    private static func staleSwapNeedsLongerRun(_ p: UsageProfile) -> Bool {
        p.peakSwapGB > 4 && p.swapGrowthGB <= 1 && p.swapGrowthEvents == 0
    }

    private static func tier(atLeast needed: Double, notBelow floor: Int) -> Int {
        let chosen = memoryTiers.first { Double($0) >= needed } ?? memoryTiers.last!
        return max(chosen, floor)
    }

    private static func nextTier(above current: Double) -> Int {
        memoryTiers.first { Double($0) > current + 0.5 } ?? Int(current.rounded())
    }
}
