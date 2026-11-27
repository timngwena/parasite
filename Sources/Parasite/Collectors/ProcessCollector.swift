import Foundation

enum ProcessCollector {
    /// How many processes to ask top for. Higher than we display, because signals
    /// like "is a camera daemon doing work" need the whole picture, not the top 40.
    static let scanLimit = 250

    /// `top` is used rather than `ps` because ps reports %CPU averaged over a
    /// process's entire lifetime — a process that hammered the CPU an hour ago
    /// still looks busy to ps. top's later samples are true deltas over the
    /// interval, which is the only thing that answers "what is busy right now".
    ///
    /// Three samples rather than two: idle-wakeup counters are cumulative since
    /// process start, so a rate needs two comparable delta-ordered blocks to
    /// subtract. Sample one is lifetime-averaged and cannot be used for either.
    static func sample() -> (processes: [ProcessSample], note: String?) {
        let intervalSeconds = 1.0
        let top = Shell.run("/usr/bin/top",
                            ["-l", "3", "-s", "\(Int(intervalSeconds))",
                             "-o", "cpu", "-n", "\(scanLimit)",
                             "-stats", "pid,cpu,mem,idlew,th,command"],
                            timeout: 30)
        guard top.ok else {
            return ([], "top failed: \(top.stderr.isEmpty ? "exit \(top.exitCode)" : top.stderr)")
        }

        let blocks = parseBlocks(top.stdout)
        guard let latest = blocks.last else {
            return ([], "could not locate top's process table")
        }
        // The block before last gives the baseline for cumulative counters.
        let previous = blocks.count >= 2 ? blocks[blocks.count - 2] : [:]

        let identities = identities()
        let total = Double(Shell.sysctlInt("hw.memsize") ?? 0)
        var rows: [ProcessSample] = []

        for (pid, row) in latest {
            let identity = identities[pid]

            // Wakeups are only reported when a real rate can be computed. A
            // cumulative figure presented as a rate would be wrong by orders of
            // magnitude on a long-running daemon, which is exactly the kind of
            // false alarm this app must not raise.
            var wakeupRate: Double?
            if let now = row.idleWakeups, let before = previous[pid]?.idleWakeups, now >= before {
                wakeupRate = Double(now - before) / intervalSeconds
            }

            rows.append(ProcessSample(
                pid: pid,
                name: identity?.name ?? row.command,
                path: identity?.path,
                cpuPercent: row.cpu,
                memoryPercent: total > 0 ? Double(row.resident) / total * 100 : 0,
                residentBytes: row.resident,
                elapsed: identity?.elapsed,
                // Populated only from powermetrics: top's POWER column simply
                // mirrors CPU% on Apple Silicon, so reporting it as energy would
                // dress one measurement up as two.
                energyImpact: nil,
                gpuMsPerSec: nil,
                diskReadBytes: nil,
                diskWriteBytes: nil,
                idleWakeupsPerSec: wakeupRate
            ))
        }

        rows.sort { $0.cpuPercent > $1.cpuPercent }
        return (rows, rows.isEmpty ? "top returned no parseable rows" : nil)
    }

    // MARK: - top parsing

    private struct Row {
        var cpu: Double
        var resident: UInt64
        var idleWakeups: UInt64?
        var threads: String
        var command: String
        var footprintGrowing: Bool
    }

    private static func parseBlocks(_ output: String) -> [[Int32: Row]] {
        var blocks: [[Int32: Row]] = []
        var current: [Int32: Row]?

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("PID") {
                if let current { blocks.append(current) }
                current = [:]
                continue
            }
            guard current != nil else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // COMMAND is last and may contain spaces, so it takes the remainder.
            let fields = trimmed.split(separator: " ", maxSplits: 5,
                                       omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 6, let pid = Int32(fields[0]) else { continue }
            current?[pid] = Row(
                cpu: Double(fields[1]) ?? 0,
                resident: parseSize(fields[2]),
                idleWakeups: parseCounter(fields[3]),
                threads: fields[4],
                command: fields[5].trimmingCharacters(in: .whitespaces),
                footprintGrowing: fields[2].hasSuffix("+")
            )
        }
        if let current { blocks.append(current) }
        return blocks
    }

