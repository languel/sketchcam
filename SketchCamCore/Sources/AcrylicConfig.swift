import CoreGraphics
import Foundation

public enum AcrylicMixModel: String, Codable, Sendable, CaseIterable {
    case rgb
    case pigment
}

public struct AcrylicStroke: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var points: [CGPoint]
    public var color: RGBAColor
    public var width: Float
    public var loading: Float
    public var body: Float
    public var mixModel: AcrylicMixModel

    public init(id: UUID = UUID(), points: [CGPoint], color: RGBAColor, width: Float,
                loading: Float, body: Float, mixModel: AcrylicMixModel) {
        self.id = id; self.points = points; self.color = color; self.width = width
        self.loading = loading; self.body = body; self.mixModel = mixModel
    }
}

public struct AcrylicConfig: Codable, Sendable, Equatable {
    public var enabled = true
    public var strokes: [AcrylicStroke] = []
    public var color = RGBAColor(red: 0.92, green: 0.18, blue: 0.12, alpha: 1)
    public var width: Float = 0.035
    public var body: Float = 0.5
    public var pigmentOpacity: Float = 0.85
    public var viscosity: Float = 0.45
    public var leveling: Float = 0.5
    public var brushRetention: Float = 0.35
    public var paintLoading: Float = 0.65
    public var flow: Float = 0.55
    public var dryRate: Float = 0.15
    public var mixModel: AcrylicMixModel = .pigment
    public var paperInfluence: Float = 0
    public var liveSurfaceInfluence: Float = 0
    public var liveAbsorbency: Float = 0
    public var liveDrag: Float = 0.5
    public var liveResist: Float = 1
    public var motionForce: Float = 0
    public var rebuildRevision = 0
    public var clearRevision = 0
    public var instantDryRevision = 0

    public init() {}

    public mutating func applyBody(_ value: Float) {
        let v = min(max(value, 0), 1)
        body = v
        pigmentOpacity = curve(v, 0.25, 0.85, 1)
        viscosity = curve(v, 0.1, 0.45, 0.95)
        leveling = curve(v, 0.9, 0.5, 0.08)
        brushRetention = curve(v, 0.05, 0.35, 0.95)
        paintLoading = curve(v, 0.3, 0.65, 1)
        flow = curve(v, 0.9, 0.55, 0.15)
    }

    private func curve(_ value: Float, _ low: Float, _ middle: Float, _ high: Float) -> Float {
        value <= 0.5 ? low + (middle - low) * value * 2 : middle + (high - middle) * (value - 0.5) * 2
    }
}
