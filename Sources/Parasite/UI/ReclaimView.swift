import SwiftUI

@Observable
@MainActor
final class ReclaimModel {
    var candidates: [AppCandidate] = []
    var ledger = ReclaimLedger()
    var swap: SwapState?
    var selected: Set<String> = []
    var isScanning = false
    var isDeepScanning = false
    var isQuitting = false
    var outcomes: [String: ReclaimScanner.QuitOutcome] = [:]
    var confirmingQuit = false
    /// Swap before a quit round, so the effect can be reported honestly
    /// rather than claimed.
    var swapBeforeQuit: UInt64?
    var lastQuitSummary: String?

    var quittable: [AppCandidate] {
        candidates.filter { !$0.isProtected && !$0.isFrontmost }
    }
    var selectedCandidates: [AppCandidate] {
        quittable.filter { selected.contains($0.id) }
    }
    var selectedBytes: UInt64 {
        selectedCandidates.reduce(0) { $0 &+ $1.footprintBytes }
    }

    func scan() {
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let samples = UsageStore.loadSamples(since: Date().addingTimeInterval(-14 * 86400))
            let hours = UsageStore.loadAllAppHours()
            let (found, ledger) = ReclaimScanner.scan(history: samples, appHours: hours)
            let swap = SwapAdvisor.read()
            await MainActor.run {
                self.candidates = found
                self.ledger = ledger
                self.swap = swap
                self.isScanning = false
                // Drop selections for apps that are gone.
                let ids = Set(found.map(\.id))
                self.selected = self.selected.intersection(ids)
            }
        }
    }

    /// Fills in swapped-out bytes for the heaviest candidates. Separate and
    /// explicit because vmmap is slow — seconds per browser.
    func deepScan() {
        isDeepScanning = true
        let targets = Array(candidates.filter { !$0.isProtected }.prefix(8))
        Task.detached(priority: .utility) {
            var found: [String: (UInt64, Bool)] = [:]
            for candidate in targets {
                if let result = ReclaimScanner.swappedBytes(forApp: candidate) {
                    found[candidate.id] = (result.bytes, result.isLowerBound)
                }
            }
            await MainActor.run {
                for index in self.candidates.indices {
                    if let result = found[self.candidates[index].id] {
                        self.candidates[index].swappedBytes = result.0
                        self.candidates[index].swapIsLowerBound = result.1
                    }
                }
                self.isDeepScanning = false
            }
        }
    }

    func quitSelected() async {
        let targets = selectedCandidates
        guard !targets.isEmpty else { return }
        isQuitting = true
        swapBeforeQuit = swap?.usedBytes
        var results: [String: ReclaimScanner.QuitOutcome] = [:]
        for candidate in targets {
            results[candidate.id] = await ReclaimScanner.quit(candidate)
        }
        outcomes = results
        isQuitting = false
        selected.removeAll()

        let quit = results.values.filter { $0 == .quit }.count
        let waiting = results.values.filter { $0 == .stillRunning || $0 == .refused }.count
        var summary = "\(quit) of \(targets.count) quit."
        if waiting > 0 {
            summary += " \(waiting) still open — they are probably asking you whether to save."
        }
        lastQuitSummary = summary

        // Give the kernel a moment, then re-read rather than asserting an effect.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        scan()
    }
}

