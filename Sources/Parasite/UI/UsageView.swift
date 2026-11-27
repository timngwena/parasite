import SwiftUI

@Observable
@MainActor
final class UsageModel {
    var profile: UsageProfile?
    var recommendation: LaptopRecommendation?
    var isLoading = false
    var isGenerating = false
    var error: String?
    /// How long the study is meant to run before the recommendation is trusted.
    let targetDays = 14.0

    func reload() {
        isLoading = true
        error = nil
        let machine = MachineCollector.profile()
        Task.detached(priority: .userInitiated) {
            let profile = UsageAnalyzer.profile(
                samples: UsageStore.loadSamples(),
                appHours: UsageStore.loadAllAppHours(),
                events: UsageStore.loadEvents(),
                state: UsageStore.loadState(),
                machine: machine
            )
            let saved = RecommendationAnalyst.load()
            await MainActor.run {
                self.profile = profile
                self.recommendation = saved
                self.isLoading = false
            }
        }
    }

    func generateRecommendation(model: String, cliPath: String) {
        guard let profile else { return }
        isGenerating = true
        error = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try RecommendationAnalyst.generate(
                    profile: profile, model: model, cliPathOverride: cliPath
                )
                RecommendationAnalyst.save(result)
                await MainActor.run {
                    self.recommendation = result
                    self.isGenerating = false
                }
            } catch {
                await MainActor.run {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.isGenerating = false
                }
            }
        }
    }

    var monitorIsRunning: Bool {
        guard let last = profile?.lastSampleAt else { return false }
        // Samples land once a minute; nothing for five means it is not running.
        return Date().timeIntervalSince(last) < 300
    }
}

