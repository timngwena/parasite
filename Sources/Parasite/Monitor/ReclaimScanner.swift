import Foundation
import AppKit
import Darwin

/// One running application, with what it is costing and how long since you last
/// looked at it.
struct AppCandidate: Identifiable, Equatable {
    var id: String { bundleID ?? name }
    var name: String
    var bundleID: String?
    var pid: Int32
    var processCount: Int
    /// Physical footprint — the figure Activity Monitor calls "Memory". Resident
    /// size understates an app that has been partly paged out; footprint is what
    /// it is actually charged for.
    var footprintBytes: UInt64
    var peakFootprintBytes: UInt64
    /// Filled in only by the deep scan, which is slow.
    var swappedBytes: UInt64?
    var lastForegroundAt: Date?
    var foregroundHours: Double
    var isFrontmost: Bool
    var launchedAt: Date?
    /// Apps Parasite will not offer to quit, and why.
    var protectionReason: String?
    /// Every process attributed to this app, so a quit can be costed properly.
    var pids: [Int32] = []
    /// True when swappedBytes covers only some of the app's processes.
    var swapIsLowerBound: Bool = false

    var isProtected: Bool { protectionReason != nil }

    var idleInterval: TimeInterval? {
        guard let lastForegroundAt else { return nil }
        return Date().timeIntervalSince(lastForegroundAt)
    }

    var idleDescription: String {
        if isFrontmost { return "in use now" }
        guard let interval = idleInterval else { return "never in front while monitoring" }
        return "last used \(Fmt.duration(interval)) ago"
    }

    /// Memory weighted by how long it has gone untouched. Something holding 4 GB
    /// that you have not looked at all day ranks above something holding 6 GB you
    /// were using ten minutes ago.
    var reclaimScore: Double {
        guard !isProtected, !isFrontmost else { return 0 }
        let gb = Double(footprintBytes) / 1_073_741_824
        guard let interval = idleInterval else { return gb }   // never seen in front
        // Ramps to full weight over four hours of disuse.
        let idleWeight = min(1, interval / (4 * 3600))
        return gb * idleWeight
    }
}

struct ReclaimLedger: Equatable {
    /// Footprint attributed to windowed applications.
    var attributedToApps: UInt64 = 0
    /// Footprint of your other processes: menu-bar agents, CLIs, daemons.
    var otherUserProcesses: UInt64 = 0
    /// Processes owned by root, which a user agent cannot read at all.
    var unreadableProcessCount: Int = 0
    var readableProcessCount: Int = 0

    var totalReadable: UInt64 { attributedToApps &+ otherUserProcesses }
}

enum ReclaimScanner {

