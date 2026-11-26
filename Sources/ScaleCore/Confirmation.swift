import Foundation
import Darwin
import TerminalIO

/// Wait for a complete "yes" line using a monotonic deadline.
/// Terminal failures throw, so they cannot be mistaken for a normal timeout.
public func waitForConfirmation(fd: Int32, timeout: TimeInterval) throws -> Bool {
    guard timeout.isFinite, timeout > 0, timeout <= 60 else {
        throw CLIError("Invalid confirmation timeout.")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var input = Data()
    while true {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining <= 0 { return false }
        let result = scale_wait_readable(fd, Int32(max(1, ceil(remaining * 1000))))
        if result < 0 {
            if errno == EINTR { continue }
            throw CLIError("Cannot wait for terminal confirmation: \(String(cString: strerror(errno))).")
        }
        if result == 0 { continue }
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = read(fd, &bytes, bytes.count)
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            throw CLIError("Cannot read terminal confirmation: \(String(cString: strerror(errno))).")
        }
        guard count > 0 else { throw CLIError("Terminal closed before confirmation was received.") }
        input.append(contentsOf: bytes.prefix(count))
        if let newline = input.firstIndex(of: 10) {
            return String(decoding: input[..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
        }
        if input.count > 128 { return false }
    }
}
