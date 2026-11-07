import AppKit
import Observation
import SwiftUI

/// True while the user drags a window edge.
///
/// Laying out a transcript of 200 messages on every frame of a live resize is the
/// expensive part of resizing: each text view re-measures at the new width. The
/// single most costly modifier there is selectable text, which wraps every text run
/// in a platform view. Dropping it for the duration of the drag is a large, local
/// win that costs nothing visually — you cannot select text while dragging an edge.
@MainActor
@Observable
final class LiveResizeState {
    var active = false
}

/// Reports live-resize start and end of the window it is attached to.
struct WindowResizeBridge: NSViewRepresentable {
    let state: LiveResizeState

    func makeNSView(context: Context) -> NSView {
        let view = BridgeView()
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? BridgeView)?.state = state
    }

    private final class BridgeView: NSView {
        weak var state: LiveResizeState?
        /// Removed when the view leaves the window; `deinit` cannot touch main-actor
        /// state under strict concurrency.
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            let center = NotificationCenter.default
            for observer in observers { center.removeObserver(observer) }
            observers = []

            guard let window else {
                state?.active = false
                return
            }

            let start = center.addObserver(
                forName: NSWindow.willStartLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.state?.active = true }
            }
            let end = center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.state?.active = false }
            }
            observers = [start, end]
        }

    }
}

/// Reads the live-resize flag; `false` when the bridge is not installed.
struct SelectableText: ViewModifier {
    @Environment(LiveResizeState.self) private var liveResize: LiveResizeState

    func body(content: Content) -> some View {
        // The two selectabilities are different types, so this cannot be a ternary.
        if liveResize.active {
            content.textSelection(.disabled)
        } else {
            content.textSelection(.enabled)
        }
    }
}

extension View {
    /// Selectable text that turns selection off for the duration of a live resize.
    func selectableWhileIdle() -> some View {
        modifier(SelectableText())
    }
}
