import AppKit
import CoreGraphics
import Foundation

/// One virtual desktop.
struct SpaceEntry: Equatable, Sendable {
    let display: Int
    let id: Int
    let index: Int
    let active: Bool
    let windows: Int?
}

/// R25.3: Spaces, Mission Control and Stage Manager. The layer is private and changes
/// between releases, so every call returns nil when the symbol is missing and the tool
/// answers `unsupported` — a success is never imitated.
enum SpaceControl {
    private static let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let coreDock = "/System/Library/PrivateFrameworks/CoreDock.framework/CoreDock"

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias GetActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias MoveWindows = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias CopyWindows = @convention(c) (Int32, Int32, CFArray, UInt32,
                                                   UnsafeMutablePointer<UInt64>,
                                                   UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?
    private typealias DockNotification = @convention(c) (CFString) -> Int32

    private static func connection() -> Int32? {
        guard let raw = PrivateSymbols.load("CGSMainConnectionID", from: skyLight) else { return nil }
        return unsafeBitCast(raw, to: MainConnection.self)()
    }

    /// Pure parser over the CFArray shape, so the fixture in tests is the real contract.
    static func parse(_ displays: [[String: Any]]) -> [SpaceEntry] {
        var result: [SpaceEntry] = []
        for (displayIndex, display) in displays.enumerated() {
            let current = (display["Current Space"] as? [String: Any])
            let currentID = spaceID(current)
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            for (index, space) in spaces.enumerated() {
                guard let id = spaceID(space) else { continue }
                result.append(SpaceEntry(
                    display: displayIndex,
                    id: id,
                    index: index + 1,
                    active: id == currentID,
                    windows: nil
                ))
            }
        }
        return result
    }

    static func spaceID(_ space: [String: Any]?) -> Int? {
        guard let space else { return nil }
        if let value = space["ManagedSpaceID"] as? Int { return value }
        if let value = space["id64"] as? Int { return value }
        if let value = space["ManagedSpaceID"] as? Int64 { return Int(value) }
        return nil
    }

    static func entries() -> [SpaceEntry]? {
        guard let cid = connection(),
              let raw = PrivateSymbols.load("CGSCopyManagedDisplaySpaces", from: skyLight) else {
            return nil
        }
        let copy = unsafeBitCast(raw, to: CopyManagedDisplaySpaces.self)
        guard let unmanaged = copy(cid),
              let displays = unmanaged.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        var parsed = parse(displays)
        guard let copyWindows = PrivateSymbols.load("CGSCopyWindowsWithOptionsAndTags", from: skyLight)
        else { return parsed }
        let windows = unsafeBitCast(copyWindows, to: CopyWindows.self)
        parsed = parsed.map { entry in
            var tags: UInt64 = 0
            var clear: UInt64 = 0
            let ids = [entry.id] as CFArray
            guard let list = windows(cid, 0, ids, 0x7, &tags, &clear),
                  let windowIDs = list.takeRetainedValue() as? [Int] else {
                return entry
            }
            return SpaceEntry(
                display: entry.display, id: entry.id, index: entry.index,
                active: entry.active, windows: windowIDs.count
            )
        }
        return parsed
    }

    static func move(window: Int, to space: Int) -> Bool? {
        guard let cid = connection(),
              let raw = PrivateSymbols.load("CGSMoveWindowsToManagedSpace", from: skyLight) else {
            return nil
        }
        let move = unsafeBitCast(raw, to: MoveWindows.self)
        let ids = [window] as CFArray
        move(cid, ids, UInt64(space))
        return true
    }

    /// Mission Control through CoreDock: the same notification the F3 key sends.
    static func missionControl(show: Bool) -> Bool? {
        guard let raw = PrivateSymbols.load("CoreDockSendNotification", from: coreDock) else {
            return nil
        }
        let send = unsafeBitCast(raw, to: DockNotification.self)
        let name = show ? "com.apple.expose.awake" : "com.apple.expose.front.awake"
        return send(name as CFString) == 0
    }
}

/// Stage Manager lives in `com.apple.WindowManager`. There is no public API; the setting
/// is written with `defaults` and read back, so "enabled" is never claimed without proof.
enum StageManager {
    static func isEnabled() -> Bool? {
        let result = try? ToolRegistry.runSync(
            "defaults read com.apple.WindowManager GloballyEnabled",
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()), timeout: 10
        )
        guard let result else { return nil }
        let (status, body) = ToolRegistry.splitExit(result)
        guard status == 0 else { return false }
        return body.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// Returns the value actually read back, or nil when the write did not stick.
    static func set(enabled: Bool) -> Bool? {
        let command = "defaults write com.apple.WindowManager GloballyEnabled -bool "
            + (enabled ? "true" : "false")
        guard let result = try? ToolRegistry.runSync(
            command, cwd: URL(fileURLWithPath: NSTemporaryDirectory()), timeout: 10
        ) else { return nil }
        let (status, _) = ToolRegistry.splitExit(result)
        guard status == 0 else { return nil }
        return isEnabled() == enabled ? enabled : nil
    }
}
