import Foundation
import ScaleCore
import Darwin
import Dispatch

final class OverrideTests {
    func testConfirmationTimeoutAndInput() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw CLIError("Could not create confirmation test pipe") }
        let reader = fds[0], writer = fds[1]
        defer { close(reader); close(writer) }
        let start = ProcessInfo.processInfo.systemUptime
        expectFalse(try waitForConfirmation(fd: reader, timeout: 0.2))
        expectTrue(ProcessInfo.processInfo.systemUptime - start >= 0.18)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            "yes\n".withCString { _ = write(writer, $0, strlen($0)) }
        }
        expectTrue(try waitForConfirmation(fd: reader, timeout: 2))
        "no\n".withCString { _ = write(writer, $0, strlen($0)) }
        expectFalse(try waitForConfirmation(fd: reader, timeout: 1))
        expectThrows(try waitForConfirmation(fd: -1, timeout: 0.1))
        expectThrows(try waitForConfirmation(fd: reader, timeout: .nan))
    }

    func testEncodingAndBounds() throws {
        let size = try Resolution("1920x1080")
        expectEqual(Array(size.hiDPIEntry), [0,0,15,0, 0,0,8,112, 0,0,0,9, 0,32,0,0])
        expectEqual(size.backingEntry.count, 8)
        for invalid in ["0x1080", "1920x0", "999999999999x1080", "4097x2160", "1920x1080x2", "-1920x1080", "1920x1080,", " 1920x1080"] {
            expectThrows(try Resolution(invalid), invalid)
        }
    }

    func testMergePreservesAndDeduplicates() throws {
        let existing: [String: Any] = ["DisplayProductName": "Existing name", "custom": 42, "scale-resolutions": [Data([1,2,3,4])]]
        let original = try PropertyListSerialization.data(fromPropertyList: existing, format: .binary, options: 0)
        let size = try Resolution("1920x1080")
        let merged = try mergedOverride(original: original, vendor: 0x610, product: 0xa05d, sizes: [size, size])
        let plist = try requireValue(PropertyListSerialization.propertyList(from: merged, format: nil) as? [String: Any])
        expectEqual(plist["DisplayProductName"] as? String, "Existing name")
        expectEqual(plist["custom"] as? Int, 42)
        expectEqual((plist["scale-resolutions"] as? [Data])?.count, 4)
        expectEqual(try mergedOverride(original: merged, vendor: 0x610, product: 0xa05d, sizes: [size]), merged)
    }

    func testRejectsMalformedAndConflictingPlists() throws {
        let size = try Resolution("1920x1080")
        for plist: [String: Any] in [["scale-resolutions": "wrong"], ["DisplayVendorID": 99]] {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            expectThrows(try mergedOverride(original: data, vendor: 1, product: 2, sizes: [size]))
        }
        expectThrows(try mergedOverride(original: Data("bad plist".utf8), vendor: 1, product: 2, sizes: [size]))
    }

    func fixture(_ body: (OverrideStore, URL) throws -> Void) throws {
        // /var is a symlink on macOS and is intentionally rejected by the store.
        // Keep isolated fixtures in the source checkout instead.
        let temp = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".scalectl-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = try OverrideStore(root: temp.appendingPathComponent("Overrides"), stateRoot: temp.appendingPathComponent("State"), vendor: 0x610, product: 0xa05d)
        try body(store, temp)
    }

    func testInstallAndRestoreOriginalBytes() throws {
        try fixture { store, _ in
            try FileManager.default.createDirectory(at: store.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = try PropertyListSerialization.data(fromPropertyList: ["untouched": true], format: .binary, options: 0)
            try original.write(to: store.target)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: store.target.path)
            try store.install(sizes: [Resolution("1920x1080")])
            expectNotEqual(try store.current(), original)
            expectThrows(try store.install(sizes: [Resolution("1600x900")]))
            try store.restore(apply: false)
            expectNotEqual(try store.current(), original)
            try store.restore(apply: true)
            expectEqual(try store.current(), original)
            expectEqual((try FileManager.default.attributesOfItem(atPath: store.target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
            expectFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
        }
    }

    func testNewOverrideRemovalAndConflictProtection() throws {
        try fixture { store, _ in
            try store.install(sizes: [Resolution("1920x1080")])
            let installed = try requireValue(store.current())
            let conflict = Data("changed by another application".utf8)
            try conflict.write(to: store.target)
            expectThrows(try store.restore(apply: true))
            expectEqual(try store.current(), conflict)
            expectTrue(FileManager.default.fileExists(atPath: store.backupURL.path))
            try installed.write(to: store.target)
            try store.restore(apply: true)
            expectNil(try store.current())
        }
    }

    func testRejectsSymlinkAndHardlink() throws {
        try fixture { store, temp in
            let victim = temp.appendingPathComponent("victim")
            try Data("do not modify".utf8).write(to: victim)
            try FileManager.default.createDirectory(at: store.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: store.target, withDestinationURL: victim)
            expectThrows(try store.install(sizes: [Resolution("1920x1080")]))
            try FileManager.default.removeItem(at: store.target)
            try FileManager.default.linkItem(at: victim, to: store.target)
            expectThrows(try store.install(sizes: [Resolution("1920x1080")]))
            expectEqual(try Data(contentsOf: victim), Data("do not modify".utf8))
        }
    }

    func testOperationLockAndInterruptedInstallRecovery() throws {
        try fixture { store, _ in
            try store.install(sizes: [Resolution("1920x1080")])
            let installed = try store.current()
            let fd = open(store.backupURL.deletingLastPathComponent().appendingPathComponent("operation.lock").path, O_RDWR)
            guard fd >= 0 else { throw CLIError("Could not open test lock") }
            defer { close(fd) }
            expectEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            expectThrows(try store.restore(apply: true))
            expectEqual(try store.current(), installed)
            expectEqual(flock(fd, LOCK_UN), 0)
            // A journal can exist before the first target write completes.
            try FileManager.default.removeItem(at: store.target)
            try store.restore(apply: true)
            expectNil(try store.current())
            expectFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
        }
        try fixture { store, _ in
            try FileManager.default.createDirectory(at: store.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = try PropertyListSerialization.data(fromPropertyList: ["original": true], format: .binary, options: 0)
            try original.write(to: store.target)
            try store.install(sizes: [Resolution("1920x1080")])
            try original.write(to: store.target)
            try store.restore(apply: true)
            expectEqual(try store.current(), original)
        }
    }
}

func failure(_ message: String, _ line: UInt) -> Never {
    fputs("FAIL line \(line): \(message)\n", stderr); exit(1)
}
func expectEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, line: UInt = #line) {
    do { if try a() != b() { failure("values differ", line) } } catch { failure("\(error)", line) }
}
func expectNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, line: UInt = #line) {
    do { if try a() == b() { failure("values unexpectedly equal", line) } } catch { failure("\(error)", line) }
}
func expectThrows<T>(_ value: @autoclosure () throws -> T, _ message: String = "", line: UInt = #line) {
    do { _ = try value(); failure("expected error: \(message)", line) } catch {}
}
func expectTrue(_ value: @autoclosure () throws -> Bool, line: UInt = #line) {
    do { if try !value() { failure("expected true", line) } } catch { failure("\(error)", line) }
}
func expectFalse(_ value: @autoclosure () throws -> Bool, line: UInt = #line) {
    do { if try value() { failure("expected false", line) } } catch { failure("\(error)", line) }
}
func expectNil<T>(_ value: @autoclosure () throws -> T?, line: UInt = #line) {
    do { if try value() != nil { failure("expected nil", line) } } catch { failure("\(error)", line) }
}
func requireValue<T>(_ value: T?) throws -> T {
    guard let value else { throw CLIError("Unexpected nil in check") }; return value
}

@main struct Checks {
    static func main() throws {
        if CommandLine.arguments.contains("--terminal") {
            let fd = open("/dev/tty", O_RDWR | O_NOCTTY)
            guard fd >= 0 else { throw CLIError("This regression check requires a terminal") }
            defer { close(fd) }
            // Match set's precondition; automation may queue an initial EOF.
            guard tcflush(fd, TCIFLUSH) == 0 else { throw CLIError("Cannot clear terminal test input") }
            let start = ProcessInfo.processInfo.systemUptime
            expectFalse(try waitForConfirmation(fd: fd, timeout: 1))
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            expectTrue(elapsed >= 0.95)
            print("PASS /dev/tty waited \(String(format: "%.2f", elapsed)) seconds. No display changes.")
            return
        }
        let suite = OverrideTests()
        let cases: [(String, () throws -> Void)] = [
            ("confirmation timeout, delayed yes, rejection and terminal errors", suite.testConfirmationTimeoutAndInput),
            ("encoding and bounds", suite.testEncodingAndBounds),
            ("merge preservation and deduplication", suite.testMergePreservesAndDeduplicates),
            ("malformed and conflicting plists", suite.testRejectsMalformedAndConflictingPlists),
            ("original byte restoration", suite.testInstallAndRestoreOriginalBytes),
            ("new override removal and conflict protection", suite.testNewOverrideRemovalAndConflictProtection),
            ("symlink and hardlink rejection", suite.testRejectsSymlinkAndHardlink),
            ("operation lock and interrupted install recovery", suite.testOperationLockAndInterruptedInstallRecovery)
        ]
        for (name, test) in cases { try test(); print("PASS \(name)") }
        print("All \(cases.count) checks passed. No system display settings changed.")
    }
}
