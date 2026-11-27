import Foundation

enum Severity: String, Codable, CaseIterable, Comparable {
    case info, elevated, high, critical

    var rank: Int {
        switch self {
        case .info: 0
        case .elevated: 1
        case .high: 2
        case .critical: 3
        }
    }
    static func < (l: Severity, r: Severity) -> Bool { l.rank < r.rank }

    var label: String {
        switch self {
        case .info: "Info"
        case .elevated: "Elevated"
        case .high: "High"
        case .critical: "Critical"
        }
    }
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .elevated: "exclamationmark.circle"
        case .high: "exclamationmark.triangle"
        case .critical: "flame"
        }
    }
}

enum FindingCategory: String, Codable, CaseIterable {
    case memory, cpu, gpu, thermal, power, display, storage, io, system

    var label: String {
        switch self {
        case .memory: "Memory"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .thermal: "Thermal"
        case .power: "Power"
        case .display: "Display"
        case .storage: "Storage"
        case .io: "Disk I/O"
        case .system: "System"
        }
    }
}

/// A measured, locally-derived observation. Findings are deterministic: the same
/// snapshot always produces the same findings. The model reasons over them, it
/// does not replace them.
struct Finding: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var category: FindingCategory
    var severity: Severity
    /// 0...1 — how sure the rule is that this is real, not how bad it is.
    var confidence: Double
    var evidence: [String]
    var culprits: [String]
    var remedy: String?
    /// How close to the machine's own ceiling this sits, when we can compute it.
    var headroomFraction: Double?
}

struct RemedyAction: Codable, Equatable, Identifiable {
    var id: String { title }
    var title: String
    var detail: String
    /// Shown for you to copy and run. Parasite never executes these itself.
    var command: String?
    var risk: String?
}

struct Verdict: Codable, Equatable {
    var primaryCause: String
    var explanation: String
    var confidence: String
    var contributingFactors: [String]
    var actionsNow: [RemedyAction]
    var actionsPreventive: [String]
    var watchFor: [String]
    var relatedPriorCases: [String]
    var modelUsed: String?
    var generatedAt: Date
    /// Kept so a malformed or surprising response can always be inspected.
    var rawResponse: String?
}

/// What the user was doing. Auto-detected where possible, always editable.
struct ActivityContext: Codable, Equatable {
    var tags: [String]
    var freeform: String
    var autoDetected: [String]
}

struct DiagnosticCase: Codable, Identifiable, Equatable {
    var id: UUID
    var createdAt: Date
    var symptom: String
    var feltSeverity: Severity
    var context: ActivityContext
    var snapshot: Snapshot
    var findings: [Finding]
    var verdict: Verdict?
    /// Filled in later by you, once you know whether the advice worked. This is
    /// what turns the library from a log into something that learns.
    var outcome: String?
    var outcomeConfirmed: Bool

    var title: String {
        symptom.isEmpty ? "Unlabelled capture" : symptom
    }

    var topFinding: Finding? {
        findings.max { a, b in
            (a.severity, a.confidence) < (b.severity, b.confidence)
        }
    }
}

/// A recurring co-occurrence mined from the case library. The "habit" half of
/// symptom-and-habit: not what you typed this time, but what keeps being true
/// whenever things go wrong.
struct HabitPattern: Codable, Identifiable, Equatable {
    var id: String
    var headline: String
    var detail: String
    var supportingCaseIDs: [UUID]
    var strength: Double        // 0...1
    var suggestion: String?

    var support: Int { supportingCaseIDs.count }
}

private func < (l: (Severity, Double), r: (Severity, Double)) -> Bool {
    l.0 == r.0 ? l.1 < r.1 : l.0 < r.0
}
