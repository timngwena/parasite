import Foundation
import Observation

@Observable
final class Settings {
    var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }
    var cliPath: String {
        didSet { defaults.set(cliPath, forKey: Keys.cliPath) }
    }
    var defaultDepth: CaptureDepth {
        didSet { defaults.set(defaultDepth.rawValue, forKey: Keys.depth) }
    }
    var useModel: Bool {
        didSet { defaults.set(useModel, forKey: Keys.useModel) }
    }
    var vitalsRefreshSeconds: Double {
        didSet { defaults.set(vitalsRefreshSeconds, forKey: Keys.vitals) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let model = "model"
        static let cliPath = "cliPath"
        static let depth = "defaultDepth"
        static let useModel = "useModel"
        static let vitals = "vitalsRefreshSeconds"
    }

    static let availableModels = ["sonnet", "opus", "haiku"]

    init() {
        model = defaults.string(forKey: Keys.model) ?? "sonnet"
        cliPath = defaults.string(forKey: Keys.cliPath) ?? ""
        defaultDepth = CaptureDepth(rawValue: defaults.string(forKey: Keys.depth) ?? "") ?? .standard
        useModel = defaults.object(forKey: Keys.useModel) as? Bool ?? true
        let stored = defaults.double(forKey: Keys.vitals)
        vitalsRefreshSeconds = stored > 0 ? stored : 5
    }

    var resolvedCLIPath: String? { ClaudeAnalyst.locateCLI(override: cliPath) }
    var powermetricsGranted: Bool { PowerMetricsCollector.isAvailable }
}
