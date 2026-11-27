import SwiftUI

/// The menu bar panel. Kept deliberately small: live vitals, one button that
/// starts the thing you came here for, and a way into everything else.
struct MenuView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let v = state.vitals { vitalsBlock(v) }

            monitorRow

            Divider()

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .parasiteStartCapture, object: nil)
            } label: {
                HStack {
                    Image(systemName: "stethoscope")
                    Text("Diagnose what's happening now").fontWeight(.medium)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(state.phase.isBusy)

            if state.phase.isBusy { busyRow }

            if !state.library.cases.isEmpty { recentBlock }

            if !state.patterns.isEmpty { patternBlock }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    /// The study's pulse, visible without opening anything. "Always monitoring"
    /// is only reassuring if you can see that it is.
    private var monitorRow: some View {
        let state = UsageStore.loadState()
        let running = state?.lastSampleAt.map { Date().timeIntervalSince($0) < 300 } ?? false
        return Button {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .parasiteShowUsage, object: nil)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(running ? Color.green : Color.orange).frame(width: 6, height: 6)
                if let state {
                    Text(running ? "Usage study running" : "Usage study paused")
                        .font(.caption)
                    Spacer()
                    Text("\(Fmt.num(state.observedSeconds / 86400, 1))d of 14")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text("Usage study not started").font(.caption)
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Parasite").font(.headline)
            Spacer()
            Text(state.library.cases.isEmpty
                 ? "no cases yet"
                 : "\(state.library.cases.count) case\(state.library.cases.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func vitalsBlock(_ v: Vitals) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HeadroomBar(label: "Memory in use", fraction: v.memoryFootprintFraction)
            HeadroomBar(
                label: "Swap",
                fraction: v.swapUsedBytes + v.swapFreeBytes > 0
                    ? Double(v.swapUsedBytes) / Double(v.swapUsedBytes + v.swapFreeBytes)
                    : 0,
                caption: "\(Fmt.bytes(v.swapUsedBytes)) used · \(Fmt.bytes(v.swapFreeBytes)) free"
            )
            HStack {
                Label(v.thermalState, systemImage: v.thermalState == "Nominal" ? "checkmark.circle" : "flame")
                    .font(.caption)
                    .foregroundStyle(v.thermalState == "Nominal" ? Color.secondary : Color.orange)
                Spacer()
                Text("load \(Fmt.num(v.loadAverage1, 2))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var busyRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(busyLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var busyLabel: String {
        switch state.phase {
        case .capturing(let message, _): message
        case .scoring: "Scoring findings…"
        case .reasoning: "Asking Claude…"
        default: ""
        }
    }

    private var recentBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(state.library.cases.prefix(3)) { item in
                Button {
                    state.current = item
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .parasiteShowReport, object: nil)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let f = item.topFinding {
                            Image(systemName: f.severity.symbol)
                                .font(.caption2).foregroundStyle(f.severity.color)
                        }
                        Text(item.title).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Fmt.ago(item.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var patternBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Habit spotted").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let p = state.patterns.first {
                Text(p.headline).font(.caption).foregroundStyle(.primary).lineLimit(3)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Parasite") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .font(.caption)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.font(.caption)
        }
        .buttonStyle(.borderless)
    }
}

extension Notification.Name {
    static let parasiteStartCapture = Notification.Name("parasite.startCapture")
    static let parasiteShowReport = Notification.Name("parasite.showReport")
    static let parasiteShowUsage = Notification.Name("parasite.showUsage")
}
