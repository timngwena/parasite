import Foundation
import Observation

/// The case library: every diagnosis is kept on disk so later analyses can be
/// informed by earlier ones. This is the part that makes the app get better at
/// your machine specifically rather than restarting from zero each time.
@Observable
final class CaseLibrary {
    private(set) var cases: [DiagnosticCase] = []
    private(set) var loadError: String?

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Parasite", isDirectory: true)
    }()
    static var casesDirectory: URL { directory.appendingPathComponent("cases", isDirectory: true) }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() { load() }

    func load() {
        loadError = nil
        do {
            try FileManager.default.createDirectory(at: Self.casesDirectory, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(
                at: Self.casesDirectory, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }

            var loaded: [DiagnosticCase] = []
            var failures: [String] = []
            for file in files {
                do {
                    loaded.append(try decoder.decode(DiagnosticCase.self, from: Data(contentsOf: file)))
                } catch {
                    // One unreadable case must not take the whole library down —
                    // an old schema or a truncated write should cost you that case
                    // and nothing else.
                    failures.append(file.lastPathComponent)
                }
            }
            cases = loaded.sorted { $0.createdAt > $1.createdAt }
            if !failures.isEmpty {
                loadError = "Could not read \(failures.count) case file(s): \(failures.prefix(3).joined(separator: ", "))"
            }
        } catch {
            loadError = "Could not open the case library: \(error.localizedDescription)"
        }
    }

    func save(_ item: DiagnosticCase) {
        do {
            try FileManager.default.createDirectory(at: Self.casesDirectory, withIntermediateDirectories: true)
            let data = try encoder.encode(item)
            try data.write(to: url(for: item), options: .atomic)
            if let index = cases.firstIndex(where: { $0.id == item.id }) {
                cases[index] = item
            } else {
                cases.insert(item, at: 0)
            }
        } catch {
            loadError = "Could not save case: \(error.localizedDescription)"
        }
    }

    func delete(_ item: DiagnosticCase) {
        try? FileManager.default.removeItem(at: url(for: item))
        cases.removeAll { $0.id == item.id }
    }

    private func url(for item: DiagnosticCase) -> URL {
        let stamp = DateFormatter.filenameStamp.string(from: item.createdAt)
        return Self.casesDirectory.appendingPathComponent("\(stamp)-\(item.id.uuidString).json")
    }

    // MARK: - Recall

    /// Finds prior cases that plausibly describe the same underlying problem, so
    /// the model can say "this is the fourth time, and last time X fixed it"
    /// instead of treating every capture as the first.
    func similar(to item: DiagnosticCase, limit: Int = 4) -> [(DiagnosticCase, Double)] {
        cases
            .filter { $0.id != item.id }
            .map { ($0, similarity($0, item)) }
            .filter { $0.1 > 0.15 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0 }
    }

    private func similarity(_ a: DiagnosticCase, _ b: DiagnosticCase) -> Double {
        var score = 0.0

        // Matching finding ids are the strongest signal: they mean the machine was
        // measurably in the same state, independent of how the symptom was worded.
        let aFindings = Set(a.findings.map(\.id).map(stripPID))
        let bFindings = Set(b.findings.map(\.id).map(stripPID))
        if !aFindings.isEmpty || !bFindings.isEmpty {
            score += 0.45 * jaccard(aFindings, bFindings)
        }

        let aTags = Set(a.context.tags.map { $0.lowercased() })
        let bTags = Set(b.context.tags.map { $0.lowercased() })
        if !aTags.isEmpty || !bTags.isEmpty {
            score += 0.3 * jaccard(aTags, bTags)
        }

        score += 0.15 * jaccard(keywords(a.symptom), keywords(b.symptom))

        let aCulprits = Set(a.findings.flatMap(\.culprits).map(normaliseCulprit))
        let bCulprits = Set(b.findings.flatMap(\.culprits).map(normaliseCulprit))
        score += 0.1 * jaccard(aCulprits, bCulprits)

        return score
    }

    /// Finding ids embed the pid for per-process rules, which would otherwise make
    /// the same recurring runaway look like a different finding every time.
    private func stripPID(_ id: String) -> String {
        let parts = id.split(separator: ".")
        guard let last = parts.last, Int(last) != nil else { return id }
        return parts.dropLast().joined(separator: ".")
    }

    private func normaliseCulprit(_ s: String) -> String {
        // Culprit strings carry live measurements ("Chrome (4.2 GB)"); strip them
        // so the identity of the process is what gets compared.
        String(s.split(separator: "(").first ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    private func keywords(_ text: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "but", "for", "with", "that", "this", "when",
                                 "then", "was", "were", "have", "has", "are", "its", "into",
                                 "just", "now", "very", "some", "also", "from", "been", "not"]
        return Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stop.contains($0) }
        )
    }

    private func jaccard<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Double {
        let union = a.union(b)
        guard !union.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(union.count)
    }

    // MARK: - Suggested context tags

    /// Tags you have used before, most-used first, so the capture sheet offers
    /// your own vocabulary rather than a fixed list.
    var knownTags: [String] {
        var counts: [String: Int] = [:]
        for c in cases {
            for t in c.context.tags { counts[t, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }
}

extension DateFormatter {
    /// Colons are legal in HFS+/APFS names but Finder renders them as slashes, so
    /// case files use a plain sortable stamp instead.
    static let filenameStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
