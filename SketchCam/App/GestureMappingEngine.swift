import CoreGraphics
import Foundation

enum MotionControlDestination: String, Codable, CaseIterable, Identifiable {
    case canvas, computer
    var id: String { rawValue }
    var title: String { self == .canvas ? "Canvas" : "Computer" }
}

enum HandGesture: String, Codable, CaseIterable, Identifiable {
    case pinch, fist, openPalm
    var id: String { rawValue }
    var title: String {
        switch self { case .pinch: "Pinch"; case .fist: "Fist"; case .openPalm: "Open palm" }
    }
}

enum MotionAction: String, Codable, CaseIterable, Identifiable {
    case none, draw, erase, primaryButton, secondaryClick, scrollUp, scrollDown, key, pause
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Nothing"
        case .draw: "Draw (hold)"
        case .erase: "Erase / dissolve (hold)"
        case .primaryButton: "Click / drag (hold)"
        case .secondaryClick: "Right click"
        case .scrollUp: "Scroll up (hold)"
        case .scrollDown: "Scroll down (hold)"
        case .key: "Key / shortcut"
        case .pause: "Disarm"
        }
    }
    static func choices(for destination: MotionControlDestination) -> [Self] {
        destination == .canvas ? [.none, .draw, .erase, .pause]
            : [.none, .primaryButton, .secondaryClick, .scrollUp, .scrollDown, .key, .pause]
    }
}

enum MotionShortcut: String, Codable, CaseIterable, Identifiable {
    case space, enter, tab, escape, left, right, up, down, undo, redo
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var keyCode: CGKeyCode {
        switch self {
        case .space: 49; case .enter: 36; case .tab: 48; case .escape: 53
        case .left: 123; case .right: 124; case .up: 126; case .down: 125
        case .undo, .redo: 6
        }
    }
    var flags: CGEventFlags {
        switch self { case .undo: .maskCommand; case .redo: [.maskCommand, .maskShift]; default: [] }
    }
}

struct GestureRule: Codable, Equatable, Identifiable {
    var gesture: HandGesture
    var action: MotionAction
    var shortcut: MotionShortcut = .space
    var id: String { gesture.id }
    static let canvas: [Self] = [.init(gesture: .pinch, action: .draw), .init(gesture: .fist, action: .erase), .init(gesture: .openPalm, action: .none)]
    static let computer: [Self] = [.init(gesture: .pinch, action: .primaryButton), .init(gesture: .fist, action: .secondaryClick), .init(gesture: .openPalm, action: .none)]
}

/// Pure recognition/action state machine. One selected hand, exclusive gestures,
/// confidence gating, hysteresis and dwell; discrete actions fire only on entry.
final class GestureMappingEngine {
    private let pointer = SystemPointerEngine()
    private var candidate: HandGesture?
    private var stable: HandGesture?
    private var candidateSince: TimeInterval = 0
    private var lastSeen: TimeInterval?
    private var lastScroll: TimeInterval = -.infinity
    private var held: MotionAction = .none
    private var lastPoint: CGPoint = .zero

