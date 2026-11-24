import Foundation

/// 子进程工具：有界等待（超时 SIGTERM，3 秒后升级 SIGKILL，与扫描 find 同款防护）。
enum Subprocess {
    static func waitBounded(_ process: Process, timeout: TimeInterval) -> Int32 {
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    kill(pid, SIGKILL)
                }
            }
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// 运行并返回 stdout 行（有界等待；失败返回空）。
    static func runLines(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        _ = waitBounded(process, timeout: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
    }
}
