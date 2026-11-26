import Foundation
import CryptoKit
import Darwin

public struct CLIError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct Resolution: Equatable, Hashable, CustomStringConvertible {
    public let width: UInt32
    public let height: UInt32
    public var description: String { "\(width)x\(height)" }

    public init(_ text: String) throws {
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
              let w = UInt32(parts[0]), let h = UInt32(parts[1]),
              (320...4096).contains(w), (200...4096).contains(h) else {
            throw CLIError("Invalid size '\(text)'. Use WIDTHxHEIGHT, width 320–4096, height 200–4096 (backing dimensions limited to 8192).")
        }
        width = w; height = h
    }

    // Observed native override encoding: big-endian backing size, scaling flags.
    // This is an undocumented WindowServer format, not an Apple compatibility promise.
    public var hiDPIEntry: Data { words([width * 2, height * 2, 0x9, 0x00200000]) }
    public var backingEntry: Data { words([width * 2, height * 2]) }
    public var lowDPIEntry: Data { words([width, height]) }
}

private func words(_ values: [UInt32]) -> Data {
    var data = Data()
    for value in values {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
    return data
}

public func mergedOverride(original: Data?, vendor: UInt32, product: UInt32, sizes: [Resolution]) throws -> Data {
    guard !sizes.isEmpty, sizes.count <= 100 else { throw CLIError("Provide 1–100 resolutions.") }
    var plist: [String: Any] = [:]
    if let original {
        guard let decoded = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any] else {
            throw CLIError("Existing override is not a dictionary; refusing to replace it.")
        }
        plist = decoded
        for (key, expected) in [("DisplayVendorID", vendor), ("DisplayProductID", product)] {
            if let existing = plist[key], (existing as? NSNumber)?.uint32Value != expected {
                throw CLIError("Existing override has a conflicting \(key).")
            }
        }
    }
    if let existing = plist["scale-resolutions"], !(existing is [Data]) {
        throw CLIError("Existing scale-resolutions has an unexpected format.")
    }
    var entries = plist["scale-resolutions"] as? [Data] ?? []
    for size in sizes {
        for entry in [size.hiDPIEntry, size.backingEntry, size.lowDPIEntry] where !entries.contains(entry) {
            entries.append(entry)
        }
    }
    plist["DisplayVendorID"] = vendor
    plist["DisplayProductID"] = product
    plist["scale-resolutions"] = entries
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
}

private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private struct Backup: Codable {
    let vendor: UInt32
    let product: UInt32
    let original: Data?
    let originalMode: UInt16?
    let installedHash: String
}

/// Only constructed by the executable with the fixed system roots.
/// Alternate roots allow tests to exercise the full lifecycle without system writes.
public struct OverrideStore {
    public let root: URL
    public let stateRoot: URL
    public let vendor: UInt32
    public let product: UInt32

    public init(root: URL, stateRoot: URL, vendor: UInt32, product: UInt32) throws {
        guard vendor > 0, product > 0 else { throw CLIError("Missing display model identifiers.") }
        self.root = root; self.stateRoot = stateRoot; self.vendor = vendor; self.product = product
    }
    public var target: URL {
        root.appendingPathComponent(String(format: "DisplayVendorID-%x/DisplayProductID-%x", vendor, product))
    }
    public var backupURL: URL {
        stateRoot.appendingPathComponent(String(format: "%x-%x.plist", vendor, product))
    }

    public func current() throws -> Data? { try read(target) }
    public func preview(sizes: [Resolution]) throws -> Data {
        try mergedOverride(original: current(), vendor: vendor, product: product, sizes: sizes)
    }

    public func install(sizes: [Resolution]) throws {
        try secureDirectories(stateRoot)
        try withLock { try installLocked(sizes: sizes) }
    }

    private func installLocked(sizes: [Resolution]) throws {
        try secureDirectories(target.deletingLastPathComponent())
        try validate(target); try validate(backupURL)
        guard try read(backupURL) == nil else {
            throw CLIError("A ScaleCLI backup already exists. Restore it before installing a different list.")
        }
        let original = try current()
        let updated = try mergedOverride(original: original, vendor: vendor, product: product, sizes: sizes)
        guard updated != original else { throw CLIError("Override is already identical; nothing to install.") }
        let mode = try original.map { _ in
            (try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        }
        let backup = Backup(vendor: vendor, product: product, original: original, originalMode: mode, installedHash: digest(updated))
        let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
        // Journal first: restore can recover even if installation is interrupted.
        try write(encoder.encode(backup), to: backupURL, mode: 0o600)
        try write(updated, to: target, mode: 0o644)
    }

    public func restore(apply: Bool) throws {
        if apply {
            // No new directories are needed to restore an existing backup.
            try withLock { try restoreLocked(apply: true) }
        } else { try restoreLocked(apply: false) }
    }

    private func restoreLocked(apply: Bool) throws {
        guard let bytes = try read(backupURL) else { throw CLIError("No ScaleCLI backup exists for this model.") }
        let backup = try PropertyListDecoder().decode(Backup.self, from: bytes)
        guard backup.vendor == vendor, backup.product == product else { throw CLIError("Backup identity mismatch.") }
        let installed = try current()
        guard installed == backup.original || installed.map(digest) == backup.installedHash else {
            throw CLIError("Override changed after installation. Refusing to overwrite another tool's changes. Backup: \(backupURL.path)")
        }
        guard apply else { return }
        if let original = backup.original {
            try write(original, to: target, mode: backup.originalMode ?? 0o644)
        } else if installed != nil {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.removeItem(at: backupURL)
    }

    private func withLock(_ action: () throws -> Void) throws {
        let url = stateRoot.appendingPathComponent("operation.lock")
        try validate(url)
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CLIError("Cannot open operation lock.") }
        defer { close(fd) }
        try validate(url)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CLIError("Another ScaleCLI operation is running.") }
        defer { flock(fd, LOCK_UN) }
        try action()
    }

    private func read(_ url: URL) throws -> Data? {
        try validate(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func write(_ data: Data, to url: URL, mode: UInt16) throws {
        try validate(url)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, mode_t(mode)) == 0 else { throw CLIError("Cannot set permissions: \(url.path)") }
    }

    private func secureDirectories(_ url: URL) throws {
        try validate(url)
        if !FileManager.default.fileExists(atPath: url.path) {
            try secureDirectories(url.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        }
        try validate(url)
    }

    private func validate(_ url: URL) throws {
        // standardizedFileURL may rewrite /private/var to the /var symlink.
        // Inspect the literal ancestors instead; production roots are fixed.
        var cursor = url
        while cursor.path != "/" {
            var info = stat()
            if lstat(cursor.path, &info) == 0 {
                let kind = info.st_mode & S_IFMT
                guard kind == S_IFDIR || (cursor == url && kind == S_IFREG),
                      info.st_nlink == 1 || kind == S_IFDIR else {
                    throw CLIError("Refusing symlink, hard-linked file, or special path: \(cursor.path)")
                }
                if geteuid() == 0 {
                    guard info.st_uid == 0, info.st_mode & 0o022 == 0 else {
                        throw CLIError("System path must be root-owned and not writable by other users: \(cursor.path)")
                    }
                }
            } else if errno != ENOENT { throw CLIError("Cannot inspect \(cursor.path): \(String(cString: strerror(errno)))") }
            cursor.deleteLastPathComponent()
        }
    }
}
