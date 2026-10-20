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

/// Deliberate session control, independent of editable action maps. A held
/// pose fires once; a visible release is required even across tracking loss.
struct PalmArmGestureRecognizer {
    private var heldSince: TimeInterval?
    private var releasedSince: TimeInterval?
    private var latched = false
    private var lastDetectionID: UInt64?
    private var lastFreshAt: TimeInterval?
    private var reserved = false
    private var anchor = CGPoint(x: 0.5, y: 0.5)

    mutating func update(detection: LandmarkDetection?, now: TimeInterval)
        -> (reserved: Bool, fired: Bool, point: CGPoint) {
        if let lastFreshAt, now - lastFreshAt > 0.4 {
            heldSince = nil
            releasedSince = nil
            reserved = latched
        }
        guard let detection else {
            heldSince = nil
            releasedSince = nil
            reserved = latched
            return (reserved, false, anchor)
        }
        let observationID = detection.observationID ?? detection.detectionID
        guard observationID != lastDetectionID else { return (reserved, false, anchor) }
        lastDetectionID = observationID
        lastFreshAt = now
        let labels = Set(detection.groups.flatMap(\.points).compactMap {
            $0.confidence >= 0.25 && $0.point.x.isFinite && $0.point.y.isFinite ? $0.label : nil
        })
        // The four fingertips and their PIP joints are enough to recognize an
        // open hand. Requiring thumb joints made the two-hand arm pose fail
        // whenever Vision had low confidence on either thumb.
        let joints = [0, 6, 8, 9, 10, 12, 14, 16, 18, 20]
        guard ["L", "R"].allSatisfy({ side in joints.allSatisfy { labels.contains("\(side)\($0)") } }) else {
            heldSince = nil
            releasedSince = nil
            reserved = latched
            return (reserved, false, anchor)
        }
        var mapping = SystemPointerMapping.default
        mapping.minimumConfidence = 0.25
        let bothOpen = MediaPipeHandSide.allCases.allSatisfy { side in
            mapping.pointer.side = side
            return GestureMappingEngine.recognize(detection: detection, mapping: mapping,
                previous: heldSince != nil || latched ? .openPalm : nil) == .openPalm
        }
        if bothOpen {
            releasedSince = nil
            reserved = true
            let palms = detection.groups.flatMap(\.points).filter { $0.label == "L9" || $0.label == "R9" }
            if palms.count == 2 {
                anchor = CGPoint(x: (palms[0].point.x + palms[1].point.x) / 2,
                                 y: (palms[0].point.y + palms[1].point.y) / 2)
            }
            if heldSince == nil { heldSince = now }
            if !latched, let heldSince, now - heldSince >= 0.9 {
                latched = true
                return (true, true, anchor)
            }
        } else {
            heldSince = nil
            if releasedSince == nil { releasedSince = now }
            if let releasedSince, now - releasedSince >= 0.3 { latched = false }
            reserved = latched
        }
        return (reserved, false, anchor)
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
    case action, parameter, tool
    var id: String { rawValue }
    var title: String {
        switch self {
        case .action: "Active action"
        case .parameter: "Passive parameter"
        case .tool: "Tool sequence"
        }
    }
}

/// A sequence can combine held hand poses with proximity between any two
/// tracked points. Labels use the same stable L/R joint IDs as Input Map.
struct MotionSequenceStep: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case gesture, handPose, fistSqueeze, proximity, angle
        var id: String { rawValue }
        var title: String {
            switch self {
            case .gesture: "Gesture"
            case .handPose: "Finger count"
            case .fistSqueeze: "Fist squeezes"
            case .proximity: "Proximity"
            case .angle: "Angle"
            }
        }
    }
    var id = UUID()
    var kind: Kind = .proximity
    var hand: MediaPipeHandSide = .left
    var gesture: MotionGestureGate = .pinch
    /// Nil means any finger count. Optional for backward-compatible presets.
    var fingerCount: Int? = nil
    /// Optional simultaneous sign on the opposite hand.
    var otherFingerCount: Int? = nil
    var thumbState: MotionDigitState? = nil
    var indexState: MotionDigitState? = nil
    var middleState: MotionDigitState? = nil
    var ringState: MotionDigitState? = nil
    var littleState: MotionDigitState? = nil
    var squeezeCount: Int? = nil
    var squeezeWindow: Double? = nil
    var pointA = "L20"
    var pointB = "nose"
    var pointVertex = "L19"
    /// Image-normalized distance. The pose must remain satisfied for dwell.
    var maximumDistance = 0.045
    var minimumAngle = 0.0
    var maximumAngle = 45.0
    var dwell = 0.18
    /// Maximum pause after the preceding step before this one completes.
    var maximumGap = 1.2

    static var pointChoices: [(label: String, title: String)] {
        [("nose", "Nose"), ("mouth", "Mouth"), ("leftEye", "Left eye"),
         ("rightEye", "Right eye")] + MediaPipeHandFeature.allCases.map {
            ($0.trackerLabel, $0.title)
        }
    }
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

