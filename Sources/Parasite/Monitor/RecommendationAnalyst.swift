import Foundation

struct ConfigOption: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var memoryGB: Int?
    var approximateCost: String?
    var why: String
    var tradeoff: String?
}

struct LaptopRecommendation: Codable, Equatable {
    var headline: String
    var summary: String
    var confidence: String
    var primary: ConfigOption
    var alternatives: [ConfigOption]
    var whatTheDataShows: [String]
    var doNotPayFor: [String]
    var whatWouldChangeThis: [String]
    var generatedAt: Date
    var modelUsed: String?
    var observedHours: Double
    var raw: String?
}

/// Turns the measured requirement into a buying decision.
///
/// The local analyser decides the *specs*, because that is what the measurements
/// support. This pass only maps those specs onto machines that exist — which is
/// why it is allowed to search the web: the lineup changes, and a model
/// recalling last year's line-up would recommend something you cannot buy.
enum RecommendationAnalyst {

    static func generate(profile: UsageProfile, model: String,
                         cliPathOverride: String?) throws -> LaptopRecommendation {
        let prompt = buildPrompt(profile)
        let (payload, raw, modelUsed) = try ClaudeAnalyst.runJSON(
            prompt: prompt, model: model, cliPathOverride: cliPathOverride,
            timeout: 420, allowWeb: true
        )
        return decode(payload, raw: raw, model: modelUsed, profile: profile)
    }

    // MARK: - Prompt

    static func buildPrompt(_ p: UsageProfile) -> String {
        let r = p.requirement
        var out = """
        You are advising on one person's next laptop, using two weeks of measurements \
        taken from the machine they use now. Your job is to turn measured requirements \
        into a specific recommendation they can act on.

        Rules:
        - The measurements below are the evidence. Do not invent usage patterns that \
        are not in them.
        - A local analyser has already sized the requirement from the data. Treat its \
        numbers as the floor. Disagree with it if the underlying measurements justify \
        that, and say so explicitly when you do.
        - The current Mac lineup matters and changes often. Search the web to check \
        which models, chips and memory configurations are actually on sale right now, \
        and what they cost. Do not recommend a configuration that cannot be ordered.
        - Be specific about what NOT to buy. Over-specifying is the common failure, and \
        the data here can show where extra spend would buy nothing measurable.
        - Where the data is thin, say so rather than padding the recommendation with \
        confidence it has not earned.
        - This person is replacing the machine described below, so say plainly whether \
        the upgrade is worth it at all, including the case for keeping what they have.

        Respond with one JSON object and nothing else:
        {
          "headline": "one line naming the recommended machine and memory, e.g. '16-inch MacBook Pro, M5 Pro, 48 GB'",
          "summary": "3-5 sentences: what the data shows about how they work, and why this configuration follows from it",
          "confidence": "low" | "medium" | "high",
          "primary": {"name": "...", "memoryGB": 48, "approximateCost": "...", "why": "...", "tradeoff": "..."},
          "alternatives": [{"name": "...", "memoryGB": 32, "approximateCost": "...", "why": "...", "tradeoff": "..."}],
          "whatTheDataShows": ["specific measured facts that drove this, each citing a number"],
          "doNotPayFor": ["upgrades the measurements show would be wasted, with the number that shows it"],
          "whatWouldChangeThis": ["what would have to be true for a different answer"]
        }

        ---

        ## The machine being replaced

        \(p.machine.summary)
        - Model: \(p.machine.modelIdentifier), macOS as measured
        - Installed memory: \(Fmt.num(p.machine.memoryGB, 0)) GB

        ## How much was observed

        - Monitoring ran from \(Fmt.timestamp.string(from: p.startedAt))
        - \(Fmt.num(p.observedHours, 1)) hours observed across \(p.calendarDays) calendar days
        - \(Fmt.num(p.activeHours, 1)) of those hours were active use (screen unlocked)
        - \(p.sampleCount) samples, \(p.events.count) spike events

        """

        func dist(_ title: String, _ d: Distribution, _ unit: String, places: Int = 1) -> String {
            """
            - \(title): median \(Fmt.num(d.p50, places))\(unit), 90th \(Fmt.num(d.p90, places))\(unit), \
            95th \(Fmt.num(d.p95, places))\(unit), 99th \(Fmt.num(d.p99, places))\(unit), peak \(Fmt.num(d.peak, places))\(unit)

            """
        }

        out += "## Measured demand, over active hours only\n\n"
        out += dist("CPU cores busy (of \(p.machine.totalCores))", p.coresBusy, " cores")
        out += dist("Busiest single process", p.singleCore, " of one core", places: 2)
        out += dist("Memory in use", p.memoryFootprintGB, " GB")
        out += dist("GPU utilisation", p.gpuBusy, "", places: 2)
        out += dist("Swap in use", p.swapUsedGB, " GB")
        out += dist("Concurrent demand (footprint + swap at the same instant)", p.concurrentDemandGB, " GB")
        if p.packageWatts.peak > 0 {
            out += dist("SoC package power", p.packageWatts, " W")
        }
        out += "\n"

        out += "## Time spent at the limits\n\n"
        out += "- Above 85% memory: \(Fmt.num(p.hoursAboveMemory85, 1)) hours\n"
        out += "- Above 70% CPU: \(Fmt.num(p.hoursAboveCPU70, 1)) hours\n"
        out += "- Above 50% GPU: \(Fmt.num(p.hoursGPUAbove50, 1)) hours\n"
        out += "- Thermal pressure above nominal: \(Fmt.num(p.hoursThermalNonNominal, 1)) hours\n"
        out += "- Fans audible (>25% of range): \(Fmt.num(p.hoursFansAudible, 1)) hours\n"
        out += "- On battery: \(Fmt.num(p.hoursOnBattery, 1)) hours\n"
        out += "- With an external display: \(Fmt.num(p.hoursWithExternalDisplay, 1)) hours, up to \(p.maxExternalDisplays) external, \(Fmt.num(Double(p.maxExternalPixels) / 1_000_000, 1))M pixels\n"
        out += "- Concurrent demand is the figure to size from: footprint and swap added at the SAME moment, so it does not combine peaks from different days.\n"
        out += "- Peak swap: \(Fmt.num(p.peakSwapGB, 1)) GB, of which \(Fmt.num(p.swapGrowthGB, 1)) GB accumulated while monitoring was running. macOS never shrinks the swap file, so only the growth is evidence of demand during this study; the rest may predate it.\n\n"

        out += "## Applications, by CPU consumed\n\n"
        out += "Core-hours means CPU time: 1.0 core-hour is one core fully busy for an hour.\n\n"
        out += "| app | core-hours | peak memory | mean memory | foreground hours | peak processes |\n|---|---|---|---|---|---|\n"
        for app in p.apps.prefix(18) {
            out += "| \(app.app) | \(Fmt.num(app.coreHours, 2)) | \(Fmt.bytes(app.peakRSSBytes)) | \(Fmt.bytes(app.meanRSSBytes)) | \(Fmt.num(app.foregroundHours, 1)) | \(app.peakProcessCount) |\n"
        }
        out += "\n"

        if !p.events.isEmpty {
            out += "## Spike events\n\n"
            for (kind, count) in p.eventCountsByKind.sorted(by: { $0.value > $1.value }) {
                let implication = SpikeKind(rawValue: kind)?.buyingImplication ?? ""
                out += "- \(SpikeKind(rawValue: kind)?.label ?? kind): \(count) times — \(implication)\n"
            }
            out += "\nMost recent, with what was running:\n"
            for event in p.events.prefix(6) {
                let top = event.processes.prefix(4)
                    .map { "\($0.app) \(Fmt.pct($0.cpuFraction))" }.joined(separator: ", ")
                out += "- \(Fmt.timestamp.string(from: event.at)) — \(event.headline)"
                if let front = event.frontmostApp { out += " (frontmost: \(front))" }
                if !top.isEmpty { out += " · busiest: \(top)" }
                out += "\n"
            }
            out += "\n"
        }

        out += """
        ## What the local analyser concluded

        These are derived from the measurements above, with stated headroom assumptions.

        - Memory: \(r.memoryGB) GB (confidence: \(r.memoryConfidence)). \(r.memoryRationale)
        - CPU: around \(r.performanceCores) performance cores. \(r.cpuRationale)
        - Single-thread bound: \(r.singleThreadBound ? "yes — more cores will not help" : "no")
        - GPU: \(r.gpuTier). \(r.gpuRationale)
        - External displays needed: \(r.externalDisplays). \(r.displayRationale)
        - Chassis: \(r.chassisNote)

        """
        if !r.caveats.isEmpty {
            out += "### Limits of this data\n\n"
            for c in r.caveats { out += "- \(c)\n" }
            out += "\n"
        }

        out += "---\n\nSearch for the current lineup and pricing, then respond with only the JSON object.\n"
        return out
    }

