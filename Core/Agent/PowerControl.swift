import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// R25.1: power, brightness, sound and media. Everything here is a system API or a
/// `pmset` call that needs a return code, never a third-party CLI. Private symbols are
/// resolved once and cached; a missing symbol is an honest `unsupported`.
enum PowerGuard {
    static let actions: Set<String> = [
        "status", "sleep", "lock", "display_off", "caffeinate", "low_power",
        "brightness", "volume", "mute", "media", "audio", "restart", "shutdown"
    ]

    /// Restart and shutdown are the only actions that must never run without an explicit
    /// confirmation, autopilot included.
    static func needsConfirm(_ action: String) -> Bool {
        action == "restart" || action == "shutdown"
    }
}

enum PowerValue {
    /// 0...100 for volume and brightness percentages.
    static func percent(_ raw: Any?) -> Int? {
        let value: Double?
        if let number = raw as? Int { value = Double(number) }
        else if let number = raw as? Double { value = number }
        else if let text = raw as? String { value = Double(text) }
        else { value = nil }
        guard let value else { return nil }
        return Int(max(0, min(100, value.rounded())))
    }

    /// 0...1 for the CoreAudio and DisplayServices APIs.
    static func level(percent: Int) -> Float {
        Float(max(0, min(100, percent))) / 100
    }

    static func percent(level: Float) -> Int {
        Int((max(0, min(1, level)) * 100).rounded())
    }
}

/// Private frameworks are loaded by path and the symbol is cached for the process. A
/// missing symbol must not silently fall back to "press the volume key".
enum PrivateSymbols {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var handles: [String: UnsafeMutableRawPointer] = [:]
        private var symbols: [String: UnsafeMutableRawPointer] = [:]

        func handle(_ framework: String) -> UnsafeMutableRawPointer? {
            lock.lock(); defer { lock.unlock() }
            if let handle = handles[framework] { return handle }
            guard let handle = dlopen(framework, RTLD_NOW) else { return nil }
            handles[framework] = handle
            return handle
        }

        func symbol(_ name: String, in framework: String) -> UnsafeMutableRawPointer? {
            let key = framework + "#" + name
            lock.lock()
            if let cached = symbols[key] { lock.unlock(); return cached }
            lock.unlock()
            guard let handle = handle(framework), let found = dlsym(handle, name) else { return nil }
            lock.lock()
            symbols[key] = found
            lock.unlock()
            return found
        }
    }

    private static let store = Store()

    static func load(_ symbol: String, from framework: String) -> UnsafeMutableRawPointer? {
        store.symbol(symbol, in: framework)
    }
}

enum PowerFrameworks {
    static let login = "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"
    static let display = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    static let media = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
}

enum DisplayBrightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    static var isAvailable: Bool {
        PrivateSymbols.load("DisplayServicesGetBrightness", from: PowerFrameworks.display) != nil
            && PrivateSymbols.load("DisplayServicesSetBrightness", from: PowerFrameworks.display) != nil
    }

    static func brightness(of display: CGDirectDisplayID) -> Int? {
        guard let raw = PrivateSymbols.load("DisplayServicesGetBrightness", from: PowerFrameworks.display)
        else { return nil }
        let get = unsafeBitCast(raw, to: GetBrightness.self)
        var level: Float = 0
        guard get(display, &level) == 0 else { return nil }
        return PowerValue.percent(level: level)
    }

    static func set(_ percent: Int, on display: CGDirectDisplayID) -> Bool {
        guard let raw = PrivateSymbols.load("DisplayServicesSetBrightness", from: PowerFrameworks.display)
        else { return false }
        let set = unsafeBitCast(raw, to: SetBrightness.self)
        return set(display, PowerValue.level(percent: percent)) == 0
    }

    static var builtinDisplay: CGDirectDisplayID? {
        CGMainDisplayID()
    }
}

/// CoreAudio HAL: default device, per-device volume and mute, switching defaults.
enum AudioHAL {
    struct Device: Sendable {
        let id: AudioDeviceID
        let name: String
        let hasInput: Bool
        let hasOutput: Bool
        let isDefaultOutput: Bool
        let isDefaultInput: Bool
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func object(_ id: AudioObjectID, _ address: inout AudioObjectPropertyAddress,
                               size: inout UInt32, data: UnsafeMutableRawPointer) -> OSStatus {
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, data)
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = address(selector)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return status == noErr && id != 0 ? id : nil
    }