enum MotionDigitState: String, Codable, CaseIterable, Identifiable {
    case extended, folded
    var id: String { rawValue }
    var title: String { self == .extended ? "Up" : "Folded" }
}

/// Vision provides 2D hand joints, so discrete hand signs are inferred from
/// fingertip-to-palm geometry rather than a semantic facing/orientation label.
enum MotionHandPoseRecognizer {
    static func fingerPattern(in detection: LandmarkDetection?, side: MediaPipeHandSide,
                              minimumConfidence: Float) -> [Bool]? {
        var points: [Int: CGPoint] = [:]
        for point in detection?.groups.flatMap(\.points) ?? [] {
            guard let label = point.label, label.first == side.labelPrefix.first,
                  let index = Int(label.dropFirst()), point.confidence >= minimumConfidence,
                  point.point.x.isFinite, point.point.y.isFinite else { continue }
            points[index] = point.point
        }
        guard let wrist = points[0], let middleMCP = points[9],
              let thumb = points[4], let indexMCP = points[5] else { return nil }
        let palmScale = hypot(wrist.x - middleMCP.x, wrist.y - middleMCP.y)
        guard palmScale > 0.00001 else { return nil }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        var pattern = [distance(thumb, indexMCP) > palmScale * 0.52]
        for (tip, pip) in [(8, 6), (12, 10), (16, 14), (20, 18)] {
            guard let fingertip = points[tip], let joint = points[pip] else { return nil }
            let tipReach = distance(fingertip, wrist)
            let jointReach = distance(joint, wrist)
            pattern.append(tipReach > jointReach * 1.10)
        }
        return pattern
    }

    static func fingerCount(in detection: LandmarkDetection?, side: MediaPipeHandSide,
                            minimumConfidence: Float) -> Int? {
        fingerPattern(in: detection, side: side, minimumConfidence: minimumConfidence)?
            .reduce(0) { $0 + ($1 ? 1 : 0) }
    }

