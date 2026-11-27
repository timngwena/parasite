import Foundation

enum Shell {
    struct Result {
        var stdout: String
        var stderr: String
        var exitCode: Int32
        var ok: Bool { exitCode == 0 }
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 20) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        // Keep the environment minimal and predictable; these are parsers, and a
        // stray LANG or COLUMNS changes how ps and top format their columns.
        proc.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "COLUMNS": "400"]

        do { try proc.run() } catch {
            return Result(stdout: "", stderr: "launch failed: \(error.localizedDescription)", exitCode: -1)
        }

        // Drain both pipes concurrently. Reading one to completion first will
        // deadlock on any command that fills the other pipe's buffer.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "parasite.shell.drain", attributes: .concurrent)
        group.enter()
        q.async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        q.async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            _ = group.wait(timeout: .now() + 2)
            return Result(stdout: String(decoding: outData, as: UTF8.self),
                          stderr: "timed out after \(Int(timeout))s",
                          exitCode: -2)
        }
        group.wait()
        proc.waitUntilExit()
        return Result(stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self),
                      exitCode: proc.terminationStatus)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 { return value }
        var v32: Int32 = 0
        var s32 = MemoryLayout<Int32>.size
        if sysctlbyname(name, &v32, &s32, nil, 0) == 0 { return Int64(v32) }
        return nil
    }
}
