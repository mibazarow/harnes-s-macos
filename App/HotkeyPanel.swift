import AppKit
import SwiftUI

/// R27.1: a small panel over the active window. It carries the selected text of the
/// frontmost app, takes one line of input, and hands it to the chat. It does not become
/// the main window and does not keep focus after Return or Esc.
@MainActor
final class HotkeyPanelController: NSObject {
    struct Context {
        let selectedText: String?
        let appName: String
    }

    static let shared = HotkeyPanelController()

    private var panel: NSPanel?
    private var field: NSTextField?
    private var onSubmit: ((String, Context) -> Void)?
    private var context = Context(selectedText: nil, appName: "")
    /// The app the person was in; focus goes back there when the panel closes.
    private var previousApp: NSRunningApplication?

    var excludedBundleIDs: [String] = []

    /// Returns false when the frontmost app is on the "do not disturb" list.
    @discardableResult
    func show(onSubmit: @escaping (String, Context) -> Void) -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard HotkeyConfig.shouldShow(
            frontmostBundleID: frontmost?.bundleIdentifier, excluded: excludedBundleIDs
        ) else { return false }
        self.onSubmit = onSubmit
        previousApp = frontmost
        context = Context(
            selectedText: HotkeyConfig.selectedText(),
            appName: frontmost?.localizedName ?? "?"
        )

        let panel = self.panel ?? makePanel()
        self.panel = panel
        field?.stringValue = ""
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        return true
    }

    func hide() {
        panel?.orderOut(nil)
        // Focus goes back to the app the person was in; without this the next keystroke
        // lands nowhere.
        previousApp?.activate()
        previousApp = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 96),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let field = NSTextField(frame: .zero)
        field.placeholderString = "Спроси Харнеса…"
        field.font = .systemFont(ofSize: 16)
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(submit)
        field.delegate = self
        self.field = field

        let hint = NSTextField(labelWithString: "Return — отправить, Esc — закрыть")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [field, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        ])
        panel.contentView = container
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let origin = NSPoint(
            x: min(max(frame.minX + 40, mouse.x - size.width / 2), frame.maxX - size.width - 40),
            y: max(frame.minY + 80, mouse.y - size.height - 40)
        )
        panel.setFrameOrigin(origin)
    }

    @objc private func submit() {
        let text = (field?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        hide()
        onSubmit?(text, context)
    }
}

extension HotkeyPanelController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }
}

/// R27.1: the assistant chord. A missing combination is reported, not silently replaced.
final class AssistantHotkey: @unchecked Sendable {
    static let shared = AssistantHotkey()

    private var hotkeyID: UInt32?
    private(set) var label: String = HotkeyConfig.default.label

    @discardableResult
    func install(_ config: HotkeyConfig, action: @escaping @Sendable () -> Void) -> Bool {
        guard let keyCode = config.keyCode else { return false }
        if let hotkeyID { HotkeyRegistry.shared.unregister(hotkeyID) }
        label = config.label
        hotkeyID = HotkeyRegistry.shared.register(
            keyCode: keyCode, modifiers: config.carbonModifiers, action: action
        )
        return hotkeyID != nil
    }

    func uninstall() {
        if let hotkeyID { HotkeyRegistry.shared.unregister(hotkeyID) }
        hotkeyID = nil
    }
}
