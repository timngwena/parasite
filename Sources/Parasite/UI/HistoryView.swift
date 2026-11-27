import SwiftUI

struct HistoryView: View {
    @Environment(AppState.self) private var state
    var onOpen: () -> Void
    @State private var query = ""

    private var filtered: [DiagnosticCase] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.library.cases }
        return state.library.cases.filter {
            $0.symptom.lowercased().contains(q)
                || $0.context.tags.joined(separator: " ").lowercased().contains(q)
                || $0.findings.contains { f in f.title.lowercased().contains(q) }
                || ($0.verdict?.primaryCause.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        Group {
            if state.library.cases.isEmpty {
                EmptyHint(
                    icon: "archivebox",
                    title: "No cases yet",
                    message: "Every diagnosis is kept here. Once there are a few, Parasite starts matching new symptoms against old ones and mining habits from the pattern."
                )
            } else {
                List {
                    if let error = state.library.loadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(filtered) { item in
                        row(item)
                    }
                }
                .searchable(text: $query, prompt: "Search symptoms, tags, causes")
            }
        }
        .navigationTitle("Case library")
    }

    private func row(_ item: DiagnosticCase) -> some View {
        Button {
            state.current = item
            state.analysisWarning = nil
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SeverityBadge(severity: item.topFinding?.severity ?? .info)
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    if item.outcomeConfirmed {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2).foregroundStyle(.green)
                            .help("You confirmed this was resolved")
                    }
                    Text(Fmt.timestamp.string(from: item.createdAt))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if let v = item.verdict {
                    Text(v.primaryCause).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text("No interpretation recorded — local findings only")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if !item.context.tags.isEmpty {
                    Text(item.context.tags.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") {
                state.current = item
                onOpen()
            }
            Button("Re-analyse") {
                Task { await state.reanalyse(item) }
            }
            Divider()
            Button("Delete", role: .destructive) { state.delete(item) }
        }
    }
}

struct HabitsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.library.cases.count < PatternMiner.minimumCases {
                EmptyHint(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "Not enough history yet",
                    message: "Habits are mined across captures, so they need at least \(PatternMiner.minimumCases) cases to mean anything. You have \(state.library.cases.count). Anything claimed before that would be noise."
                )
            } else if state.patterns.isEmpty {
                EmptyHint(
                    icon: "checkmark.circle",
                    title: "No recurring pattern found",
                    message: "Across \(state.library.cases.count) captures, nothing repeats strongly enough to call a habit. Your problems look like one-offs rather than a standing condition — which is good news."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Derived from all \(state.library.cases.count) captures. These are not from any single incident — they are what keeps being true when things go wrong.")
                            .font(.callout).foregroundStyle(.secondary)

                        ForEach(state.patterns) { p in
                            SectionCard(title: p.headline,
                                        subtitle: "\(p.support) case\(p.support == 1 ? "" : "s") · strength \(Fmt.pct(p.strength))") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(p.detail).font(.callout)
                                    if let s = p.suggestion {
                                        Label(s, systemImage: "lightbulb")
                                            .font(.caption)
                                            .padding(8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .navigationTitle("Habits")
    }
}
