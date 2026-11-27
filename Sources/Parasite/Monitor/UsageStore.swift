import Foundation

/// On-disk home for the monitor. Deliberately plain: one JSON object per line for
/// samples, so appending is a single write that cannot corrupt what came before,
/// and a half-written final line costs one row rather than the whole day.
enum UsageStore {
    static var root: URL { CaseLibrary.directory.appendingPathComponent("monitor", isDirectory: true) }
    static var samplesDir: URL { root.appendingPathComponent("samples", isDirectory: true) }
    static var appsDir: URL { root.appendingPathComponent("apps", isDirectory: true) }
    static var eventsDir: URL { root.appendingPathComponent("events", isDirectory: true) }
    static var stateURL: URL { root.appendingPathComponent("state.json") }
    static var reportURL: URL { root.appendingPathComponent("recommendation.json") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func prepare() throws {
        for dir in [root, samplesDir, appsDir, eventsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Samples

    static func append(_ sample: UsageSample) {
        guard var line = try? encoder.encode(sample) else { return }
        line.append(0x0A)
        let url = samplesDir.appendingPathComponent("\(dayFormatter.string(from: sample.t)).jsonl")
        appendData(line, to: url)
    }

    /// Appending via a file handle keeps memory flat regardless of how long the
    /// monitor has been running.
    private static func appendData(_ data: Data, to url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    static func loadSamples(since: Date? = nil) -> [UsageSample] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: samplesDir, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [UsageSample] = []
        for file in files.filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.path < $1.path }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let sample = try? decoder.decode(UsageSample.self, from: data) else { continue }
                if let since, sample.t < since { continue }
                out.append(sample)
            }
        }
        return out.sorted { $0.t < $1.t }
    }

    // MARK: - Per-app hours

    static func writeAppHour(_ hour: AppHour) {
        let url = appsDir.appendingPathComponent("\(dayFormatter.string(from: hour.hour)).json")
        var existing = loadAppHours(at: url)
        // Replace the matching hour rather than appending, so a daemon restart
        // inside the same hour updates that hour instead of double-counting it.
        existing.removeAll { abs($0.hour.timeIntervalSince(hour.hour)) < 1 }
        existing.append(hour)
        existing.sort { $0.hour < $1.hour }
        if let data = try? encoder.encode(existing) { try? data.write(to: url, options: .atomic) }
    }

    private static func loadAppHours(at url: URL) -> [AppHour] {
        guard let data = try? Data(contentsOf: url),
              let hours = try? decoder.decode([AppHour].self, from: data) else { return [] }
        return hours
    }

    static func loadAllAppHours(since: Date? = nil) -> [AppHour] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [AppHour] = []
        for file in files.filter({ $0.pathExtension == "json" }) {
            for hour in loadAppHours(at: file) where since == nil || hour.hour >= since! {
                out.append(hour)
            }
        }
        return out.sorted { $0.hour < $1.hour }
    }

    // MARK: - Events

    static func write(_ event: SpikeEvent) {
        let stamp = DateFormatter.filenameStamp.string(from: event.at)
        let url = eventsDir.appendingPathComponent("\(stamp)-\(event.kind.rawValue).json")
        if let data = try? encoder.encode(event) { try? data.write(to: url, options: .atomic) }
    }

    static func loadEvents(since: Date? = nil) -> [SpikeEvent] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [SpikeEvent] = []
        for file in files.filter({ $0.pathExtension == "json" }) {
            guard let data = try? Data(contentsOf: file),
                  let event = try? decoder.decode(SpikeEvent.self, from: data) else { continue }
            if let since, event.at < since { continue }
            out.append(event)
        }
        return out.sorted { $0.at > $1.at }
    }

    // MARK: - State

    static func loadState() -> MonitorState? {
        if let data = try? Data(contentsOf: stateURL),
           var state = try? decoder.decode(MonitorState.self, from: data) {
            // Self-heal: the samples on disk outrank the bookkeeping file. If the
            // file claims fewer samples or a later start than the samples show, it
            // was truncated or reset at some point and the samples are the truth.
            if let rebuilt = reconstructState(),
               rebuilt.totalSamples > state.totalSamples || rebuilt.startedAt < state.startedAt {
                state.startedAt = min(state.startedAt, rebuilt.startedAt)
                state.totalSamples = max(state.totalSamples, rebuilt.totalSamples)
                state.totalEvents = max(state.totalEvents, rebuilt.totalEvents)
                state.observedSeconds = max(state.observedSeconds, rebuilt.observedSeconds)
                save(state)
            }
            return state
        }
        // The samples on disk are the real record; state.json is only bookkeeping.
        // If it is missing or unreadable, rebuild from them rather than letting a
        // study that has been running for a week look like it started today.
        return reconstructState()
    }

    /// Rebuilds the counters by reading the sample files. Cheap enough to do once
    /// at daemon start, and it makes the state file non-authoritative by design.
    static func reconstructState() -> MonitorState? {
        let samples = loadSamples()
        guard let first = samples.first else { return nil }
        var state = MonitorState(startedAt: first.t)
        state.lastSampleAt = samples.last?.t
        state.totalSamples = samples.count
        state.observedSeconds = samples.reduce(0) { $0 + $1.span }
        state.totalEvents = (try? FileManager.default.contentsOfDirectory(
            atPath: eventsDir.path).filter { $0.hasSuffix(".json") }.count) ?? 0
        return state
    }

    static func save(_ state: MonitorState) {
        if let data = try? encoder.encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    /// Total bytes on disk, so the view can show the cost of keeping all this.
    static func diskUsage() -> UInt64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in e {
            total += UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
