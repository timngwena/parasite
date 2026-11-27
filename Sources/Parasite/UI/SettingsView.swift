import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state

    private var cliStatus: (text: String, ok: Bool) {
        if let path = state.settings.resolvedCLIPath { return ("Found at \(path)", true) }
        return ("Not found. Install the Claude Code CLI, or set its full path below.", false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionCard(
                    title: "Reasoning",
                    subtitle: "Parasite always produces local findings. This controls whether Claude also interprets them against your symptom and history."
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Interpret findings with Claude", isOn: Binding(
                            get: { state.settings.useModel },
                            set: { state.settings.useModel = $0 }
                        ))

                        Picker("Model", selection: Binding(
                            get: { state.settings.model },
                            set: { state.settings.model = $0 }
                        )) {
                            ForEach(Settings.availableModels, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(maxWidth: 260)

                        HStack(spacing: 6) {
                            Image(systemName: cliStatus.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(cliStatus.ok ? .green : .orange)
                            Text(cliStatus.text).font(.caption)
                        }

                        TextField("Custom path to the claude binary (optional)", text: Binding(
                            get: { state.settings.cliPath },
                            set: { state.settings.cliPath = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                        Text("Uses your existing CLI sign-in, so there is no API key to store and nothing billed separately. If analysis fails with an authentication error, open Terminal, run `claude`, and sign in.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                SectionCard(
                    title: "Thermal and power telemetry",
                    subtitle: "powermetrics needs root. Without it, fan and throttling questions can only be inferred rather than measured."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: state.settings.powermetricsGranted
                                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(state.settings.powermetricsGranted ? .green : .orange)
                            Text(state.settings.powermetricsGranted
                                 ? "Granted — SoC power, per-cluster residency, thermal pressure, fan speed and per-process GPU time are all available."
                                 : "Not granted. Run the install script once from Terminal:")
                                .font(.caption)
                        }
                        if !state.settings.powermetricsGranted {
                            CommandBlock(command: "cd \(projectPath) && sudo ./scripts/install-privileges.sh")
                            Text("It installs a root-owned wrapper that runs powermetrics with a fixed sampler set, and a sudoers rule permitting only that wrapper. It does not grant general sudo, and it deliberately does not grant powermetrics itself — powermetrics can write files as root via its -o flag, which would be an escalation path.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                SectionCard(title: "Capture") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Default capture length", selection: Binding(
                            get: { state.settings.defaultDepth },
                            set: { state.settings.defaultDepth = $0 }
                        )) {
                            ForEach(CaptureDepth.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .frame(maxWidth: 300)

                        HStack {
                            Text("Menu bar refresh")
                            Slider(
                                value: Binding(
                                    get: { state.settings.vitalsRefreshSeconds },
                                    set: {
                                        state.settings.vitalsRefreshSeconds = $0
                                        state.startVitalsTimer()
                                    }
                                ),
                                in: 2...30, step: 1
                            )
                            Text("\(Int(state.settings.vitalsRefreshSeconds))s")
                                .font(.caption.monospacedDigit()).frame(width: 30)
                        }
                        .frame(maxWidth: 360)
                    }
                }

                SectionCard(
                    title: "Case library",
                    subtitle: "Plain JSON on disk, one file per case. Nothing is uploaded, and a future agent can read the directory directly."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(CaseLibrary.casesDirectory.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack {
                            Button("Reveal in Finder") { state.revealLibrary() }
                            Button("Reload from disk") {
                                state.library.load()
                                state.refreshPatterns()
                            }
                            Spacer()
                            Text("\(state.library.cases.count) case\(state.library.cases.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }

                SectionCard(title: "This machine") {
                    let m = MachineCollector.profile()
                    VStack(alignment: .leading, spacing: 4) {
                        detail("Chip", m.chip)
                        detail("Model", m.modelIdentifier + (m.chassis.map { " (\($0))" } ?? ""))
                        detail("CPU", "\(m.totalCores) cores — \(m.performanceCores) performance, \(m.efficiencyCores) efficiency")
                        detail("GPU", m.gpuCores.map { "\($0) cores" } ?? "unknown")
                        detail("Memory", Fmt.bytes(m.memoryBytes))
                        detail("Memory bandwidth", m.memoryBandwidthGBs.map { "\(Fmt.num($0, 0)) GB/s" } ?? "no figure on record for this chip")
                        detail("SoC power envelope", m.sustainedPackageWatts.map { s in
                            "about \(Fmt.watts(s)) sustained" + (m.peakPackageWatts.map { ", \(Fmt.watts($0)) peak" } ?? "")
                        } ?? "no figure on record for this chip")
                        detail("Power adapter", m.adapterWatts.map { "\($0) W" } ?? "unknown")
                    }
                }
            }
            .padding(18)
        }
        .navigationTitle("Settings")
    }

    private var projectPath: String {
        // Where the repo most likely lives, for the copyable install command.
        let cwd = FileManager.default.currentDirectoryPath
        if FileManager.default.fileExists(atPath: cwd + "/scripts/install-privileges.sh") { return cwd }
        return "~/Documents/parasite"
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
            Spacer()
        }
    }
}
