import Foundation

/// Headless view of the reclaim picture. Read-only by default: quitting things
/// requires an explicit flag, and even then names must be given, because a
/// command that closes your apps should never be one you can run by accident.
enum ReclaimCLI {
    @MainActor
    static func run() {
        let args = CommandLine.arguments
        let samples = UsageStore.loadSamples(since: Date().addingTimeInterval(-14 * 86400))
        let hours = UsageStore.loadAllAppHours()
        let (candidates, ledger) = ReclaimScanner.scan(history: samples, appHours: hours)
        let swap = SwapAdvisor.read()

        if args.contains("--deep") {
            FileHandle.standardError.write(Data("Reading per-app swap with vmmap (slow)…\n".utf8))
        }

        print("")
        print("SWAP")
        print("  used        \(Fmt.bytes(swap.usedBytes)) of \(Fmt.bytes(swap.totalBytes)) (\(Fmt.pct(swap.usedFraction)))")
        print("  swapfiles   \(swap.swapfileCount) files, \(Fmt.bytes(swap.swapfileBytes)) in \(SwapAdvisor.swapDirectory)")
        if let oldest = swap.oldestSwapfile, let newest = swap.newestSwapfile {
            print("              written between \(Fmt.ago(oldest)) and \(Fmt.ago(newest))")
        }
        print("  pressure    \(swap.pressureLabel)")
        print("")
        print("MEMORY LEDGER")
        print("  resident    \(Fmt.bytes(swap.footprintBytes)) of \(Fmt.bytes(swap.physicalBytes)) physical")
        print("  compressed  \(Fmt.bytes(swap.compressedBytes))")
        print("  wired       \(Fmt.bytes(swap.wiredBytes))")
        print("  swapped     \(Fmt.bytes(swap.usedBytes))")
        print("  TOTAL DEMAND \(Fmt.bytes(swap.totalDemandBytes)) against \(Fmt.bytes(swap.physicalBytes)) installed")
        print("")
        print("WHERE THAT MEMORY SITS")
        print("  windowed apps       \(Fmt.bytes(ledger.attributedToApps))")
        print("  your other procs    \(Fmt.bytes(ledger.otherUserProcesses)) (menu-bar agents, CLIs, background tools)")
        print("  readable total      \(Fmt.bytes(ledger.totalReadable)) across \(ledger.readableProcessCount) processes")
        print("  not readable        \(ledger.unreadableProcessCount) system-owned processes — their memory is inside the totals above but cannot be attributed to an app")

        print("")
        let inUse = candidates.filter { $0.isFrontmost && !$0.isProtected }
        if !inUse.isEmpty {
            print("")
            print("IN USE NOW (not offered)")
            for c in inUse {
                print("  " + c.name.rightPadded(26) + Fmt.bytes(c.footprintBytes).leftPadded(9)
                      + "  \(c.processCount) processes · in use now")
            }
        }

        print("")
        print("APPS, RANKED BY WHAT YOU'D GET BACK")
        let quittable = candidates.filter { !$0.isProtected && !$0.isFrontmost }
        if quittable.isEmpty {
            print("  nothing idle")
        }
        for c in quittable.prefix(20) {
            var line = "  " + c.name.rightPadded(26) + Fmt.bytes(c.footprintBytes).leftPadded(9)
            line += "  peak " + Fmt.bytes(c.peakFootprintBytes).leftPadded(8)
            line += "  " + c.idleDescription
            if c.processCount > 1 { line += " · \(c.processCount) processes" }
            print(line)
        }
        let protectedApps = candidates.filter(\.isProtected)
        if !protectedApps.isEmpty {
            print("")
            print("  protected (never offered): " + protectedApps.map(\.name).joined(separator: ", "))
        }

        if args.contains("--deep") {
            print("")
            print("SWAPPED OUT PER APP (vmmap)")
            for c in quittable.prefix(8) {
                if let result = ReclaimScanner.swappedBytes(forApp: c) {
                    print("  " + c.name.rightPadded(26) + Fmt.bytes(result.bytes).leftPadded(9)
                          + " swapped out" + (result.isLowerBound ? " (at least — \(c.processCount) processes, largest 4 measured)" : ""))
                } else {
                    print("  " + c.name.rightPadded(26) + "   unreadable")
                }
            }
        }

        print("")
        print("WHAT ACTUALLY REDUCES IT")
        for line in SwapAdvisor.explanation(for: swap) { print("  · \(line)") }
        print("")
        for action in SwapAdvisor.actions(for: swap, topIdleApps: candidates) {
            print("  \(action.isPrimary ? "→" : " ") \(action.title)")
            print("      \(action.detail)")
            print("      \(action.effect)")
            if let command = action.command { print("      $ \(command)") }
        }
        print("")
        exit(0)
    }
}

private extension String {
    func rightPadded(_ width: Int) -> String {
        count >= width ? String(prefix(width)) : self + String(repeating: " ", count: width - count)
    }
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
