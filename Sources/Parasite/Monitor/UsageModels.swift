import Foundation

/// One cheap reading of the whole machine. Taken every few seconds, aggregated,
/// and written once a minute — so it has to stay small: two weeks of these is
/// about 20,000 rows.
struct UsageSample: Codable, Equatable {
    var t: Date
    /// Seconds this row represents. Lets a gap (sleep, daemon restart) be told
    /// apart from a stretch of genuine idleness when the data is read back.
    var span: Double

    // CPU as a fraction of ALL cores, 0...1. Mean and peak over the span.
    var cpu: Double
    var cpuPeak: Double
    /// The busiest single process over the span, as a fraction of one core.
    /// A workload pinned here is single-thread bound, and more cores will not help.
    var cpu1: Double

    var memFootprint: UInt64
    var memPeak: UInt64
    var memWired: UInt64
    var memCompressed: UInt64
    var swapUsed: UInt64
    var swapOutRate: Double

    var gpu: Double
    var gpuPeak: Double
    var gpuMemInUse: UInt64

    var thermal: String
    var fanLoad: Double?
    var cpuDieC: Double?
    /// Only present on the slower powermetrics cadence.
    var packageWatts: Double?

    var displays: Int
    var externalPixels: Int
    var onBattery: Bool
    var frontmostApp: String?
    /// True when the screen was locked or asleep — excluded from "how you work".
    var idle: Bool
}

/// What one application cost over one hour. Accumulated in memory and flushed
/// hourly, rather than stored per sample, which keeps two weeks of per-app detail
/// to a few hundred kilobytes.
struct AppUsage: Codable, Equatable {
    /// CPU seconds consumed. 3600 core-seconds in an hour means one core pinned.
    var coreSeconds: Double = 0
    var peakRSS: UInt64 = 0
    /// Sum of resident bytes across samples, for a time-weighted mean.
    var rssSum: Double = 0
    var samples: Int = 0
    /// Samples where this app was frontmost — actual attention, not background cost.
    var foregroundSamples: Int = 0
    var peakProcessCount: Int = 0
    var peakGPUMem: UInt64 = 0

    var meanRSS: UInt64 { samples == 0 ? 0 : UInt64(rssSum / Double(samples)) }

    mutating func merge(_ other: AppUsage) {
        coreSeconds += other.coreSeconds
        peakRSS = max(peakRSS, other.peakRSS)
        rssSum += other.rssSum
        samples += other.samples
        foregroundSamples += other.foregroundSamples
        peakProcessCount = max(peakProcessCount, other.peakProcessCount)
        peakGPUMem = max(peakGPUMem, other.peakGPUMem)
    }
}

struct AppHour: Codable, Equatable {
    var hour: Date
    var apps: [String: AppUsage]
}

/// Why a spike capture fired.
enum SpikeKind: String, Codable, CaseIterable {
    /// `singleCore` is retained so events recorded before it was retired still
    /// decode, but it is no longer raised — see MonitorDaemon.checkSpikes.
    case cpuSaturation, memoryPressure, swapGrowth, thermal, fanRamp, gpuSaturation, singleCore

    var label: String {
        switch self {
        case .cpuSaturation: "CPU saturated"
        case .memoryPressure: "Memory pressure"
        case .swapGrowth: "Swap growing"
        case .thermal: "Thermal pressure"
        case .fanRamp: "Fans ramped"
        case .gpuSaturation: "GPU saturated"
        case .singleCore: "Single core pinned"
        }
    }

    /// What this spike implies about a future machine. The point of recording
    /// spikes is not to alarm you but to say which spec would have absorbed them.
    var buyingImplication: String {
        switch self {
        case .cpuSaturation: "Sustained demand for every core — more cores would absorb this."
        case .memoryPressure: "The working set exceeded physical memory — more RAM would absorb this."
        case .swapGrowth: "Paging to disk. The strongest single argument for more RAM."
        case .thermal: "Heat limited performance — a larger chassis or more efficient chip would absorb this."
        case .fanRamp: "Sustained power draw. Audible, but not necessarily a performance limit."
        case .gpuSaturation: "GPU-bound work — more GPU cores would absorb this."
        case .singleCore: "One thread is the bottleneck. More cores will NOT help; single-core speed will."
        }
    }
}

/// A richer capture taken when something crosses a threshold. These are the
/// moments that actually constrain the next machine, so they get full detail.
struct SpikeEvent: Codable, Identifiable, Equatable {
    var id: UUID
    var at: Date
    var kind: SpikeKind
    var severity: Severity
    var headline: String
    var sample: UsageSample
    /// Top processes at the moment it fired.
    var processes: [ProcessSlice]
    var frontmostApp: String?
    var runningApps: [String]
    var note: String?
}

struct ProcessSlice: Codable, Equatable {
    var name: String
    var app: String
    var cpuFraction: Double
    var rss: UInt64
}

/// Monitor bookkeeping, so the view can say how much of the two weeks is done
/// and whether collection actually ran.
struct MonitorState: Codable, Equatable {
    var startedAt: Date
    var lastSampleAt: Date?
    var totalSamples: Int = 0
    var totalEvents: Int = 0
    /// Wall-clock seconds the machine was awake and sampled.
    var observedSeconds: Double = 0
    var daemonVersion: Int = 1
    /// Seconds between per-process samples. Anything turning a sample count into
    /// a duration needs this: the cadence changed once already, and the
    /// conversions that hard-coded a minute silently reported 12x the real time.
    var fastIntervalSeconds: Double = 5

    init(startedAt: Date, lastSampleAt: Date? = nil, totalSamples: Int = 0,
         totalEvents: Int = 0, observedSeconds: Double = 0,
         daemonVersion: Int = 1, fastIntervalSeconds: Double = 5) {
        self.startedAt = startedAt
        self.lastSampleAt = lastSampleAt
        self.totalSamples = totalSamples
        self.totalEvents = totalEvents
        self.observedSeconds = observedSeconds
        self.daemonVersion = daemonVersion
        self.fastIntervalSeconds = fastIntervalSeconds
    }

    /// Decoded field by field, because Swift's synthesised Codable treats a
    /// missing key as an error even when the property has a default. Adding one
    /// field made every existing state file undecodable, which silently reset the
    /// study's start date and counters. Every field here is optional on read so
    /// that never happens again.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        lastSampleAt = try c.decodeIfPresent(Date.self, forKey: .lastSampleAt)
        totalSamples = try c.decodeIfPresent(Int.self, forKey: .totalSamples) ?? 0
        totalEvents = try c.decodeIfPresent(Int.self, forKey: .totalEvents) ?? 0
        observedSeconds = try c.decodeIfPresent(Double.self, forKey: .observedSeconds) ?? 0
        daemonVersion = try c.decodeIfPresent(Int.self, forKey: .daemonVersion) ?? 1
        fastIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .fastIntervalSeconds) ?? 5
    }
}
