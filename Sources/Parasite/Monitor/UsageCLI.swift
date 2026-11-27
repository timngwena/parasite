import Foundation

/// Headless access to everything the monitor has collected.
enum UsageCLI {
    static func run() {
        let args = CommandLine.arguments
        let machine = MachineCollector.profile()
        let profile = UsageAnalyzer.profile(
            samples: UsageStore.loadSamples(),
            appHours: UsageStore.loadAllAppHours(),
            events: UsageStore.loadEvents(),
            state: UsageStore.loadState(),
            machine: machine
        )

        if args.contains("--prompt") {
            print(RecommendationAnalyst.buildPrompt(profile))
            exit(0)
        }
        if args.contains("--json") {
            UsageStore.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? UsageStore.encoder.encode(profile),
               let text = String(data: data, encoding: .utf8) { print(text) }
            exit(0)
        }

        printReport(profile)

        if args.contains("--recommend") {
            let settings = MainActor.assumeIsolated { Settings() }
            FileHandle.standardError.write(Data("\nAsking Claude (this searches the web for the current lineup, so it takes a minute)…\n".utf8))
            do {
                let recommendation = try RecommendationAnalyst.generate(
                    profile: profile, model: settings.model, cliPathOverride: settings.cliPath
                )
                RecommendationAnalyst.save(recommendation)
                printRecommendation(recommendation)
            } catch {
                FileHandle.standardError.write(Data(
                    "recommendation failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)\n".utf8))
            }
        }
        exit(0)
    }

    private static func printReport(_ p: UsageProfile) {
        print("")
        print("COLLECTION")
        print("  machine      \(p.machine.summary)")
        print("  started      \(Fmt.timestamp.string(from: p.startedAt))")
        print("  observed     \(Fmt.num(p.observedHours, 1))h over \(p.calendarDays) day(s); \(Fmt.num(p.activeHours, 1))h active")
        print("  samples      \(p.sampleCount) · events \(p.events.count) · on disk \(Fmt.bytes(p.diskBytes))")

        // Built by padding rather than String(format:). %s expects a C string
        // pointer; handing it a Swift String (or a utf8String borrowed from a
        // temporary NSString) reads freed memory and segfaults.
        func dist(_ label: String, _ d: Distribution, _ unit: String, _ places: Int = 1) {
            func cell(_ v: Double) -> String { (Fmt.num(v, places) + unit).leftPadded(9) }
            print("  " + label.rightPadded(20)
                  + "p50 " + cell(d.p50) + "   p95 " + cell(d.p95)
                  + "   p99 " + cell(d.p99) + "   peak " + cell(d.peak))
        }
        print("")
        print("DEMAND (active hours only)")
        dist("cores busy", p.coresBusy, "")
        dist("single process", p.singleCore, " core", 2)
        dist("memory in use", p.memoryFootprintGB, " GB")
        dist("gpu", p.gpuBusy, "", 2)
        dist("swap", p.swapUsedGB, " GB")
        if p.packageWatts.peak > 0 { dist("package power", p.packageWatts, " W") }

        print("")
        print("TIME AT THE LIMITS")
        print("  above 85% memory   \(Fmt.num(p.hoursAboveMemory85, 1))h")
        print("  above 70% cpu      \(Fmt.num(p.hoursAboveCPU70, 1))h")
        print("  above 50% gpu      \(Fmt.num(p.hoursGPUAbove50, 1))h")
        print("  thermal > nominal  \(Fmt.num(p.hoursThermalNonNominal, 1))h")
        print("  fans audible       \(Fmt.num(p.hoursFansAudible, 1))h")
        print("  on battery         \(Fmt.num(p.hoursOnBattery, 1))h")

        if !p.apps.isEmpty {
            print("")
            print("APPS BY CPU CONSUMED")
            for app in p.apps.prefix(12) {
                print("  " + app.app.rightPadded(26)
                      + Fmt.num(app.coreHours, 2).leftPadded(8) + " core-h"
                      + "   peak" + Fmt.bytes(app.peakRSSBytes).leftPadded(9)
                      + "   fg" + Fmt.num(app.foregroundHours, 1).leftPadded(6) + "h")
            }
        }

        if !p.eventCountsByKind.isEmpty {
            print("")
            print("SPIKES")
            for (kind, count) in p.eventCountsByKind.sorted(by: { $0.value > $1.value }) {
                print("  \(SpikeKind(rawValue: kind)?.label ?? kind): \(count)")
            }
        }

        let r = p.requirement
        print("")
        print("REQUIREMENT DERIVED FROM THE DATA")
        print("  memory     \(r.memoryGB) GB (confidence \(r.memoryConfidence))")
        print("             \(r.memoryRationale)")
        print("  cpu        ~\(r.performanceCores) performance cores\(r.singleThreadBound ? " — single-thread bound" : "")")
        print("             \(r.cpuRationale)")
        print("  gpu        \(r.gpuTier)")
        print("             \(r.gpuRationale)")
        print("  displays   \(r.externalDisplays) external")
        print("  chassis    \(r.chassisNote)")
        for c in r.caveats { print("  caveat     \(c)") }
        if !p.isReadyForRecommendation {
            print("")
            print("  NOT READY: \(Fmt.num(p.activeHours, 1))h of active use so far. Let it run longer.")
        }
        print("")
    }

    private static func printRecommendation(_ r: LaptopRecommendation) {
        print("")
        print("RECOMMENDATION (\(r.modelUsed ?? "model"), confidence \(r.confidence))")
        print("  \(r.headline)")
        print("")
        print("  \(r.summary)")
        if !r.whatTheDataShows.isEmpty {
            print("")
            print("  what the data shows:")
            for x in r.whatTheDataShows { print("    · \(x)") }
        }
        if !r.doNotPayFor.isEmpty {
            print("")
            print("  do not pay for:")
            for x in r.doNotPayFor { print("    · \(x)") }
        }
        if !r.alternatives.isEmpty {
            print("")
            print("  alternatives:")
            for a in r.alternatives {
                print("    · \(a.name)\(a.approximateCost.map { " (\($0))" } ?? "") — \(a.why)")
            }
        }
        print("")
    }
}


private extension String {
    func rightPadded(_ width: Int) -> String {
        count >= width ? String(prefix(width)) : self + String(repeating: " ", count: width - count)
    }
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
