import Foundation
import Observation
import AppKit

enum RunPhase: Equatable {
    case idle
    case capturing(message: String, progress: Double)
    case scoring
    case reasoning
    case done
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .capturing, .scoring, .reasoning: true
        default: false
        }
    }
}

@Observable
@MainActor
final class AppState {
    let library = CaseLibrary()
    let settings = Settings()

    var phase: RunPhase = .idle
    var vitals: Vitals?
    /// The case currently on screen — either just produced or opened from history.
    var current: DiagnosticCase?
    /// Set when the model step fails but the local findings are still good. The
    /// case is saved regardless, so a failed reasoning step never loses the capture.
    var analysisWarning: String?
    var patterns: [HabitPattern] = []

    private var vitalsTimer: Timer?

    init() {
        refreshPatterns()
        refreshVitals()
        startVitalsTimer()
    }

    // MARK: - Vitals

    func startVitalsTimer() {
        vitalsTimer?.invalidate()
        vitalsTimer = Timer.scheduledTimer(
            withTimeInterval: settings.vitalsRefreshSeconds, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshVitals() }
        }
    }

    func refreshVitals() {
        // Deliberately synchronous and cheap: this reads mach counters and one
        // sysctl, so it costs less than dispatching it would.
        vitals = SnapshotCollector.vitals()
    }

    func refreshPatterns() {
        patterns = PatternMiner.mine(library.cases)
    }

    // MARK: - The main flow

    func runDiagnosis(
        symptom: String,
        feltSeverity: Severity,
        tags: [String],
        freeform: String,
        depth: CaptureDepth
    ) async {
        analysisWarning = nil
        phase = .capturing(message: "Starting capture…", progress: 0)

        let snapshot = await SnapshotCollector.capture(depth: depth) { [weak self] message, fraction in
            Task { @MainActor in
                self?.phase = .capturing(message: message, progress: fraction)
            }
        }

        phase = .scoring
        let findings = HeuristicEngine.analyse(snapshot)
        let headroom = HeuristicEngine.headroom(snapshot)

        var item = DiagnosticCase(
            id: UUID(),
            createdAt: Date(),
            symptom: symptom,
            feltSeverity: feltSeverity,
            context: ActivityContext(
                tags: tags,
                freeform: freeform,
                autoDetected: Self.autoDetect(snapshot)
            ),
            snapshot: snapshot,
            findings: findings,
            verdict: nil,
            outcome: nil,
            outcomeConfirmed: false
        )

        // Save before reasoning. A capture is expensive and unrepeatable — the
        // machine will not be in this state again — so it must never be lost
        // because a later step failed.
        library.save(item)
        current = item

        guard settings.useModel else {
            phase = .done
            refreshPatterns()
            return
        }

        phase = .reasoning
        let priors = library.similar(to: item)
        let prompt = PromptBuilder.build(
            symptom: symptom,
            feltSeverity: feltSeverity,
            context: item.context,
            snapshot: snapshot,
            findings: findings,
            headroom: headroom,
            priorCases: priors,
            patterns: patterns
        )

        let model = settings.model
        let override = settings.cliPath
        do {
            let verdict = try await Task.detached(priority: .userInitiated) {
                try ClaudeAnalyst.analyse(prompt: prompt, model: model, cliPathOverride: override)
            }.value
            item.verdict = verdict
            library.save(item)
            current = item
            phase = .done
        } catch {
            // The local findings stand on their own; say what was lost and move on.
            analysisWarning = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .done
        }
        refreshPatterns()
    }

    /// Re-runs only the reasoning step against a capture already on disk. Useful
    /// after signing the CLI in, or to compare models on the same evidence.
    func reanalyse(_ item: DiagnosticCase) async {
        var item = item
        analysisWarning = nil
        phase = .reasoning
        let priors = library.similar(to: item)
        let prompt = PromptBuilder.build(
            symptom: item.symptom,
            feltSeverity: item.feltSeverity,
            context: item.context,
            snapshot: item.snapshot,
            findings: item.findings,
            headroom: HeuristicEngine.headroom(item.snapshot),
            priorCases: priors,
            patterns: patterns
        )
        let model = settings.model
        let override = settings.cliPath
        do {
            let verdict = try await Task.detached(priority: .userInitiated) {
                try ClaudeAnalyst.analyse(prompt: prompt, model: model, cliPathOverride: override)
            }.value
            item.verdict = verdict
            library.save(item)
            current = item
            phase = .done
        } catch {
            analysisWarning = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .done
        }
    }

    func recordOutcome(_ item: DiagnosticCase, outcome: String, confirmed: Bool) {
        var item = item
        item.outcome = outcome
        item.outcomeConfirmed = confirmed
        library.save(item)
        if current?.id == item.id { current = item }
        refreshPatterns()
    }

    func delete(_ item: DiagnosticCase) {
        library.delete(item)
        if current?.id == item.id { current = nil }
        refreshPatterns()
    }

    // MARK: - Context auto-detection

    /// Guesses what you were doing so the capture sheet starts with something true
    /// rather than an empty box. Everything here is presented for you to confirm.
    static func autoDetect(_ s: Snapshot) -> [String] {
        var detected: [String] = []

        let interesting: [(match: [String], tag: String)] = [
            (["microsoft teams", "msteams"], "Teams call"),
            (["zoom"], "Zoom call"),
            (["slack"], "Slack"),
            (["descript"], "Editing in Descript"),
            (["final cut"], "Final Cut Pro"),
            (["premiere"], "Premiere Pro"),
            (["davinci"], "DaVinci Resolve"),
            (["after effects"], "After Effects"),
            (["photoshop"], "Photoshop"),
            (["docker", "orbstack"], "Containers running"),
            (["xcode"], "Xcode"),
            (["parallels", "vmware", "utm"], "Virtual machine"),
            (["blender"], "Blender"),
            (["handbrake"], "Encoding video"),
            (["obs"], "Screen recording / OBS"),
            (["google chrome"], "Chrome"),
            (["safari"], "Safari")
        ]
        let appNames = s.apps.map { $0.name.lowercased() }
        for entry in interesting where entry.match.contains(where: { needle in appNames.contains { $0.contains(needle) } }) {
            detected.append(entry.tag)
        }

        if s.system.microphoneInUse == true { detected.append("Microphone live") }
        if s.system.cameraInUse == true { detected.append("Camera in use") }

        let externals = s.displays.filter { !$0.isBuiltIn }
        if !externals.isEmpty {
            detected.append(externals.count == 1
                            ? "External display (\(externals[0].name))"
                            : "\(externals.count) external displays")
        }
        if s.displays.contains(where: \.isNonNative) {
            detected.append("Scaled resolution in use")
        }
        if s.latest?.power?.onBattery == true { detected.append("On battery") }
        if s.latest?.power?.lowPowerMode == true { detected.append("Low Power Mode") }
        if s.system.uptimeSeconds > 86400 * 5 {
            detected.append("Uptime \(Fmt.duration(s.system.uptimeSeconds))")
        }
        return detected
    }

    // MARK: - Export

    /// Writes the whole case, evidence included, as JSON. The point is that a
    /// capture can leave the app — for a support thread, or a future agent that
    /// reads the library directly.
    func exportCurrent() -> URL? {
        guard let current else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(current) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parasite-case-\(current.id.uuidString.prefix(8)).json")
        try? data.write(to: url)
        return url
    }

    func revealLibrary() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: CaseLibrary.casesDirectory.path)
    }
}