    // MARK: - Decode

    private static func decode(_ d: [String: Any], raw: String, model: String,
                               profile: UsageProfile) -> LaptopRecommendation {
        func strings(_ key: String) -> [String] {
            if let a = d[key] as? [String] { return a }
            if let s = d[key] as? String, !s.isEmpty { return [s] }
            return []
        }
        func option(_ any: Any?) -> ConfigOption? {
            guard let o = any as? [String: Any], let name = o["name"] as? String else { return nil }
            return ConfigOption(
                name: name,
                memoryGB: (o["memoryGB"] as? NSNumber)?.intValue,
                approximateCost: o["approximateCost"] as? String,
                why: (o["why"] as? String) ?? "",
                tradeoff: (o["tradeoff"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }

        let primary = option(d["primary"]) ?? ConfigOption(
            name: (d["headline"] as? String) ?? "No configuration named",
            memoryGB: profile.requirement.memoryGB, approximateCost: nil,
            why: "", tradeoff: nil
        )

        return LaptopRecommendation(
            headline: (d["headline"] as? String) ?? primary.name,
            summary: (d["summary"] as? String) ?? "",
            confidence: ((d["confidence"] as? String) ?? "unknown").lowercased(),
            primary: primary,
            alternatives: (d["alternatives"] as? [[String: Any]])?.compactMap { option($0) } ?? [],
            whatTheDataShows: strings("whatTheDataShows"),
            doNotPayFor: strings("doNotPayFor"),
            whatWouldChangeThis: strings("whatWouldChangeThis"),
            generatedAt: Date(),
            modelUsed: model,
            observedHours: profile.observedHours,
            raw: raw
        )
    }

    // MARK: - Persistence

    static func save(_ recommendation: LaptopRecommendation) {
        if let data = try? UsageStore.encoder.encode(recommendation) {
            try? data.write(to: UsageStore.reportURL, options: .atomic)
        }
    }

    static func load() -> LaptopRecommendation? {
        guard let data = try? Data(contentsOf: UsageStore.reportURL) else { return nil }
        return try? UsageStore.decoder.decode(LaptopRecommendation.self, from: data)
    }
}