    // MARK: - Identity

    private struct Identity { var name: String; var path: String?; var elapsed: String? }

    /// top truncates COMMAND to the column width, so the full name comes from ps.
    ///
    /// `comm` is used rather than `args` deliberately: macOS application paths
    /// contain spaces ("/Applications/Google Chrome.app/…"), and splitting argv on
    /// whitespace truncates them mid-path. comm is the executable path alone, so it
    /// survives intact.
    private static func identities() -> [Int32: Identity] {
        let r = Shell.run("/bin/ps", ["-Ao", "pid=,etime=,comm="], timeout: 15)
        guard r.ok else { return [:] }

        let roles = helperRoles()
        var map: [Int32: Identity] = [:]
        for line in r.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 2,
                                      omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3, let pid = Int32(parts[0]) else { continue }
            let executable = parts[2]
            map[pid] = Identity(
                name: displayName(executable: executable, role: roles[pid]),
                path: executable.hasPrefix("/") ? executable : nil,
                elapsed: parts[1]
            )
        }
        return map
    }

    /// Chromium and Electron helpers all share one binary, so the only way to tell
    /// a renderer from a GPU process is the --type= argument.
    private static func helperRoles() -> [Int32: String] {
        let r = Shell.run("/bin/ps", ["-Ao", "pid=,args="], timeout: 15)
        guard r.ok else { return [:] }
        var roles: [Int32: String] = [:]
        for line in r.stdout.components(separatedBy: "\n") {
            guard let typeRange = line.range(of: "--type=") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let pidField = trimmed.split(separator: " ").first,
                  let pid = Int32(pidField) else { continue }
            let role = String(line[typeRange.upperBound...].prefix { !$0.isWhitespace })
            if !role.isEmpty { roles[pid] = role }
        }
        return roles
    }

    /// Prefers the .app bundle name over the raw binary path, so a report says
    /// "Google Chrome Helper (renderer)" rather than a 140-character path.
    private static func displayName(executable: String, role: String?) -> String {
        let components = executable.split(separator: "/").map(String.init)
        guard let appIndex = components.lastIndex(where: { $0.hasSuffix(".app") }) else {
            return components.last ?? executable
        }
        let bundle = String(components[appIndex].dropLast(4))
        // Some helpers already name their role in the bundle itself ("Claude Helper
        // (Renderer).app"), so appending --type= would repeat it.
        if let role, !bundle.localizedCaseInsensitiveContains(role) {
            return "\(bundle) (\(role))"
        }
        return bundle
    }

    /// top marks any column that changed since the previous sample with a trailing
    /// '+' or '-', including the counter columns. A strict integer parse therefore
    /// fails on exactly the rows that are changing — the ones worth measuring.
    private static func parseCounter(_ raw: String) -> UInt64? {
        let digits = raw.prefix { $0.isNumber }
        return digits.isEmpty ? nil : UInt64(digits)
    }

    private static func parseSize(_ raw: String) -> UInt64 {
        // top appends '+' or '-' to mark a footprint that grew or shrank since the
        // previous sample.
        var s = raw
        while let last = s.last, last == "+" || last == "-" { s.removeLast() }
        guard let unit = s.last else { return 0 }
        let numeric = Double(s.dropLast()) ?? 0
        switch unit {
        case "K": return UInt64(numeric * 1024)
        case "M": return UInt64(numeric * 1024 * 1024)
        case "G": return UInt64(numeric * 1024 * 1024 * 1024)
        case "T": return UInt64(numeric * 1024 * 1024 * 1024 * 1024)
        default:  return UInt64(Double(s) ?? 0)
        }
    }
}
