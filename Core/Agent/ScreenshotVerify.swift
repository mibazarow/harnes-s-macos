import CryptoKit
import Foundation

/// R19.6: after a click, prove something changed. Two small captures of the element's
/// rectangle are compared by hash; a miss is reported as `changed: false`, not as success.
enum ScreenshotVerify {
    static func changed(before: Data, after: Data) -> Bool { before != after }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// Returns (changed, beforePath, afterPath) or nil when capture is unavailable.
    static func captureAndCompare(rect: CGRect) -> (Bool, String, String)? {
        let before = capture(rect: rect, tag: "before")
        Thread.sleep(forTimeInterval: 0.25)
        let after = capture(rect: rect, tag: "after")
        guard let before, let after,
              let beforeData = try? Data(contentsOf: before),
              let afterData = try? Data(contentsOf: after) else { return nil }
        return (beforeData != afterData, before.path, after.path)
    }

    static func capture(rect: CGRect, tag: String) -> URL? {
        let path = AppPaths.artifactsDirectory
            .appendingPathComponent("verify-\(tag)-\(UUID().uuidString.prefix(6)).png")
        try? AppPaths.ensureDirectory(AppPaths.artifactsDirectory)
        let command = "screencapture -x -R \(Int(rect.minX)),\(Int(rect.minY)),"
            + "\(Int(rect.width)),\(Int(rect.height)) \(path.path)"
        guard let output = try? ToolRegistry.runSync(
            command, cwd: path.deletingLastPathComponent(), timeout: 10
        ) else { return nil }
        let (status, _) = ToolRegistry.splitExit(output)
        return status == 0 && FileManager.default.fileExists(atPath: path.path) ? path : nil
    }
}
