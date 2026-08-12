import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum MediaPipeHandSide: String, Codable, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }
    var title: String { self == .left ? "Left hand" : "Right hand" }
    var labelPrefix: String { self == .left ? "L" : "R" }
}

enum MediaPipeHandLandmark: Int, Codable, CaseIterable, Identifiable {
    case wrist = 0
    case thumbCMC = 1
    case thumbMCP = 2
    case thumbIP = 3
    case thumbTip = 4
    case indexMCP = 5
    case indexPIP = 6
    case indexDIP = 7
    case indexTip = 8
    case middleMCP = 9
    case middlePIP = 10
    case middleDIP = 11
    case middleTip = 12
    case ringMCP = 13
    case ringPIP = 14
    case ringDIP = 15
    case ringTip = 16
    case littleMCP = 17
    case littlePIP = 18
    case littleDIP = 19
    case littleTip = 20

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .wrist: "Wrist"
        case .thumbCMC: "Thumb CMC"
        case .thumbMCP: "Thumb MCP"
        case .thumbIP: "Thumb IP"
        case .thumbTip: "Thumb tip"
        case .indexMCP: "Index MCP"
        case .indexPIP: "Index PIP"
        case .indexDIP: "Index DIP"
        case .indexTip: "Index tip"
        case .middleMCP: "Middle MCP"
        case .middlePIP: "Middle PIP"
        case .middleDIP: "Middle DIP"
        case .middleTip: "Middle tip"
        case .ringMCP: "Ring MCP"
        case .ringPIP: "Ring PIP"
        case .ringDIP: "Ring DIP"
        case .ringTip: "Ring tip"
        case .littleMCP: "Little MCP"
        case .littlePIP: "Little PIP"
        case .littleDIP: "Little DIP"
        case .littleTip: "Little tip"
        }
    }
}

struct MediaPipeHandFeature: Codable, Equatable, Hashable, Identifiable {
    var side: MediaPipeHandSide
    var landmark: MediaPipeHandLandmark

    var id: String { "\(side.rawValue).\(landmark.rawValue)" }
    var trackerLabel: String { "\(side.labelPrefix)\(landmark.rawValue)" }
    var title: String { "\(side.title) · \(landmark.title)" }

    static let rightIndexTip = MediaPipeHandFeature(side: .right, landmark: .indexTip)
    static let allCases = MediaPipeHandSide.allCases.flatMap { side in
        MediaPipeHandLandmark.allCases.map { MediaPipeHandFeature(side: side, landmark: $0) }
    }
}

enum SystemPointerDriveMode: String, Codable, CaseIterable, Identifiable {
    case always
    case whilePinching

    var id: String { rawValue }
    var title: String { self == .always ? "Always" : "While pinching" }
}

struct SystemPointerMapping: Codable, Equatable {
    var pointer = MediaPipeHandFeature.rightIndexTip
    var driveMode = SystemPointerDriveMode.whilePinching
    var clickWithPinch = true
    var smoothing: Double = 0.55
    var horizontalCoverage: Double = 0.75
    var verticalCoverage: Double = 0.75
    var minimumConfidence: Float = 0.25
    var pinchThreshold: Double = 0.35
    var missingGraceSeconds: Double = 0.18

    static let `default` = SystemPointerMapping()
}

struct SystemPointerLiveState: Equatable {
    var featureAvailable = false
    var normalizedPoint: CGPoint?
    var pinchValue: Double?
    var pinching = false
    var status = "Not armed"
}

enum SystemPointerEvent: Equatable {
    case move(CGPoint)
    case leftDown(CGPoint)
    case leftDrag(CGPoint)
    case leftUp(CGPoint)
}

/// Pure mapping state machine. Keeping Quartz event posting outside this type
/// makes pinch hysteresis, coordinate mapping, and missing-data release testable
/// without moving the user's real cursor during tests.
final class SystemPointerEngine {
    private var smoothedPoint: CGPoint?
    private var pinchActive = false
    private var buttonDown = false
    private var lastAvailableAt: TimeInterval?

