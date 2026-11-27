import Foundation

struct ProcessSample: Codable, Identifiable, Equatable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var path: String?
    var cpuPercent: Double
    var memoryPercent: Double
    var residentBytes: UInt64
    var elapsed: String?

    // Only populated when powermetrics is available.
    var energyImpact: Double?
    var gpuMsPerSec: Double?
    var diskReadBytes: UInt64?
    var diskWriteBytes: UInt64?
    var idleWakeupsPerSec: Double?

    /// Collapses helper processes (Chrome Helper, Electron renderers) onto the
    /// app they belong to, because "Chrome is using 180% CPU across 9 helpers"
    /// is the useful sentence, not nine separate 20% lines.
    var family: String {
        let n = name
        if n.contains("Google Chrome Helper") || n == "Google Chrome" { return "Google Chrome" }
        if n.contains("Safari") { return "Safari" }
        if n.contains("Teams") || n.contains("MSTeams") { return "Microsoft Teams" }
        if n.contains("Slack") { return "Slack" }
        if n.contains("Code Helper") || n == "Electron" { return "Electron app" }
        if n.contains("Descript") { return "Descript" }
        if n.contains("Final Cut") { return "Final Cut Pro" }
        return n
    }
}

struct RunningApp: Codable, Equatable {
    var name: String
    var bundleID: String?
    var isActive: Bool
    var isHidden: Bool
    var launchedAt: Date?
}

struct DisplayInfo: Codable, Equatable {
    var name: String
    var isMain: Bool
    var isBuiltIn: Bool
    /// The framebuffer the GPU actually renders into.
    var pixelWidth: Int
    var pixelHeight: Int
    /// The logical desktop size in points.
    var pointWidth: Int
    var pointHeight: Int
    /// The panel's own maximum addressable resolution, when it could be read.
    var nativePixelWidth: Int?
    var nativePixelHeight: Int?
    var refreshHz: Double?
    var backingScale: Double

    var pixelCount: Int { pixelWidth * pixelHeight }
    var nativePixelCount: Int? {
        guard let w = nativePixelWidth, let h = nativePixelHeight else { return nil }
        return w * h
    }

    /// The costly case, and the one macOS presents as "More Space": the framebuffer
    /// is larger than the panel, so every frame is rendered oversized and then
    /// resampled down to fit. It is a continuous GPU and memory-bandwidth tax.
    ///
    /// Note this is NOT the same as a fractional backing scale — a 3600x2338
    /// framebuffer on a 3024x1964 panel has an exactly 2.0 point ratio while still
    /// rendering 41% more pixels than the screen can show.
    var isRenderingAboveNative: Bool {
        guard let native = nativePixelCount, native > 0 else { return false }
        return pixelCount > native + (native / 100)
    }

    var overRenderFactor: Double? {
        guard let native = nativePixelCount, native > 0 else { return nil }
        return Double(pixelCount) / Double(native)
    }

    /// A non-integer backing scale, which forces a resample for a different reason.
    var isFractionallyScaled: Bool {
        guard pointWidth > 0 else { return false }
        let ratio = Double(pixelWidth) / Double(pointWidth)
        return abs(ratio - ratio.rounded()) > 0.01
    }

    var isNonNative: Bool { isRenderingAboveNative || isFractionallyScaled }

    /// Pixels the compositor must produce every second. A far better proxy for
    /// WindowServer load than resolution alone, because a 120Hz panel costs twice
    /// what the same panel costs at 60Hz.
    var pixelThroughputPerSecond: Double {
        Double(pixelCount) * (refreshHz ?? 60)
    }

    var description: String {
        var s = "\(name) \(pixelWidth)x\(pixelHeight)"
        if pointWidth != pixelWidth { s += " (desktop \(pointWidth)x\(pointHeight))" }
        if let w = nativePixelWidth, let h = nativePixelHeight, w != pixelWidth || h != pixelHeight {
            s += " on a \(w)x\(h) panel"
        }
        if let refreshHz, refreshHz > 0 { s += String(format: " @%.0fHz", refreshHz) }
        return s
    }
}

struct MemoryState: Codable, Equatable {
    var totalBytes: UInt64
    var freeBytes: UInt64
    var activeBytes: UInt64
    var inactiveBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var purgeableBytes: UInt64
    var swapTotalBytes: UInt64
    var swapUsedBytes: UInt64
    var swapFreeBytes: UInt64
    var pageInsPerSec: Double?
    var pageOutsPerSec: Double?
    var swapInsPerSec: Double?
    var swapOutsPerSec: Double?
    var pressurePercent: Double?

