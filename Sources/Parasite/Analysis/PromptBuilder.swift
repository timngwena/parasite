import Foundation

/// Turns a snapshot, a symptom and the relevant history into the text the model
/// reasons over. Everything here is measured or previously recorded — the builder
/// never editorialises, so the model's conclusions rest on data rather than on
/// hints smuggled into the prompt.
enum PromptBuilder {

    static func build(
        symptom: String,
        feltSeverity: Severity,
        context: ActivityContext,
        snapshot s: Snapshot,
        findings: [Finding],
        headroom: Headroom,
        priorCases: [(DiagnosticCase, Double)],
        patterns: [HabitPattern]
    ) -> String {
        var out = ""

        out += """
        You are the diagnostic engine inside Parasite, a local macOS utility. Your job is to \
        explain, for one specific machine, what is most likely causing the symptom its owner \
        just reported, using the measurements below.

        Rules:
        - Reason from the measurements provided. Do not invent numbers or processes.
        - Judge everything against this machine's stated capability envelope, not against \
        general expectations. A figure that would be alarming on a smaller machine may be \
        unremarkable here, and vice versa.
        - Distinguish what is measured from what is inferred, and say which is which.
        - The local rule engine has already produced findings. Weigh them against the symptom \
        and against history. You may downgrade a finding if it does not fit the reported \
        symptom, and you may promote something the rules only mentioned in passing. Say so \
        when you disagree with a finding.
        - If the measurements genuinely do not explain the symptom, say that plainly and say \
        what to capture next. A confident wrong answer is worse than an honest gap.
        - Prefer one primary cause. Put genuinely separate contributors under contributing \
        factors rather than hedging the primary.
        - Commands you suggest will be shown to the user to run themselves, never executed \
        automatically. Do not suggest anything destructive.

        Respond with a single JSON object and no other text, matching this shape exactly:
        {
          "primaryCause": "one sentence naming the most likely cause",
          "explanation": "2-5 sentences: the causal chain from cause to the symptom reported, citing specific measurements",
          "confidence": "low" | "medium" | "high",
          "contributingFactors": ["separate issues that make it worse, each one sentence"],
          "actionsNow": [{"title": "short imperative", "detail": "why this, and what to expect", "command": "optional shell command or null", "risk": "optional caveat or null"}],
          "actionsPreventive": ["changes that stop this recurring"],
          "watchFor": ["what would confirm or refute this diagnosis next time"],
          "relatedPriorCases": ["ids of prior cases below that are the same underlying problem"]
        }

        ---

        """

        out += "## The machine\n\n"
        out += "\(s.machine.summary)\n"
        out += "- Model identifier: \(s.machine.modelIdentifier)\n"
        out += "- macOS: \(s.system.osVersion)\n"
        if let bw = s.machine.memoryBandwidthGBs {
            out += "- Memory bandwidth ceiling: \(Fmt.num(bw, 0)) GB/s\n"
        }
        if let sustained = s.machine.sustainedPackageWatts, let peak = s.machine.peakPackageWatts {
            out += "- SoC power envelope: about \(Fmt.watts(sustained)) sustainable, \(Fmt.watts(peak)) short burst\n"
        }
        if let adapter = s.machine.adapterWatts { out += "- Power adapter: \(adapter) W\n" }
        if let note = s.machine.thermalHeadroomNote { out += "- \(note)\n" }
        out += "- Uptime: \(Fmt.duration(s.system.uptimeSeconds))\n\n"

        out += "## What the user reports\n\n"
        out += "Symptom: \(symptom.isEmpty ? "(not described)" : symptom)\n"
        out += "How bad it feels to them: \(feltSeverity.label)\n"
        if !context.tags.isEmpty {
            out += "Activity they confirmed: \(context.tags.joined(separator: ", "))\n"
        }
        if !context.autoDetected.isEmpty {
            out += "Activity auto-detected: \(context.autoDetected.joined(separator: ", "))\n"
        }
        if !context.freeform.isEmpty {
            out += "Their extra notes: \(context.freeform)\n"
        }
        out += "\n"

        out += "## Headroom against this machine's own ceilings\n\n"
        func line(_ name: String, _ v: Double?) -> String {
            guard let v else { return "- \(name): not measured\n" }
            return "- \(name): \(Fmt.pct(min(1.5, v))) of ceiling\n"
        }
        out += line("CPU (sustained, all cores)", headroom.cpu)
        out += line("GPU", headroom.gpu)
        out += line("Physical memory in use", headroom.memory)
        out += line("Swap", headroom.swap)
        out += line("SoC power vs sustained envelope", headroom.power)
        out += line("Disk used", headroom.storage)
        out += line("Fan speed through its range", headroom.fans)
        if let tightest = headroom.tightest {
            out += "Tightest constraint right now: \(tightest.name) at \(Fmt.pct(min(1.5, tightest.value)))\n"
        }
        out += "\n"

        out += findingsSection(findings)
        out += timelineSection(s)
        out += thermalSection(s)
        out += memorySection(s)
        out += processSection(s)
        out += displaySection(s)
        out += environmentSection(s)

        if !s.degradations.isEmpty {
            out += "## What could not be measured\n\n"
            out += "Treat these as unknowns, not as zeroes:\n"
            for d in s.degradations { out += "- \(d)\n" }
            out += "\n"
        }

        out += historySection(priorCases, patterns: patterns)

        out += "---\n\nRespond now with only the JSON object.\n"
        return out
    }

