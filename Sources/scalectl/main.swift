import CoreGraphics
import ColorSync
import Foundation
import ScaleCore
import Darwin

let help = """
scalectl — native macOS scaled resolution manager

  scalectl displays [--json]
  scalectl show [--display UUID_OR_ID] [--json]
  scalectl modes --display UUID_OR_ID [--json]
  scalectl add --display UUID_OR_ID --sizes 1920x1241,2048x1324 [--apply]
  scalectl restore --vendor HEX --product HEX [--apply]
  scalectl set --display UUID_OR_ID --mode MODE_ID [--timeout 15]

add and restore PREVIEW by default. --apply requires sudo.
add preserves existing override keys and modes, and backs up original bytes.
After add/restore: reboot, then run modes again to see what macOS accepts.
Overrides affect ALL displays with the same vendor/product identifiers.
Built-in display support depends on macOS; new modes are not guaranteed.
set requires a local terminal; type 'yes' and Enter before the timeout to keep.
set is session-scoped and must be run as your normal user, without sudo.
Mode IDs are current-session values: list again after reconnecting/rebooting.
Use UUIDs from displays for stable display selection.
"""

struct Arguments {
    let command: String
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) throws {
        command = raw.first ?? "help"
        let specs: [String: (Set<String>, Set<String>)] = [
            "help": ([], []), "--help": ([], []), "-h": ([], []),
            "displays": ([], ["--json"]),
            "show": (["--display"], ["--json"]),
            "modes": (["--display"], ["--json"]),
            "add": (["--display", "--sizes"], ["--apply"]),
            "restore": (["--vendor", "--product"], ["--apply"]),
            "set": (["--display", "--mode", "--timeout"], [])
        ]
        guard let (options, switches) = specs[command] else { throw CLIError("Unknown command '\(command)'. Run scalectl help.") }
        var index = 1
        while index < raw.count {
            let key = raw[index]
            guard values[key] == nil, !flags.contains(key) else { throw CLIError("Repeated option \(key).") }
            if switches.contains(key) { flags.insert(key); index += 1 }
            else if options.contains(key), index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                values[key] = raw[index + 1]; index += 2
            } else { throw CLIError("Unknown option or missing value: \(key).") }
        }
    }
    func require(_ key: String) throws -> String {
        guard let value = values[key] else { throw CLIError("Missing \(key). Run scalectl help.") }
        return value
    }
}

func check(_ error: CGError, _ operation: String) throws {
    guard error == .success else { throw CLIError("\(operation) failed (Core Graphics \(error.rawValue)).") }
}

func onlineDisplays() throws -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    try check(CGGetOnlineDisplayList(0, nil, &count), "List displays")
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    try check(CGGetOnlineDisplayList(count, &ids, &count), "List displays")
    return Array(ids.prefix(Int(count)))
}

func uuid(_ id: CGDirectDisplayID) -> String {
    guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "unavailable" }
    return CFUUIDCreateString(nil, value) as String
}

func selectDisplay(_ text: String) throws -> CGDirectDisplayID {
    let displays = try onlineDisplays()
    guard let id = displays.first(where: { String($0) == text || uuid($0).caseInsensitiveCompare(text) == .orderedSame }) else {
        throw CLIError("Display '\(text)' is not online. Run scalectl displays.")
    }
    return id
}

func allModes(_ id: CGDirectDisplayID) throws -> [CGDisplayMode] {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else {
        throw CLIError("Cannot enumerate display modes.")
    }
    return modes.sorted {
        if $0.width != $1.width { return $0.width < $1.width }
        if $0.height != $1.height { return $0.height < $1.height }
        if $0.pixelWidth != $1.pixelWidth { return $0.pixelWidth > $1.pixelWidth }
        if $0.refreshRate != $1.refreshRate { return $0.refreshRate > $1.refreshRate }
        return $0.ioDisplayModeID < $1.ioDisplayModeID
    }
}

func modeRow(_ mode: CGDisplayMode) -> [String: Any] {
    ["modeID": mode.ioDisplayModeID, "width": mode.width, "height": mode.height,
     "pixelWidth": mode.pixelWidth, "pixelHeight": mode.pixelHeight,
     "hiDPI": mode.pixelWidth > mode.width && mode.pixelHeight > mode.height,
     "refreshRate": mode.refreshRate, "usableForDesktop": mode.isUsableForDesktopGUI()]
}