    var swapUsedFraction: Double {
        swapTotalBytes == 0 ? 0 : Double(swapUsedBytes) / Double(swapTotalBytes)
    }
    var footprintBytes: UInt64 { activeBytes &+ wiredBytes &+ compressedBytes }
    var footprintFraction: Double {
        totalBytes == 0 ? 0 : Double(footprintBytes) / Double(totalBytes)
    }
}

struct StorageState: Codable, Equatable {
    var volumeName: String
    var totalBytes: UInt64
    var freeBytes: UInt64
    var freeFraction: Double { totalBytes == 0 ? 0 : Double(freeBytes) / Double(totalBytes) }
}

struct ThermalState: Codable, Equatable {
    /// From ProcessInfo.thermalState — available without root.
    var systemThermalState: String
    /// From powermetrics, root only.
    var powermetricsPressure: String?
    /// From the SMC over IOKit — no root required.
    var smc: SMCCollector.Reading?

    var fanRPM: [Double]? {
        guard let smc, !smc.fans.isEmpty else { return nil }
        return smc.fans.map(\.actualRPM)
    }
    var cpuDieTemperatureC: Double? { smc?.cpuDieC }
    var gpuDieTemperatureC: Double? { smc?.gpuDieC }
    var fanLoadFraction: Double? { smc?.maxFanLoad }
}

struct PowerState: Codable, Equatable {
    var cpuWatts: Double?
    var gpuWatts: Double?
    var aneWatts: Double?
    var packageWatts: Double?
    var onBattery: Bool
    var batteryPercent: Double?
    var adapterConnected: Bool
    var lowPowerMode: Bool
}

struct ClusterResidency: Codable, Equatable {
    var name: String                 // E-Cluster, P0-Cluster...
    var activeRatio: Double          // 0...1
    var averageFrequencyMHz: Double?
    var maxFrequencyMHz: Double?

    /// Load without frequency is ambiguous: a cluster pinned at 100% but held at
    /// a low frequency is being throttled, which is a different story from a
    /// cluster at 100% running flat out.
    var frequencyFraction: Double? {
        guard let a = averageFrequencyMHz, let m = maxFrequencyMHz, m > 0 else { return nil }
        return a / m
    }
}

struct GPUState: Codable, Equatable {
    var busyRatio: Double?
    var frequencyMHz: Double?
    var maxFrequencyMHz: Double?
}

struct SystemState: Codable, Equatable {
    var uptimeSeconds: Double
    var bootedAt: Date
    var loadAverage1: Double
    var loadAverage5: Double
    var loadAverage15: Double
    var processCount: Int
    var threadCount: Int?
    var osVersion: String
    var cameraInUse: Bool?
    var microphoneInUse: Bool?
    var screenRecordingActive: Bool?
}

/// One instant inside a capture window. Capturing several and diffing them is
/// what separates "memory is full" from "memory is filling up right now".
struct Instant: Codable, Equatable {
    var at: Date
    var cpuUsagePercent: Double
    var memory: MemoryState
    var thermal: ThermalState
    var power: PowerState?
    var clusters: [ClusterResidency]
    var gpu: GPUState?
}

struct Snapshot: Codable, Equatable {
    var capturedAt: Date
    var windowSeconds: Double
    var machine: MachineProfile
    var instants: [Instant]
    var processes: [ProcessSample]
    var apps: [RunningApp]
    var displays: [DisplayInfo]
    var storage: StorageState
    var system: SystemState
    /// Anything a collector could not read, and why. Surfaced in the UI so a
    /// missing signal never quietly becomes a wrong conclusion.
    var degradations: [String]

    var latest: Instant? { instants.last }
    var first: Instant? { instants.first }

    var totalDrivenPixels: Int { displays.reduce(0) { $0 + $1.pixelCount } }

    /// Total pixels per second across every attached display.
    var totalPixelThroughput: Double {
        displays.reduce(0) { $0 + $1.pixelThroughputPerSecond }
    }

    func processFamilies() -> [(name: String, cpu: Double, memory: UInt64, count: Int)] {
        var map: [String: (Double, UInt64, Int)] = [:]
        for p in processes {
            var e = map[p.family] ?? (0, 0, 0)
            e.0 += p.cpuPercent
            e.1 &+= p.residentBytes
            e.2 += 1
            map[p.family] = e
        }
        return map.map { (name: $0.key, cpu: $0.value.0, memory: $0.value.1, count: $0.value.2) }
            .sorted { $0.cpu > $1.cpu }
    }
}
