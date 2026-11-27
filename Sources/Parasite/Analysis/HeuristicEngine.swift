import Foundation

/// Deterministic local scoring. Every finding here is a measurement plus a
/// threshold, so the same snapshot always yields the same findings — the model's
/// job is to weigh them against the reported symptom, not to invent them.
enum HeuristicEngine {

    static func analyse(_ s: Snapshot) -> [Finding] {
        var findings: [Finding] = []
        findings += memoryFindings(s)
        findings += cpuFindings(s)
        findings += thermalAndPowerFindings(s)
        findings += displayFindings(s)
        findings += storageFindings(s)
        findings += systemFindings(s)
        return findings.sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity : $0.confidence > $1.confidence
        }
    }

    static func headroom(_ s: Snapshot) -> Headroom {
        var h = Headroom()
        let m = s.machine

        // CPU: sustained total utilisation over the window, not the peak, because
        // a single spike is not what makes a machine feel slow.
        if !s.instants.isEmpty {
            let avg = s.instants.map(\.cpuUsagePercent).reduce(0, +) / Double(s.instants.count)
            h.cpu = avg / 100
        }
        if let latest = s.latest {
            h.memory = latest.memory.footprintFraction
            h.swap = latest.memory.swapUsedFraction
            if let gpu = latest.gpu?.busyRatio { h.gpu = gpu }
            if let pkg = latest.power?.packageWatts, let sustained = m.sustainedPackageWatts, sustained > 0 {
                h.power = pkg / sustained
            }
        }
        h.storage = 1 - s.storage.freeFraction
        h.fans = s.latest?.thermal.fanLoadFraction
        return h
    }

    // MARK: - Memory

    private static func memoryFindings(_ s: Snapshot) -> [Finding] {
        guard let latest = s.latest else { return [] }
        var out: [Finding] = []
        let m = latest.memory

        // Swap exhaustion is the single most reliable explanation for a Mac that
        // freezes rather than merely slows: when there is nowhere left to page,
        // allocation stalls and the UI stops answering.
        if m.swapTotalBytes > 0 {
            let used = m.swapUsedFraction
            if used > 0.85 || m.swapFreeBytes < 2_147_483_648 {
                out.append(Finding(
                    id: "swap.exhaustion",
                    title: "Swap is nearly exhausted",
                    category: .memory,
                    severity: used > 0.95 || m.swapFreeBytes < 1_073_741_824 ? .critical : .high,
                    confidence: 0.95,
                    evidence: [
                        "Swap: \(Fmt.bytes(m.swapUsedBytes)) used of \(Fmt.bytes(m.swapTotalBytes)) (\(Fmt.pct(used))), only \(Fmt.bytes(m.swapFreeBytes)) free",
                        "Physical memory: \(Fmt.bytes(m.totalBytes)) total, \(Fmt.bytes(m.footprintBytes)) in active use (\(Fmt.pct(m.footprintFraction)))",
                        "Compressed: \(Fmt.bytes(m.compressedBytes)) — the compressor is already absorbing pressure before paging"
                    ],
                    culprits: topMemoryFamilies(s, count: 4),
                    remedy: "Quit or restart the largest memory holders. If swap stays near full after that, restart the machine — swap is not reclaimed until processes release the pages backing it.",
                    headroomFraction: used
                ))
            } else if used > 0.6 {
                out.append(Finding(
                    id: "swap.elevated",
                    title: "Swap use is high",
                    category: .memory,
                    severity: .elevated,
                    confidence: 0.85,
                    evidence: ["Swap: \(Fmt.bytes(m.swapUsedBytes)) of \(Fmt.bytes(m.swapTotalBytes)) (\(Fmt.pct(used)))"],
                    culprits: topMemoryFamilies(s, count: 3),
                    remedy: "Not yet a stall risk, but this is the direction that ends in one.",
                    headroomFraction: used
                ))
            }
        }

        // Paging rate matters independently of swap size: it is the difference
        // between memory that is merely full and memory that is actively thrashing.
        let swapRates = s.instants.compactMap { i -> Double? in
            guard let si = i.memory.swapInsPerSec, let so = i.memory.swapOutsPerSec else { return nil }
            return si + so
        }
        if let peak = swapRates.max(), peak > 50 {
            let avg = swapRates.reduce(0, +) / Double(swapRates.count)
            out.append(Finding(
                id: "memory.thrashing",
                title: "Active swap thrashing",
                category: .memory,
                severity: avg > 400 ? .critical : (avg > 100 ? .high : .elevated),
                confidence: 0.9,
                evidence: [
                    "Swap I/O averaged \(Fmt.num(avg, 0)) pages/s over \(Fmt.num(s.windowSeconds, 0))s, peaking at \(Fmt.num(peak, 0))/s",
                    "Every swapped page read back is a blocking disk access — this is what a beachball is made of"
                ],
                culprits: topMemoryFamilies(s, count: 3),
                remedy: "Reduce the working set rather than waiting it out: close the largest consumers. Thrashing does not settle on its own while demand stays above physical memory.",
                headroomFraction: nil
            ))
        }

        if m.footprintFraction > 0.88 {
            out.append(Finding(
                id: "memory.footprint",
                title: "Physical memory effectively full",
                category: .memory,
                severity: m.footprintFraction > 0.95 ? .high : .elevated,
                confidence: 0.9,
                evidence: [
                    "Active + wired + compressed = \(Fmt.bytes(m.footprintBytes)) of \(Fmt.bytes(m.totalBytes)) (\(Fmt.pct(m.footprintFraction)))",
                    "Free: \(Fmt.bytes(m.freeBytes))"
                ],
                culprits: topMemoryFamilies(s, count: 4),
                remedy: nil,
                headroomFraction: m.footprintFraction
            ))
        }

        // Wired memory cannot be paged out or compressed. A large wired figure
        // narrows the ceiling for everything else and usually points at drivers,
        // virtualisation, or a kernel-side leak rather than at an app.
        let wiredFraction = m.totalBytes > 0 ? Double(m.wiredBytes) / Double(m.totalBytes) : 0
        if wiredFraction > 0.28 {
            out.append(Finding(
                id: "memory.wired",
                title: "Unusually large wired memory",
                category: .memory,
                severity: wiredFraction > 0.4 ? .high : .elevated,
                confidence: 0.75,
                evidence: [
                    "Wired: \(Fmt.bytes(m.wiredBytes)) (\(Fmt.pct(wiredFraction)) of physical memory)",
                    "Wired pages cannot be compressed or paged out, so this is a hard reduction in usable memory"
                ],
                culprits: ["kernel_task", "third-party drivers or virtualisation"],
                remedy: "Common causes: VM or container runtimes, external GPU or dock drivers, VPN and filesystem kernel extensions. A restart clears an accumulated leak; if it returns quickly, suspect a resident driver.",
                headroomFraction: wiredFraction
            ))
        }

        return out
    }

    private static func topMemoryFamilies(_ s: Snapshot, count: Int) -> [String] {
        let physical = s.machine.memoryBytes
        return s.processFamilies()
            .sorted { $0.memory > $1.memory }
            .prefix(count)
            .map { family in
                var line = "\(family.name) (\(Fmt.bytes(family.memory))"
                if family.count > 1 { line += " summed across \(family.count) processes" }
                line += ")"
                // A footprint larger than physical memory cannot all be resident: it
                // includes memory-mapped files, and for a group it also double-counts
                // pages shared between the processes. Saying so keeps the number
                // useful instead of absurd.
                if physical > 0 && family.memory > physical {
                    line += " — exceeds the \(Fmt.bytes(physical)) of physical memory, so this figure includes mapped file pages rather than occupied RAM"
                } else if family.count > 1 {
                    line += " — shared pages are counted once per process, so treat the total as an upper bound"
                }
                return line
            }
    }

    // MARK: - CPU

    private static func cpuFindings(_ s: Snapshot) -> [Finding] {
        var out: [Finding] = []
        let cores = max(1, s.machine.totalCores)

        // A single process above ~80% of one core, sustained, is a runaway. This
        // is scored separately from overall saturation because the remedy is
        // completely different: kill one thing, versus reduce total load.
        for p in s.processes.prefix(12) where p.cpuPercent > 75 {
            let isSystemDaemon = (p.path ?? "").hasPrefix("/System/")
                || (p.path ?? "").hasPrefix("/usr/libexec/")
                || (p.path ?? "").hasPrefix("/usr/sbin/")
            out.append(Finding(
                id: "cpu.runaway.\(p.pid)",
                title: isSystemDaemon
                    ? "System daemon \(p.name) is running away"
                    : "\(p.name) is consuming a full core or more",
                category: .cpu,
                severity: p.cpuPercent > 180 ? .high : (isSystemDaemon ? .high : .elevated),
                confidence: 0.9,
                evidence: [
                    "\(p.name) (pid \(p.pid)): \(Fmt.num(p.cpuPercent, 1))% CPU — \(Fmt.num(p.cpuPercent / 100, 1)) cores of \(cores)",
                    p.energyImpact.map { "Energy impact: \(Fmt.num($0, 1))" },
                    p.idleWakeupsPerSec.flatMap { $0 >= 100 ? "Idle wakeups: \(Fmt.num($0, 0))/s" : nil },
                    p.path.map { "Path: \($0)" }
                ].compactMap { $0 },
                culprits: [p.name],
                remedy: isSystemDaemon
                    ? "A system daemon pinned this high is stuck, not busy. Killing it is safe — launchd restarts it immediately and it usually comes back idle: `sudo kill \(p.pid)`"
                    : "Quit and reopen \(p.name). If it returns to this level immediately, the work is real rather than stuck.",
                headroomFraction: p.cpuPercent / Double(cores * 100)
            ))
        }

        if !s.instants.isEmpty {
            let avg = s.instants.map(\.cpuUsagePercent).reduce(0, +) / Double(s.instants.count)
            if avg > 70 {
                out.append(Finding(
                    id: "cpu.saturation",
                    title: "CPU sustained near capacity",
                    category: .cpu,
                    severity: avg > 88 ? .high : .elevated,
                    confidence: 0.85,
                    evidence: [
                        "Average total CPU across the \(Fmt.num(s.windowSeconds, 0))s window: \(Fmt.num(avg, 0))% of \(cores) cores",
                        "Load average: \(Fmt.num(s.system.loadAverage1, 2)) (1m) / \(Fmt.num(s.system.loadAverage5, 2)) (5m) / \(Fmt.num(s.system.loadAverage15, 2)) (15m)"
                    ],
                    culprits: s.processFamilies().prefix(3).map { "\($0.name) \(Fmt.num($0.cpu, 0))%" },
                    remedy: nil,
                    headroomFraction: avg / 100
                ))
            }
        }

        // Excessive idle wakeups cost power and latency out of proportion to the
        // CPU time they show, and they are a classic cause of a machine that runs
        // hot while apparently doing very little.
        // Thresholds are per-second rates. A busy compositor sits in the hundreds;
        // several thousand per second means something is spinning.
        for p in s.processes.prefix(25) where (p.idleWakeupsPerSec ?? 0) > 3000 {
            out.append(Finding(
                id: "cpu.wakeups.\(p.pid)",
                title: "\(p.name) is waking the CPU constantly",
                category: .power,
                severity: (p.idleWakeupsPerSec ?? 0) > 15000 ? .high : .elevated,
                confidence: 0.8,
                evidence: [
                    "\(p.name) (pid \(p.pid)): \(Fmt.num(p.idleWakeupsPerSec ?? 0, 0)) idle wakeups per second",
                    "Wakeups prevent the CPU from reaching deep idle states, which costs power and raises temperature even at low utilisation"
                ],
                culprits: [p.name],
                remedy: nil,
                headroomFraction: nil
            ))
        }

        // kernel_task on Apple Silicon is doing driver and I/O work on your
        // behalf; it is not the thermal shim it was on Intel, so high values here
        // point at a driver or a device rather than at heat.
        if let kernel = s.processes.first(where: { $0.name == "kernel_task" }), kernel.cpuPercent > 25 {
            out.append(Finding(
                id: "cpu.kernel",
                title: "kernel_task is unusually busy",
                category: .system,
                severity: kernel.cpuPercent > 60 ? .high : .elevated,
                confidence: 0.7,
                evidence: [
                    "kernel_task: \(Fmt.num(kernel.cpuPercent, 1))% CPU",
                    kernel.idleWakeupsPerSec.flatMap { $0 >= 100 ? "Idle wakeups: \(Fmt.num($0, 0))/s" : nil } ?? "",
                    "On Apple Silicon this is real driver and I/O work, not thermal absorption"
                ].filter { !$0.isEmpty },
                culprits: ["kernel_task", "device drivers", "external peripherals"],
                remedy: "Usually a peripheral or its driver: docks, DisplayLink adapters, external drives, VPN or filesystem extensions. Disconnecting peripherals one at a time isolates it quickly.",
                headroomFraction: nil
            ))
        }

        return out
    }

    // MARK: - Thermal and power

    private static func thermalAndPowerFindings(_ s: Snapshot) -> [Finding] {
        var out: [Finding] = []
        let m = s.machine

        let states = s.instants.map(\.thermal.systemThermalState)
        if let worst = states.first(where: { $0 == "Critical" }) ?? states.first(where: { $0 == "Serious" })
            ?? states.first(where: { $0 == "Fair" }) {
            let severity: Severity = worst == "Critical" ? .critical : (worst == "Serious" ? .high : .elevated)
            out.append(Finding(
                id: "thermal.pressure",
                title: "System reporting thermal pressure: \(worst)",
                category: .thermal,
                severity: severity,
                confidence: 0.95,
                evidence: [
                    "ProcessInfo thermal state across the window: \(Set(states).sorted().joined(separator: ", "))",
                    m.thermalHeadroomNote
                ].compactMap { $0 },
                culprits: topEnergyFamilies(s, count: 3),
                remedy: worst == "Fair"
                    ? "Fair is the first step above nominal. It is the state in which fans ramp but performance is still intact."
                    : "At this level macOS is actively reducing clocks. Cutting sustained load is the only thing that restores speed.",
                headroomFraction: nil
            ))
        }

        if let pm = s.instants.compactMap(\.thermal.powermetricsPressure).last, pm != "Nominal" {
            out.append(Finding(
                id: "thermal.powermetrics",
                title: "SoC thermal pressure: \(pm)",
                category: .thermal,
                severity: pm.lowercased().contains("heavy") || pm.lowercased().contains("trapping") ? .critical : .high,
                confidence: 0.95,
                evidence: ["powermetrics thermal_pressure: \(pm)"],
                culprits: topEnergyFamilies(s, count: 3),
                remedy: nil,
                headroomFraction: nil
            ))
        }

        // Package power against the chip's own sustained envelope is the direct,
        // measured answer to "why did the fans just spin up" — fans respond to
        // watts dissipated, not to CPU percentage.
        let packages = s.instants.compactMap { $0.power?.packageWatts }
        if let peak = packages.max(), let sustained = m.sustainedPackageWatts, sustained > 0 {
            let avg = packages.reduce(0, +) / Double(packages.count)
            let ratio = avg / sustained
            if ratio > 0.6 {
                out.append(Finding(
                    id: "power.envelope",
                    title: ratio > 0.95
                        ? "SoC is at its sustained power limit"
                        : "SoC power high enough to ramp fans",
                    category: .power,
                    severity: ratio > 0.95 ? .high : .elevated,
                    confidence: 0.9,
                    evidence: [
                        "Package power averaged \(Fmt.watts(avg)), peaked at \(Fmt.watts(peak))",
                        "\(m.chip) sustains roughly \(Fmt.watts(sustained)) before fans must ramp (peak burst about \(Fmt.watts(m.peakPackageWatts ?? sustained)))",
                        s.instants.compactMap { $0.power?.cpuWatts }.max().map { "CPU domain peak: \(Fmt.watts($0))" },
                        s.instants.compactMap { $0.power?.gpuWatts }.max().map { "GPU domain peak: \(Fmt.watts($0))" },
                        s.instants.compactMap { $0.power?.aneWatts }.max().map { "Neural Engine peak: \(Fmt.watts($0))" }
                    ].compactMap { $0 },
                    culprits: topEnergyFamilies(s, count: 3),
                    remedy: "Fan noise at this power level is the cooling system working correctly, not a fault. It is only a problem if the load itself is unexpected.",
                    headroomFraction: ratio
                ))
            }
        }

        // A cluster genuinely pinned but held below its maximum clock is being
        // throttled. The activity bar is high deliberately: an idle cluster sits at
        // a low frequency because there is nothing to do, which is correct
        // behaviour and must never be reported as throttling.
        if let latest = s.latest {
            for cluster in latest.clusters {
                guard let freqFraction = cluster.frequencyFraction,
                      cluster.activeRatio > 0.75, freqFraction < 0.7 else { continue }
                out.append(Finding(
                    id: "thermal.throttle.\(cluster.name)",
                    title: "\(cluster.name) is being held below full speed",
                    category: .thermal,
                    severity: freqFraction < 0.55 ? .high : .elevated,
                    confidence: 0.75,
                    evidence: [
                        "\(cluster.name): \(Fmt.pct(cluster.activeRatio)) active but averaging \(Fmt.num(cluster.averageFrequencyMHz ?? 0, 0)) MHz of \(Fmt.num(cluster.maxFrequencyMHz ?? 0, 0)) MHz (\(Fmt.pct(freqFraction)) of peak clock)",
                        "Cores being kept busy and downclocked at the same time means the limit is thermal or power, not lack of demand"
                    ],
                    culprits: topEnergyFamilies(s, count: 2),
                    remedy: nil,
                    headroomFraction: 1 - freqFraction
                ))
            }
        }

        // Fan behaviour, scored against each fan's own floor and ceiling rather
        // than an absolute RPM, because what counts as loud differs per machine.
        let fanLoads = s.instants.compactMap { $0.thermal.fanLoadFraction }
        let fanRPMs = s.instants.compactMap { $0.thermal.fanRPM?.max() }
        if let latestLoad = fanLoads.last, let latestRPM = fanRPMs.last {
            let rising = (fanRPMs.last ?? 0) - (fanRPMs.first ?? 0)
            let ramping = s.latest?.thermal.smc?.anyFanRamping ?? false

            if latestLoad > 0.25 || rising > 250 || ramping {
                var evidence: [String] = []
                if let smc = s.latest?.thermal.smc {
                    for fan in smc.fans {
                        var line = "Fan \(fan.index + 1): \(Fmt.num(fan.actualRPM, 0)) RPM"
                        if let lo = fan.minimumRPM, let hi = fan.maximumRPM {
                            line += " (range \(Fmt.num(lo, 0))–\(Fmt.num(hi, 0)), so \(Fmt.pct(fan.loadFraction ?? 0)) of the way up)"
                        }
                        if fan.isRampingUp, let target = fan.targetRPM {
                            line += " — climbing towards \(Fmt.num(target, 0)) RPM"
                        }
                        evidence.append(line)
                    }
                }
                if rising > 100 {
                    evidence.append("Rose \(Fmt.num(rising, 0)) RPM over the \(Fmt.num(s.windowSeconds, 0))s window")
                }
                if let cpu = s.latest?.thermal.cpuDieTemperatureC {
                    evidence.append("CPU die: \(Fmt.num(cpu, 1))°C")
                }
                if let gpu = s.latest?.thermal.gpuDieTemperatureC {
                    evidence.append("GPU die: \(Fmt.num(gpu, 1))°C")
                }
                if let sys = s.latest?.thermal.smc?.systemWatts {
                    evidence.append("Whole-system power draw: \(Fmt.watts(sys)) (includes display and peripherals)")
                }

                out.append(Finding(
                    id: "thermal.fans",
                    title: ramping ? "Fans are ramping up right now"
                                   : (latestLoad > 0.5 ? "Fans are running hard" : "Fans are above idle"),
                    category: .thermal,
                    severity: latestLoad > 0.6 ? .high : (latestLoad > 0.3 ? .elevated : .info),
                    confidence: 0.9,
                    evidence: evidence,
                    culprits: topEnergyFamilies(s, count: 3),
                    remedy: latestLoad < 0.35
                        ? "Still in the lower part of their range — audible in a quiet room, but the cooling system is not under strain."
                        : nil,
                    headroomFraction: latestLoad
                ))
            } else if latestRPM > 0 {
                out.append(Finding(
                    id: "thermal.fans.idle",
                    title: "Fans are at idle",
                    category: .thermal,
                    severity: .info,
                    confidence: 0.95,
                    evidence: [
                        "Fans at \(Fmt.num(latestRPM, 0)) RPM, \(Fmt.pct(latestLoad)) of their range",
                        s.latest?.thermal.cpuDieTemperatureC.map { "CPU die: \(Fmt.num($0, 1))°C" }
                    ].compactMap { $0 },
                    culprits: [],
                    remedy: "If you are hearing fan noise while they read this low, the sound is coming from somewhere other than thermal load.",
                    headroomFraction: latestLoad
                ))
            }
        }

        if let latest = s.latest, let power = latest.power {
            if power.lowPowerMode {
                out.append(Finding(
                    id: "power.lowPowerMode",
                    title: "Low Power Mode is on",
                    category: .power,
                    severity: .elevated,
                    confidence: 1.0,
                    evidence: ["Low Power Mode caps sustained performance and fan speed by design"],
                    culprits: [],
                    remedy: "If the machine feels slow and you did not intend this, turn it off in Settings › Battery.",
                    headroomFraction: nil
                ))
            }
            if power.onBattery, let avg = s.instants.compactMap({ $0.power?.packageWatts }).max(), avg > 30 {
                out.append(Finding(
                    id: "power.battery",
                    title: "Heavy load while on battery",
                    category: .power,
                    severity: .info,
                    confidence: 0.8,
                    evidence: [
                        "Running on battery at \(Fmt.watts(avg)) package power",
                        power.batteryPercent.map { "Battery: \(Fmt.num($0, 0))%" } ?? "",
                        m.adapterWatts.map { "Plugging into the \(  $0)W adapter restores the full sustained power limit" } ?? ""
                    ].filter { !$0.isEmpty },
                    culprits: [],
                    remedy: nil,
                    headroomFraction: nil
                ))
            }
        }

        if let gpu = s.latest?.gpu, let busy = gpu.busyRatio, busy > 0.8 {
            out.append(Finding(
                id: "gpu.saturation",
                title: "GPU running near capacity",
                category: .gpu,
                severity: busy > 0.93 ? .high : .elevated,
                confidence: 0.85,
                evidence: [
                    "GPU busy: \(Fmt.pct(busy))",
                    gpu.frequencyMHz.map { "GPU frequency: \(Fmt.num($0, 0)) MHz" },
                    m.gpuCores.map { "\($0)-core GPU" }
                ].compactMap { $0 },
                culprits: topGPUFamilies(s, count: 3),
                remedy: nil,
                headroomFraction: busy
            ))
        }

        return out
    }

    private static func topEnergyFamilies(_ s: Snapshot, count: Int) -> [String] {
        let ranked = s.processes
            .filter { ($0.energyImpact ?? 0) > 0 }
            .sorted { ($0.energyImpact ?? 0) > ($1.energyImpact ?? 0) }
        if ranked.isEmpty {
            return s.processFamilies().prefix(count).map { "\($0.name) \(Fmt.num($0.cpu, 0))% CPU" }
        }
        return ranked.prefix(count).map { "\($0.name) (energy \(Fmt.num($0.energyImpact ?? 0, 1)))" }
    }

    private static func topGPUFamilies(_ s: Snapshot, count: Int) -> [String] {
        let ranked = s.processes
            .filter { ($0.gpuMsPerSec ?? 0) > 1 }
            .sorted { ($0.gpuMsPerSec ?? 0) > ($1.gpuMsPerSec ?? 0) }
        if ranked.isEmpty { return topEnergyFamilies(s, count: count) }
        return ranked.prefix(count).map { "\($0.name) (\(Fmt.num($0.gpuMsPerSec ?? 0, 0)) ms GPU/s)" }
    }

    // MARK: - Display

    private static func displayFindings(_ s: Snapshot) -> [Finding] {
        var out: [Finding] = []
        let overRendered = s.displays.filter(\.isRenderingAboveNative)
        let fractional = s.displays.filter(\.isFractionallyScaled)
        let nonNative = s.displays.filter(\.isNonNative)

        // WindowServer is the compositor. When it saturates, the whole UI stops
        // responding regardless of how idle the rest of the machine is — which is
        // exactly what "the screen froze but the machine seemed fine" looks like.
        if let ws = s.processes.first(where: { $0.name.contains("WindowServer") }), ws.cpuPercent > 18 {
            var evidence = [
                "WindowServer: \(Fmt.num(ws.cpuPercent, 1))% CPU",
                "Driving \(s.displays.count) display\(s.displays.count == 1 ? "" : "s"), \(Fmt.num(Double(s.totalDrivenPixels) / 1_000_000, 1))M pixels per frame",
                "Compositor throughput: \(Fmt.num(s.totalPixelThroughput / 1_000_000_000, 2)) billion pixels/second across all displays and refresh rates"
            ]
            if let w = ws.idleWakeupsPerSec, w > 1500 {
                evidence.append("WindowServer idle wakeups: \(Fmt.num(w, 0))/s — far more often than the refresh rate requires")
            }
            for d in s.displays { evidence.append("• \(d.description)") }
            for d in overRendered {
                evidence.append("\(d.name) renders \(Fmt.num((d.overRenderFactor ?? 1) * 100 - 100, 0))% more pixels than the panel can show, then resamples every frame down to fit")
            }
            if !fractional.isEmpty {
                evidence.append("Fractionally scaled: \(fractional.map(\.name).joined(separator: ", "))")
            }

            out.append(Finding(
                id: "display.windowserver",
                title: "WindowServer is under heavy load",
                category: .display,
                severity: ws.cpuPercent > 45 ? .high : .elevated,
                confidence: 0.85,
                evidence: evidence,
                culprits: ["WindowServer"] + nonNative.map(\.name),
                remedy: nonNative.isEmpty
                    ? "Reduce compositing work: fewer windows with live content, fewer transparency and motion effects, and check for any app redrawing continuously."
                    : "Set \(nonNative.map(\.name).joined(separator: " and ")) to the panel's native resolution. That removes the per-frame resample entirely and is the single biggest lever available here — larger than closing apps.",
                headroomFraction: nil
            ))
        }

        // Worth reporting even when the compositor currently looks calm, because it
        // sets the floor for how much headroom is left when something else arrives —
        // a screen share, say.
        if !overRendered.isEmpty && !out.contains(where: { $0.id == "display.windowserver" }) {
            out.append(Finding(
                id: "display.overrender",
                title: overRendered.count == 1
                    ? "\(overRendered[0].name) is rendering above its native resolution"
                    : "\(overRendered.count) displays are rendering above native resolution",
                category: .display,
                severity: .info,
                confidence: 0.9,
                evidence: overRendered.map {
                    "\($0.name): framebuffer \($0.pixelWidth)x\($0.pixelHeight) on a \($0.nativePixelWidth ?? 0)x\($0.nativePixelHeight ?? 0) panel — \(Fmt.num((($0.overRenderFactor ?? 1) * 100) - 100, 0))% more pixels than the screen can display"
                } + [
                    "Total compositor throughput: \(Fmt.num(s.totalPixelThroughput / 1_000_000_000, 2)) billion pixels/second"
                ],
                culprits: overRendered.map(\.name),
                remedy: "Costs GPU time and memory bandwidth continuously. Harmless while there is headroom; the first thing to change when there is not.",
                headroomFraction: nil
            ))
        }

        if !fractional.isEmpty && !out.contains(where: { $0.category == .display }) {
            out.append(Finding(
                id: "display.scaling",
                title: "Fractionally scaled display in use",
                category: .display,
                severity: .info,
                confidence: 0.9,
                evidence: fractional.map {
                    "\($0.name): rendering \($0.pixelWidth)x\($0.pixelHeight) for a \($0.pointWidth)x\($0.pointHeight) desktop (scale \(Fmt.num($0.backingScale, 2))x)"
                },
                culprits: fractional.map(\.name),
                remedy: nil,
                headroomFraction: nil
            ))
        }

        if s.displays.count > 2 {
            out.append(Finding(
                id: "display.count",
                title: "\(s.displays.count) displays attached",
                category: .display,
                severity: .info,
                confidence: 1.0,
                evidence: s.displays.map { "• \($0.description)" },
                culprits: [],
                remedy: nil,
                headroomFraction: nil
            ))
        }

        return out
    }

    // MARK: - Storage

    private static func storageFindings(_ s: Snapshot) -> [Finding] {
        var out: [Finding] = []
        let free = s.storage.freeFraction

        if free < 0.12 {
            // Low disk and heavy swap compound viciously: swap files live on the
            // same volume, so a full disk removes the system's last release valve.
            let swapPressure = (s.latest?.memory.swapUsedFraction ?? 0) > 0.6
            out.append(Finding(
                id: "storage.low",
                title: free < 0.05 ? "Disk critically full" : "Disk space low",
                category: .storage,
                severity: free < 0.05 ? .critical : (swapPressure ? .high : .elevated),
                confidence: 0.95,
                evidence: [
                    "\(s.storage.volumeName): \(Fmt.bytes(s.storage.freeBytes)) free of \(Fmt.bytes(s.storage.totalBytes)) (\(Fmt.pct(free)))",
                    swapPressure
                        ? "Swap is also under pressure, and swap files live on this volume — the system has nowhere left to page"
                        : "Swap files, app caches and video scratch files all compete for this space"
                ],
                culprits: [],
                remedy: "Free space on the boot volume. Video editing scratch files and render caches are usually the largest recoverable items.",
                headroomFraction: 1 - free
            ))
        }

        let writers = s.processes
            .filter { ($0.diskWriteBytes ?? 0) > 0 }
            .sorted { ($0.diskWriteBytes ?? 0) > ($1.diskWriteBytes ?? 0) }
        if let top = writers.first, (top.diskWriteBytes ?? 0) > 1_073_741_824 {
            out.append(Finding(
                id: "io.writes",
                title: "Heavy disk writes",
                category: .io,
                severity: .info,
                confidence: 0.8,
                evidence: writers.prefix(4).map {
                    "\($0.name): \(Fmt.bytes($0.diskWriteBytes ?? 0)) written, \(Fmt.bytes($0.diskReadBytes ?? 0)) read"
                },
                culprits: writers.prefix(3).map(\.name),
                remedy: nil,
                headroomFraction: nil
            ))
        }
        return out
    }

    // MARK: - System

    private static func systemFindings(_ s: Snapshot) -> [Finding] {
        var out: [Finding] = []

        // Long uptime is not itself a fault, but it is the condition under which
        // slow leaks and unreclaimed swap become the dominant explanation.
        let days = s.system.uptimeSeconds / 86400
        let swapHigh = (s.latest?.memory.swapUsedFraction ?? 0) > 0.6
        if days > 5 && swapHigh {
            out.append(Finding(
                id: "system.uptime",
                title: "Long uptime with accumulated memory pressure",
                category: .system,
                severity: .elevated,
                confidence: 0.75,
                evidence: [
                    "Up for \(Fmt.duration(s.system.uptimeSeconds)) (booted \(Fmt.timestamp.string(from: s.system.bootedAt)))",
                    "Swap at \(Fmt.pct(s.latest?.memory.swapUsedFraction ?? 0)) — pressure that has built up rather than arrived suddenly"
                ],
                culprits: [],
                remedy: "A restart is the cheapest test of whether this is accumulated leakage or genuine current demand. If the symptom returns within an hour of rebooting, it is current demand.",
                headroomFraction: nil
            ))
        }

        // Helper-process sprawl: individually modest, collectively the largest
        // consumer on many machines, and invisible unless you group them.
        let families = s.processFamilies()
        for f in families where f.count >= 12 && f.cpu > 40 {
            out.append(Finding(
                id: "system.sprawl.\(f.name)",
                title: "\(f.name) is spread across \(f.count) processes",
                category: .cpu,
                severity: f.cpu > 150 ? .high : .elevated,
                confidence: 0.8,
                evidence: [
                    "\(f.name): \(f.count) processes, \(Fmt.num(f.cpu, 0))% CPU combined, \(Fmt.bytes(f.memory)) resident",
                    "No single process looks alarming — the total is what matters"
                ],
                culprits: [f.name],
                remedy: "Closing unused tabs or windows reclaims this directly. Each renderer is a separate process with its own memory floor.",
                headroomFraction: nil
            ))
        }

        if s.system.microphoneInUse == true || s.system.cameraInUse == true {
            var evidence: [String] = []
            if s.system.microphoneInUse == true { evidence.append("An audio input device is actively recording") }
            if s.system.cameraInUse == true { evidence.append("Camera daemons are resident, which usually means the camera is open") }
            let assertions = SystemCollector.sleepAssertions()
            if !assertions.isEmpty {
                evidence.append("Power assertions held by: " + assertions.prefix(3).joined(separator: "; "))
            }
            out.append(Finding(
                id: "system.call",
                title: "A call or capture session appears to be live",
                category: .system,
                severity: .info,
                confidence: 0.7,
                evidence: evidence,
                culprits: [],
                remedy: "Video calls combine continuous encode, decode, capture and screen composition. They raise the floor under everything else, so other load that would normally be fine can tip the machine over.",
                headroomFraction: nil
            ))
        }

        return out
    }
}
