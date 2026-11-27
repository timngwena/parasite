import Foundation
import Darwin

struct VMCounters: Equatable {
    var pageins: UInt64 = 0
    var pageouts: UInt64 = 0
    var swapins: UInt64 = 0
    var swapouts: UInt64 = 0
}

enum MemoryCollector {
    static let pageSize: UInt64 = UInt64(Shell.sysctlInt("hw.pagesize") ?? 16384)

    static func read() -> (MemoryState, VMCounters) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let total = UInt64(Shell.sysctlInt("hw.memsize") ?? 0)
        var state = MemoryState(
            totalBytes: total, freeBytes: 0, activeBytes: 0, inactiveBytes: 0,
            wiredBytes: 0, compressedBytes: 0, purgeableBytes: 0,
            swapTotalBytes: 0, swapUsedBytes: 0, swapFreeBytes: 0
        )
        var counters = VMCounters()

        if kr == KERN_SUCCESS {
            let ps = pageSize
            // Speculative pages are reclaimable on demand, so counting them as
            // free matches how the system actually behaves under pressure.
            state.freeBytes = (UInt64(stats.free_count) &+ UInt64(stats.speculative_count)) &* ps
            state.activeBytes = UInt64(stats.active_count) &* ps
            state.inactiveBytes = UInt64(stats.inactive_count) &* ps
            state.wiredBytes = UInt64(stats.wire_count) &* ps
            state.compressedBytes = UInt64(stats.compressor_page_count) &* ps
            state.purgeableBytes = UInt64(stats.purgeable_count) &* ps
            counters = VMCounters(
                pageins: UInt64(stats.pageins), pageouts: UInt64(stats.pageouts),
                swapins: UInt64(stats.swapins), swapouts: UInt64(stats.swapouts)
            )
        }

        var xsw = xsw_usage()
        var xswSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &xswSize, nil, 0) == 0 {
            state.swapTotalBytes = xsw.xsu_total
            state.swapUsedBytes = xsw.xsu_used
            state.swapFreeBytes = xsw.xsu_avail
        }

        state.pressurePercent = pressurePercent(state)
        return (state, counters)
    }

    /// Approximates the Activity Monitor pressure figure: the share of physical
    /// memory that cannot be reclaimed without paging something out.
    private static func pressurePercent(_ s: MemoryState) -> Double? {
        guard s.totalBytes > 0 else { return nil }
        let irreclaimable = Double(s.wiredBytes &+ s.compressedBytes)
        return min(100, (irreclaimable / Double(s.totalBytes)) * 100)
    }

    /// The kernel's own pressure level: 1 normal, 2 warning, 4 critical.
    static func kernelPressureLevel() -> Int? {
        Shell.sysctlInt("kern.memorystatus_vm_pressure_level").map(Int.init)
    }

    static func rates(from a: VMCounters, to b: VMCounters, seconds: Double) -> (Double, Double, Double, Double) {
        guard seconds > 0 else { return (0, 0, 0, 0) }
        // Counters are cumulative and monotonic; a negative delta means they
        // wrapped or the read failed, so clamp rather than report nonsense.
        func rate(_ x: UInt64, _ y: UInt64) -> Double {
            y >= x ? Double(y - x) / seconds : 0
        }
        return (rate(a.pageins, b.pageins), rate(a.pageouts, b.pageouts),
                rate(a.swapins, b.swapins), rate(a.swapouts, b.swapouts))
    }
}

enum StorageCollector {
    static func read() -> StorageState {
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        var name = "Macintosh HD"
        var total: UInt64 = 0, free: UInt64 = 0
        if let values = try? url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]) {
            name = values.volumeName ?? name
            total = UInt64(values.volumeTotalCapacity ?? 0)
            // "Important usage" is the figure that matters: it counts space the
            // system would free by evicting purgeable content, which is what
            // actually stands between you and a full-disk stall.
            free = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        }
        return StorageState(volumeName: name, totalBytes: total, freeBytes: free)
    }
}
