import Foundation

/// What the swap situation actually is, and what can honestly be done about it.
///
/// The short version, because it shapes everything below: **there is no supported
/// way to shrink swap on macOS.** No API, no command, no entitlement. The kernel
/// allocates swapfiles under memory pressure and deletes them when the pages they
/// back are released — on its own schedule, not on request. Anything claiming to
/// "clear swap" is either rebooting, or lying.
///
/// So this type does not offer a button that frees swap. It explains what is
/// holding it, and ranks the things that genuinely reduce it.
struct SwapState: Equatable {
    var usedBytes: UInt64
    var totalBytes: UInt64
    var freeBytes: UInt64
    var swapfileCount: Int
    var swapfileBytes: UInt64
    var oldestSwapfile: Date?
    var newestSwapfile: Date?
    var compressedBytes: UInt64
    var wiredBytes: UInt64
    var footprintBytes: UInt64
    var physicalBytes: UInt64
    var pressureLevel: Int?

    var usedFraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }

    var pressureLabel: String {
        switch pressureLevel {
        case 4: "critical"
        case 2: "warning"
        case 1: "normal"
        default: "unknown"
        }
    }

    /// Total memory demand: what is resident plus what has been pushed out. This
    /// is the number that says what size machine the workload actually wants.
    var totalDemandBytes: UInt64 { footprintBytes &+ usedBytes }
}

enum SwapAdvisor {
    static let swapDirectory = "/System/Volumes/VM"

    static func read() -> SwapState {
        let (memory, _) = MemoryCollector.read()
        let files = swapfiles()
        return SwapState(
            usedBytes: memory.swapUsedBytes,
            totalBytes: memory.swapTotalBytes,
            freeBytes: memory.swapFreeBytes,
            swapfileCount: files.count,
            swapfileBytes: files.reduce(0) { $0 + $1.size },
            oldestSwapfile: files.map(\.modified).min(),
            newestSwapfile: files.map(\.modified).max(),
            compressedBytes: memory.compressedBytes,
            wiredBytes: memory.wiredBytes,
            footprintBytes: memory.footprintBytes,
            physicalBytes: memory.totalBytes,
            pressureLevel: MemoryCollector.kernelPressureLevel()
        )
    }

    /// The swapfiles themselves. Their timestamps are informative: a swapfile
    /// dated days ago means the kernel has had no reason to release it since,
    /// which usually means something is still holding the pages it backs.
    static func swapfiles() -> [(name: String, size: UInt64, modified: Date)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: swapDirectory) else { return [] }
        var out: [(String, UInt64, Date)] = []
        for name in names where name.hasPrefix("swapfile") {
            let path = (swapDirectory as NSString).appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: path) else { continue }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date) ?? Date.distantPast
            out.append((name, size, modified))
        }
        return out.sorted { $0.2 < $1.2 }
    }

    // MARK: - Advice

    struct Action: Identifiable, Equatable {
        var id: String { title }
        var title: String
        var detail: String
        /// What this actually does to swap, stated plainly — including "nothing".
        var effect: String
        var command: String?
        var isPrimary: Bool
    }

    /// Ordered by how much they actually help, not by how satisfying they sound.
    static func actions(for state: SwapState, topIdleApps: [AppCandidate]) -> [Action] {
        var out: [Action] = []

        let reclaimable = topIdleApps.filter { !$0.isProtected && !$0.isFrontmost }
            .prefix(5).reduce(UInt64(0)) { $0 &+ $1.footprintBytes }

        out.append(Action(
            title: "Quit the apps you aren't using",
            detail: reclaimable > 0
                ? "The idle apps listed above are holding about \(Fmt.bytes(reclaimable)) between them."
                : "Nothing is sitting idle with significant memory right now.",
            effect: "This is the only lever that works while the machine stays up. Releasing pages is what lets the kernel delete swapfiles — but it does so lazily, so expect swap to fall over minutes, not instantly, and not always all the way.",
            command: nil,
            isPrimary: true
        ))

        out.append(Action(
            title: "Restart",
            detail: "Swap is rebuilt from empty on boot.",
            effect: "The only guaranteed way to return swap to zero. Everything else reduces pressure and hopes the kernel reclaims.",
            command: nil,
            isPrimary: state.usedFraction > 0.9
        ))

        out.append(Action(
            title: "Flush the disk cache",
            detail: "`purge` drops cached file data and forces the compressor to settle.",
            effect: "Does NOT free swap. It frees inactive and cached pages, which can relieve the pressure that is causing more swapping. Worth doing before you decide whether quitting apps helped; harmless, but often does nothing visible.",
            command: "sudo purge",
            isPrimary: false
        ))

        if state.compressedBytes > 4_294_967_296 {
            out.append(Action(
                title: "Understand the compressor first",
                detail: "\(Fmt.bytes(state.compressedBytes)) is currently held compressed in RAM, separately from the \(Fmt.bytes(state.usedBytes)) on disk.",
                effect: "macOS compresses before it swaps. A large compressed pool means pressure is being absorbed in memory and is not, by itself, a problem — but it is demand that would need real RAM on a machine without it.",
                command: nil,
                isPrimary: false
            ))
        }

        return out
    }

    /// The honest answer to "can I manage swap on device?".
    static func explanation(for state: SwapState) -> [String] {
        var out: [String] = [
            "There is no supported way to shrink swap on macOS. No command, no API, no setting. The kernel creates swapfiles under pressure and deletes them when the pages they hold are released, on its own schedule."
        ]

        if state.swapfileCount > 0 {
            var line = "Right now there are \(state.swapfileCount) swapfiles totalling \(Fmt.bytes(state.swapfileBytes)) in \(swapDirectory)"
            if let oldest = state.oldestSwapfile {
                line += ", the oldest written \(Fmt.ago(oldest))"
            }
            out.append(line + ".")
        }

        // The distinction that actually matters for a buying decision.
        out.append("Your workload is asking for roughly \(Fmt.bytes(state.totalDemandBytes)) — \(Fmt.bytes(state.footprintBytes)) resident plus \(Fmt.bytes(state.usedBytes)) pushed out — against \(Fmt.bytes(state.physicalBytes)) of physical memory.")

        if state.pressureLevel == 1 {
            out.append("The kernel still reports memory pressure as normal, so despite the size of the swap file the system does not currently consider itself short. Large swap with normal pressure usually means pages were written out once during a busy spell and have simply never been needed since.")
        }

        out.append("Disabling swap is not possible on Apple Silicon, and would not be a good idea if it were: without it, the memory pressure you are currently absorbing would become application crashes instead.")

        return out
    }
}