    // MARK: - Sections

    private static func findingsSection(_ findings: [Finding]) -> String {
        var out = "## Findings from the local rule engine\n\n"
        if findings.isEmpty {
            out += "No rule fired. Nothing measured crossed a threshold — which is itself informative if the symptom is real.\n\n"
            return out
        }
        for f in findings {
            out += "### [\(f.severity.label)] \(f.title)\n"
            out += "- id: `\(f.id)` · category: \(f.category.label) · rule confidence: \(Fmt.pct(f.confidence))\n"
            if let h = f.headroomFraction {
                out += "- at \(Fmt.pct(min(1.5, h))) of the relevant ceiling\n"
            }
            for e in f.evidence { out += "- \(e)\n" }
            if !f.culprits.isEmpty { out += "- implicated: \(f.culprits.joined(separator: "; "))\n" }
            if let r = f.remedy { out += "- rule's suggested remedy: \(r)\n" }
            out += "\n"
        }
        return out
    }

    /// The timeline is what distinguishes a state from a trend. A model given only
    /// the final instant cannot tell a fan ramping up from a fan already loud.
    private static func timelineSection(_ s: Snapshot) -> String {
        guard !s.instants.isEmpty else { return "" }
        var out = "## Timeline over the \(Fmt.num(s.windowSeconds, 0))s capture window\n\n"
        out += "| t | CPU % | mem used | swap used | swap I/O pages/s | thermal | pkg W | GPU busy | fan RPM |\n"
        out += "|---|---|---|---|---|---|---|---|---|\n"
        let start = s.instants.first!.at
        for i in s.instants {
            let t = Fmt.num(i.at.timeIntervalSince(start), 0) + "s"
            let swapIO = (i.memory.swapInsPerSec ?? 0) + (i.memory.swapOutsPerSec ?? 0)
            out += "| \(t)"
            out += " | \(Fmt.num(i.cpuUsagePercent, 0))"
            out += " | \(Fmt.pct(i.memory.footprintFraction))"
            out += " | \(Fmt.pct(i.memory.swapUsedFraction))"
            out += " | \(Fmt.num(swapIO, 0))"
            out += " | \(i.thermal.powermetricsPressure ?? i.thermal.systemThermalState)"
            out += " | \(i.power?.packageWatts.map { Fmt.num($0, 1) } ?? "-")"
            out += " | \(i.gpu?.busyRatio.map { Fmt.pct($0) } ?? "-")"
            out += " | \(i.thermal.fanRPM?.max().map { Fmt.num($0, 0) } ?? "-")"
            out += " |\n"
        }
        out += "\n"

        if let latest = s.latest, !latest.clusters.isEmpty {
            out += "Core cluster residency at the end of the window:\n"
            for c in latest.clusters {
                out += "- \(c.name): \(Fmt.pct(c.activeRatio)) active"
                if let avg = c.averageFrequencyMHz {
                    out += " at \(Fmt.num(avg, 0)) MHz"
                    if let max = c.maxFrequencyMHz {
                        out += " of \(Fmt.num(max, 0)) MHz max (\(Fmt.pct(avg / max)) of peak clock)"
                    }
                }
                out += "\n"
            }
            out += "\n"
        }
        return out
    }

