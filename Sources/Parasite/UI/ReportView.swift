import SwiftUI

struct ReportView: View {
    @Environment(AppState.self) private var state
    let item: DiagnosticCase

    @State private var outcomeDraft = ""
    @State private var showingRaw = false

    private var headroom: Headroom { HeuristicEngine.headroom(item.snapshot) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                if let warning = state.analysisWarning { warningCard(warning) }
                if let verdict = item.verdict { verdictCard(verdict) }
                else if state.phase != .reasoning { noVerdictCard }
                headroomCard
                findingsCard
                evidenceCard
                outcomeCard
                footerRow
            }
            .padding(18)
        }
        .navigationTitle("Report")
    }

    // MARK: - Header

    private var headerCard: some View {
        SectionCard(title: item.title, subtitle: Fmt.timestamp.string(from: item.createdAt)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    SeverityBadge(severity: item.topFinding?.severity ?? .info)
                    Text("You reported it as: \(item.feltSeverity.label)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Fmt.num(item.snapshot.windowSeconds, 0))s window")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !item.context.tags.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(item.context.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.secondary.opacity(0.14), in: Capsule())
                        }
                    }
                }
                if !item.context.freeform.isEmpty {
                    Text(item.context.freeform).font(.callout).italic()
                }
                Text(item.snapshot.machine.summary)
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func warningCard(_ warning: String) -> some View {
        SectionCard(title: "The reasoning step did not run") {
            VStack(alignment: .leading, spacing: 10) {
                Text(warning).font(.callout)
                Text("The capture and the local findings below are complete and saved — only Claude's interpretation is missing.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    Task { await state.reanalyse(item) }
                } label: {
                    Label("Try the analysis again", systemImage: "arrow.clockwise")
                }
                .disabled(state.phase.isBusy)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.5)))
    }

    private var noVerdictCard: some View {
        SectionCard(title: "No interpretation yet") {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.settings.useModel
                     ? "This capture was saved without a reasoning pass."
                     : "The reasoning step is switched off in Settings, so this report is local findings only.")
                    .font(.callout)
                Button {
                    Task { await state.reanalyse(item) }
                } label: {
                    Label("Analyse this capture now", systemImage: "sparkles")
                }
                .disabled(state.phase.isBusy)
            }
        }
    }

    // MARK: - Verdict

    private func verdictCard(_ v: Verdict) -> some View {
        SectionCard(
            title: "Most likely cause",
            subtitle: "Confidence: \(v.confidence)\(v.modelUsed.map { " · \($0)" } ?? "")"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text(v.primaryCause)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)

                if !v.explanation.isEmpty {
                    Text(v.explanation).font(.callout).textSelection(.enabled)
                }

                if !v.contributingFactors.isEmpty {
                    labelled("Also contributing") {
                        ForEach(Array(v.contributingFactors.enumerated()), id: \.offset) { _, f in
                            bullet(f)
                        }
                    }
                }

                if !v.actionsNow.isEmpty {
                    labelled("Do now") {
                        ForEach(v.actionsNow) { action in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(action.title).font(.callout.weight(.medium))
                                if !action.detail.isEmpty {
                                    Text(action.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                if let command = action.command { CommandBlock(command: command) }
                                if let risk = action.risk {
                                    Label(risk, systemImage: "exclamationmark.triangle")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            .padding(.bottom, 4)
                        }
                    }
                }

                if !v.actionsPreventive.isEmpty {
                    labelled("Stop it coming back") {
                        ForEach(Array(v.actionsPreventive.enumerated()), id: \.offset) { _, a in bullet(a) }
                    }
                }

                if !v.watchFor.isEmpty {
                    labelled("Watch for next time") {
                        ForEach(Array(v.watchFor.enumerated()), id: \.offset) { _, w in bullet(w) }
                    }
                }

                if !v.relatedPriorCases.isEmpty {
                    Text("Linked to earlier cases: \(v.relatedPriorCases.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        Task { await state.reanalyse(item) }
                    } label: {
                        Label("Re-analyse", systemImage: "arrow.clockwise")
                    }
                    .disabled(state.phase.isBusy)
                    .font(.caption)

                    if v.rawResponse != nil {
                        Button(showingRaw ? "Hide raw reply" : "Show raw reply") {
                            showingRaw.toggle()
                        }
                        .font(.caption)
                    }
                    Spacer()
                }
                .buttonStyle(.borderless)

                if showingRaw, let raw = v.rawResponse {
                    ScrollView {
                        Text(raw)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(8)
                    .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Headroom

    private var headroomCard: some View {
        SectionCard(
            title: "Against this machine's own limits",
            subtitle: headroom.tightest.map { "Tightest constraint: \($0.name) at \(Fmt.pct(min(1.5, $0.value)))" }
                ?? "Nothing could be measured against a known ceiling"
        ) {
            VStack(spacing: 10) {
                HeadroomBar(label: "CPU, sustained across \(item.snapshot.machine.totalCores) cores", fraction: headroom.cpu)
                HeadroomBar(label: "GPU", fraction: headroom.gpu,
                            caption: item.snapshot.machine.gpuCores.map { "\($0)-core GPU" })
                HeadroomBar(label: "Physical memory", fraction: headroom.memory,
                            caption: Fmt.bytes(item.snapshot.machine.memoryBytes) + " unified")
                HeadroomBar(label: "Swap", fraction: headroom.swap,
                            caption: item.snapshot.latest.map {
                                "\(Fmt.bytes($0.memory.swapUsedBytes)) of \(Fmt.bytes($0.memory.swapTotalBytes))"
                            })
                HeadroomBar(
                    label: "SoC power vs sustained envelope", fraction: headroom.power,
                    caption: item.snapshot.machine.sustainedPackageWatts.map {
                        "sustained ceiling about \(Fmt.watts($0))"
                    } ?? "requires the powermetrics grant"
                )
                HeadroomBar(label: "Disk used", fraction: headroom.storage,
                            caption: "\(Fmt.bytes(item.snapshot.storage.freeBytes)) free")
            }
        }
    }

    // MARK: - Findings

    private var findingsCard: some View {
        SectionCard(
            title: "Measured findings",
            subtitle: item.findings.isEmpty
                ? "No rule crossed a threshold"
                : "\(item.findings.count) finding\(item.findings.count == 1 ? "" : "s") · click to expand the evidence"
        ) {
            if item.findings.isEmpty {
                Text("Nothing measured crossed a threshold. If the symptom was real, the cause is either outside what Parasite samples, or it had already passed by the time the capture ran — try a Deep capture while it is happening.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.findings) { f in
                        FindingRow(finding: f)
                        if f.id != item.findings.last?.id { Divider() }
                    }
                }
            }
        }
    }

    // MARK: - Evidence

    private var evidenceCard: some View {
        SectionCard(title: "Raw evidence", subtitle: "What the capture actually saw") {
            VStack(alignment: .leading, spacing: 14) {
                if !item.snapshot.degradations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Could not be measured", systemImage: "eye.slash")
                            .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        ForEach(Array(item.snapshot.degradations.enumerated()), id: \.offset) { _, d in
                            Text("· \(d)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                timeline
                processTable
                displayList
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Timeline").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if item.snapshot.instants.isEmpty {
                Text("No samples recorded.").font(.caption).foregroundStyle(.secondary)
            } else {
                let start = item.snapshot.instants[0].at
                ForEach(Array(item.snapshot.instants.enumerated()), id: \.offset) { _, i in
                    HStack(spacing: 10) {
                        Text("\(Fmt.num(i.at.timeIntervalSince(start), 0))s")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(width: 32, alignment: .trailing)
                        Text("cpu \(Fmt.num(i.cpuUsagePercent, 0))%")
                            .font(.caption2.monospacedDigit()).frame(width: 64, alignment: .leading)
                        Text("mem \(Fmt.pct(i.memory.footprintFraction))")
                            .font(.caption2.monospacedDigit()).frame(width: 64, alignment: .leading)
                        Text("swap \(Fmt.pct(i.memory.swapUsedFraction))")
                            .font(.caption2.monospacedDigit()).frame(width: 72, alignment: .leading)
                        if let w = i.power?.packageWatts {
                            Text(Fmt.watts(w)).font(.caption2.monospacedDigit())
                                .frame(width: 52, alignment: .leading)
                        }
                        if let fan = i.thermal.fanRPM?.max() {
                            Text("\(Fmt.num(fan, 0)) rpm").font(.caption2.monospacedDigit())
                        }
                        Text(i.thermal.powermetricsPressure ?? i.thermal.systemThermalState)
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    private var processTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Busiest processes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(item.snapshot.processes.prefix(12)) { p in
                HStack(spacing: 8) {
                    Text("\(Fmt.num(p.cpuPercent, 1))%")
                        .font(.caption2.monospacedDigit()).frame(width: 52, alignment: .trailing)
                    Text(p.name).font(.caption2).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.bytes(p.residentBytes))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if let gpu = p.gpuMsPerSec, gpu > 1 {
                        Text("\(Fmt.num(gpu, 0)) ms gpu/s")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var displayList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Displays").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(item.snapshot.displays.enumerated()), id: \.offset) { _, d in
                HStack(spacing: 6) {
                    Image(systemName: d.isBuiltIn ? "laptopcomputer" : "display").font(.caption2)
                    Text(d.description).font(.caption2)
                    if d.isRenderingAboveNative, let factor = d.overRenderFactor {
                        Text("over-rendering +\(Fmt.num((factor * 100) - 100, 0))%")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    } else if d.isFractionallyScaled {
                        Text("fractionally scaled")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Outcome

    private var outcomeCard: some View {
        SectionCard(
            title: "Did it work?",
            subtitle: "Recording the outcome is what makes the next diagnosis better — it is the only way the library learns which advice actually helped."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let outcome = item.outcome, !outcome.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: item.outcomeConfirmed ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(item.outcomeConfirmed ? .green : .secondary)
                        Text(outcome).font(.callout)
                    }
                }
                TextField("What happened after you acted on this?", text: $outcomeDraft, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("This fixed it") {
                        state.recordOutcome(item, outcome: draftOrDefault("Resolved."), confirmed: true)
                        outcomeDraft = ""
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Didn't fix it") {
                        state.recordOutcome(item, outcome: draftOrDefault("Did not resolve the symptom."), confirmed: false)
                        outcomeDraft = ""
                    }
                    Spacer()
                }
            }
        }
    }

    private func draftOrDefault(_ fallback: String) -> String {
        let t = outcomeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack {
            Button {
                if let url = state.exportCurrent() {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } label: {
                Label("Export case JSON", systemImage: "square.and.arrow.up")
            }
            Button {
                state.revealLibrary()
            } label: {
                Label("Reveal library", systemImage: "folder")
            }
            Spacer()
            Button(role: .destructive) {
                state.delete(item)
            } label: {
                Label("Delete case", systemImage: "trash")
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }

    // MARK: - Small helpers

    private func labelled<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            content()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·").foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled)
        }
    }
}
