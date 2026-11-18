import AppKit
import CoreGraphics
import Foundation
import ObjectiveC

/// One display mode as the layout file stores it.
struct DisplayModeEntry: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let refresh: Double
}

struct DisplayEntry: Codable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let mode: DisplayModeEntry?
    let originX: Double
    let originY: Double
    let mirrored: Bool
    let main: Bool
    let builtin: Bool
}

struct DisplayLayout: Codable, Equatable, Sendable {
    let savedAt: String
    let displays: [DisplayEntry]
}

/// R25.2: display state has to survive a bad `set_mode` — a wrong resolution is "no
/// signal" on a real monitor. The snapshot is written at launch and before every change.
enum DisplayLayoutStore {
    /// Test seam: a temp file instead of the user's real backup.
    nonisolated(unsafe) static var storageOverride: URL?

    static var fileURL: URL {
        storageOverride ?? AppPaths.backupsDirectory.appendingPathComponent("display.json")
    }

    static func save(_ layout: DisplayLayout) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        try? AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> DisplayLayout? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(DisplayLayout.self, from: data)
    }
}

/// Mode choice is pure so the dangerous part — applying it — is the only thing left.
enum DisplayChooser {
    /// Exact size, closest refresh; when the exact size is missing, the nearest one that
    /// is not larger in either dimension, so a typo does not black out the screen.
    static func pick(_ modes: [DisplayModeEntry], width: Int, height: Int,
                     refresh: Double? = nil) -> DisplayModeEntry? {
        let sameSize = modes.filter { $0.width == width && $0.height == height }
        if let refresh, let exact = sameSize.min(by: {
            abs($0.refresh - refresh) < abs($1.refresh - refresh)
        }), abs(exact.refresh - refresh) <= 1 {
            return exact
        }
        if let best = sameSize.max(by: { $0.refresh < $1.refresh }) { return best }
        let smaller = modes.filter { $0.width <= width && $0.height <= height }
        return smaller.max { $0.width * $0.height < $1.width * $1.height }
    }
}

/// R25.2: displays, layout and Night Shift. Every mutating action needs `confirm: true`
/// and saves the previous layout first.
enum DisplayControl {
    static func entries() -> [DisplayEntry] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).enumerated().map { index, id in
            let bounds = CGDisplayBounds(id)
            let current = CGDisplayCopyDisplayMode(id)
            let mode = current.map {
                DisplayModeEntry(
                    width: $0.width, height: $0.height,
                    refresh: $0.refreshRate > 0 ? $0.refreshRate : 60
                )
            }
            let builtin = CGDisplayIsBuiltin(id) != 0
            return DisplayEntry(
                id: id,
                name: builtin ? "builtin" : (id == main ? "main" : "display \(index)"),
                mode: mode,
                originX: Double(bounds.origin.x),
                originY: Double(bounds.origin.y),
                mirrored: CGDisplayIsInMirrorSet(id) != 0,
                main: id == main,
                builtin: builtin
            )
        }
    }

    static func layout() -> DisplayLayout {
        DisplayLayout(savedAt: Timestamps.now(), displays: entries())
    }

    static func modes(of id: CGDirectDisplayID) -> [DisplayModeEntry] {
        let raw = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? []
        return raw.map {
            DisplayModeEntry(
                width: $0.width, height: $0.height,
                refresh: $0.refreshRate > 0 ? $0.refreshRate : 60
            )
        }
    }

    static func displayID(at index: Int) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        guard index >= 0, index < Int(count) else { return nil }
        return ids[index]
    }

    static func scale(of id: CGDirectDisplayID) -> CGFloat {
        let bounds = CGDisplayBounds(id)
        guard bounds.width > 0 else { return 1 }
        return CGFloat(CGDisplayPixelsWide(id)) / bounds.width
    }

    /// All three mutations share one configuration transaction: begin, change, commit.
    static func apply(
        origin: (id: CGDirectDisplayID, point: CGPoint)? = nil,
        mode: (id: CGDirectDisplayID, entry: DisplayModeEntry)? = nil,
        mirror: (id: CGDirectDisplayID, master: CGDirectDisplayID)? = nil
    ) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        var completed = false
        defer { if !completed { CGCancelDisplayConfiguration(config) } }

        if let origin {
            guard CGConfigureDisplayOrigin(
                config, origin.id,
                Int32(origin.point.x.rounded()), Int32(origin.point.y.rounded())
            ) == .success else { return false }
        }
        if let mode {
            guard let displayMode = CGDisplayCopyAllDisplayModes(mode.id, nil) as? [CGDisplayMode],
                  let chosen = displayMode.first(where: {
                      $0.width == mode.entry.width && $0.height == mode.entry.height
                          && abs($0.refreshRate - mode.entry.refresh) <= 1
                  }) ?? displayMode.first(where: {
                      $0.width == mode.entry.width && $0.height == mode.entry.height
                  }) else { return false }
            guard CGConfigureDisplayWithDisplayMode(config, mode.id, chosen, nil) == .success else {
                return false
            }
        }
        if let mirror {
            guard CGConfigureDisplayMirrorOfDisplay(config, mirror.id, mirror.master) == .success else {
                return false
            }
        }

        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else { return false }
        completed = true
        return true
    }

    /// Rotation is private. A missing symbol is `unsupported`, never a fake success.
    static func rotate(_ id: CGDirectDisplayID, degrees: Double) -> Bool? {
        guard let raw = PrivateSymbols.load(
            "CGSConfigureDisplayRotation", from: "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        ) else { return nil }
        typealias Rotate = @convention(c) (CGDirectDisplayID, Double) -> Int32
        let rotate = unsafeBitCast(raw, to: Rotate.self)
        return rotate(id, degrees) == 0
    }
}

/// Night Shift through CoreBrightness. The class is private; key-value coding is used
/// only where the property exists, otherwise the action is `unsupported` — never a fake
/// "done". Swift cannot call a two-argument ObjC selector without a C shim, so the
/// `setStrength:commit:` route reports itself instead of pretending.
enum NightShift {
    private static func client() -> NSObject? {
        guard let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return cls.init()
    }

    static var isAvailable: Bool {
        guard let client = client() else { return false }
        return client.responds(to: NSSelectorFromString("setEnabled:"))
    }

    static func setEnabled(_ enabled: Bool) -> Bool? {
        guard let client = client(),
              client.responds(to: NSSelectorFromString("setEnabled:")) else { return nil }
        client.setValue(enabled, forKey: "enabled")
        return true
    }

    static func setStrength(_ strength: Float) -> Bool? {
        guard let client = client(),
              client.responds(to: NSSelectorFromString("setStrength:")) else { return nil }
        client.setValue(NSNumber(value: max(0, min(1, strength))), forKey: "strength")
        return true
    }
}