    static func matches(_ pattern: [Bool], states: [MotionDigitState?]) -> Bool {
        guard pattern.count == states.count else { return false }
        return zip(pattern, states).allSatisfy { extended, state in
            guard let state else { return true }
            return (state == .extended) == extended
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
    /// Optional extended-finger count; pair with Any gesture for sign-only maps.
    var fingerCount: Int? = nil
    var otherFingerCount: Int? = nil
    var thumbState: MotionDigitState? = nil
    var indexState: MotionDigitState? = nil
    var middleState: MotionDigitState? = nil
    var ringState: MotionDigitState? = nil
    var littleState: MotionDigitState? = nil
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
    var toolID = ""
    var sequence: [MotionSequenceStep] = []

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, kind, hand, gesture, mode, intent, metric
        case first, vertex, last, target, inputLow, inputHigh, outputLow, outputHigh
        case toolID, sequence, fingerCount, otherFingerCount
        case thumbState, indexState, middleState, ringState, littleState
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try box.decode(String.self, forKey: .name)
        enabled = try box.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        kind = try box.decode(MotionMapKind.self, forKey: .kind)
        hand = try box.decode(MediaPipeHandSide.self, forKey: .hand)
        gesture = try box.decode(MotionGestureGate.self, forKey: .gesture)
        fingerCount = try box.decodeIfPresent(Int.self, forKey: .fingerCount)
        otherFingerCount = try box.decodeIfPresent(Int.self, forKey: .otherFingerCount)
        thumbState = try box.decodeIfPresent(MotionDigitState.self, forKey: .thumbState)
        indexState = try box.decodeIfPresent(MotionDigitState.self, forKey: .indexState)
        middleState = try box.decodeIfPresent(MotionDigitState.self, forKey: .middleState)
        ringState = try box.decodeIfPresent(MotionDigitState.self, forKey: .ringState)
        littleState = try box.decodeIfPresent(MotionDigitState.self, forKey: .littleState)
        mode = try box.decodeIfPresent(MotionPaintMode.self, forKey: .mode) ?? .pen
        intent = try box.decodeIfPresent(MotionPaintIntent.self, forKey: .intent) ?? .draw
        metric = try box.decodeIfPresent(MotionJointMetric.self, forKey: .metric) ?? .distance
        first = try box.decodeIfPresent(MediaPipeHandFeature.self, forKey: .first)
            ?? MediaPipeHandFeature(side: .left, landmark: .littleTip)
        vertex = try box.decodeIfPresent(MediaPipeHandFeature.self, forKey: .vertex)
            ?? MediaPipeHandFeature(side: .left, landmark: .indexMCP)
        last = try box.decodeIfPresent(MediaPipeHandFeature.self, forKey: .last)
            ?? MediaPipeHandFeature(side: .left, landmark: .thumbTip)
        target = try box.decodeIfPresent(MotionParameterTarget.self, forKey: .target) ?? .washSize
        inputLow = try box.decodeIfPresent(Double.self, forKey: .inputLow) ?? 0.2
        inputHigh = try box.decodeIfPresent(Double.self, forKey: .inputHigh) ?? 1.2
        outputLow = try box.decodeIfPresent(Double.self, forKey: .outputLow) ?? 0.1
        outputHigh = try box.decodeIfPresent(Double.self, forKey: .outputHigh) ?? 1.2
        toolID = try box.decodeIfPresent(String.self, forKey: .toolID) ?? ""
        sequence = try box.decodeIfPresent([MotionSequenceStep].self, forKey: .sequence) ?? []
    }

    init(id: UUID = UUID(), name: String, enabled: Bool = true, kind: MotionMapKind,
         hand: MediaPipeHandSide, gesture: MotionGestureGate,
         mode: MotionPaintMode = .pen, intent: MotionPaintIntent = .draw) {
        self.id = id; self.name = name; self.enabled = enabled; self.kind = kind
        self.hand = hand; self.gesture = gesture; self.mode = mode; self.intent = intent
    }

    static func action(_ hand: MediaPipeHandSide, _ gesture: MotionGestureGate,
                       _ mode: MotionPaintMode, _ intent: MotionPaintIntent) -> Self {
        Self(name: "\(hand.title) \(gesture.title)", kind: .action, hand: hand,
             gesture: gesture, mode: mode, intent: intent)
    }
    static func parameter() -> Self {
        Self(name: "Finger distance → wash size", kind: .parameter,
             hand: .right, gesture: .pinch)
    }
    static func tool() -> Self {
        var rule = Self(name: "Pinky to nose → tool", kind: .tool, hand: .left,
                        gesture: .any)
        rule.toolID = "ink.color.sampleNose"
        rule.sequence = [MotionSequenceStep()]
        return rule
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

/// Edge-triggered sequence recognizer. Each map has independent progress and
/// must release its final condition before it can fire again. Tracking loss
/// cancels partial sequences, rather than completing them from stale points.
final class MotionSequenceRecognizer {
    private struct SqueezePulse {
        var id: Int
        var at: TimeInterval
    }
    private struct Progress {
        var index = 0
        var satisfiedSince: TimeInterval?
        var previousCompletedAt: TimeInterval?
        var waitingForRelease = false
        var awaitingReleaseOf: Int?
        var squeezeCursor: Int?
        var squeezeBurstCount = 0
        var squeezeBurstStartedAt: TimeInterval?
    }
    private var progress: [UUID: Progress] = [:]
    private var squeezeReleaseReady: Set<MediaPipeHandSide> = []
    private var squeezePulses: [MediaPipeHandSide: [SqueezePulse]] = [:]
    private var nextSqueezeID = 0
    private(set) var lastFiredRuleIDs: [UUID] = []

    func reset() {
        progress.removeAll()
        squeezeReleaseReady.removeAll()
        squeezePulses.removeAll()
        nextSqueezeID = 0
        lastFiredRuleIDs = []
    }

    func update(rules: [MotionGestureMap], detection: LandmarkDetection?,
                gestures: [MediaPipeHandSide: HandGesture],
                minimumConfidence: Float, now: TimeInterval,
                fingerCounts: [MediaPipeHandSide: Int] = [:],
                fingerPatterns: [MediaPipeHandSide: [Bool]] = [:]) -> [String] {
        lastFiredRuleIDs = []
        guard let detection else { reset(); return [] }
        var newSqueezeIDs: [MediaPipeHandSide: Int] = [:]
        for side in MediaPipeHandSide.allCases {
            let gesture = gestures[side]
            if gesture == .fist {
                if squeezeReleaseReady.remove(side) != nil {
                    nextSqueezeID += 1
                    let pulse = SqueezePulse(id: nextSqueezeID, at: now)
                    squeezePulses[side, default: []].append(pulse)
                    newSqueezeIDs[side] = pulse.id
                }
            } else if gesture != nil || (fingerCounts[side] ?? 0) > 0 {
                // Require an observed release pose before counting another
                // fist, preventing tracking loss from becoming a phantom click.
                squeezeReleaseReady.insert(side)
            } else {
                squeezeReleaseReady.remove(side)
            }
            squeezePulses[side]?.removeAll { now - $0.at > 3 }
        }
        let points = Self.points(in: detection, minimumConfidence: minimumConfidence)
        let enabled = rules.filter { $0.enabled && $0.kind == .tool && !$0.toolID.isEmpty && !$0.sequence.isEmpty }
        progress = progress.filter { id, _ in enabled.contains { $0.id == id } }
        var fired: [String] = []
        for rule in enabled {
            var state = progress[rule.id] ?? Progress()
            let steps = rule.sequence
            if state.waitingForRelease {
                if !Self.matches(steps[steps.count - 1], points: points, gestures: gestures,
                                 fingerCounts: fingerCounts, fingerPatterns: fingerPatterns) {
                    state.waitingForRelease = false
                }
                progress[rule.id] = state
                continue
            }
            if let previous = state.awaitingReleaseOf {
                if steps[previous].kind != .fistSqueeze,
                   Self.matches(steps[previous], points: points, gestures: gestures,
                                fingerCounts: fingerCounts, fingerPatterns: fingerPatterns) {
                    progress[rule.id] = state
                    continue
                }
                state.awaitingReleaseOf = nil
            }
            if let completed = state.previousCompletedAt,
               now - completed > steps[state.index].maximumGap {
                state = Progress()
            }
            let step = steps[state.index]
            if step.kind == .fistSqueeze {
                let pulses = squeezePulses[step.hand] ?? []
                if state.squeezeCursor == nil {
                    // Ignore old squeezes when a map is enabled, but include a
                    // fist edge occurring on this frame.
                    state.squeezeCursor = newSqueezeIDs[step.hand].map { $0 - 1 }
                        ?? pulses.last?.id ?? 0
                }
                let window = max(0.2, step.squeezeWindow ?? 0.8)
                let required = min(5, max(1, step.squeezeCount ?? 2))
                for pulse in pulses where pulse.id > (state.squeezeCursor ?? 0) {
                    if let started = state.squeezeBurstStartedAt,
                       pulse.at - started <= window {
                        state.squeezeBurstCount += 1
                    } else {
                        state.squeezeBurstCount = 1
                        state.squeezeBurstStartedAt = pulse.at
                    }
                    state.squeezeCursor = pulse.id
                }
                if let started = state.squeezeBurstStartedAt, now - started > window {
                    state.squeezeBurstCount = 0
                    state.squeezeBurstStartedAt = nil
                }
                if state.squeezeBurstCount >= required {
                    let completedIndex = state.index
                    state.index += 1
                    state.satisfiedSince = nil
                    state.previousCompletedAt = now
                    state.squeezeBurstCount = 0
                    state.squeezeBurstStartedAt = nil
                    if state.index == steps.count {
                        fired.append(rule.toolID)
                        lastFiredRuleIDs.append(rule.id)
                        state = Progress(squeezeCursor: state.squeezeCursor)
                    } else {
                        state.awaitingReleaseOf = completedIndex
                        if steps[state.index].kind == .fistSqueeze {
                            state.squeezeCursor = squeezePulses[steps[state.index].hand]?.last?.id ?? 0
                        }
                    }
                }
                progress[rule.id] = state
                continue
            }
            if state.squeezeCursor == nil {
                state.squeezeCursor = squeezePulses[step.hand]?.last?.id ?? 0
            }
            if Self.matches(step, points: points, gestures: gestures,
                            fingerCounts: fingerCounts, fingerPatterns: fingerPatterns) {
                if state.satisfiedSince == nil { state.satisfiedSince = now }
                if now - (state.satisfiedSince ?? now) >= max(0.04, step.dwell) {
                    let completedIndex = state.index
                    state.index += 1
                    state.satisfiedSince = nil
                    state.previousCompletedAt = now
                    if state.index == steps.count {
                        fired.append(rule.toolID)
                        lastFiredRuleIDs.append(rule.id)
                        state = Progress(waitingForRelease: true,
                                         squeezeCursor: state.squeezeCursor)
                    } else {
                        state.awaitingReleaseOf = completedIndex
                        if steps[state.index].kind == .fistSqueeze {
                            state.squeezeCursor = squeezePulses[steps[state.index].hand]?.last?.id ?? 0
                            state.squeezeBurstCount = 0
                            state.squeezeBurstStartedAt = nil
                        }
                    }
                }
            } else {
                state.satisfiedSince = nil
            }
            progress[rule.id] = state
        }
        return fired
    }

    private static func points(in detection: LandmarkDetection, minimumConfidence: Float) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        for group in detection.groups {
            let valid = group.points.filter { $0.confidence >= minimumConfidence &&
                $0.point.x.isFinite && $0.point.y.isFinite }
            for point in valid {
                if let label = point.label { result[label] = point.point }
            }
            let alias: String? = switch group.region {
            case .nose: "nose"
            case .mouth: "mouth"
            case .leftEye: "leftEye"
            case .rightEye: "rightEye"
            default: nil
            }
            if let alias, !valid.isEmpty {
                let count = CGFloat(valid.count)
                result[alias] = CGPoint(x: valid.reduce(0) { $0 + $1.point.x } / count,
                                        y: valid.reduce(0) { $0 + $1.point.y } / count)
            }
        }
        return result
    }

    private static func matches(_ step: MotionSequenceStep, points: [String: CGPoint],
                                gestures: [MediaPipeHandSide: HandGesture],
                                fingerCounts: [MediaPipeHandSide: Int],
                                fingerPatterns: [MediaPipeHandSide: [Bool]]) -> Bool {
        switch step.kind {
        case .gesture:
            return gestures[step.hand] != nil && step.gesture.matches(gestures[step.hand])
        case .handPose:
            guard let count = fingerCounts[step.hand] else { return false }
            guard step.fingerCount.map({ $0 == count }) ?? true else { return false }
            if let pattern = fingerPatterns[step.hand],
               !MotionHandPoseRecognizer.matches(pattern, states: [step.thumbState, step.indexState,
                                                                    step.middleState, step.ringState,
                                                                    step.littleState]) { return false }
            if [step.thumbState, step.indexState, step.middleState, step.ringState, step.littleState]
                .contains(where: { $0 != nil }), fingerPatterns[step.hand] == nil { return false }
            if let otherCount = step.otherFingerCount {
                return fingerCounts[step.hand.opposite] == otherCount
            }
            return true
        case .fistSqueeze:
            return false
        case .proximity:
            guard let a = points[step.pointA], let b = points[step.pointB] else { return false }
            return Double(hypot(a.x - b.x, a.y - b.y)) <= max(0.001, step.maximumDistance)
        case .angle:
            guard let a = points[step.pointA], let v = points[step.pointVertex],
                  let b = points[step.pointB] else { return false }
            let av = Double(hypot(a.x - v.x, a.y - v.y))
            let bv = Double(hypot(b.x - v.x, b.y - v.y))
            guard av > 0.00001, bv > 0.00001 else { return false }
            let dot = Double((a.x - v.x) * (b.x - v.x) + (a.y - v.y) * (b.y - v.y)) / (av * bv)
            let degrees = acos(min(1, max(-1, dot))) * 180 / .pi
            return degrees >= step.minimumAngle && degrees <= step.maximumAngle
        }
    }
}

/// Pure two-hand rule evaluator. It intentionally emits one active paint
/// action because the current Ink live channel has one stroke identity.
final class CanvasGestureStackEngine {
    private var leftPointer = SystemPointerEngine()
    private var rightPointer = SystemPointerEngine()
    private var candidate: [MediaPipeHandSide: HandGesture] = [:]
    private var candidateSince: [MediaPipeHandSide: TimeInterval] = [:]
    private var stable: [MediaPipeHandSide: HandGesture] = [:]
    private var fingerCountCandidateSince: [MediaPipeHandSide: TimeInterval] = [:]
    private var stableFingerCounts: [MediaPipeHandSide: Int] = [:]
    private var fingerPatternCandidate: [MediaPipeHandSide: [Bool]] = [:]
    private var stableFingerPatterns: [MediaPipeHandSide: [Bool]] = [:]
    private var owner: UUID?
    private var lastSeen: TimeInterval?
    private let sequences = MotionSequenceRecognizer()

    func update(detection: LandmarkDetection?, mapping: SystemPointerMapping, screen: CGRect,
                mirrored: Bool, now: TimeInterval) -> (events: [SystemPointerEvent], live: SystemPointerLiveState) {
        var locations: [MediaPipeHandSide: CGPoint] = [:]
        var hasHandPose = false
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
            }

            // Pose recognition must not depend on the selected cursor tip being
            // visible: a fist can occlude its index tip while still being a
            // perfectly valid squeeze or hand-sign input.
            let found = GestureMappingEngine.recognize(detection: detection, mapping: positionMapping,
                                                       previous: stable[side])
            if found != nil { hasHandPose = true }
            if candidate[side] != found {
                candidate[side] = found
                candidateSince[side] = now
            }
            if stable[side] != found { stable[side] = nil }
            if let found, stable[side] == nil,
               now - (candidateSince[side] ?? now) >= max(0.04, mapping.gestureDwell ?? 0.12) {
                stable[side] = found
            }

            let foundPattern = MotionHandPoseRecognizer.fingerPattern(in: detection, side: side,
                                                                       minimumConfidence: mapping.minimumConfidence)
            if foundPattern != nil { hasHandPose = true }
            if fingerPatternCandidate[side] != foundPattern {
                fingerPatternCandidate[side] = foundPattern
                fingerCountCandidateSince[side] = now
            }
            if stableFingerPatterns[side] != foundPattern {
                stableFingerPatterns[side] = nil
                stableFingerCounts[side] = nil
            }
            if let foundPattern, stableFingerPatterns[side] == nil,
               now - (fingerCountCandidateSince[side] ?? now) >= max(0.04, mapping.gestureDwell ?? 0.12) {
                stableFingerPatterns[side] = foundPattern
                stableFingerCounts[side] = foundPattern.reduce(0) { $0 + ($1 ? 1 : 0) }
            }
        }
        if !locations.isEmpty || hasHandPose { lastSeen = now }
        let rules = mapping.customGestureMaps ?? []
        _ = sequences.update(rules: rules, detection: detection,
            gestures: stable, minimumConfidence: mapping.minimumConfidence, now: now,
            fingerCounts: stableFingerCounts, fingerPatterns: stableFingerPatterns)
        let firedRules = sequences.lastFiredRuleIDs
        let active = rules.first { $0.enabled && $0.kind == .action
            && Self.matches($0, gestures: stable, fingerCounts: stableFingerCounts,
                            fingerPatterns: stableFingerPatterns)
            && locations[$0.hand] != nil }
        var events: [SystemPointerEvent] = []
        for id in firedRules {
            guard let rule = rules.first(where: { $0.id == id }),
                  let step = rule.sequence.first,
                  let point = Self.sequenceAnchor(step, detection: detection,
                                                  minimumConfidence: mapping.minimumConfidence) else { continue }
            events.append(.tool(rule.toolID))
            events.append(.recognition(GestureRecognition(mapID: id.uuidString,
                label: rule.name, point: point)))
        }
        if owner != active?.id {
            if owner != nil { events.append(.canvasEnd) }
            owner = active?.id
            if let active, stable[active.hand] != nil,
               let point = Self.normalizedLandmark(MediaPipeHandFeature(side: active.hand,
                                                   landmark: mapping.pointer.landmark).trackerLabel, detection: detection,
                                                   minimumConfidence: mapping.minimumConfidence) {
                events.append(.recognition(GestureRecognition(mapID: active.id.uuidString,
                    label: active.name, point: point)))
            }
        }
        if let active, let point = locations[active.hand] {
            var parameters: [MotionParameterTarget: Float] = [:]
            for rule in rules where rule.enabled && rule.kind == .parameter
                && Self.matches(rule, gestures: stable, fingerCounts: stableFingerCounts,
                                fingerPatterns: stableFingerPatterns) {
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
            fingerPatternCandidate.removeAll(); stableFingerPatterns.removeAll()
            fingerCountCandidateSince.removeAll(); stableFingerCounts.removeAll()
        }
        let status = active.map { "\($0.name) → \($0.mode.title) \($0.intent.title)" }
            ?? (locations.isEmpty ? "Waiting for hands" : "Tracking")
        return (events, SystemPointerLiveState(featureAvailable: !locations.isEmpty,
                                                status: status))
    }

    func stop() -> [SystemPointerEvent] {
        _ = leftPointer.stop(); _ = rightPointer.stop()
        candidate.removeAll(); candidateSince.removeAll(); stable.removeAll()
        fingerCountCandidateSince.removeAll(); stableFingerCounts.removeAll()
        fingerPatternCandidate.removeAll(); stableFingerPatterns.removeAll()
        lastSeen = nil
        sequences.reset()
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

    private static func matches(_ rule: MotionGestureMap,
                                gestures: [MediaPipeHandSide: HandGesture],
                                fingerCounts: [MediaPipeHandSide: Int],
                                fingerPatterns: [MediaPipeHandSide: [Bool]]) -> Bool {
        let gesture = gestures[rule.hand]
        let count = fingerCounts[rule.hand]
        let digitStates = [rule.thumbState, rule.indexState, rule.middleState,
                           rule.ringState, rule.littleState]
        let hasFingerCondition = rule.fingerCount != nil || rule.otherFingerCount != nil
            || digitStates.contains(where: { $0 != nil })
        let fingerConditionsMatch = (rule.fingerCount.map { $0 == count } ?? true)
            && (rule.otherFingerCount.map { $0 == fingerCounts[rule.hand.opposite] } ?? true)
        guard fingerConditionsMatch else { return false }
        if digitStates.contains(where: { $0 != nil }) {
            guard let pattern = fingerPatterns[rule.hand],
                  MotionHandPoseRecognizer.matches(pattern, states: digitStates) else { return false }
        }
        let gestureMatches: Bool
        if rule.gesture == .any {
            // Any + a finger count is an explicit hand-sign rule and doesn't
            // need to be classifiable as pinch/fist/open palm.
            gestureMatches = gesture != nil || hasFingerCondition
        } else {
            gestureMatches = gesture != nil && rule.gesture.matches(gesture)
        }
        guard gestureMatches else { return false }
        return rule.fingerCount.map { $0 == count } ?? true
    }

    private static func normalizedLandmark(_ label: String, detection: LandmarkDetection?,
                                           minimumConfidence: Float) -> CGPoint? {
        for group in detection?.groups ?? [] {
            let valid = group.points.filter { $0.confidence >= minimumConfidence && $0.point.x.isFinite && $0.point.y.isFinite }
            if let point = valid.first(where: { $0.label == label }) { return point.point }
            let alias: String? = switch group.region {
            case .nose: "nose"
            case .mouth: "mouth"
            case .leftEye: "leftEye"
            case .rightEye: "rightEye"
            default: nil
            }
            if alias == label, !valid.isEmpty {
                let count = CGFloat(valid.count)
                return CGPoint(x: valid.reduce(0) { $0 + $1.point.x } / count,
                               y: valid.reduce(0) { $0 + $1.point.y } / count)
            }
        }
        return nil
    }

    private static func sequenceAnchor(_ step: MotionSequenceStep, detection: LandmarkDetection?,
                                       minimumConfidence: Float) -> CGPoint? {
        func point(_ label: String) -> CGPoint? { normalizedLandmark(label, detection: detection, minimumConfidence: minimumConfidence) }
        switch step.kind {
        case .proximity:
            guard let a = point(step.pointA), let b = point(step.pointB) else { return point(step.pointA) ?? point(step.pointB) }
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        case .angle: return point(step.pointVertex)
        case .gesture: return point("\(step.hand.labelPrefix)0")
        case .handPose: return point("\(step.hand.labelPrefix)0")
        case .fistSqueeze: return point("\(step.hand.labelPrefix)0")
        }
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
        if entered, let stable, action != .none,
           let landmark = detection?.groups.flatMap(\.points).first(where: {
               $0.label == mapping.pointer.trackerLabel && $0.confidence >= mapping.minimumConfidence
                   && $0.point.x.isFinite && $0.point.y.isFinite
           }) {
            events.append(.recognition(GestureRecognition(mapID: "legacy.\(stable.rawValue)",
                label: "\(stable.title) → \(action.title)", point: landmark.point)))
        }
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
