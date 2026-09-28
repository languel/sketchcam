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

enum MotionMapKind: String, Codable, CaseIterable, Identifiable {
    case action, parameter
    var id: String { rawValue }
    var title: String { self == .action ? "Active action" : "Passive parameter" }
}

enum MotionPaintMode: String, Codable, CaseIterable, Identifiable {
    case pen, wash
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum MotionPaintIntent: String, Codable, CaseIterable, Identifiable {
    case draw, erase
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum MotionGestureGate: String, Codable, CaseIterable, Identifiable {
    case any, pinch, fist, openPalm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: "Any gesture"
        case .pinch: "Pinch"
        case .fist: "Fist"
        case .openPalm: "Open palm"
        }
    }
    func matches(_ gesture: HandGesture?) -> Bool {
        switch self {
        case .any: true
        case .pinch: gesture == .pinch
        case .fist: gesture == .fist
        case .openPalm: gesture == .openPalm
        }
    }
}

enum MotionJointMetric: String, Codable, CaseIterable, Identifiable {
    case distance, angle
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum MotionParameterTarget: String, Codable, CaseIterable, Identifiable {
    case penSize, washSize, flow, brushInk
    var id: String { rawValue }
    var title: String {
        switch self {
        case .penSize: "Pen size"
        case .washSize: "Wash size"
        case .flow: "Flow"
        case .brushInk: "Brush ink"
        }
    }
    var limits: ClosedRange<Double> {
        switch self {
        case .penSize, .washSize: 0...1.5
        case .flow, .brushInk: 0...1
        }
    }
}

/// Ordered canvas rules. The first matching active action owns the stroke;
/// every matching passive rule can modulate it, with later values winning.
struct MotionGestureMap: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var enabled = true
    var kind: MotionMapKind
    var hand: MediaPipeHandSide
    var gesture: MotionGestureGate
    var mode: MotionPaintMode = .pen
    var intent: MotionPaintIntent = .draw
    var metric: MotionJointMetric = .distance
    var first = MediaPipeHandFeature(side: .left, landmark: .littleTip)
    var vertex = MediaPipeHandFeature(side: .left, landmark: .indexMCP)
    var last = MediaPipeHandFeature(side: .left, landmark: .thumbTip)
    var target: MotionParameterTarget = .washSize
    var inputLow = 0.2
    var inputHigh = 1.2
    var outputLow = 0.1
    var outputHigh = 1.2

    static func action(_ hand: MediaPipeHandSide, _ gesture: MotionGestureGate,
                       _ mode: MotionPaintMode, _ intent: MotionPaintIntent) -> Self {
        Self(name: "\(hand.title) \(gesture.title)", kind: .action, hand: hand,
             gesture: gesture, mode: mode, intent: intent)
    }
    static func parameter() -> Self {
        Self(name: "Finger distance → wash size", kind: .parameter,
             hand: .right, gesture: .pinch)
    }
    static let examples: [Self] = [
        .action(.left, .pinch, .pen, .draw),
        .action(.right, .pinch, .wash, .draw),
        .action(.right, .fist, .wash, .erase),
        .action(.left, .fist, .pen, .erase),
        .parameter()
    ]
}

struct MotionPaintCommand: Equatable {
    var ruleID: UUID
    var hand: MediaPipeHandSide
    var mode: MotionPaintMode
    var intent: MotionPaintIntent
    var point: CGPoint
    var parameters: [MotionParameterTarget: Float]
}

/// Pure two-hand rule evaluator. It intentionally emits one active paint
/// action because the current Ink live channel has one stroke identity.
final class CanvasGestureStackEngine {
    private var leftPointer = SystemPointerEngine()
    private var rightPointer = SystemPointerEngine()
    private var candidate: [MediaPipeHandSide: HandGesture] = [:]
    private var candidateSince: [MediaPipeHandSide: TimeInterval] = [:]
    private var stable: [MediaPipeHandSide: HandGesture] = [:]
    private var owner: UUID?
    private var lastSeen: TimeInterval?

