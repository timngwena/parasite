import Foundation

/// A headless path through the same collectors and engine the GUI uses.
///
/// Two reasons it exists: it makes the diagnostic layer testable without clicking
/// anything, and it is the hook for unattended capture later — a scheduled job or
/// a log-watching agent can call this and read the JSON.
enum CLIRunner {

    static func run() {
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }

        let depth: CaptureDepth = {
            if args.contains("--quick") { return .quick }
            if args.contains("--deep") { return .deep }
            return .standard
        }()
        let wantsJSON = args.contains("--json")
        let wantsPrompt = args.contains("--prompt")
        let wantsAnalysis = args.contains("--analyse") || args.contains("--analyze")
        let symptom = value(after: "--symptom", in: args) ?? ""
        let tags = (value(after: "--tags", in: args) ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if !wantsJSON {
            FileHandle.standardError.write(
                Data("Capturing for \(Int(depth.seconds))s…\n".utf8))
        }

        let snapshot = blocking { await SnapshotCollector.capture(depth: depth) { message, _ in
            if !wantsJSON {
                FileHandle.standardError.write(Data("  \(message)\n".utf8))
            }
        }}

        let findings = HeuristicEngine.analyse(snapshot)
        let headroom = HeuristicEngine.headroom(snapshot)

        let library = CaseLibrary()
        let patterns = PatternMiner.mine(library.cases)

        var item = DiagnosticCase(
            id: UUID(), createdAt: Date(),
            symptom: symptom, feltSeverity: .high,
            context: ActivityContext(
                tags: tags, freeform: "",
                autoDetected: MainActor.assumeIsolated { AppState.autoDetect(snapshot) }
            ),
            snapshot: snapshot, findings: findings, verdict: nil,
            outcome: nil, outcomeConfirmed: false
        )

        let prompt = PromptBuilder.build(
            symptom: symptom, feltSeverity: .high, context: item.context,
            snapshot: snapshot, findings: findings, headroom: headroom,
            priorCases: library.similar(to: item), patterns: patterns
        )

        if wantsPrompt { print(prompt); exit(0) }

        if wantsAnalysis {
            let settings = MainActor.assumeIsolated { Settings() }
            do {
                item.verdict = try ClaudeAnalyst.analyse(
                    prompt: prompt, model: settings.model, cliPathOverride: settings.cliPath
                )
            } catch {
                FileHandle.standardError.write(Data(
                    "analysis failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)\n".utf8))
            }
        }

        if args.contains("--save") { library.save(item) }

        if wantsJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(item), let s = String(data: data, encoding: .utf8) {
                print(s)
            }
        } else {
            printReport(snapshot, findings: findings, headroom: headroom,
                        verdict: item.verdict, patterns: patterns, caseCount: library.cases.count)
        }
        exit(0)
    }

    // MARK: - Output

    private static func printReport(
        _ s: Snapshot, findings: [Finding], headroom: Headroom,
        verdict: Verdict?, patterns: [HabitPattern], caseCount: Int
    ) {
        print("")
        print("MACHINE")
        print("  \(s.machine.summary)")
        print("  \(s.machine.modelIdentifier) · \(s.system.osVersion) · up \(Fmt.duration(s.system.uptimeSeconds))")
        if let bw = s.machine.memoryBandwidthGBs { print("  memory bandwidth ceiling \(Fmt.num(bw, 0)) GB/s") }
        if let sustained = s.machine.sustainedPackageWatts {
            print("  SoC envelope about \(Fmt.watts(sustained)) sustained")
        }

        print("")
        print("HEADROOM")
        func bar(_ name: String, _ v: Double?) {
            guard let v else { print("  \(name.padded(34)) not measured"); return }
            let filled = Int((min(1, v) * 24).rounded())
            let track = String(repeating: "#", count: filled) + String(repeating: ".", count: 24 - filled)
            print("  \(name.padded(34)) [\(track)] \(Fmt.pct(min(1.5, v)))")
        }
        bar("CPU sustained (\(s.machine.totalCores) cores)", headroom.cpu)
        bar("GPU", headroom.gpu)
        bar("Physical memory", headroom.memory)
        bar("Swap", headroom.swap)
        bar("SoC power vs sustained", headroom.power)
        bar("Disk used", headroom.storage)
        if let t = headroom.tightest {
            print("  tightest constraint: \(t.name) at \(Fmt.pct(min(1.5, t.value)))")
        }

        print("")
        print("FINDINGS (\(findings.count))")
        if findings.isEmpty {
            print("  nothing crossed a threshold")
        }
        for f in findings {
            print("  [\(f.severity.label.uppercased())] \(f.title)   (\(f.category.label), confidence \(Fmt.pct(f.confidence)))")
            for e in f.evidence { print("      · \(e)") }
            if !f.culprits.isEmpty { print("      implicated: \(f.culprits.joined(separator: "; "))") }
            if let r = f.remedy { print("      → \(r)") }
        }

        if !s.degradations.isEmpty {
            print("")
            print("NOT MEASURED")
            for d in s.degradations { print("  · \(d)") }
        }

        if let v = verdict {
            print("")
            print("VERDICT (\(v.modelUsed ?? "model"), confidence \(v.confidence))")
            print("  \(v.primaryCause)")
            if !v.explanation.isEmpty { print("  \(v.explanation)") }
            if !v.contributingFactors.isEmpty {
                print("  also contributing:")
                for f in v.contributingFactors { print("    · \(f)") }
            }
            if !v.actionsNow.isEmpty {
                print("  do now:")
                for a in v.actionsNow {
                    print("    · \(a.title)")
                    if !a.detail.isEmpty { print("      \(a.detail)") }
                    if let c = a.command { print("      $ \(c)") }
                }
            }
            if !v.actionsPreventive.isEmpty {
                print("  prevent:")
                for a in v.actionsPreventive { print("    · \(a)") }
            }
        }

        if !patterns.isEmpty {
            print("")
            print("HABITS (from \(caseCount) stored cases)")
            for p in patterns.prefix(5) {
                print("  · \(p.headline) [strength \(Fmt.pct(p.strength)), \(p.support) cases]")
            }
        }
        print("")
    }

    private static func printUsage() {
        print("""
        parasite --cli [options]

        Captures the machine, scores it against this hardware's limits, and reports.

          --quick | --deep      capture window (default: standard, 10s)
          --symptom "text"      what you are experiencing
          --tags "a,b,c"        activity context tags
          --analyse             also run the reasoning pass through the claude CLI
          --save                store the result in the case library
          --json                emit the full case as JSON instead of text
          --prompt              print the analysis prompt and exit (no model call)
          --help

        Examples:
          parasite --cli --deep --symptom "fans spun up while editing video"
          parasite --cli --json --save --analyse --symptom "screen freezing in Teams"
        """)
    }

    // MARK: - Helpers

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let next = args[i + 1]
        return next.hasPrefix("--") ? nil : next
    }

    /// Bridges the async collector into a synchronous command-line entry point.
    private static func blocking<T>(_ operation: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached(priority: .userInitiated) {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }
}

/// Boxed result so the detached task can write back across the semaphore without
/// the compiler objecting to escaping mutable state.
private final class ResultBox<V>: @unchecked Sendable {
    var value: V?
}

private extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