struct UsageView: View {
    @Environment(AppState.self) private var state
    @State private var model = UsageModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.isLoading && model.profile == nil {
                    ProgressView("Reading what the monitor has collected…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let profile = model.profile, profile.sampleCount > 0 {
                    collectionCard(profile)
                    demandCard(profile)
                    appsCard(profile)
                    if !profile.events.isEmpty { eventsCard(profile) }
                    requirementCard(profile)
                    recommendationCard(profile)
                } else {
                    notRunningCard
                }
            }
            .padding(18)
        }
        .navigationTitle("Usage study")
        .task { model.reload() }
        .toolbar {
            Button { model.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    // MARK: - Not running

    private var notRunningCard: some View {
        SectionCard(
            title: "The monitor isn't collecting yet",
            subtitle: "It runs as a background agent, separate from this window, so it keeps going whether or not Parasite is open."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Start it once and leave it. It samples every five seconds, writes a row a minute, and runs on the efficiency cores at the lowest priority — measured at well under a tenth of one percent of a single core.")
                    .font(.callout)
                CommandBlock(command: "cd ~/Documents/parasite && ./scripts/install-monitor.sh")
                Text("After two weeks of ordinary work there will be enough to size a replacement machine from evidence rather than guesswork.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Collection

    private func collectionCard(_ p: UsageProfile) -> some View {
        let progress = min(1, p.observedHours / 24 / model.targetDays)
        return SectionCard(
            title: "Collection",
            subtitle: model.monitorIsRunning
                ? "Running — last sample \(Fmt.ago(p.lastSampleAt ?? Date()))"
                : "Not running. The last sample was \(Fmt.ago(p.lastSampleAt ?? Date()))."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.monitorIsRunning ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(p.machine.summary).font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(Fmt.num(p.observedHours / 24, 1)) of \(Int(model.targetDays)) days")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("\(Fmt.num(p.activeHours, 1))h actually at the machine")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: progress)
                }

                HStack(spacing: 18) {
                    stat("Samples", "\(p.sampleCount)")
                    stat("Spikes", "\(p.events.count)")
                    stat("Apps seen", "\(p.apps.count)")
                    stat("On disk", Fmt.bytes(p.diskBytes))
                }

                if !p.isReadyForRecommendation {
                    Label("Still early — \(Fmt.num(p.activeHours, 1)) active hours so far. The headline numbers are already meaningful; the 99th percentiles are not yet.",
                          systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !model.monitorIsRunning && p.sampleCount > 0 {
                    CommandBlock(command: "cd ~/Documents/parasite && ./scripts/install-monitor.sh --status")
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Demand

    private func demandCard(_ p: UsageProfile) -> some View {
        SectionCard(
            title: "What you actually demand of it",
            subtitle: "Measured over active hours only — time at a locked screen is excluded."
        ) {
            VStack(spacing: 14) {
                distributionRow(
                    "Memory in use", p.memoryFootprintGB, unit: " GB",
                    ceiling: p.machine.memoryGB,
                    note: p.swapGrowthGB > 1
                        ? "Swap grew \(Fmt.num(p.swapGrowthGB, 1)) GB while watching — demand exceeded installed memory"
                        : (p.peakSwapGB > 4
                           ? "Swap sits at \(Fmt.num(p.peakSwapGB, 1)) GB but hasn't grown — likely left over from before the study"
                           : nil)
                )
                distributionRow(
                    "Memory needed to never swap", p.concurrentDemandGB, unit: " GB",
                    ceiling: max(p.machine.memoryGB, p.concurrentDemandGB.peak),
                    note: "Footprint plus swap at the same instant — what would have been needed to avoid paging entirely"
                )
                distributionRow(
                    "CPU cores busy", p.coresBusy, unit: " cores",
                    ceiling: Double(p.machine.totalCores),
                    note: p.requirement.singleThreadBound
                        ? "One thread is usually the bottleneck, not the core count"
                        : nil
                )
                distributionRow(
                    "GPU", p.gpuBusy, unit: "", ceiling: 1, asPercent: true,
                    note: p.machine.gpuCores.map { "\($0)-core GPU" }
                )
                if p.packageWatts.peak > 0 {
                    distributionRow(
                        "SoC power", p.packageWatts, unit: " W",
                        ceiling: p.machine.sustainedPackageWatts ?? p.packageWatts.peak,
                        note: p.machine.sustainedPackageWatts.map { "sustained ceiling about \(Fmt.watts($0))" }
                    )
                }

                Divider()
                limitsGrid(p)
            }
        }
    }

    private func formatted(_ v: Double, unit: String, asPercent: Bool) -> String {
        asPercent ? Fmt.pct(v) : Fmt.num(v, 1) + unit
    }

    private func distributionRow(_ title: String, _ d: Distribution, unit: String,
                                 ceiling: Double, asPercent: Bool = false,
                                 note: String? = nil) -> some View {
        let format: (Double) -> String = { self.formatted($0, unit: unit, asPercent: asPercent) }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text("peak \(format(d.peak))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            // A single bar showing median, 95th and peak against the machine's
            // own ceiling says more than three numbers in a row.
            GeometryReader { geo in
                let w = geo.size.width
                let x: (Double) -> CGFloat = { v in
                    ceiling <= 0 ? 0 : CGFloat(min(1, v / ceiling)) * w
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor.opacity(0.28)).frame(width: max(2, x(d.p95)))
                    Capsule().fill(Color.accentColor).frame(width: max(2, x(d.p50)))
                    Rectangle()
                        .fill(d.peak >= ceiling * 0.97 ? Color.red : Color.primary.opacity(0.6))
                        .frame(width: 2)
                        .offset(x: max(0, x(d.peak) - 1))
                }
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                legend("median", format(d.p50), .accentColor)
                legend("95th", format(d.p95), Color.accentColor.opacity(0.4))
                legend("ceiling", asPercent ? "100%" : Fmt.num(ceiling, 0) + unit, .secondary)
                Spacer()
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(value)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func limitsGrid(_ p: UsageProfile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("HOURS SPENT AT THE LIMITS").font(.caption2.weight(.bold))
                .foregroundStyle(.secondary).tracking(0.5)
            FlowLayout(spacing: 8) {
                limitChip("memory >85%", p.hoursAboveMemory85)
                limitChip("CPU >70%", p.hoursAboveCPU70)
                limitChip("GPU >50%", p.hoursGPUAbove50)
                limitChip("thermal", p.hoursThermalNonNominal)
                limitChip("fans audible", p.hoursFansAudible)
                limitChip("on battery", p.hoursOnBattery)
                limitChip("external display", p.hoursWithExternalDisplay)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func limitChip(_ label: String, _ hours: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text("\(Fmt.num(hours, 1))h").font(.caption2.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(hours > 1 ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.1), in: Capsule())
    }

    // MARK: - Apps

    private func appsCard(_ p: UsageProfile) -> some View {
        SectionCard(
            title: "Where the machine's time goes",
            subtitle: "Core-hours is CPU time: 1.0 means one core fully busy for an hour. Helper processes are folded into their app."
        ) {
            let maxCore = max(p.apps.first?.coreHours ?? 1, 0.001)
            VStack(spacing: 7) {
                ForEach(p.apps.prefix(14)) { app in
                    HStack(spacing: 10) {
                        Text(app.app).font(.caption).lineLimit(1).frame(width: 150, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule().fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(2, geo.size.width * CGFloat(app.coreHours / maxCore)))
                            }
                        }
                        .frame(height: 8)
                        Text("\(Fmt.num(app.coreHours, 2))h")
                            .font(.caption2.monospacedDigit()).frame(width: 48, alignment: .trailing)
                        Text(Fmt.bytes(app.peakRSSBytes))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                        Text(app.foregroundHours > 0.05 ? "\(Fmt.num(app.foregroundHours, 1))h front" : "")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .frame(width: 72, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Events

    private func eventsCard(_ p: UsageProfile) -> some View {
        SectionCard(
            title: "Moments that hit a limit",
            subtitle: "Captured automatically when something crossed a threshold and stayed there."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                FlowLayout(spacing: 6) {
                    ForEach(p.eventCountsByKind.sorted(by: { $0.value > $1.value }), id: \.key) { kind, count in
                        HStack(spacing: 4) {
                            Text(SpikeKind(rawValue: kind)?.label ?? kind).font(.caption2)
                            Text("\(count)").font(.caption2.weight(.bold))
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.orange.opacity(0.15), in: Capsule())
                    }
                }
                ForEach(p.events.prefix(8)) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            SeverityBadge(severity: event.severity)
                            Text(event.headline).font(.caption)
                            Spacer()
                            Text(Fmt.ago(event.at)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let note = event.note {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                        let top = event.processes.prefix(3)
                            .map { "\($0.app) \(Fmt.pct($0.cpuFraction))" }.joined(separator: " · ")
                        if !top.isEmpty {
                            Text(top).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Requirement

    private func requirementCard(_ p: UsageProfile) -> some View {
        let r = p.requirement
        return SectionCard(
            title: "What the measurements say you need",
            subtitle: "Derived locally from the data above, before any model is involved."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 20) {
                    headlineSpec("Memory", "\(r.memoryGB) GB",
                                 current: "\(Fmt.num(p.machine.memoryGB, 0)) GB now",
                                 changed: Double(r.memoryGB) != p.machine.memoryGB.rounded())
                    headlineSpec("Performance cores", "\(r.performanceCores)",
                                 current: "\(p.machine.performanceCores) now",
                                 changed: r.performanceCores != p.machine.performanceCores)
                    headlineSpec("GPU", r.gpuTier, current: p.machine.gpuCores.map { "\($0) cores now" } ?? "",
                                 changed: r.gpuTier != "same as current")
                }
                reason("Memory", r.memoryRationale)
                reason("CPU", r.cpuRationale)
                reason("GPU", r.gpuRationale)
                reason("Displays", r.displayRationale)
                reason("Chassis", r.chassisNote)
                if !r.caveats.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("WHAT THIS DATA CANNOT SETTLE").font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary).tracking(0.5)
                        ForEach(Array(r.caveats.enumerated()), id: \.offset) { _, c in
                            Text("· \(c)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func headlineSpec(_ label: String, _ value: String, current: String, changed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.caption2.weight(.bold))
                .foregroundStyle(.secondary).tracking(0.5)
            Text(value).font(.title3.weight(.semibold))
                .foregroundStyle(changed ? Color.accentColor : Color.primary)
            Text(current).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func reason(_ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption.weight(.semibold))
                .frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
            Text(text).font(.caption).textSelection(.enabled)
        }
    }

    // MARK: - Recommendation

    private func recommendationCard(_ p: UsageProfile) -> some View {
        SectionCard(
            title: "The recommendation",
            subtitle: "Claude maps the measured requirement onto machines actually on sale — it searches the web, because the lineup changes."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }

                if let r = model.recommendation {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(r.headline).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text("Confidence: \(r.confidence) · from \(Fmt.num(r.observedHours, 1))h of data · \(Fmt.timestamp.string(from: r.generatedAt))")
                            .font(.caption2).foregroundStyle(.secondary)
                        if !r.summary.isEmpty {
                            Text(r.summary).font(.callout).textSelection(.enabled)
                        }
                        if !r.whatTheDataShows.isEmpty {
                            bulletBlock("WHAT DROVE THIS", r.whatTheDataShows)
                        }
                        if !r.doNotPayFor.isEmpty {
                            bulletBlock("DON'T PAY FOR", r.doNotPayFor)
                        }
                        if !r.alternatives.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("ALTERNATIVES").font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary).tracking(0.5)
                                ForEach(r.alternatives) { option in
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack {
                                            Text(option.name).font(.caption.weight(.medium))
                                            if let cost = option.approximateCost {
                                                Text(cost).font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                        Text(option.why).font(.caption2).foregroundStyle(.secondary)
                                        if let t = option.tradeoff {
                                            Text("Trade-off: \(t)").font(.caption2).foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                        }
                        if !r.whatWouldChangeThis.isEmpty {
                            bulletBlock("WHAT WOULD CHANGE THIS", r.whatWouldChangeThis)
                        }
                    }
                }

                HStack {
                    Button {
                        model.generateRecommendation(
                            model: state.settings.model, cliPath: state.settings.cliPath
                        )
                    } label: {
                        if model.isGenerating {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Searching and reasoning…")
                            }
                        } else {
                            Label(model.recommendation == nil ? "Generate recommendation" : "Regenerate",
                                  systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isGenerating || p.sampleCount == 0)

                    if !p.isReadyForRecommendation {
                        Text("You can run it now, but it will say the data is thin.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private func bulletBlock(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary).tracking(0.5)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("·").foregroundStyle(.secondary)
                    Text(item).font(.caption).textSelection(.enabled)
                }
            }
        }
    }
}