    func update(detection: LandmarkDetection?, mapping: SystemPointerMapping, screen: CGRect,
                mirrored: Bool, now: TimeInterval) -> (events: [SystemPointerEvent], live: SystemPointerLiveState) {
        var locations: [MediaPipeHandSide: CGPoint] = [:]
        for side in MediaPipeHandSide.allCases {
            var positionMapping = mapping
            positionMapping.pointer = MediaPipeHandFeature(side: side, landmark: mapping.pointer.landmark)
            positionMapping.driveMode = .always
            positionMapping.clickWithPinch = false
            let pointer = side == .left ? leftPointer : rightPointer
            let result = pointer.update(detection: detection, mapping: positionMapping,
                                        screenBounds: screen, mirrored: mirrored, now: now)
            if result.live.featureAvailable, case .move(let point)? = result.events.first {
                locations[side] = point
                let found = GestureMappingEngine.recognize(detection: detection, mapping: positionMapping,
                                                           previous: stable[side])
                if candidate[side] != found {
                    candidate[side] = found
                    candidateSince[side] = now
                }
                if stable[side] != found { stable[side] = nil }
                if let found, stable[side] == nil,
                   now - (candidateSince[side] ?? now) >= max(0.04, mapping.gestureDwell ?? 0.12) {
                    stable[side] = found
                }
            } else {
                candidate[side] = nil
                stable[side] = nil
            }
        }
        if !locations.isEmpty { lastSeen = now }
        let rules = mapping.customGestureMaps ?? []
        let active = rules.first { $0.enabled && $0.kind == .action
            && $0.gesture.matches(stable[$0.hand]) && stable[$0.hand] != nil
            && locations[$0.hand] != nil }
        var events: [SystemPointerEvent] = []
        if owner != active?.id {
            if owner != nil { events.append(.canvasEnd) }
            owner = active?.id
        }
        if let active, let point = locations[active.hand] {
            var parameters: [MotionParameterTarget: Float] = [:]
            for rule in rules where rule.enabled && rule.kind == .parameter
                && rule.gesture.matches(stable[rule.hand]) && stable[rule.hand] != nil {
                guard let value = Self.measure(rule, detection: detection,
                                               minimumConfidence: mapping.minimumConfidence),
                      value.isFinite, rule.inputLow.isFinite, rule.inputHigh.isFinite,
                      rule.outputLow.isFinite, rule.outputHigh.isFinite else { continue }
                let span = rule.inputHigh - rule.inputLow
                guard abs(span) > 0.00001 else { continue }
                let t = min(1, max(0, (value - rule.inputLow) / span))
                let output = rule.outputLow + t * (rule.outputHigh - rule.outputLow)
                parameters[rule.target] = Float(min(rule.target.limits.upperBound,
                                                    max(rule.target.limits.lowerBound, output)))
            }
            let unit = CGPoint(x: (point.x - screen.minX) / max(1, screen.width),
                               y: (point.y - screen.minY) / max(1, screen.height))
            events.append(.canvasPaint(MotionPaintCommand(ruleID: active.id, hand: active.hand,
                mode: active.mode, intent: active.intent, point: unit, parameters: parameters)))
        } else if now - (lastSeen ?? -.infinity) >= mapping.missingGraceSeconds {
            candidate.removeAll(); stable.removeAll()
        }
        let status = active.map { "\($0.name) → \($0.mode.title) \($0.intent.title)" }
            ?? (locations.isEmpty ? "Waiting for hands" : "Tracking")
        return (events, SystemPointerLiveState(featureAvailable: !locations.isEmpty,
                                                status: status))
    }

    func stop() -> [SystemPointerEvent] {
        _ = leftPointer.stop(); _ = rightPointer.stop()
        candidate.removeAll(); candidateSince.removeAll(); stable.removeAll(); lastSeen = nil
        defer { owner = nil }
        return owner == nil ? [] : [.canvasEnd]
    }

    static func measure(_ rule: MotionGestureMap, detection: LandmarkDetection?,
                        minimumConfidence: Float) -> Double? {
        var points: [String: CGPoint] = [:]
        for group in detection?.groups ?? [] {
            for point in group.points where point.confidence >= minimumConfidence {
                if let label = point.label, point.point.x.isFinite, point.point.y.isFinite {
                    points[label] = point.point
                }
            }
        }
        guard let a = points[rule.first.trackerLabel], let b = points[rule.last.trackerLabel] else { return nil }
        func length(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }
        if rule.metric == .distance {
            guard rule.first.side == rule.last.side else { return length(a, b) }
            let prefix = rule.first.side.labelPrefix
            guard let wrist = points["\(prefix)0"], let middle = points["\(prefix)9"],
                  length(wrist, middle) > 0.00001 else { return nil }
            return length(a, b) / length(wrist, middle)
        }
        guard let vertex = points[rule.vertex.trackerLabel] else { return nil }
        let ab = length(a, vertex), cb = length(b, vertex)
        guard ab > 0.00001, cb > 0.00001 else { return nil }
        let dot = Double((a.x - vertex.x) * (b.x - vertex.x)
            + (a.y - vertex.y) * (b.y - vertex.y)) / (ab * cb)
        return acos(min(1, max(-1, dot))) * 180 / .pi
    }
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