func showConfiguration(_ args: Arguments) throws {
    let ids: [CGDirectDisplayID]
    if let selector = args.values["--display"] { ids = [try selectDisplay(selector)] }
    else { ids = try onlineDisplays() }
    var rows: [[String: Any]] = []
    for id in ids {
        guard let mode = CGDisplayCopyDisplayMode(id) else {
            throw CLIError("Cannot read current mode for display \(id).")
        }
        let bounds = CGDisplayBounds(id)
        var current = modeRow(mode)
        let scaleX = mode.width > 0 ? Double(mode.pixelWidth) / Double(mode.width) : 0
        let scaleY = mode.height > 0 ? Double(mode.pixelHeight) / Double(mode.height) : 0
        current["renderScaleX"] = scaleX
        current["renderScaleY"] = scaleY
        let builtIn = CGDisplayIsBuiltin(id) != 0
        let main = CGDisplayIsMain(id) != 0
        let mirror = CGDisplayMirrorsDisplay(id)
        let vendor = String(CGDisplayVendorNumber(id), radix: 16)
        let product = String(CGDisplayModelNumber(id), radix: 16)
        rows.append(["id": id, "uuid": uuid(id), "builtIn": builtIn, "main": main,
                     "vendor": vendor, "product": product, "currentMode": current,
                     "rotation": CGDisplayRotation(id), "origin": ["x": bounds.origin.x, "y": bounds.origin.y],
                     "mirrorsDisplayID": mirror == kCGNullDirectDisplay ? NSNull() : mirror as Any])
        if !args.flags.contains("--json") {
            if rows.count > 1 { print("") }
            print("Display \(id) (\(builtIn ? "built-in" : "external")\(main ? ", main" : ""))")
            print("  UUID:             \(uuid(id))")
            print("  Model:            vendor \(vendor), product \(product) (hex)")
            print("  Mode ID:          \(mode.ioDisplayModeID)")
            print("  Looks like:       \(mode.width)x\(mode.height)")
            print("  Render pixels:    \(mode.pixelWidth)x\(mode.pixelHeight)")
            let scale = abs(scaleX - scaleY) < 0.01
                ? String(format: "~%.2fx", scaleX)
                : String(format: "~%.2fx horizontal, ~%.2fx vertical", scaleX, scaleY)
            print("  Rendering scale:  \(scale) (\(mode.pixelWidth > mode.width && mode.pixelHeight > mode.height ? "HiDPI" : "LoDPI"))")
            print("  Refresh rate:     \(mode.refreshRate == 0 ? "adaptive/unspecified" : String(format: "%.2f Hz", mode.refreshRate))")
            print("  Rotation:         \(String(format: "%.0f", CGDisplayRotation(id))) degrees")
            print("  Position:         (\(Int(bounds.origin.x)), \(Int(bounds.origin.y)))")
            print("  Mirrors display:  \(mirror == kCGNullDirectDisplay ? "none" : String(mirror))")
        }
    }
    if args.flags.contains("--json") { try json(rows) }
    else if ids.isEmpty { print("No online displays.") }
}

func json(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func store(vendor: UInt32, product: UInt32) throws -> OverrideStore {
    try OverrideStore(root: URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides"),
                      stateRoot: URL(fileURLWithPath: "/Library/Application Support/ScaleCLI"),
                      vendor: vendor, product: product)
}

func hex(_ text: String) throws -> UInt32 {
    let value = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }),
          let number = UInt32(value, radix: 16), number > 0 else { throw CLIError("Invalid hexadecimal model ID '\(text)'.") }
    return number
}

func applyMode(_ id: CGDirectDisplayID, _ mode: CGDisplayMode) throws {
    var configuration: CGDisplayConfigRef?
    try check(CGBeginDisplayConfiguration(&configuration), "Begin configuration")
    guard let configuration else { throw CLIError("No display configuration returned.") }
    let status = CGConfigureDisplayWithDisplayMode(configuration, id, mode, nil)
    guard status == .success else { CGCancelDisplayConfiguration(configuration); try check(status, "Configure mode"); return }
    try check(CGCompleteDisplayConfiguration(configuration, .forSession), "Apply mode")
}

func setMode(_ args: Arguments) throws {
    guard geteuid() != 0 else { throw CLIError("Run set as your normal logged-in user, without sudo.") }
    let id = try selectDisplay(args.require("--display"))
    let text = try args.require("--mode")
    guard let requested = UInt32(text) else { throw CLIError("Mode ID must be a decimal integer from modes.") }
    guard let timeout = Int(args.values["--timeout"] ?? "15"), (5...60).contains(timeout) else {
        throw CLIError("Timeout must be 5–60 seconds.")
    }
    let matches = try allModes(id).filter { $0.ioDisplayModeID == requested }
    guard let target = matches.first, target.isUsableForDesktopGUI() else { throw CLIError("Mode ID is unavailable or unsuitable for desktop use.") }
    guard let previous = CGDisplayCopyDisplayMode(id) else { throw CLIError("Cannot save current mode.") }
    guard previous.ioDisplayModeID != requested else { print("Already using this mode."); return }
    let tty = open("/dev/tty", O_RDWR | O_NOCTTY)
    guard tty >= 0 else { throw CLIError("A local interactive terminal is required for rollback confirmation.") }
    defer { close(tty) }
    guard tcflush(tty, TCIFLUSH) == 0 else { throw CLIError("Cannot clear terminal input before confirmation.") }
    let oldINT = signal(SIGINT, SIG_IGN), oldTERM = signal(SIGTERM, SIG_IGN), oldHUP = signal(SIGHUP, SIG_IGN)
    defer { signal(SIGINT, oldINT); signal(SIGTERM, oldTERM); signal(SIGHUP, oldHUP) }
    var keep = false
    defer {
        if !keep {
            do { try applyMode(id, previous); print("Previous mode restored.") }
            catch { fputs("RESTORE FAILED: \(error). Reconnect the display or log out.\n", stderr) }
        }
    }
    try applyMode(id, target)
    let prompt = "Type yes and press Enter within \(timeout) seconds to keep \(target.width)x\(target.height): "
    prompt.withCString { _ = write(tty, $0, strlen($0)) }
    keep = try waitForConfirmation(fd: tty, timeout: Double(timeout))
    if keep { print("Mode kept for this login session.") }
}