    static func name(of id: AudioDeviceID) -> String {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return "device \(id)" }
        return name.takeUnretainedValue() as String
    }

    static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size = UInt32(0)
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    static func devices() -> [Device] {
        var address = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        let output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let input = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        return ids.map { id in
            Device(
                id: id, name: name(of: id),
                hasInput: hasStreams(id, scope: kAudioDevicePropertyScopeInput),
                hasOutput: hasStreams(id, scope: kAudioDevicePropertyScopeOutput),
                isDefaultOutput: id == output,
                isDefaultInput: id == input
            )
        }
    }

    static func volume(of id: AudioDeviceID) -> Int? {
        var address = address(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &volume) == noErr else {
            return nil
        }
        return PowerValue.percent(level: volume)
    }

    @discardableResult
    static func setVolume(_ percent: Int, of id: AudioDeviceID) -> Bool {
        var address = address(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput
        )
        guard AudioObjectHasProperty(id, &address) else { return false }
        var volume = PowerValue.level(percent: percent)
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(id, &address, 0, nil, size, &volume) == noErr
    }

    static func isMuted(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool? {
        var address = address(kAudioDevicePropertyMute, scope: scope)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &muted) == noErr else {
            return nil
        }
        return muted != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool, of id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyMute, scope: scope)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(id, &address, 0, nil, size, &value) == noErr
    }

    static func setDefault(_ id: AudioDeviceID, output: Bool) -> Bool {
        var address = address(output
            ? kAudioHardwarePropertyDefaultOutputDevice
            : kAudioHardwarePropertyDefaultInputDevice)
        var device = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &device
        ) == noErr
    }
}

/// Play/pause through MediaRemote. Not a key press: a simulated media key would need the
/// same grant and would lie about which player reacted.
enum MediaRemote {
    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool

    static let commands: [String: Int32] = [
        "play": 0, "pause": 1, "toggle": 2, "next": 4, "previous": 5, "prev": 5
    ]

    static func send(_ name: String) -> Bool? {
        guard let command = commands[name] else { return nil }
        guard let raw = PrivateSymbols.load("MRMediaRemoteSendCommand", from: PowerFrameworks.media)
        else { return nil }
        let send = unsafeBitCast(raw, to: SendCommand.self)
        return send(command, nil)
    }
}

/// Caffeinate assertions are held in memory: the assertion dies with the process, and an
/// assertion that outlives the turn would keep the Mac awake forever.
enum PowerAssertions {
    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [UUID: IOPMAssertionID] = [:]
        private let releaseAssertion: @Sendable (IOPMAssertionID) -> Void

        init(releaseAssertion: @escaping @Sendable (IOPMAssertionID) -> Void = { _ = IOPMAssertionRelease($0) }) {
            self.releaseAssertion = releaseAssertion
        }

        func add(_ id: IOPMAssertionID) -> UUID {
            lock.lock(); defer { lock.unlock() }
            let token = UUID()
            ids[token] = id
            return token
        }

        func release(_ token: UUID) {
            lock.lock()
            defer { lock.unlock() }
            guard let id = ids.removeValue(forKey: token) else { return }
            releaseAssertion(id)
        }

        func releaseAll() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let all = Array(ids.values)
            ids.removeAll()
            for id in all { releaseAssertion(id) }
            return all.count
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return ids.count
        }
    }

    private static let store = Store()

    @discardableResult
    static func hold(seconds: Int) -> Bool {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "HARNES-S: caffeinate" as CFString,
            &id
        )
        guard status == kIOReturnSuccess else { return false }
        let token = store.add(id)
        let bounded = min(max(seconds, 1), 3_600)
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(bounded)) {
            store.release(token)
        }
        return true
    }

    static var count: Int { store.count }

    static func releaseAll() -> Int { store.releaseAll() }
}

/// Refuses restart/shutdown when an application has an unsaved document: the save sheet
/// would hang the shutdown and the Mac would stay awake with the dialog in the way.
enum UnsavedDocuments {
    /// A window with a document and the edited flag is exactly the "save?" dialog case.
    static func isEdited(document: String?, edited: Bool?) -> Bool {
        guard edited == true else { return false }
        guard let document, !document.isEmpty else { return false }
        return true
    }

    /// Applications whose windows look edited right now.
    static func riskyApps() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> String? in
                let root = AXUIElementCreateApplication(app.processIdentifier)
                let windows = AXBridge.attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
                let edited = windows.contains { window in
                    let document = AXBridge.attribute(window, kAXDocumentAttribute) as? String
                    let flag = AXBridge.attribute(window, kAXEditedAttribute) as? Bool
                    return isEdited(document: document, edited: flag)
                }
                guard edited else { return nil }
                return app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
            }
    }
}
