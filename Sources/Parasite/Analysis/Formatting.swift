import Foundation

enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(b) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        let kb = Double(b) / 1024
        if kb >= 1 { return String(format: "%.0f KB", kb) }
        return "\(b) B"
    }

    static func pct(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    static func pct1(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    static func num(_ d: Double, _ places: Int = 1) -> String {
        String(format: "%.\(places)f", d)
    }

    static func watts(_ w: Double) -> String {
        String(format: "%.1f W", w)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        let days = s / 86400, hours = (s % 86400) / 3600, mins = (s % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func ago(_ date: Date) -> String {
        relative.localizedString(for: date, relativeTo: Date())
    }

    static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy 'at' HH:mm"
        return f
    }()
}

/// How much of each of the machine's own ceilings is currently in use. This is
/// what makes a report specific to an M3 Max rather than generic advice.
struct Headroom: Codable, Equatable {
    var cpu: Double?
    var gpu: Double?
    var memory: Double?
    var swap: Double?
    var power: Double?
    var storage: Double?
    /// How far the fans are through their own RPM range.
    var fans: Double?

    /// The single tightest constraint, which is usually the thing to fix first.
    var tightest: (name: String, value: Double)? {
        let candidates: [(String, Double?)] = [
            ("CPU", cpu), ("GPU", gpu), ("Memory", memory),
            ("Swap", swap), ("SoC power", power), ("Disk", storage), ("Fan speed", fans)
        ]
        return candidates
            .compactMap { name, value in value.map { (name, $0) } }
            .max { $0.1 < $1.1 }
    }
}
