import Foundation

/// The "habit" half of the picture. A single case tells you what you were doing;
/// the library tells you what keeps being true whenever things go wrong. These
/// patterns are derived, never typed in.
enum PatternMiner {

    /// Patterns need something to be a pattern over. Below this many cases the
    /// output would be noise dressed up as insight, so nothing is claimed.
    static let minimumCases = 3

    static func mine(_ cases: [DiagnosticCase]) -> [HabitPattern] {
        guard cases.count >= minimumCases else { return [] }
        var patterns: [HabitPattern] = []
        patterns += recurringCauses(cases)
        patterns += tagCorrelations(cases)
        patterns += repeatOffenders(cases)
        patterns += uptimeCorrelation(cases)
        patterns += timeOfDayClusters(cases)
        return patterns.sorted { $0.strength > $1.strength }
    }

    // MARK: - Recurring root causes

    private static func recurringCauses(_ cases: [DiagnosticCase]) -> [HabitPattern] {
        var buckets: [String: [DiagnosticCase]] = [:]
        for c in cases {
            for f in c.findings where f.severity >= .high {
                buckets[stripPID(f.id), default: []].append(c)
            }
        }
        return buckets.compactMap { id, matching in
            guard matching.count >= 2 else { return nil }
            let share = Double(matching.count) / Double(cases.count)
            guard share >= 0.4 else { return nil }
            let title = matching.first?.findings.first { stripPID($0.id) == id }?.title ?? id
            return HabitPattern(
                id: "cause.\(id)",
                headline: "\"\(title)\" is behind \(matching.count) of your \(cases.count) captures",
                detail: "This is not an incident, it is the shape of your setup. Fixing it once removes a recurring class of symptom rather than one occurrence.",
                supportingCaseIDs: matching.map(\.id),
                strength: min(1, share + 0.2),
                suggestion: matching.compactMap { $0.findings.first { stripPID($0.id) == id }?.remedy }.first
            )
        }
    }

    // MARK: - Activity correlation

    private static func tagCorrelations(_ cases: [DiagnosticCase]) -> [HabitPattern] {
        var tagCases: [String: [DiagnosticCase]] = [:]
        for c in cases {
            for t in Set(c.context.tags.map { $0.lowercased() }) {
                tagCases[t, default: []].append(c)
            }
        }
        let baselineSevere = Double(cases.filter { ($0.topFinding?.severity ?? .info) >= .high }.count)
            / Double(cases.count)

        return tagCases.compactMap { tag, matching in
            guard matching.count >= 2 else { return nil }
            let severe = Double(matching.filter { ($0.topFinding?.severity ?? .info) >= .high }.count)
                / Double(matching.count)
            // Only interesting if this activity is worse than your own baseline;
            // a tag present in every case explains nothing.
            guard severe > baselineSevere + 0.2, severe > 0.5 else { return nil }
            let causes = Set(matching.compactMap { $0.topFinding.map { stripPID($0.id) } })
            return HabitPattern(
                id: "tag.\(tag)",
                headline: "\"\(tag)\" goes wrong more often than your average session",
                detail: "\(Fmt.pct(severe)) of captures tagged \"\(tag)\" reached high severity, against \(Fmt.pct(baselineSevere)) across everything. Usual culprit\(causes.count == 1 ? "" : "s"): \(causes.sorted().joined(separator: ", ")).",
                supportingCaseIDs: matching.map(\.id),
                strength: min(1, severe),
                suggestion: nil
            )
        }
    }

    // MARK: - Repeat offenders