struct ReclaimView: View {
    @State private var model = ReclaimModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                swapCard
                appsCard
                actionsCard
            }
            .padding(18)
        }
        .navigationTitle("Reclaim")
        .task { if model.candidates.isEmpty { model.scan() } }
        .toolbar {
            Button { model.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(model.isScanning)
        }
        .confirmationDialog(
            "Quit \(model.selectedCandidates.count) app\(model.selectedCandidates.count == 1 ? "" : "s")?",
            isPresented: $model.confirmingQuit, titleVisibility: .visible
        ) {
            Button("Quit \(model.selectedCandidates.count) app\(model.selectedCandidates.count == 1 ? "" : "s")") {
                Task { await model.quitSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.selectedCandidates.map(\.name).joined(separator: ", ")).\n\nThese are asked to quit the same way ⌘Q does, so anything with unsaved work will prompt you rather than lose it. Parasite never force-quits.")
        }
    }

    // MARK: - Swap

    private var swapCard: some View {
        SectionCard(
            title: "Swap",
            subtitle: model.swap.map { "\(Fmt.bytes($0.usedBytes)) used of \(Fmt.bytes($0.totalBytes)) · kernel pressure: \($0.pressureLabel)" }
                ?? "Reading…"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let swap = model.swap {
                    HeadroomBar(
                        label: "Swap in use", fraction: swap.usedFraction,
                        caption: "\(swap.swapfileCount) swapfiles on disk, \(Fmt.bytes(swap.swapfileBytes))"
                    )

                    // The ledger that actually explains the number.
                    VStack(alignment: .leading, spacing: 3) {
                        ledgerRow("Resident in RAM", swap.footprintBytes, of: swap.physicalBytes)
                        ledgerRow("…of which compressed", swap.compressedBytes, of: swap.physicalBytes)
                        ledgerRow("…of which wired", swap.wiredBytes, of: swap.physicalBytes)
                        ledgerRow("Pushed out to swap", swap.usedBytes, of: swap.physicalBytes)
                        Divider().padding(.vertical, 2)
                        ledgerRow("…held by windowed apps", model.ledger.attributedToApps, of: swap.physicalBytes)
                        ledgerRow("…held by your other processes", model.ledger.otherUserProcesses, of: swap.physicalBytes)
                        HStack {
                            Text("Total demand").font(.caption.weight(.semibold))
                            Spacer()
                            Text(Fmt.bytes(swap.totalDemandBytes))
                                .font(.caption.weight(.semibold).monospacedDigit())
                            Text("vs \(Fmt.bytes(swap.physicalBytes)) installed")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(SwapAdvisor.explanation(for: swap).enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 6) {
                                Text("·").foregroundStyle(.secondary)
                                Text(line).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    private func ledgerRow(_ label: String, _ bytes: UInt64, of total: UInt64) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(Fmt.bytes(bytes)).font(.caption.monospacedDigit())
        }
    }

    // MARK: - Apps

    private var appsCard: some View {
        SectionCard(
            title: "Apps you aren't using",
            subtitle: "Ranked by memory held, weighted by how long since you last had it in front. \"Last used\" comes from the usage study, so it only knows about time since monitoring started."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if model.isScanning && model.candidates.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if model.quittable.isEmpty {
                    Text("Nothing idle worth quitting — everything open is either in use or a system app.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(model.quittable) { candidate in
                        appRow(candidate)
                    }
                }

                let inUse = model.candidates.filter { $0.isFrontmost && !$0.isProtected }
                if !inUse.isEmpty {
                    Divider()
                    ForEach(inUse) { candidate in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                            Text(candidate.name).font(.callout).foregroundStyle(.secondary)
                            Text("in use now — not offered").font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text(Fmt.bytes(candidate.footprintBytes))
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }

                if let summary = model.lastQuitSummary {
                    Label(summary, systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        model.confirmingQuit = true
                    } label: {
                        if model.isQuitting {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Asking them to quit…")
                            }
                        } else {
                            Label("Quit selected (\(Fmt.bytes(model.selectedBytes)))", systemImage: "xmark.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty || model.isQuitting)

                    Button("Select everything idle over 2 hours") {
                        model.selected = Set(
                            model.quittable
                                .filter { ($0.idleInterval ?? .greatestFiniteMagnitude) > 7200 }
                                .map(\.id)
                        )
                    }
                    .font(.caption)

                    if !model.selected.isEmpty {
                        Button("Clear") { model.selected.removeAll() }.font(.caption)
                    }

                    Spacer()

                    Button {
                        model.deepScan()
                    } label: {
                        if model.isDeepScanning {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text("Reading swap per app…")
                            }
                        } else {
                            Label("Check swap per app", systemImage: "magnifyingglass")
                        }
                    }
                    .font(.caption)
                    .disabled(model.isDeepScanning)
                    .help("Runs vmmap on the heaviest apps. Accurate, but slow — seconds per browser.")
                }
            }
        }
    }

    private func appRow(_ candidate: AppCandidate) -> some View {
        let isSelected = model.selected.contains(candidate.id)
        let idleHours = (candidate.idleInterval ?? .greatestFiniteMagnitude) / 3600
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { on in
                    if on { model.selected.insert(candidate.id) }
                    else { model.selected.remove(candidate.id) }
                }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(candidate.name).font(.callout.weight(.medium)).lineLimit(1)
                    if candidate.processCount > 1 {
                        Text("\(candidate.processCount) processes")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let outcome = model.outcomes[candidate.id] {
                        outcomeBadge(outcome)
                    }
                }
                HStack(spacing: 8) {
                    Text(candidate.idleDescription)
                        .font(.caption2)
                        .foregroundStyle(idleHours > 2 ? Color.orange : Color.secondary)
                    if candidate.foregroundHours > 0.05 {
                        Text("\(Fmt.num(candidate.foregroundHours, 1))h in front over the study")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let swapped = candidate.swappedBytes, swapped > 0 {
                        Text("\(candidate.swapIsLowerBound ? "≥" : "")\(Fmt.bytes(swapped)) swapped out")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.bytes(candidate.footprintBytes))
                    .font(.callout.monospacedDigit())
                Text("peak \(Fmt.bytes(candidate.peakFootprintBytes))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Button("Quit") {
                model.selected = [candidate.id]
                model.confirmingQuit = true
            }
            .font(.caption)
            .disabled(model.isQuitting)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func outcomeBadge(_ outcome: ReclaimScanner.QuitOutcome) -> some View {
        switch outcome {
        case .quit:
            Text("quit").font(.caption2).foregroundStyle(.green)
        case .refused, .stillRunning:
            Text("still open — check for a save prompt")
                .font(.caption2).foregroundStyle(.orange)
        case .notFound:
            Text("already gone").font(.caption2).foregroundStyle(.secondary)
        case .protected:
            EmptyView()
        }
    }

    // MARK: - Actions

    private var actionsCard: some View {
        SectionCard(
            title: "What actually reduces swap",
            subtitle: "In order of how much they help, not how satisfying they sound."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let swap = model.swap {
                    ForEach(SwapAdvisor.actions(for: swap, topIdleApps: model.candidates)) { action in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: action.isPrimary ? "arrow.right.circle.fill" : "circle")
                                    .font(.caption2)
                                    .foregroundStyle(action.isPrimary ? Color.accentColor : Color.secondary)
                                Text(action.title).font(.callout.weight(.medium))
                            }
                            Text(action.detail).font(.caption).foregroundStyle(.secondary)
                            Text(action.effect).font(.caption2).foregroundStyle(.tertiary)
                            if let command = action.command { CommandBlock(command: command) }
                        }
                    }
                }
            }
        }
    }
}