    func update(
        detection: LandmarkDetection?,
        mapping: SystemPointerMapping,
        screenBounds: CGRect,
        mirrored: Bool,
        now: TimeInterval
    ) -> (events: [SystemPointerEvent], live: SystemPointerLiveState) {
        let points = Self.pointsByLabel(detection)
        guard let pointer = points[mapping.pointer.trackerLabel],
              pointer.confidence >= mapping.minimumConfidence else {
            let stale = lastAvailableAt.map { now - $0 >= mapping.missingGraceSeconds } ?? true
            var events: [SystemPointerEvent] = []
            if stale {
                if buttonDown, let smoothedPoint { events.append(.leftUp(smoothedPoint)) }
                buttonDown = false
                pinchActive = false
                smoothedPoint = nil
            }
            return (events, SystemPointerLiveState(status: stale ? "Waiting for \(mapping.pointer.title)" : "Tracking grace"))
        }

        lastAvailableAt = now
        let normalized = CGPoint(
            x: Self.remap(pointer.point.x, coverage: mapping.horizontalCoverage),
            y: Self.remap(pointer.point.y, coverage: mapping.verticalCoverage)
        )
        let screenPoint = CGPoint(
            x: screenBounds.minX + (mirrored ? 1 - normalized.x : normalized.x) * screenBounds.width,
            y: screenBounds.minY + (1 - normalized.y) * screenBounds.height
        )
        let keep = min(0.95, max(0, mapping.smoothing))
        let smoothed = smoothedPoint.map {
            CGPoint(x: $0.x * keep + screenPoint.x * (1 - keep),
                    y: $0.y * keep + screenPoint.y * (1 - keep))
        } ?? screenPoint
        smoothedPoint = smoothed

        let pinch = Self.pinch(side: mapping.pointer.side, points: points)
        if let value = pinch.value, pinch.available {
            let releaseThreshold = min(1.5, mapping.pinchThreshold + 0.10)
            pinchActive = pinchActive ? value < releaseThreshold : value < mapping.pinchThreshold
        } else {
            pinchActive = false
        }

        let shouldMove = mapping.driveMode == .always || pinchActive
        var events: [SystemPointerEvent] = []
        if shouldMove {
            events.append(buttonDown ? .leftDrag(smoothed) : .move(smoothed))
        }
        if mapping.clickWithPinch {
            if pinchActive, !buttonDown {
                if !shouldMove { events.append(.move(smoothed)) }
                events.append(.leftDown(smoothed))
                buttonDown = true
            } else if !pinchActive, buttonDown {
                events.append(.leftUp(smoothed))
                buttonDown = false
            }
        } else if buttonDown {
            events.append(.leftUp(smoothed))
            buttonDown = false
        }

        return (
            events,
            SystemPointerLiveState(
                featureAvailable: true,
                normalizedPoint: pointer.point,
                pinchValue: pinch.value,
                pinching: pinchActive,
                status: pinchActive ? "Pinching" : "Tracking"
            )
        )
    }

    func stop() -> [SystemPointerEvent] {
        defer {
            smoothedPoint = nil
            pinchActive = false
            buttonDown = false
            lastAvailableAt = nil
        }
        guard buttonDown, let smoothedPoint else { return [] }
        return [.leftUp(smoothedPoint)]
    }

    private static func pointsByLabel(_ detection: LandmarkDetection?) -> [String: LandmarkPoint] {
        guard let detection else { return [:] }
        return detection.groups.reduce(into: [:]) { result, group in
            for point in group.points {
                if let label = point.label { result[label] = point }
            }
        }
    }

    private static func pinch(side: MediaPipeHandSide, points: [String: LandmarkPoint]) -> (available: Bool, value: Double?) {
        func point(_ index: MediaPipeHandLandmark) -> LandmarkPoint? {
            points["\(side.labelPrefix)\(index.rawValue)"]
        }
        guard let thumb = point(.thumbTip), let index = point(.indexTip),
              let wrist = point(.wrist), let middle = point(.middleMCP) else { return (false, nil) }
        let palmSize = hypot(wrist.point.x - middle.point.x, wrist.point.y - middle.point.y)
        guard palmSize > 0.000_001 else { return (false, nil) }
        let distance = hypot(thumb.point.x - index.point.x, thumb.point.y - index.point.y)
        return (true, Double(distance / palmSize))
    }