    func update(detection: LandmarkDetection?, mapping: SystemPointerMapping, screen: CGRect,
                mirrored: Bool, now: TimeInterval) -> (events: [SystemPointerEvent], live: SystemPointerLiveState) {
        var positionMapping = mapping
        positionMapping.driveMode = .always
        positionMapping.clickWithPinch = false
        let position = pointer.update(detection: detection, mapping: positionMapping, screenBounds: screen, mirrored: mirrored, now: now)
        guard position.live.featureAvailable, case .move(let point)? = position.events.first else {
            if now - (lastSeen ?? -.infinity) >= mapping.missingGraceSeconds {
                return (stop(), SystemPointerLiveState(status: "Waiting for \(mapping.pointer.title)"))
            }
            return ([], SystemPointerLiveState(status: "Tracking grace"))
        }
        lastSeen = now
        lastPoint = point
        let gesture = Self.recognize(detection: detection, mapping: mapping, previous: stable)
        if gesture != candidate { candidate = gesture; candidateSince = now }
        // Release promptly; only activation needs dwell. This avoids sticky
        // buttons and prevents an uncertain fist/pinch transition painting.
        var events: [SystemPointerEvent] = []
        if stable != gesture { events += release(); stable = nil }
        let entered = stable == nil && gesture != nil && now - candidateSince >= max(0.04, mapping.gestureDwell ?? 0.12)
        if entered { stable = gesture }
        let rule = mapping.gestureRules?.first { $0.gesture == stable }
        let action = rule?.action ?? .none
        let destination = mapping.destination ?? .computer
        if destination == .computer && (mapping.driveMode == .always || stable != nil) {
            events.append(held == .primaryButton ? .leftDrag(point) : .move(point))
        }
        if MotionAction.choices(for: destination).contains(action) {
            switch action {
            case .draw, .erase:
                held = action
                let unit = CGPoint(x: (point.x - screen.minX) / max(1, screen.width), y: (point.y - screen.minY) / max(1, screen.height))
                events.append(.canvas(action, unit))
            case .primaryButton:
                if held != .primaryButton { events.append(.leftDown(point)); held = .primaryButton }
            case .secondaryClick:
                if entered { events.append(.rightClick(point)) }
            case .scrollUp, .scrollDown:
                if now - lastScroll >= 0.08 { events.append(.scroll(action == .scrollUp ? 3 : -3)); lastScroll = now }
            case .key:
                if entered { events.append(.shortcut(rule?.shortcut ?? .space)) }
            case .pause:
                if entered { events.append(.disarm) }
            case .none: break
            }
        }
        var live = position.live
        live.pinching = stable == .pinch
        live.status = stable.map { "\($0.title) → \(action.title)" } ?? "Tracking"
        return (events, live)
    }

    func stop() -> [SystemPointerEvent] {
        let events = release()
        _ = pointer.stop()
        candidate = nil; stable = nil; lastSeen = nil; candidateSince = 0; lastScroll = -.infinity
        return events
    }

    private func release() -> [SystemPointerEvent] {
        defer { held = .none }
        switch held {
        case .primaryButton: return [.leftUp(lastPoint)]
        case .draw, .erase: return [.canvasEnd]
        default: return []
        }
    }

    static func recognize(detection: LandmarkDetection?, mapping: SystemPointerMapping, previous: HandGesture?) -> HandGesture? {
        var points: [String: LandmarkPoint] = [:]
        for group in detection?.groups ?? [] {
            for point in group.points where point.confidence >= mapping.minimumConfidence {
                if let label = point.label, point.point.x.isFinite, point.point.y.isFinite { points[label] = point }
            }
        }
        func p(_ i: Int) -> CGPoint? { points["\(mapping.pointer.side.labelPrefix)\(i)"]?.point }
        guard let wrist = p(0), let middle = p(9) else { return nil }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x-b.x, a.y-b.y) }
        let palm = distance(wrist, middle)
        guard palm > 0.00001 else { return nil }
        let ratios = [8, 12, 16, 20].compactMap { tip -> CGFloat? in
            guard let t = p(tip), let pip = p(tip - 2) else { return nil }
            return distance(t, wrist) / max(palm * 0.1, distance(pip, wrist))
        }
        if ratios.count == 4 && ratios.allSatisfy({ $0 < (previous == .fist ? 1.18 : 1.03) }) { return .fist }
        if let thumb = p(4), let index = p(8),
           distance(thumb, index) / palm < mapping.pinchThreshold + (previous == .pinch ? 0.10 : 0) { return .pinch }
        if ratios.count == 4 && ratios.allSatisfy({ $0 > (previous == .openPalm ? 1.1 : 1.23) }) { return .openPalm }
        return nil
    }
}