    /// Fan and temperature detail. Read from the SMC over IOKit rather than
    /// powermetrics, whose smc sampler is unavailable on Apple Silicon.
    private static func thermalSection(_ s: Snapshot) -> String {
        guard let smc = s.latest?.thermal.smc else { return "" }
        var out = "## Fans and temperatures\n\n"
        for fan in smc.fans {
            out += "- Fan \(fan.index + 1): \(Fmt.num(fan.actualRPM, 0)) RPM"
            if let lo = fan.minimumRPM, let hi = fan.maximumRPM {
                out += " — its range is \(Fmt.num(lo, 0))–\(Fmt.num(hi, 0)) RPM, so it is \(Fmt.pct(fan.loadFraction ?? 0)) of the way up"
            }
            if let target = fan.targetRPM {
                out += ", controller target \(Fmt.num(target, 0)) RPM"
                if fan.isRampingUp { out += " (RAMPING UP — the controller has called for more than the fan has reached)" }
            }
            out += "\n"
        }
        if let v = smc.cpuDieC { out += "- CPU die (hottest core cluster): \(Fmt.num(v, 1))°C\n" }
        if let v = smc.efficiencyDieC { out += "- Efficiency-core die: \(Fmt.num(v, 1))°C\n" }
        if let v = smc.gpuDieC { out += "- GPU die: \(Fmt.num(v, 1))°C\n" }
        if let v = smc.enclosureC { out += "- Enclosure/skin: \(Fmt.num(v, 1))°C\n" }
        if let v = smc.batteryC { out += "- Battery: \(Fmt.num(v, 1))°C\n" }
        if let v = smc.systemWatts {
            out += "- Whole-system power draw: \(Fmt.watts(v)) (includes display, peripherals and charging — compare with the SoC-only figure above)\n"
        }
        out += "\nFan speed is the machine's response to heat, so judge loudness against each fan's own range, not against an absolute RPM.\n\n"
        return out
    }

    private static func memorySection(_ s: Snapshot) -> String {
        guard let m = s.latest?.memory else { return "" }
        var out = "## Memory detail\n\n"
        out += "- Physical: \(Fmt.bytes(m.totalBytes)) total\n"
        out += "- Active \(Fmt.bytes(m.activeBytes)) · inactive \(Fmt.bytes(m.inactiveBytes)) · wired \(Fmt.bytes(m.wiredBytes)) · compressed \(Fmt.bytes(m.compressedBytes)) · free \(Fmt.bytes(m.freeBytes)) · purgeable \(Fmt.bytes(m.purgeableBytes))\n"
        out += "- Swap: \(Fmt.bytes(m.swapUsedBytes)) used of \(Fmt.bytes(m.swapTotalBytes)), \(Fmt.bytes(m.swapFreeBytes)) free\n"
        if let p = m.pressurePercent { out += "- Irreclaimable share of physical memory: \(Fmt.num(p, 0))%\n" }
        if let level = MemoryCollector.kernelPressureLevel() {
            let name = level >= 4 ? "critical" : (level >= 2 ? "warning" : "normal")
            out += "- Kernel memory pressure level: \(level) (\(name))\n"
        }
        out += "- Disk: \(Fmt.bytes(s.storage.freeBytes)) free of \(Fmt.bytes(s.storage.totalBytes)) on \(s.storage.volumeName)\n\n"
        return out
    }

    private static func processSection(_ s: Snapshot) -> String {
        var out = "## Processes, busiest first\n\n"
        out += "CPU % is measured over the sample interval, so it reflects now rather than a lifetime average. 100% = one core of \(s.machine.totalCores).\n\n"
        out += "| pid | process | CPU % | resident | energy | GPU ms/s | idle wakeups/s |\n"
        out += "|---|---|---|---|---|---|---|\n"
        for p in s.processes.prefix(18) {
            out += "| \(p.pid) | \(p.name.prefix(60)) | \(Fmt.num(p.cpuPercent, 1))"
            out += " | \(Fmt.bytes(p.residentBytes))"
            out += " | \(p.energyImpact.map { Fmt.num($0, 1) } ?? "-")"
            out += " | \(p.gpuMsPerSec.map { Fmt.num($0, 0) } ?? "-")"
            out += " | \(p.idleWakeupsPerSec.map { Fmt.num($0, 0) } ?? "-")"
            out += " |\n"
        }
        out += "\n"

        let families = s.processFamilies().filter { $0.count > 1 }.prefix(6)
        if !families.isEmpty {
            out += "Grouped by application (helper processes folded in):\n"
            for f in families {
                out += "- \(f.name): \(f.count) processes, \(Fmt.num(f.cpu, 0))% CPU, \(Fmt.bytes(f.memory)) resident\n"
            }
            out += "\n"
        }
        return out
    }

