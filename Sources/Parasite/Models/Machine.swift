import Foundation

/// What this machine is physically capable of. Findings are scored against this
/// envelope rather than against absolute numbers, so "80% busy" means something
/// different on an M3 Max than it would on a base M3.
struct MachineProfile: Codable, Equatable {
    var modelIdentifier: String        // e.g. Mac15,10
    var chip: String                   // e.g. Apple M3 Max
    var chassis: String?               // e.g. 14-inch
    var performanceCores: Int
    var efficiencyCores: Int
    var gpuCores: Int?
    var memoryBytes: UInt64
    var adapterWatts: Int?

    // Derived envelope. Nil when we have no trustworthy figure for this chip —
    // we would rather say "unknown" than score against a number we invented.
    var memoryBandwidthGBs: Double?
    var sustainedPackageWatts: Double?
    var peakPackageWatts: Double?
    var thermalHeadroomNote: String?

    var totalCores: Int { performanceCores + efficiencyCores }
    var memoryGB: Double { Double(memoryBytes) / 1_073_741_824.0 }

    var summary: String {
        var parts = ["\(chip)"]
        if let chassis { parts.append(chassis) }
        parts.append("\(totalCores)-core CPU (\(performanceCores)P/\(efficiencyCores)E)")
        if let gpuCores { parts.append("\(gpuCores)-core GPU") }
        parts.append(String(format: "%.0f GB unified memory", memoryGB))
        return parts.joined(separator: " · ")
    }
}

/// Known power/bandwidth envelopes. These are the figures that let us say
/// "you are at the chip's sustained limit" instead of "CPU is busy".
enum ChipEnvelope {
    struct Entry {
        let bandwidthGBs: Double
        let sustainedWatts: Double
        let peakWatts: Double
    }

    /// Keyed by chip name + GPU core count, because the binned variants differ
    /// materially in memory bandwidth (the 30-core M3 Max is 300 GB/s, the
    /// 40-core is 400 GB/s) and that ceiling is what video work actually hits.
    static func lookup(chip: String, gpuCores: Int?) -> Entry? {
        let c = chip.lowercased()
        switch (c, gpuCores ?? 0) {
        case let (n, g) where n.contains("m3 max") && g <= 30:
            return Entry(bandwidthGBs: 300, sustainedWatts: 55, peakWatts: 78)
        case let (n, _) where n.contains("m3 max"):
            return Entry(bandwidthGBs: 400, sustainedWatts: 60, peakWatts: 92)
        case let (n, _) where n.contains("m3 pro"):
            return Entry(bandwidthGBs: 150, sustainedWatts: 35, peakWatts: 48)
        case let (n, _) where n.contains("m3"):
            return Entry(bandwidthGBs: 100, sustainedWatts: 20, peakWatts: 30)
        case let (n, g) where n.contains("m4 max") && g <= 32:
            return Entry(bandwidthGBs: 410, sustainedWatts: 58, peakWatts: 85)
        case let (n, _) where n.contains("m4 max"):
            return Entry(bandwidthGBs: 546, sustainedWatts: 65, peakWatts: 100)
        case let (n, _) where n.contains("m4 pro"):
            return Entry(bandwidthGBs: 273, sustainedWatts: 38, peakWatts: 55)
        case let (n, _) where n.contains("m2 max"):
            return Entry(bandwidthGBs: 400, sustainedWatts: 55, peakWatts: 79)
        case let (n, _) where n.contains("m1 max"):
            return Entry(bandwidthGBs: 400, sustainedWatts: 50, peakWatts: 72)
        default:
            return nil
        }
    }
}
