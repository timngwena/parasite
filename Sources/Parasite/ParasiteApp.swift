import SwiftUI

/// Explicit entry point so the same binary can serve both the menu bar app and a
/// headless `--cli` mode.
@main
struct Entry {
    static func main() {
        let args = CommandLine.arguments
        // The background monitor. Runs headless under launchd for weeks, so it
        // never touches AppKit's app lifecycle.
        if args.contains("--monitor") {
            MonitorDaemon().run()
        }
        if args.contains("--reclaim") {
            // Called straight through on the main thread. Hopping to a @MainActor
            // Task and then blocking on a semaphore deadlocks: the wait occupies
            // the very thread the task needs in order to run.
            MainActor.assumeIsolated { ReclaimCLI.run() }
            return
        }
        if args.contains("--usage") || args.contains("--recommend") {
            UsageCLI.run()
            return
        }
        if args.contains("--cli") {
            CLIRunner.run()
            return
        }
        ParasiteApp.main()
    }
}

struct ParasiteApp: App {
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environment(state)
        } label: {
            // The icon carries the machine's current state so the menu bar itself
            // is the first line of diagnosis.
            Image(systemName: menuSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("Parasite", id: "main") {
            MainWindow().environment(state)
        }
        .defaultSize(width: 1000, height: 760)
        .windowResizability(.contentMinSize)
    }

    private var menuSymbol: String {
        guard let v = state.vitals else { return "waveform.path.ecg" }
        if v.thermalState == "Critical" { return "flame.fill" }
        if v.thermalState == "Serious" { return "flame" }
        let swapTotal = v.swapUsedBytes + v.swapFreeBytes
        if swapTotal > 0, Double(v.swapUsedBytes) / Double(swapTotal) > 0.9 {
            return "exclamationmark.triangle.fill"
        }
        if v.memoryFootprintFraction > 0.92 { return "exclamationmark.triangle" }
        return "waveform.path.ecg"
    }
}
