import Foundation
import CoreAudio
import IOKit.ps

enum SystemCollector {
    static func read(processes: [ProcessSample]) -> SystemState {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var bootedAt = Date()
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            bootedAt = Date(timeIntervalSince1970: Double(boot.tv_sec))
        }

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)

        let os = ProcessInfo.processInfo.operatingSystemVersion
        return SystemState(
            uptimeSeconds: Date().timeIntervalSince(bootedAt),
            bootedAt: bootedAt,
            loadAverage1: loads[0], loadAverage5: loads[1], loadAverage15: loads[2],
            processCount: processCount(),
            threadCount: nil,
            osVersion: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            cameraInUse: cameraLikelyInUse(processes: processes),
            microphoneInUse: microphoneInUse(),
            screenRecordingActive: nil
        )
    }

    private static func processCount() -> Int {
        let r = Shell.run("/bin/ps", ["-Ao", "pid="], timeout: 10)
        guard r.ok else { return 0 }
        return r.stdout.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// True when any audio input device reports that something is recording from
    /// it. This is the reliable, permission-free way to detect "you are on a call".
    static func microphoneInUse() -> Bool? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &devices) == noErr
        else { return nil }

        for device in devices {
            guard hasInputStreams(device) else { continue }
            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &runningAddr, 0, nil, &runningSize, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }

    private static func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    /// Heuristic, and labelled as such wherever it is shown.
    ///
    /// Presence alone is not enough: on Apple Silicon the camera daemons
    /// (appleh1xcamerad, VDCAssistant, avconferenced) stay resident whether or not
    /// a capture session is open, so checking for them at all produced a false
    /// positive on every machine. An open camera does measurable per-frame work, so
    /// the test is a marker daemon that is actually consuming CPU.
    static func cameraLikelyInUse(processes: [ProcessSample]) -> Bool? {
        guard !processes.isEmpty else { return nil }
        let markers = ["camerad", "vdcassistant", "avconferenced", "applecameraassistant"]
        return processes.contains { p in
            let name = p.name.lowercased()
            return p.cpuPercent > 1.0 && markers.contains { name.contains($0) }
        }
    }

    /// Power assertions name the process keeping the machine awake. During a
    /// Teams or Zoom call this is the clearest signal that a call is live, and it
    /// often names the exact process responsible for a stuck display.
    static func sleepAssertions() -> [String] {
        let r = Shell.run("/usr/bin/pmset", ["-g", "assertions"], timeout: 12)
        guard r.ok else { return [] }
        var out: [String] = []
        var inListing = false
        for line in r.stdout.components(separatedBy: "\n") {
            if line.contains("Listed by owning process") { inListing = true; continue }
            if inListing {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                if t.hasPrefix("pid ") { out.append(t) }
            }
        }
        return out
    }

    static func batteryState() -> (onBattery: Bool, percent: Double?, adapter: Bool, lowPower: Bool) {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return (false, nil, true, lowPower) }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            let state = desc[kIOPSPowerSourceStateKey] as? String
            let onBattery = state == kIOPSBatteryPowerValue
            var percent: Double?
            if let current = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percent = Double(current) / Double(max) * 100
            }
            return (onBattery, percent, !onBattery, lowPower)
        }
        return (false, nil, true, lowPower)
    }

    static func cpuUsagePercent() -> Double {
        // Total CPU load across all cores, derived from the host tick counters.
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &cpuInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }

        let user = Double(cpuInfo.cpu_ticks.0)
        let system = Double(cpuInfo.cpu_ticks.1)
        let idle = Double(cpuInfo.cpu_ticks.2)
        let nice = Double(cpuInfo.cpu_ticks.3)

        // These are cumulative since boot, so a single read is meaningless on its
        // own. Diff against the previous read to get the load over the interval.
        defer { previousTicks = (user, system, idle, nice) }
        guard let prev = previousTicks else { return 0 }
        let dUser = user - prev.0, dSystem = system - prev.1
        let dIdle = idle - prev.2, dNice = nice - prev.3
        let total = dUser + dSystem + dIdle + dNice
        guard total > 0 else { return 0 }
        return (dUser + dSystem + dNice) / total * 100
    }

    private static var previousTicks: (Double, Double, Double, Double)?

    static func thermalStateDescription() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}