func run() throws {
    let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
    switch args.command {
    case "help", "--help", "-h": print(help)
    case "show": try showConfiguration(args)
    case "displays":
        let rows = try onlineDisplays().map { id -> [String: Any] in
            var row: [String: Any] = ["id": id, "uuid": uuid(id), "builtIn": CGDisplayIsBuiltin(id) != 0,
                "main": CGDisplayIsMain(id) != 0, "vendor": String(format: "%x", CGDisplayVendorNumber(id)),
                "product": String(format: "%x", CGDisplayModelNumber(id))]
            if let mode = CGDisplayCopyDisplayMode(id) { row["currentMode"] = modeRow(mode) }
            return row
        }
        if args.flags.contains("--json") { try json(rows) }
        else {
            for row in rows {
                print("\(row["uuid"]!)  id=\(row["id"]!)  \((row["builtIn"] as? Bool) == true ? "built-in" : "external")  vendor=\(row["vendor"]!) product=\(row["product"]!)")
            }
        }
    case "modes":
        let id = try selectDisplay(args.require("--display"))
        let current = CGDisplayCopyDisplayMode(id)?.ioDisplayModeID
        let modes = try allModes(id)
        if args.flags.contains("--json") {
            try json(modes.map { mode -> [String: Any] in
                var row = modeRow(mode); row["current"] = mode.ioDisplayModeID == current; return row
            })
        } else {
            print("MODE ID    LOOKS LIKE     RENDER PIXELS    TYPE     REFRESH (* current)")
            for mode in modes {
                let hidpi = mode.pixelWidth > mode.width && mode.pixelHeight > mode.height
                print("\(mode.ioDisplayModeID == current ? "*" : " ") \(mode.ioDisplayModeID)  \(mode.width)x\(mode.height)  \(mode.pixelWidth)x\(mode.pixelHeight)  \(hidpi ? "HiDPI" : "LoDPI")  \(mode.refreshRate == 0 ? "adaptive/unspecified" : String(format: "%.2f Hz", mode.refreshRate))")
            }
        }
    case "add":
        let id = try selectDisplay(args.require("--display"))
        let sizes = try args.require("--sizes").split(separator: ",", omittingEmptySubsequences: false).map { try Resolution(String($0)) }
        let override = try store(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id))
        let preview = try override.preview(sizes: sizes)
        print("Display: \(uuid(id))\nModel override: \(override.target.path)")
        for size in sizes { print("  request \(size) HiDPI (renders \(size.width * 2)x\(size.height * 2))") }
        print("Merged plist: \(preview.count) bytes. Affects every display of this model.")
        print("Restore: sudo scalectl restore --vendor \(String(CGDisplayVendorNumber(id), radix: 16)) --product \(String(CGDisplayModelNumber(id), radix: 16)) --apply")
        if args.flags.contains("--apply") {
            guard geteuid() == 0 else { throw CLIError("Installing the override requires sudo. Preview completed; no changes made.") }
            try override.install(sizes: sizes)
            print("Installed. Backup: \(override.backupURL.path)\nReboot, then use modes to check which requests macOS accepted.")
        } else { print("PREVIEW ONLY. Add --apply with sudo to install. No system changes made.") }
    case "restore":
        let override = try store(vendor: hex(args.require("--vendor")), product: hex(args.require("--product")))
        let apply = args.flags.contains("--apply")
        guard !apply || geteuid() == 0 else { throw CLIError("Restoring system configuration requires sudo.") }
        try override.restore(apply: apply)
        print(apply ? "Original override restored. Reboot to activate." : "Backup and current override checked. Add --apply with sudo to restore. No changes made.")
    case "set": try setMode(args)
    default: throw CLIError("Unknown command.")
    }
}

do { try run() }
catch { fputs("Error: \(error)\n", stderr); exit(1) }