    /// Applications Parasite never offers to quit. Finder and the app itself are
    /// obvious; the rest are system UI whose loss would be confusing rather than
    /// helpful, and which hold little memory anyway.
    private static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.loginwindow", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.Spotlight", "com.apple.WindowServer", "local.parasite.diagnostics"
    ]

    /// A live inventory. Cheap enough to refresh on every view appearance:
    /// one NSWorkspace read plus a rusage call per process.
    static func scan(history: [UsageSample] = [], appHours: [AppHour] = [])
    -> (candidates: [AppCandidate], ledger: ReclaimLedger) {
        let running = NSWorkspace.shared.runningApplications
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let lastSeen = lastForegroundTimes(history: history)
        let foregroundHours = foregroundTotals(
            appHours: appHours,
            intervalSeconds: UsageStore.loadState()?.fastIntervalSeconds ?? 5
        )
        let regularNames = running.filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
        let (processesByApp, ledger) = footprintsByOwningApp(
            helperOwners: helperOwners(running: running, regularNames: regularNames)
        )

        var out: [AppCandidate] = []
        for app in running {
            // Only windowed applications. Menu-bar agents and daemons are covered
            // by the usage study; quitting them breaks things for little memory.
            guard app.activationPolicy == .regular else { continue }
            let name = app.localizedName ?? app.bundleIdentifier ?? "unknown"
            let bundleID = app.bundleIdentifier

            let group = processesByApp[name] ?? (footprint: 0, peak: 0, count: 0, pids: [])
            // Fall back to the main process alone if nothing grouped onto it.
            var footprint = group.footprint
            var peak = group.peak
            var count = group.count
            var pids = group.pids
            if footprint == 0, let direct = processFootprint(app.processIdentifier) {
                footprint = direct.phys
                peak = direct.peak
                count = 1
                pids = [app.processIdentifier]
            }

            var protection: String?
            if let bundleID, protectedBundleIDs.contains(bundleID) {
                protection = "System app — Parasite will not quit this"
            }
            if bundleID == Bundle.main.bundleIdentifier {
                protection = "This is Parasite"
            }

            out.append(AppCandidate(
                name: name,
                bundleID: bundleID,
                pid: app.processIdentifier,
                processCount: max(1, count),
                footprintBytes: footprint,
                peakFootprintBytes: peak,
                swappedBytes: nil,
                lastForegroundAt: app.isActive ? Date() : lastSeen[name],
                foregroundHours: foregroundHours[name] ?? 0,
                isFrontmost: bundleID != nil && bundleID == frontmost,
                launchedAt: app.launchDate,
                protectionReason: protection,
                pids: pids
            ))
        }
        // Split the ledger now that we know which names are windowed apps.
        let appNames = Set(out.map(\.name))
        var finalLedger = ledger
        finalLedger.attributedToApps = out.reduce(0) { $0 &+ $1.footprintBytes }
        finalLedger.otherUserProcesses = processesByApp
            .filter { !appNames.contains($0.key) }
            .reduce(0) { $0 &+ $1.value.footprint }

        return (out.sorted { $0.reclaimScore > $1.reclaimScore }, finalLedger)
    }

    /// Maps helper processes back to the application that owns them.
    ///
    /// WebKit content, GPU and networking processes, and AutoFill services, are
    /// XPC services reparented to launchd, so their ppid is 1 and the process tree
    /// is useless. They do not live inside the owner's bundle either, so the path
    /// says "com.apple.WebKit.WebContent". But NSWorkspace names them after their
    /// owner — "Ardia Web Content", "AutoFill (1Password)" — and that is the only
    /// link available. Without this a browser's web content, often the single
    /// largest block of memory on the machine, is attributed to nobody.
    private static func helperOwners(running: [NSRunningApplication],
                                     regularNames: [String]) -> [Int32: String] {
        // Longest first, so "Microsoft Teams" wins over a hypothetical "Microsoft".
        let owners = regularNames.sorted { $0.count > $1.count }
        var out: [Int32: String] = [:]
        for app in running where app.activationPolicy != .regular {
            guard let helperName = app.localizedName else { continue }
            for owner in owners where !owner.isEmpty {
                if helperName == owner
                    || helperName.hasPrefix(owner + " ")
                    || helperName.contains("(" + owner + ")")
                    || helperName.contains("(" + owner + ".app)") {
                    out[app.processIdentifier] = owner
                    break
                }
            }
        }
        return out
    }

    // MARK: - Footprint

    /// Physical footprint per process, grouped under the owning application, so a
    /// browser's forty helpers read as one number.
    private static func footprintsByOwningApp(helperOwners: [Int32: String])
    -> ([String: (footprint: UInt64, peak: UInt64, count: Int, pids: [Int32])], ReclaimLedger) {
        var out: [String: (UInt64, UInt64, Int, [Int32])] = [:]
        var ledger = ReclaimLedger()
        let processes = FastCollectors.processes()

        // processes() already drops what it cannot read, so the shortfall has to be
        // measured against the kernel's own pid count rather than counted here.
        ledger.unreadableProcessCount = max(0, FastCollectors.totalProcessCount() - processes.count)

        for reading in processes {
            guard let f = processFootprint(reading.pid) else { continue }
            ledger.readableProcessCount += 1
            // The NSWorkspace mapping takes precedence: it knows ownership the
            // executable path cannot express.
            let owner = helperOwners[reading.pid] ?? reading.app
            var entry = out[owner] ?? (0, 0, 0, [])
            entry.0 &+= f.phys
            entry.1 &+= f.peak
            entry.2 += 1
            entry.3.append(reading.pid)
            out[owner] = entry
        }
        return (out.mapValues { (footprint: $0.0, peak: $0.1, count: $0.2, pids: $0.3) }, ledger)
    }

    static func processFootprint(_ pid: Int32) -> (phys: UInt64, peak: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }   // another user's process
        return (info.ri_phys_footprint, info.ri_lifetime_max_phys_footprint)
    }

    // MARK: - History

    /// When each app was last the frontmost one, from the study's own samples.
    /// Resolution is the sample interval, which is a minute — plenty for deciding
    /// whether you have touched something today.
    private static func lastForegroundTimes(history: [UsageSample]) -> [String: Date] {
        var out: [String: Date] = [:]
        for sample in history {
            guard let app = sample.frontmostApp else { continue }
            if let existing = out[app], existing >= sample.t { continue }
            out[app] = sample.t
        }
        return out
    }

    private static func foregroundTotals(appHours: [AppHour],
                                         intervalSeconds: Double) -> [String: Double] {
        var out: [String: Double] = [:]
        let hoursPerSample = intervalSeconds / 3600
        for hour in appHours {
            for (app, usage) in hour.apps {
                out[app, default: 0] += Double(usage.foregroundSamples) * hoursPerSample
            }
        }
        return out
    }

    // MARK: - Deep scan

    /// How much of each app has been pushed out to swap.
    ///
    /// `vmmap` walks the entire VM map of the target, which costs hundreds of
    /// milliseconds per process and can take seconds for a browser. It is never
    /// run by the monitor — only here, on demand, for the handful of apps you are
    /// actually considering.
    /// Swapped-out bytes across an application's processes.
    ///
    /// Capped at `budget` processes because vmmap walks the entire VM map of each
    /// target — seconds apiece for a browser. The result is therefore a lower
    /// bound when an app has more processes than the budget allows, and says so.
    static func swappedBytes(forApp candidate: AppCandidate, budget: Int = 4)
    -> (bytes: UInt64, isLowerBound: Bool)? {
        let ranked = candidate.pids
            .compactMap { pid -> (Int32, UInt64)? in
                processFootprint(pid).map { (pid, $0.phys) }
            }
            .sorted { $0.1 > $1.1 }
        guard !ranked.isEmpty else { return nil }

        let targets = ranked.prefix(budget)
        var total: UInt64 = 0
        var measured = 0
        for (pid, _) in targets {
            if let bytes = swappedBytes(for: pid) {
                total &+= bytes
                measured += 1
            }
        }
        guard measured > 0 else { return nil }
        return (total, ranked.count > targets.count)
    }

    static func swappedBytes(for pid: Int32, timeout: TimeInterval = 20) -> UInt64? {
        let result = Shell.run("/usr/bin/vmmap", ["--summary", "\(pid)"], timeout: timeout)
        guard result.ok || !result.stdout.isEmpty else { return nil }
        for line in result.stdout.components(separatedBy: "\n") {
            guard line.hasPrefix("TOTAL") else { continue }
            // TOTAL  VIRTUAL RESIDENT DIRTY SWAPPED VOLATILE NONVOL EMPTY REGION
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 5 else { continue }
            return parseVMMapSize(fields[4])
        }
        return nil
    }

    /// vmmap prints sizes as "254.8M", "1.3G", "482K" or "0K".
    static func parseVMMapSize(_ raw: String) -> UInt64? {
        guard let unit = raw.last else { return nil }
        let numeric = Double(raw.dropLast()) ?? Double(raw)
        guard let value = numeric else { return nil }
        switch unit {
        case "K": return UInt64(value * 1024)
        case "M": return UInt64(value * 1024 * 1024)
        case "G": return UInt64(value * 1024 * 1024 * 1024)
        case "T": return UInt64(value * 1024 * 1024 * 1024 * 1024)
        default:  return UInt64(value)
        }
    }

    // MARK: - Quitting

    enum QuitOutcome: Equatable {
        case quit
        case refused          // app declined, usually an unsaved-changes dialog
        case stillRunning
        case notFound
        case protected
    }

    /// Asks an application to quit, the same way ⌘Q does.
    ///
    /// Always `terminate()`, never `forceTerminate()`: a graceful request lets the
    /// app save, flush and put up its own "do you want to save?" sheet. Force
    /// quitting would discard unsaved work without asking, which is not a decision
    /// a utility should make on your behalf.
    @MainActor
    static func quit(_ candidate: AppCandidate, waitFor seconds: TimeInterval = 6) async -> QuitOutcome {
        guard !candidate.isProtected else { return .protected }
        guard let app = NSRunningApplication(processIdentifier: candidate.pid) else { return .notFound }
        guard app.terminate() else { return .refused }

        // The request was delivered; whether it completes is up to the app, which
        // may be showing a save dialog and waiting for you.
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if app.isTerminated { return .quit }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return app.isTerminated ? .quit : .stillRunning
    }
}
