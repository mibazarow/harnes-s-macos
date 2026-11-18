import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One observed action. Metadata only: which app, what kind, which key or where. The
/// typed text is never recorded (R27.2: no keylogger, no history on disk).
struct ObservedEvent: Codable, Equatable, Sendable {
    let at: Date
    let app: String
    let kind: String
    let detail: String
    let x: Double?
    let y: Double?
}

/// R27.2: "человек 40 секунд работал в PhpStorm, потом переключился в браузер".
/// Pure so the shape of the answer is tested without a tap.
enum ActivitySummary {
    struct Segment: Equatable, Sendable {
        let app: String
        let seconds: Double
    }

    /// Splits the stream into per-app segments; a pause longer than `gap` also closes a
    /// segment, because "был в приложении" and "работал в приложении" are different.
    static func segments(_ events: [ObservedEvent], gap: TimeInterval = 5) -> [Segment] {
        guard !events.isEmpty else { return [] }
        var segments: [Segment] = []
        var start = events[0].at
        var end = events[0].at
        var app = events[0].app

        for event in events.dropFirst() {
            if event.app == app, event.at.timeIntervalSince(end) <= gap {
                end = event.at
                continue
            }
            segments.append(Segment(app: app, seconds: max(0, end.timeIntervalSince(start))))
            start = event.at
            end = event.at
            app = event.app
        }
        segments.append(Segment(app: app, seconds: max(0, end.timeIntervalSince(start))))
        return segments.filter { $0.seconds >= 1 }
    }

    static func text(_ segments: [Segment]) -> String {
        guard !segments.isEmpty else { return "Активности не было." }
        return segments.map { segment in
            "\(Int(segment.seconds)) с в \(segment.app)"
        }.joined(separator: ", потом ")
    }
}

/// Listen-only event tap on its own thread. It reads key codes and points, never text.
final class InputObserver: @unchecked Sendable {
    static let shared = InputObserver()

    private let lock = NSLock()
    private var events: [ObservedEvent] = []
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var startedAt: Date?
    private var recording = false
    private var recorded: [ObservedEvent] = []

    /// Reason the tap could not be created, with the grant the person has to give.
    private(set) var lastError: String?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return tap != nil
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return events.count
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        if tap != nil { lock.unlock(); return true }
        lock.unlock()

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                Unmanaged<InputObserver>.fromOpaque(userInfo)
                    .takeUnretainedValue().record(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            lastError = "CGEvent.tapCreate отказал: нужен грант Accessibility, для чужих "
                + "клавиш — Input Monitoring (kTCCServiceListenEvent). "
                + "Панель: x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread { [weak self] in
            guard let self else { return }
            let loop = CFRunLoopGetCurrent()
            self.lock.lock()
            self.runLoop = loop
            self.thread = Thread.current
            self.startedAt = Date()
            self.events.removeAll()
            self.lock.unlock()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "harness.input-observer"
        thread.start()

        lock.lock()
        self.tap = tap
        lastError = nil
        lock.unlock()
        return true
    }

    func stop() {
        lock.lock()
        let tap = self.tap
        let loop = self.runLoop
        self.tap = nil
        self.runLoop = nil
        self.thread = nil
        self.recording = false
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
    }

    fileprivate func record(_ event: CGEvent) {
        let kind: String
        var detail = ""
        var point: CGPoint?
        switch event.type {
        case .keyDown:
            kind = "key"
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            var mods = ""
            if flags.contains(.maskCommand) { mods += "cmd+" }
            if flags.contains(.maskControl) { mods += "ctrl+" }
            if flags.contains(.maskAlternate) { mods += "alt+" }
            if flags.contains(.maskShift) { mods += "shift+" }
            detail = "\(mods)code=\(code)"
        case .leftMouseDown, .rightMouseDown:
            kind = event.type == .leftMouseDown ? "left_click" : "right_click"
            point = event.location
        case .scrollWheel:
            kind = "scroll"
            detail = "dy=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))"
        case .mouseMoved:
            kind = "move"
            point = event.location
        default:
            return
        }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let observed = ObservedEvent(
            at: Date(), app: app, kind: kind, detail: detail,
            x: point.map { Double($0.x) }, y: point.map { Double($0.y) }
        )
        lock.lock()
        events.append(observed)
        if events.count > 5_000 { events.removeFirst(events.count - 5_000) }
        if recording { recorded.append(observed) }
        lock.unlock()
    }

    func snapshot() -> [ObservedEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    func clear() {
        lock.lock(); events.removeAll(); lock.unlock()
    }

    func beginRecording() {
        lock.lock(); recorded.removeAll(); recording = true; lock.unlock()
    }

    /// Stops recording and returns the steps. Nothing is written to disk here: the caller
    /// decides where the macro file goes, and the person confirms the replay.
    func endRecording() -> [ObservedEvent] {
        lock.lock()
        recording = false
        let steps = recorded
        lock.unlock()
        return steps
    }

    /// Replays clicks and key codes, never text. The stop hotkey aborts between steps.
    func replay(_ steps: [ObservedEvent], abort: AgentAbortSignal = .shared) async -> (done: Int, stopped: Bool) {
        var done = 0
        for step in steps {
            if abort.current != nil { return (done, true) }
            switch step.kind {
            case "left_click", "right_click":
                guard let x = step.x, let y = step.y,
                      let source = CGEventSource(stateID: .hidSystemState) else { continue }
                let type: CGEventType = step.kind == "left_click" ? .leftMouseDown : .rightMouseDown
                let upType: CGEventType = step.kind == "left_click" ? .leftMouseUp : .rightMouseUp
                let button: CGMouseButton = step.kind == "left_click" ? .left : .right
                let point = CGPoint(x: x, y: y)
                CGEvent(mouseEventSource: source, mouseType: type,
                        mouseCursorPosition: point, mouseButton: button)?
                    .post(tap: .cghidEventTap)
                CGEvent(mouseEventSource: source, mouseType: upType,
                        mouseCursorPosition: point, mouseButton: button)?
                    .post(tap: .cghidEventTap)
            case "key":
                guard let code = Self.keyCode(from: step.detail) else { continue }
                let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            default:
                continue
            }
            done += 1
            try? await Task.sleep(for: .milliseconds(120))
        }
        return (done, abort.current != nil)
    }

    static func keyCode(from detail: String) -> CGKeyCode? {
        guard let range = detail.range(of: "code=") else { return nil }
        let digits = detail[range.upperBound...].prefix { $0.isNumber }
        return UInt16(digits).map { CGKeyCode($0) }
    }
}
