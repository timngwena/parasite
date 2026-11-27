import Foundation

/// Runs the analysis through the local `claude` CLI. Using the CLI rather than the
/// API means no API key to store and no separate billing — it reuses whatever
/// authentication you already have.
enum ClaudeAnalyst {

    enum AnalystError: LocalizedError {
        case cliNotFound
        case notAuthenticated
        case invocationFailed(String)
        case unparseable(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                "Could not find the `claude` command. Set its path in Parasite's settings, or install the Claude Code CLI."
            case .notAuthenticated:
                "The `claude` CLI is not signed in. Open Terminal, run `claude`, and sign in — then try again."
            case .invocationFailed(let detail):
                "The `claude` CLI failed: \(detail)"
            case .unparseable(let detail):
                "Could not read the model's reply as JSON. \(detail)"
            }
        }
    }

    /// GUI apps do not inherit your shell PATH, so the CLI has to be located
    /// explicitly. The login shell is asked last because it is the slowest route
    /// but the only one that respects a custom install location.
    static func locateCLI(override: String?) -> String? {
        if let override, !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) { return override }

        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }

        let r = Shell.run("/bin/zsh", ["-lc", "command -v claude"], timeout: 15)
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.ok && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
    }

    static func analyse(
        prompt: String,
        model: String,
        cliPathOverride: String?,
        timeout: TimeInterval = 240
    ) throws -> Verdict {
        let (payload, raw, modelUsed) = try runJSON(
            prompt: prompt, model: model, cliPathOverride: cliPathOverride,
            timeout: timeout, allowWeb: false
        )
        return decode(payload, raw: raw, model: modelUsed)
    }

    /// Runs one turn through the CLI and returns the first JSON object in the
    /// reply, the raw reply, and the model that answered.
    ///
    /// `allowWeb` exists for the laptop recommendation: which machines are
    /// actually on sale changes faster than any model's training data, so that
    /// one pass is allowed to look it up rather than recall it.
    static func runJSON(
        prompt: String,
        model: String,
        cliPathOverride: String?,
        timeout: TimeInterval,
        allowWeb: Bool
    ) throws -> (payload: [String: Any], raw: String, model: String) {
        guard let cli = locateCLI(override: cliPathOverride) else { throw AnalystError.cliNotFound }

        // The prompt is piped on stdin rather than passed as an argument: it is
        // several kilobytes of tables, which would risk the argument length limit
        // and would need careful shell quoting for no benefit.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parasite-prompt-\(UUID().uuidString).txt")
        try prompt.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        var arguments = [
            "-p",
            "--output-format", "json",
            "--model", model,
            // Session persistence and MCP servers are unnecessary for a single
            // reasoning turn, and each one costs startup time.
            "--no-session-persistence",
            "--strict-mcp-config"
        ]
        if allowWeb {
            arguments += ["--allowed-tools", "WebSearch", "WebFetch"]
            arguments += ["--disallowed-tools", "Bash", "Edit", "Write", "Agent"]
        } else {
            arguments += ["--disallowed-tools", "Bash", "Edit", "Write", "Read",
                          "WebSearch", "WebFetch", "Agent"]
        }
        proc.arguments = arguments
        // Inherit the real environment so the CLI finds its own credentials and any
        // ANTHROPIC_BASE_URL the user has configured.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [
            (env["PATH"] ?? ""), "/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin",
            "\(NSHomeDirectory())/.local/bin"
        ].joined(separator: ":")
        proc.environment = env
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory

        let inputHandle = try FileHandle(forReadingFrom: temp)
        proc.standardInput = inputHandle
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        do { try proc.run() } catch {
            throw AnalystError.invocationFailed("could not launch \(cli): \(error.localizedDescription)")
        }

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "parasite.analyst", attributes: .concurrent)
        group.enter(); q.async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if proc.isRunning {
            proc.terminate()
            _ = group.wait(timeout: .now() + 3)
            throw AnalystError.invocationFailed("timed out after \(Int(timeout))s")
        }
        group.wait()
        proc.waitUntilExit()
        try? inputHandle.close()

        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)

        guard let envelope = extractJSONObject(from: stdout) else {
            if stdout.isEmpty && !stderr.isEmpty {
                throw AnalystError.invocationFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw AnalystError.unparseable("The CLI produced no JSON envelope. Output began: \(stdout.prefix(300))")
        }

        // The CLI wraps the model's reply in its own result envelope, and reports
        // authentication and quota problems inside it with exit status 0.
        let resultText = (envelope["result"] as? String) ?? ""
        if (envelope["is_error"] as? Bool) == true {
            if resultText.localizedCaseInsensitiveContains("authenticate")
                || resultText.localizedCaseInsensitiveContains("oauth")
                || resultText.localizedCaseInsensitiveContains("login") {
                throw AnalystError.notAuthenticated
            }
            throw AnalystError.invocationFailed(resultText.isEmpty ? "unknown error" : resultText)
        }
        if resultText.isEmpty {
            throw AnalystError.unparseable("The CLI returned an empty result.")
        }

        guard let payload = extractJSONObject(from: resultText) else {
            throw AnalystError.unparseable("The model replied with prose rather than JSON. It said: \(resultText.prefix(400))")
        }

        // modelUsage can list several models when the CLI delegates sub-tasks.
        // Pick the one that did the most work rather than the first alphabetically,
        // which would credit a helper model for the whole answer.
        var modelUsed = model
        if let usage = envelope["modelUsage"] as? [String: Any], !usage.isEmpty {
            func tokens(_ any: Any?) -> Int {
                guard let d = any as? [String: Any] else { return 0 }
                let input = (d["inputTokens"] as? NSNumber)?.intValue ?? 0
                let output = (d["outputTokens"] as? NSNumber)?.intValue ?? 0
                return input + output
            }
            if let busiest = usage.max(by: { tokens($0.value) < tokens($1.value) })?.key {
                modelUsed = busiest
            }
        }
        return (payload, resultText, modelUsed)
    }

    // MARK: - Parsing

    /// Scans for the first balanced, brace-delimited object. This survives a model
    /// that wraps its JSON in a fenced code block or a preamble, and a login shell
    /// that prints a banner before the CLI's own output.
    static func extractJSONObject(from text: String) -> [String: Any]? {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            guard chars[index] == "{" else { index += 1; continue }
            var depth = 0
            var inString = false
            var escaped = false
            var cursor = index
            while cursor < chars.count {
                let ch = chars[cursor]
                if escaped {
                    escaped = false
                } else if ch == "\\" && inString {
                    escaped = true
                } else if ch == "\"" {
                    inString.toggle()
                } else if !inString {
                    if ch == "{" { depth += 1 }
                    if ch == "}" {
                        depth -= 1
                        if depth == 0 {
                            let candidate = String(chars[index...cursor])
                            if let data = candidate.data(using: .utf8),
                               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                return obj
                            }
                            break
                        }
                    }
                }
                cursor += 1
            }
            index += 1
        }
        return nil
    }

    private static func decode(_ d: [String: Any], raw: String, model: String) -> Verdict {
        func strings(_ key: String) -> [String] {
            if let a = d[key] as? [String] { return a }
            if let s = d[key] as? String, !s.isEmpty { return [s] }
            return []
        }

        var actions: [RemedyAction] = []
        if let raw = d["actionsNow"] as? [[String: Any]] {
            for a in raw {
                guard let title = a["title"] as? String, !title.isEmpty else { continue }
                actions.append(RemedyAction(
                    title: title,
                    detail: (a["detail"] as? String) ?? "",
                    command: (a["command"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    risk: (a["risk"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ))
            }
        } else {
            // Tolerate a model that returns plain strings where objects were asked for.
            actions = strings("actionsNow").map {
                RemedyAction(title: $0, detail: "", command: nil, risk: nil)
            }
        }

        return Verdict(
            primaryCause: (d["primaryCause"] as? String) ?? "The model did not name a primary cause.",
            explanation: (d["explanation"] as? String) ?? "",
            confidence: ((d["confidence"] as? String) ?? "unknown").lowercased(),
            contributingFactors: strings("contributingFactors"),
            actionsNow: actions,
            actionsPreventive: strings("actionsPreventive"),
            watchFor: strings("watchFor"),
            relatedPriorCases: strings("relatedPriorCases"),
            modelUsed: model,
            generatedAt: Date(),
            rawResponse: raw
        )
    }
}
