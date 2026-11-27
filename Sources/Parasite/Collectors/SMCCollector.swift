import Foundation
import IOKit

/// Reads the System Management Controller directly over IOKit.
///
/// This exists because the `smc` powermetrics sampler is rejected on Apple
/// Silicon, so fan speed and die temperature are otherwise unavailable — and
/// "the fans spun up" is the single most common symptom this app is asked about.
/// Reading AppleSMC needs no root, so these signals are available even without
/// the powermetrics grant.
enum SMCCollector {

    struct Fan: Codable, Equatable {
        var index: Int
        var actualRPM: Double
        var minimumRPM: Double?
        var maximumRPM: Double?
        var targetRPM: Double?

        /// Where this fan sits between its own floor and ceiling. Far more
        /// meaningful than raw RPM: 2300 RPM is silent on one machine and audible
        /// on another, but "8% of range" means the same thing everywhere.
        var loadFraction: Double? {
            guard let minimumRPM, let maximumRPM, maximumRPM > minimumRPM else { return nil }
            return max(0, min(1, (actualRPM - minimumRPM) / (maximumRPM - minimumRPM)))
        }

        /// The controller has decided to speed up but the fan has not got there
        /// yet — the moment you actually hear as "the fans just kicked in".
        var isRampingUp: Bool {
            guard let targetRPM else { return false }
            return targetRPM > actualRPM + 150
        }
    }

    struct Reading: Codable, Equatable {
        var fans: [Fan] = []
        var cpuDieC: Double?
        var gpuDieC: Double?
        var efficiencyDieC: Double?
        var enclosureC: Double?
        var batteryC: Double?
        /// Whole-system power draw, which includes the display and peripherals —
        /// a useful cross-check against the SoC-only figure from powermetrics.
        var systemWatts: Double?

        var maxFanLoad: Double? { fans.compactMap(\.loadFraction).max() }
        var anyFanRamping: Bool { fans.contains(where: \.isRampingUp) }
    }

    // MARK: - Public

    static func read() -> Reading? {
        guard let connection = Connection.shared else { return nil }
        var out = Reading()

        let fanCount = Int(connection.number("FNum") ?? 0)
        for i in 0..<min(fanCount, 4) {
            guard let actual = connection.number("F\(i)Ac") else { continue }
            out.fans.append(Fan(
                index: i,
                actualRPM: actual,
                minimumRPM: connection.number("F\(i)Mn"),
                maximumRPM: connection.number("F\(i)Mx"),
                targetRPM: connection.number("F\(i)Tg")
            ))
        }

        // Apple Silicon exposes one sensor per core cluster rather than a single
        // package sensor, so the hottest is the one that matters.
        out.cpuDieC = hottest(connection, ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0b",
                                          "Tp0e", "Tp0j", "Tp0n", "Tp0r", "Tp0v", "Tp0x"])
        out.gpuDieC = hottest(connection, ["Tg0D", "Tg05"])
        out.efficiencyDieC = hottest(connection, ["Te05"])
        out.enclosureC = hottest(connection, ["Ts0S", "Ts0P", "Ts1S"])
        out.batteryC = hottest(connection, ["TB0T", "TB1T"])
        out.systemWatts = connection.number("PSTR")

        return out.fans.isEmpty && out.cpuDieC == nil ? nil : out
    }

    private static func hottest(_ c: Connection, _ keys: [String]) -> Double? {
        keys.compactMap { c.number($0) }.filter { $0 > 0 && $0 < 150 }.max()
    }

    // MARK: - IOKit plumbing

    /// One long-lived connection. Opening AppleSMC per key would dominate the cost
    /// of reading a dozen sensors several times a second.
    private final class Connection {
        static let shared: Connection? = Connection()
        private let port: io_connect_t

        init?() {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
            guard service != 0 else { return nil }
            var conn: io_connect_t = 0
            let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
            IOObjectRelease(service)
            guard result == kIOReturnSuccess else { return nil }
            port = conn
        }

        func number(_ key: String) -> Double? {
            guard let (type, bytes) = read(key) else { return nil }
            return decode(bytes, type: type)
        }

        private func read(_ key: String) -> (type: String, bytes: [UInt8])? {
            // Two round trips per key: first for the value's type and size, then
            // for the bytes themselves. The SMC has no combined call.
            var infoRequest = ParamStruct()
            infoRequest.key = Self.fourCC(key)
            infoRequest.data8 = 9                      // kSMCGetKeyInfo
            guard let info = call(&infoRequest), info.result == 0 else { return nil }

            var readRequest = ParamStruct()
            readRequest.key = Self.fourCC(key)
            readRequest.keyInfo = info.keyInfo
            readRequest.data8 = 5                      // kSMCReadKey
            guard let value = call(&readRequest), value.result == 0 else { return nil }

            let all = withUnsafeBytes(of: value.bytes) { Array($0) }
            let size = Int(info.keyInfo.dataSize)
            guard size > 0, size <= all.count else { return nil }
            return (Self.typeString(info.keyInfo.dataType), Array(all.prefix(size)))
        }

        private func call(_ input: inout ParamStruct) -> ParamStruct? {
            var output = ParamStruct()
            var size = MemoryLayout<ParamStruct>.stride
            let r = IOConnectCallStructMethod(
                port, 2, &input, MemoryLayout<ParamStruct>.stride, &output, &size
            )
            return r == kIOReturnSuccess ? output : nil
        }

        private func decode(_ b: [UInt8], type: String) -> Double? {
            let t = type.trimmingCharacters(in: .whitespaces)
            switch t {
            case "flt":
                // Little-endian IEEE 754 single.
                guard b.count >= 4 else { return nil }
                let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                let f = Float(bitPattern: bits)
                return f.isFinite ? Double(f) : nil
            case "fpe2":
                // Big-endian fixed point, 2 fractional bits — the older fan encoding.
                guard b.count >= 2 else { return nil }
                return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
            case "ui8", "ui16", "ui32":
                return b.reduce(0.0) { $0 * 256 + Double($1) }
            case "sp78":
                guard b.count >= 2 else { return nil }
                return Double(Int8(bitPattern: b[0])) + Double(b[1]) / 256.0
            default:
                return nil
            }
        }

        private static func fourCC(_ s: String) -> UInt32 {
            s.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        private static func typeString(_ v: UInt32) -> String {
            let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                         UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
            return String(bytes: bytes, encoding: .ascii) ?? ""
        }
    }

    // Layout must match the kernel's SMCParamStruct exactly.
    private struct Version { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0
                             var reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct LimitData { var version: UInt16 = 0; var length: UInt16 = 0
                               var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
    fileprivate struct KeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    private struct ParamStruct {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = LimitData()
        var keyInfo = KeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
}
