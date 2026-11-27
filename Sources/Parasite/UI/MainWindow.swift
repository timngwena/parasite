import SwiftUI
import Combine

enum Pane: String, Hashable, CaseIterable, Identifiable {
    case usage, reclaim, diagnose, report, history, habits, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .usage: "Usage study"
        case .reclaim: "Reclaim"
        case .diagnose: "New diagnosis"
        case .report: "Report"
        case .history: "Case library"
        case .habits: "Habits"
        case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .usage: "chart.bar.xaxis"
        case .reclaim: "arrow.3.trianglepath"
        case .diagnose: "stethoscope"
        case .report: "doc.text.magnifyingglass"
        case .history: "archivebox"
        case .habits: "chart.line.uptrend.xyaxis"
        case .settings: "gearshape"
        }
    }
}

struct MainWindow: View {
    @Environment(AppState.self) private var state
    @State private var pane: Pane = .usage

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { p in
                    // The report pane is meaningless with nothing selected, so it
                    // stays hidden until there is something to show.
                    if p != .report || state.current != nil {
                        Label(p.title, systemImage: p.icon).tag(p)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            Group {
                switch pane {
                case .usage: UsageView()
                case .reclaim: ReclaimView()
                case .diagnose: CaptureView(onFinished: { pane = .report })
                case .report:
                    if let current = state.current {
                        ReportView(item: current)
                    } else {
                        EmptyHint(icon: "doc.text.magnifyingglass",
                                  title: "No report open",
                                  message: "Run a diagnosis, or open one from the case library.")
                    }
                case .history: HistoryView(onOpen: { pane = .report })
                case .habits: HabitsView()
                case .settings: SettingsView()
                }
            }
            .frame(minWidth: 620, minHeight: 520)
        }
        .onReceive(NotificationCenter.default.publisher(for: .parasiteStartCapture)) { _ in
            pane = .diagnose
        }
        .onReceive(NotificationCenter.default.publisher(for: .parasiteShowReport)) { _ in
            pane = .report
        }
        .onReceive(NotificationCenter.default.publisher(for: .parasiteShowUsage)) { _ in
            pane = .usage
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            if !state.settings.powermetricsGranted {
                Label("No thermal data", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
                    .help("Run scripts/install-privileges.sh to enable thermal, power and GPU telemetry.")
            }
            if state.settings.resolvedCLIPath == nil {
                Label("claude CLI not found", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Text(MachineCollector.profile().chip)
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
