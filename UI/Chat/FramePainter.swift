import AppKit
import QuartzCore

/// Coalesces streamed chunks to one paint per display frame.
///
/// The paint used to run on a fixed 60 ms sleep, which capped fast providers and made
/// the text arrive in lumps: nothing for a moment, then a paragraph. Here the flush
/// waits for the next vsync instead. Many chunks that arrive in one frame become one
/// publication, and a slow provider never waits longer than a frame. There is no queue
/// and no catching up: what is painted equals what arrived.
///
/// The 100 ms safety net exists for an occluded window, where Core Animation may stop
/// delivering frames. It is a fallback, not the pacing mechanism.
@MainActor
enum FramePainter {
    private static var link: CADisplayLink?
    private static var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private static let target = FramePainterTarget()

    /// Suspends until the next display frame, or until the safety net fires.
    static func next() async {
        await withCheckedContinuation { continuation in
            let id = UUID()
            waiters[id] = continuation
            start()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                resolve(id)
            }
        }
    }

    fileprivate static func fire() {
        link?.isPaused = true
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    private static func resolve(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    private static func start() {
        guard let link else {
            guard let created = NSScreen.main?.displayLink(
                target: target,
                selector: #selector(FramePainterTarget.tick(_:))
            ) else {
                // No screen at all (a headless test runner): the next run-loop pass is
                // the closest thing to a frame, and it is still not a fixed delay.
                Task { @MainActor in fire() }
                return
            }
            created.add(to: .main, forMode: .common)
            self.link = created
            created.isPaused = false
            return
        }
        link.isPaused = false
    }
}

private final class FramePainterTarget: NSObject {
    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            FramePainter.fire()
        }
    }
}
