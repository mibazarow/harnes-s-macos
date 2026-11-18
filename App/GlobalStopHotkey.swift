import AppKit
import Carbon.HIToolbox
import Foundation

extension Notification.Name {
    /// Raised by the global stop hotkey. `AppModel` forwards it to `ChatStore.stop()`.
    static let harnessAbortRequested = Notification.Name("harness.abortRequested")
}

/// One Carbon hotkey table for the whole app: the system handler receives every hotkey
/// event, so a second `InstallEventHandler` would fire both callbacks for either key.
final class HotkeyRegistry: @unchecked Sendable {
    static let shared = HotkeyRegistry()

    private let lock = NSLock()
    private var actions: [UInt32: @Sendable () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// Returns nil when the combination is already taken by another app.
    func register(keyCode: UInt32, modifiers: UInt32,
                  action: @escaping @Sendable () -> Void) -> UInt32? {
        guard installHandlerIfNeeded() else { return nil }
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4852_4E53), id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return nil }
        lock.lock()
        actions[id] = action
        refs[id] = ref
        lock.unlock()
        return id
    }

    func unregister(_ id: UInt32) {
        lock.lock()
        let ref = refs.removeValue(forKey: id)
        actions.removeValue(forKey: id)
        lock.unlock()
        if let ref { UnregisterEventHotKey(ref) }
    }

    fileprivate func fire(_ id: UInt32) {
        lock.lock()
        let action = actions[id]
        lock.unlock()
        action?()
    }

    private func installHandlerIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if handlerRef != nil { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                if let event {
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                    )
                }
                HotkeyRegistry.shared.fire(hotKeyID.id)
                return noErr
            },
            1, &eventType, nil, &handlerRef
        )
        return status == noErr
    }
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

    private var hotkeyID: UInt32?
    private var action: (@Sendable () -> Void)?

    /// Returns false when the combination is already taken; the caller must say so
    /// instead of pretending the stop works.
    @discardableResult
    func install(_ action: @escaping @Sendable () -> Void) -> Bool {
        self.action = action
        if hotkeyID != nil { return true }
        hotkeyID = HotkeyRegistry.shared.register(
            keyCode: Self.key, modifiers: Self.modifiers
        ) { [weak self] in
            self?.fire()
        }
        return hotkeyID != nil
    }

    func uninstall() {
        if let hotkeyID { HotkeyRegistry.shared.unregister(hotkeyID) }
        hotkeyID = nil
        action = nil
    }

    func fire() {
        action?()
    }
}
