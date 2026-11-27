import SwiftUI

/// The symptom-and-habit entry point. The whole design intent: describe what you
/// are experiencing in your own words, confirm what you were doing, and let the
/// machine be measured while it is still misbehaving.
struct CaptureView: View {
    @Environment(AppState.self) private var state
    var onFinished: () -> Void

    @State private var symptom = ""
    @State private var felt: Severity = .high
    @State private var freeform = ""
    @State private var depth: CaptureDepth?
    @State private var selectedTags: Set<String> = []
    @State private var newTag = ""
    @State private var autoDetected: [String] = []

    private static let starterTags = [
        "Teams call", "Zoom call", "Editing video", "Screen sharing", "Many browser tabs",
        "Compiling", "Containers running", "External display", "On battery", "Just woke from sleep"
    ]

    private var suggestedTags: [String] {
        // Your own vocabulary first, then the starters, so the list reflects how
        // you actually describe your work.
        var seen = Set<String>()
        return (autoDetected + state.library.knownTags + Self.starterTags).filter {
            seen.insert($0.lowercased()).inserted
        }
    }

    /// Falls back to the stored default until overridden for this capture, so the
    /// Settings preference is actually honoured.
    private var effectiveDepth: CaptureDepth { depth ?? state.settings.defaultDepth }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.phase.isBusy {
                    progressCard
                } else {
                    symptomCard
                    contextCard
                    depthCard
                    runRow
                }
            }
            .padding(18)
        }
        .navigationTitle("New diagnosis")
        .task { refreshAutoDetected() }
    }

    // MARK: - Cards

    private var symptomCard: some View {
        SectionCard(
            title: "What are you experiencing?",
            subtitle: "Plain words are better than technical ones. What you notice is the symptom; the measurements are this app's job."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                TextField(
                    "e.g. fans spun up hard and both displays started freezing mid-sentence",
                    text: $symptom,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

                Picker("How bad does it feel?", selection: $felt) {
                    Text("Just noticeable").tag(Severity.info)
                    Text("Annoying").tag(Severity.elevated)
                    Text("Getting in my way").tag(Severity.high)
                    Text("Unusable").tag(Severity.critical)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var contextCard: some View {
        SectionCard(
            title: "What were you doing?",
            subtitle: "Pre-ticked items were detected automatically. Correct anything wrong — these tags are what later analyses match against."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                FlowTags(tags: suggestedTags, selected: $selectedTags, autoDetected: Set(autoDetected))

                HStack {
                    TextField("Add your own tag", text: $newTag)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTag)
                    Button("Add", action: addTag).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                TextField(
                    "Anything else worth knowing (optional) — e.g. it started right after I plugged in the dock",
                    text: $freeform, axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)

                Button {
                    refreshAutoDetected()
                } label: {
                    Label("Re-detect what's running", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var depthCard: some View {
        SectionCard(
            title: "How long should it watch?",
            subtitle: "A window rather than an instant — fan ramps and building stalls are only visible as a trend."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: Binding(
                    get: { effectiveDepth },
                    set: { depth = $0 }
                )) {
                    ForEach(CaptureDepth.allCases, id: \.self) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(effectiveDepth.blurb).font(.caption).foregroundStyle(.secondary)

                if !state.settings.powermetricsGranted {
                    Label(
                        "Thermal, power and per-process GPU data are unavailable. Run scripts/install-privileges.sh once to enable them — without it, fan and throttling questions can only be inferred.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                if state.settings.useModel && state.settings.resolvedCLIPath == nil {
                    Label(
                        "The claude CLI could not be found, so you will get local findings without the reasoning step. Set its path in Settings.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var runRow: some View {
        HStack {
            Button {
                Task {
                    await state.runDiagnosis(
                        symptom: symptom.trimmingCharacters(in: .whitespacesAndNewlines),
                        feltSeverity: felt,
                        tags: Array(selectedTags).sorted(),
                        freeform: freeform.trimmingCharacters(in: .whitespacesAndNewlines),
                        depth: effectiveDepth
                    )
                    onFinished()
                }
            } label: {
                Label("Capture and diagnose", systemImage: "play.fill")
                    .frame(minWidth: 200)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)

            Spacer()
            Text("Nothing leaves your machine except the analysis prompt, and only if the reasoning step is on.")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: 260, alignment: .trailing)
        }
    }

    private var progressCard: some View {
        SectionCard(title: "Watching the machine", subtitle: phaseSubtitle) {
            VStack(alignment: .leading, spacing: 12) {
                if case .capturing(let message, let fraction) = state.phase {
                    ProgressView(value: fraction) { Text(message).font(.callout) }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(phaseSubtitle).font(.callout)
                    }
                }
                Text("Keep doing whatever triggered the problem. The capture is only useful if the machine is still misbehaving while it runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var phaseSubtitle: String {
        switch state.phase {
        case .capturing: "Sampling processes, memory, thermals and power"
        case .scoring: "Scoring findings against this machine's limits"
        case .reasoning: "Asking Claude to weigh the findings against your symptom and history"
        default: ""
        }
    }

    // MARK: - Actions

    private func addTag() {
        let t = newTag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        selectedTags.insert(t)
        newTag = ""
    }

    /// Detection needs a process and app list, which is cheap enough to gather on
    /// its own without a full capture.
    private func refreshAutoDetected() {
        let apps = AppCollector.read()
        let (displays, _) = DisplayCollector.read()
        let system = SystemCollector.read(processes: [])
        let probe = Snapshot(
            capturedAt: Date(), windowSeconds: 0,
            machine: MachineCollector.profile(),
            instants: [], processes: [], apps: apps, displays: displays,
            storage: StorageCollector.read(), system: system, degradations: []
        )
        let detected = AppState.autoDetect(probe)
        autoDetected = detected
        // Pre-tick detections but leave anything you already chose alone.
        for d in detected { selectedTags.insert(d) }
    }
}

/// A wrapping row of toggleable tags. Auto-detected ones are marked so it is
/// always clear what the app guessed versus what you said.
struct FlowTags: View {
    let tags: [String]
    @Binding var selected: Set<String>
    var autoDetected: Set<String> = []

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                let isOn = selected.contains(tag)
                Button {
                    if isOn { selected.remove(tag) } else { selected.insert(tag) }
                } label: {
                    HStack(spacing: 4) {
                        if autoDetected.contains(tag) {
                            Image(systemName: "wand.and.stars").font(.caption2)
                        }
                        Text(tag).font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        isOn ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
                        in: Capsule()
                    )
                    .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Minimal wrapping layout — SwiftUI has no built-in flow container, and a
/// horizontal ScrollView would hide tags rather than wrap them.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