    private static func remap(_ value: CGFloat, coverage: Double) -> CGFloat {
        let width = CGFloat(min(1, max(0.2, coverage)))
        let lower = (1 - width) / 2
        return min(1, max(0, (value - lower) / width))
    }
}

/// The narrow imperative macOS boundary: Accessibility trust plus Quartz event
/// posting. Mapping state remains a Codable Swift value owned by the editor.
final class SystemPointerController: ObservableObject, @unchecked Sendable {
    @Published var mapping: SystemPointerMapping {
        didSet {
            stateLock.withLock { runtimeMapping = mapping }
            if let data = try? JSONEncoder().encode(mapping) {
                defaults.set(data, forKey: Self.mappingDefaultsKey)
            }
        }
    }
    @Published private(set) var isTrusted: Bool
    @Published private(set) var isArmed = false
    @Published private(set) var live = SystemPointerLiveState()

    private static let mappingDefaultsKey = "systemPointerMapping.v1"
    private let defaults: UserDefaults
    private let stateLock = NSLock()
    private let engine = SystemPointerEngine()
    private var runtimeMapping: SystemPointerMapping
    private var runtimeArmed = false
    private var lastLivePublish: TimeInterval = 0
    private var lastPublishedPinching = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.mappingDefaultsKey)
            .flatMap { try? JSONDecoder().decode(SystemPointerMapping.self, from: $0) }
            ?? .default
        mapping = saved
        runtimeMapping = saved
        isTrusted = AXIsProcessTrusted()
    }

    var isRuntimeArmed: Bool { stateLock.withLock { runtimeArmed } }

    @discardableResult
    func arm() -> Bool {
        refreshTrust()
        guard isTrusted else {
            live.status = "Reapprove Accessibility after rebuild"
            requestAccessibility()
            return false
        }
        stateLock.withLock { runtimeArmed = true }
        isArmed = true
        live.status = "Waiting for \(mapping.pointer.title)"
        return true
    }

    func disarm() {
        let events = stateLock.withLock { () -> [SystemPointerEvent] in
            runtimeArmed = false
            return engine.stop()
        }
        post(events)
        isArmed = false
        live = SystemPointerLiveState()
    }

    func refreshTrust() {
        isTrusted = AXIsProcessTrusted()
        if !isTrusted {
            if isArmed { disarm() }
            live.status = "Accessibility unavailable"
        } else if !isArmed {
            live.status = "Ready to arm"
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        guard !isTrusted else {
            live.status = "Ready to arm"
            return
        }
        live.status = "Approve the current build in System Settings"
        // macOS does not present another AX prompt when a stale entry from a
        // previous development signature already exists. Opening the pane is
        // the only actionable fallback in that state.
        openAccessibilitySettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshTrust() }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func update(detection: LandmarkDetection?, mirrored: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let result: (events: [SystemPointerEvent], live: SystemPointerLiveState, shouldPublish: Bool)? = stateLock.withLock {
            guard runtimeArmed else { return nil }
            let result = engine.update(
                detection: detection,
                mapping: runtimeMapping,
                screenBounds: CGDisplayBounds(CGMainDisplayID()),
                mirrored: mirrored,
                now: now
            )
            let shouldPublish = now - lastLivePublish >= 0.08 || result.live.pinching != lastPublishedPinching
            if shouldPublish {
                lastLivePublish = now
                lastPublishedPinching = result.live.pinching
            }
            return (result.events, result.live, shouldPublish)
        }
        guard let result else { return }
        post(result.events)
        if result.shouldPublish {
            DispatchQueue.main.async { [weak self] in self?.live = result.live }
        }
    }

    private func post(_ events: [SystemPointerEvent]) {
        for event in events {
            let type: CGEventType
            let point: CGPoint
            switch event {
            case .move(let p): type = .mouseMoved; point = p
            case .leftDown(let p): type = .leftMouseDown; point = p
            case .leftDrag(let p): type = .leftMouseDragged; point = p
            case .leftUp(let p): type = .leftMouseUp; point = p
            }
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }
}
