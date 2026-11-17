import CoreGraphics
import Foundation

extension ToolRegistry {
    /// R18.3: physical mouse input in screen points (after R18.1). Every path checks the
    /// Accessibility grant first; posting without it silently does nothing on modern macOS.
    func mouseTool(_ args: [String: Any]) -> ToolResult {
        guard InputAccess.isTrusted else { return .fail(InputAccess.refusal) }
        let action = (args["action"] as? String)?.lowercased() ?? ""
        guard let x = Self.int(args, "x"), let y = Self.int(args, "y") else {
            return .fail("x и y обязательны (точки экрана, не пиксели снимка).")
        }
        let point = CGPoint(x: x, y: y)

        switch action {
        case "move":
            CGWarpMouseCursorPosition(point)
            Self.postMouse(.mouseMoved, at: point, button: .left)
            return .ok("Курсор в \(x),\(y).")
        case "click", "double_click", "right_click":
            let button: CGMouseButton = action == "right_click" ? .right : .left
            let down: CGEventType = action == "right_click" ? .rightMouseDown : .leftMouseDown
            let up: CGEventType = action == "right_click" ? .rightMouseUp : .leftMouseUp
            CGWarpMouseCursorPosition(point)
            let clicks = action == "double_click" ? 2 : 1
            for index in 1...clicks {
                Self.postMouse(down, at: point, button: button, clickCount: index)
                Self.postMouse(up, at: point, button: button, clickCount: index)
            }
            return .ok("\(action) в \(x),\(y).")
        case "drag":
            guard let toX = Self.int(args, "to_x"), let toY = Self.int(args, "to_y") else {
                return .fail("Для drag нужны to_x и to_y.")
            }
            let target = CGPoint(x: toX, y: toY)
            CGWarpMouseCursorPosition(point)
            Self.postMouse(.leftMouseDown, at: point, button: .left)
            for step in 1...3 {
                let fraction = CGFloat(step) / 3
                let intermediate = CGPoint(
                    x: point.x + (target.x - point.x) * fraction,
                    y: point.y + (target.y - point.y) * fraction
                )
                Self.postMouse(.leftMouseDragged, at: intermediate, button: .left)
            }
            Self.postMouse(.leftMouseUp, at: target, button: .left)
            return .ok("Перетащено \(x),\(y) → \(toX),\(toY).")
        case "scroll":
            let dx = Self.int(args, "dx") ?? 0
            let dy = Self.int(args, "dy") ?? 0
            guard dx != 0 || dy != 0 else { return .fail("Нужен dx или dy в пикселях.") }
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                      wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
            else { return .fail("Не удалось собрать событие прокрутки.") }
            CGWarpMouseCursorPosition(point)
            event.post(tap: .cghidEventTap)
            return .ok("Прокрутка dx=\(dx) dy=\(dy) в \(x),\(y).")
        default:
            return .fail("action: move | click | double_click | right_click | drag | scroll")
        }
    }

    static func postMouse(_ type: CGEventType, at point: CGPoint,
                          button: CGMouseButton, clickCount: Int = 1) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.post(tap: .cghidEventTap)
    }
}
