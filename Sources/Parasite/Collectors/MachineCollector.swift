import Foundation

enum MachineCollector {
    static func profile() -> MachineProfile {
        let model = Shell.sysctlString("hw.model") ?? "unknown"
        let chip = Shell.sysctlString("machdep.cpu.brand_string") ?? "unknown"
        let p = Int(Shell.sysctlInt("hw.perflevel0.logicalcpu") ?? 0)
        let e = Int(Shell.sysctlInt("hw.perflevel1.logicalcpu") ?? 0)
        let mem = UInt64(Shell.sysctlInt("hw.memsize") ?? 0)

        let gpuCores = gpuCoreCount()
        let adapter = adapterWattage()
        let env = ChipEnvelope.lookup(chip: chip, gpuCores: gpuCores)

        return MachineProfile(
            modelIdentifier: model,
            chip: chip,
            chassis: chassis(),
            // Fall back to the total core count on the P line if perflevel
            // probing fails, rather than reporting a zero-core machine.
            performanceCores: p > 0 ? p : Int(Shell.sysctlInt("hw.ncpu") ?? 0),
            efficiencyCores: e,
            gpuCores: gpuCores,
            memoryBytes: mem,
            adapterWatts: adapter,
            memoryBandwidthGBs: env?.bandwidthGBs,
            sustainedPackageWatts: env?.sustainedWatts,
            peakPackageWatts: env?.peakWatts,
            thermalHeadroomNote: thermalNote()
        )
    }

    /// system_profiler is slow (a second or more), so both the GPU core count
    /// and the chassis are cached for the life of the process. Neither changes.
    private static var cachedDisplaysPlist: [String: Any]?
    private static func displaysPlist() -> [String: Any]? {
        if let cachedDisplaysPlist { return cachedDisplaysPlist }
        let r = Shell.run("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-xml"], timeout: 25)
        guard r.ok, let data = r.stdout.data(using: .utf8),
              let arr = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any],
              let root = arr.first as? [String: Any],
              let items = root["_items"] as? [[String: Any]],
              let gpu = items.first
        else { return nil }
        cachedDisplaysPlist = gpu
        return gpu
    }

    static func gpuCoreCount() -> Int? {
        guard let gpu = displaysPlist() else { return nil }
        for key in ["sppci_cores", "spdisplays_gpu_cores", "_spdisplays_gpu_cores"] {
            if let v = gpu[key] {
                if let i = v as? Int { return i }
                if let s = v as? String, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
            }
        }
        return nil
    }

    private static func chassis() -> String? {
        // hw.model alone does not distinguish a 14-inch from a 16-inch, and the
        // two have genuinely different sustained thermal ceilings. The built-in
        // panel's native resolution does distinguish them.
        guard let gpu = displaysPlist(),
              let displays = gpu["spdisplays_ndrvs"] as? [[String: Any]] else { return nil }
        for d in displays {
            guard (d["spdisplays_connection_type"] as? String)?.contains("internal") == true
                    || (d["spdisplays_display_type"] as? String)?.contains("built") == true
            else { continue }
            let res = (d["_spdisplays_pixels"] as? String) ?? (d["spdisplays_resolution"] as? String) ?? ""
            if res.contains("3024") { return "14-inch" }
            if res.contains("3456") { return "16-inch" }
            if res.contains("2560") { return "13-inch" }
            if res.contains("2880") { return "15-inch" }
        }
        return nil
    }

    private static func adapterWattage() -> Int? {
        let r = Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType"], timeout: 20)
        guard r.ok else { return nil }
        for line in r.stdout.split(separator: "\n") {
            if line.contains("Wattage (W)"),
               let v = line.split(separator: ":").last,
               let w = Int(v.trimmingCharacters(in: .whitespaces)) { return w }
        }
        return nil
    }

    private static func thermalNote() -> String? {
        guard let c = chassis() else { return nil }
        switch c {
        case "14-inch":
            return "14-inch chassis: smaller fan and heatsink than the 16-inch, so the same sustained load ramps fans sooner and throttles earlier."
        case "16-inch":
            return "16-inch chassis: larger thermal mass, sustains peak power longer before fans ramp."
        default:
            return nil
        }
    }
}
