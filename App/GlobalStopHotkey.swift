import AppKit
import Carbon.HIToolbox
import Foundation

extension Notification.Name {
    /// Raised by the global stop hotkey. `AppModel` forwards it to `ChatStore.stop()`.
    static let harnessAbortRequested = Notification.Name("harness.abortRequested")
}

/// R18.11: the only way to stop a runaway GUI loop without quitting the app.
///
/// Carbon is used on purpose: `RegisterEventHotKey` works system-wide and needs no
/// Input Monitoring grant, unlike a `CGEventTap`. ⌃⌥⌘. is not taken by macOS.
final class GlobalStopHotkey: @unchecked Sendable {
    static let shared = GlobalStopHotkey()

    /// Virtual key and modifiers, exposed for the test and for the log line.
    static let key = UInt32(kVK_ANSI_Period)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let label = "⌃⌥⌘."

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (@Sendable () -> Void)?

    /// Returns false when the combination is already taken; the caller must say so
    /// instead of pretending the stop works.
    @discardableResult
    func install(_ action: @escaping @Sendable () -> Void) -> Bool {
        self.action = action
        if handlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, _ in
                    GlobalStopHotkey.shared.fire()
                    return noErr
                },
                1, &eventType, nil, &handlerRef
            )
            guard status == noErr else { return false }
        }
        if hotKeyRef == nil {
            let identifier = EventHotKeyID(signature: OSType(0x4852_4E53), id: 1)
            let status = RegisterEventHotKey(
                Self.key, Self.modifiers, identifier,
                GetApplicationEventTarget(), 0, &hotKeyRef
            )
            guard status == noErr else { return false }
        }
        return true
    }

    func uninstall() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        action = nil
    }

    func fire() {
        action?()
    }
}