    private static func repeatOffenders(_ cases: [DiagnosticCase]) -> [HabitPattern] {
        var counts: [String: [DiagnosticCase]] = [:]
        for c in cases {
            let culprits = Set(c.findings.filter { $0.severity >= .elevated }
                .flatMap(\.culprits).map(normalise).filter { !$0.isEmpty })
            for culprit in culprits { counts[culprit, default: []].append(c) }
        }
        return counts.compactMap { name, matching in
            guard matching.count >= 3 else { return nil }
            let share = Double(matching.count) / Double(cases.count)
            guard share >= 0.5 else { return nil }
            return HabitPattern(
                id: "offender.\(name)",
                headline: "\(name) turns up in \(matching.count) of \(cases.count) captures",
                detail: "Across unrelated symptoms, this keeps appearing among the contributors. That makes it a standing condition of your setup rather than a coincidence.",
                supportingCaseIDs: matching.map(\.id),
                strength: min(1, share),
                suggestion: nil
            )
        }
    }

    // MARK: - Uptime

    private static func uptimeCorrelation(_ cases: [DiagnosticCase]) -> [HabitPattern] {
        let withUptime = cases.map { ($0, $0.snapshot.system.uptimeSeconds / 86400) }
        let severe = withUptime.filter { ($0.0.topFinding?.severity ?? .info) >= .high }
        let calm = withUptime.filter { ($0.0.topFinding?.severity ?? .info) < .high }
        guard severe.count >= 2, calm.count >= 2 else { return [] }

        let severeAvg = severe.map(\.1).reduce(0, +) / Double(severe.count)
        let calmAvg = calm.map(\.1).reduce(0, +) / Double(calm.count)
        // A meaningful gap, not just any gap: at least two days and a clear ratio.
        guard severeAvg > calmAvg * 1.6, severeAvg - calmAvg > 2 else { return [] }

        return [HabitPattern(
            id: "habit.uptime",
            headline: "Your bad sessions happen after the machine has been up a long time",
            detail: "Captures that reached high severity averaged \(Fmt.num(severeAvg, 1)) days of uptime; the calm ones averaged \(Fmt.num(calmAvg, 1)). That gap points at something accumulating rather than at what you happen to be running.",
            supportingCaseIDs: severe.map(\.0.id),
            strength: min(1, (severeAvg - calmAvg) / 14 + 0.4),
            suggestion: "Restarting roughly every \(Fmt.num(max(2, calmAvg * 1.5), 0)) days would keep you inside the range where things behave."
        )]
    }

    // MARK: - Time of day

    private static func timeOfDayClusters(_ cases: [DiagnosticCase]) -> [HabitPattern] {
        let severe = cases.filter { ($0.topFinding?.severity ?? .info) >= .high }
        guard severe.count >= 3 else { return [] }

        let calendar = Calendar.current
        var hourBuckets: [Int: [DiagnosticCase]] = [:]
        for c in severe {
            // Three-hour bands: finer than that and every case is its own cluster.
            let band = (calendar.component(.hour, from: c.createdAt) / 3) * 3
            hourBuckets[band, default: []].append(c)
        }
        guard let (band, matching) = hourBuckets.max(by: { $0.value.count < $1.value.count }),
              matching.count >= 3,
              Double(matching.count) / Double(severe.count) > 0.5
        else { return [] }

        return [HabitPattern(
            id: "habit.timeofday",
            headline: "Most of your bad sessions land between \(band):00 and \(band + 3):00",
            detail: "\(matching.count) of \(severe.count) high-severity captures fall in this window. Worth checking what is scheduled then — backups, indexing, sync, or simply your heaviest meetings.",
            supportingCaseIDs: matching.map(\.id),
            strength: Double(matching.count) / Double(severe.count),
            suggestion: "Compare against Time Machine, Spotlight indexing and cloud sync schedules."
        )]
    }

    // MARK: - Helpers

    private static func stripPID(_ id: String) -> String {
        let parts = id.split(separator: ".")
        guard let last = parts.last, Int(last) != nil else { return id }
        return parts.dropLast().joined(separator: ".")
    }

    private static func normalise(_ s: String) -> String {
        String(s.split(separator: "(").first ?? "").trimmingCharacters(in: .whitespaces)
    }
}