    private static func displaySection(_ s: Snapshot) -> String {
        var out = "## Displays\n\n"
        for d in s.displays {
            out += "- \(d.description)"
            out += d.isBuiltIn ? " [built-in]" : " [external]"
            if d.isMain { out += " [main]" }
            out += " backing scale \(Fmt.num(d.backingScale, 2))x"
            if d.isRenderingAboveNative, let factor = d.overRenderFactor {
                out += " — OVER-RENDERING: the framebuffer is \(Fmt.num((factor * 100) - 100, 0))% larger than the panel's native resolution, so every frame is rendered oversized and resampled down"
            }
            if d.isFractionallyScaled { out += " — fractional backing scale, which also forces a resample" }
            // State the good case explicitly. Left unsaid, a model carrying advice
            // over from an earlier case will recommend "switch to native" for a
            // display that is already there.
            if !d.isNonNative {
                out += d.nativePixelCount != nil
                    ? " — already at its native panel resolution, so there is nothing to gain by changing it"
                    : " — native resolution could not be read, so whether it is over-rendering is unknown"
            }
            out += "\n"
        }
        out += "- Total pixels per frame: \(Fmt.num(Double(s.totalDrivenPixels) / 1_000_000, 1))M\n"
        out += "- Compositor throughput: \(Fmt.num(s.totalPixelThroughput / 1_000_000_000, 2)) billion pixels/second (pixels x refresh rate, summed)\n\n"
        return out
    }

    private static func environmentSection(_ s: Snapshot) -> String {
        var out = "## Environment\n\n"
        if let p = s.latest?.power {
            out += "- On battery: \(p.onBattery ? "yes" : "no")"
            if let pct = p.batteryPercent { out += " (\(Fmt.num(pct, 0))%)" }
            out += " · Low Power Mode: \(p.lowPowerMode ? "on" : "off")\n"
        }
        out += "- Microphone in use: \(describe(s.system.microphoneInUse)) · camera likely in use: \(describe(s.system.cameraInUse)) (camera is inferred from resident daemons, not measured directly)\n"
        out += "- Load average: \(Fmt.num(s.system.loadAverage1, 2)) / \(Fmt.num(s.system.loadAverage5, 2)) / \(Fmt.num(s.system.loadAverage15, 2))\n"
        out += "- Processes running: \(s.system.processCount)\n"

        let assertions = SystemCollector.sleepAssertions()
        if !assertions.isEmpty {
            out += "- Processes holding power assertions (preventing sleep): \(assertions.prefix(5).joined(separator: "; "))\n"
        }

        let notable = s.apps.filter { app in
            ["teams", "zoom", "descript", "final cut", "premiere", "docker", "chrome",
             "slack", "davinci", "photoshop", "after effects", "obs", "xcode", "parallels",
             "vmware", "utm", "blender", "logic", "handbrake"]
                .contains { app.name.lowercased().contains($0) }
        }
        if !notable.isEmpty {
            out += "- Heavyweight apps open: \(notable.map(\.name).joined(separator: ", "))\n"
        }
        out += "- Applications open: \(s.apps.count)\n\n"
        return out
    }

    private static func describe(_ b: Bool?) -> String {
        guard let b else { return "unknown" }
        return b ? "yes" : "no"
    }

    // MARK: - History

    private static func historySection(
        _ priorCases: [(DiagnosticCase, Double)],
        patterns: [HabitPattern]
    ) -> String {
        var out = ""
        if !priorCases.isEmpty {
            out += "## Earlier captures that look like this one\n\n"
            out += "Use these to notice recurrence, and to check whether advice given before actually worked.\n\n"
            for (c, score) in priorCases {
                out += "### Case \(c.id.uuidString.prefix(8)) — \(Fmt.timestamp.string(from: c.createdAt)) (similarity \(Fmt.pct(score)))\n"
                out += "- Symptom then: \(c.symptom)\n"
                if !c.context.tags.isEmpty { out += "- Activity then: \(c.context.tags.joined(separator: ", "))\n" }
                if let v = c.verdict {
                    out += "- Diagnosed then as: \(v.primaryCause) (confidence \(v.confidence))\n"
                    if !v.actionsNow.isEmpty {
                        out += "- Advised then: \(v.actionsNow.map(\.title).joined(separator: "; "))\n"
                    }
                }
                if let outcome = c.outcome, !outcome.isEmpty {
                    out += "- What actually happened afterwards: \(outcome)"
                    out += c.outcomeConfirmed ? " (user confirmed this resolved it)\n" : " (unconfirmed)\n"
                } else {
                    out += "- Outcome: never recorded\n"
                }
                let top = c.findings.filter { $0.severity >= .high }.map(\.title)
                if !top.isEmpty { out += "- High-severity findings then: \(top.joined(separator: "; "))\n" }
                out += "\n"
            }
        }

        if !patterns.isEmpty {
            out += "## Habits mined from the whole case library\n\n"
            out += "Derived from every capture so far, not from this one:\n\n"
            for p in patterns.prefix(6) {
                out += "- **\(p.headline)** (strength \(Fmt.pct(p.strength)), \(p.support) cases) — \(p.detail)\n"
            }
            out += "\n"
        }
        return out
    }
}
