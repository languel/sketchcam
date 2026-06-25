import CoreGraphics
import Foundation

public enum CanvasBrushSpace: String, Codable, Sendable, CaseIterable, Identifiable {
    case screen
    case world

    public var id: String { rawValue }
}

/// Runtime mapping from SketchCam's fixed output viewport into the authored
/// world canvas. The output frame is a camera/loupe; it does not move as a page.
public struct CanvasRenderContext: Codable, Equatable, Sendable {
    public var camera: CanvasCamera
    public var worldPixelExtent: Int
    public var worldHeight: CGFloat
    public var navigationActive: Bool
    public var brushSpace: CanvasBrushSpace

    public init(
        camera: CanvasCamera = CanvasCamera(),
        worldPixelExtent: Int = 8192,
        worldHeight: CGFloat = 1,
        navigationActive: Bool = false,
        brushSpace: CanvasBrushSpace = .screen
    ) {
        self.camera = camera
        self.worldPixelExtent = max(1, worldPixelExtent)
        self.worldHeight = max(0.000_001, worldHeight)
        self.navigationActive = navigationActive
        self.brushSpace = brushSpace
    }

    public func worldPixelRect(aspect: CGFloat, includeGuard: Bool) -> CGRect {
        let bounds = camera.worldBounds(aspect: aspect, includeGuard: includeGuard)
        let scale = CGFloat(worldPixelExtent) / max(0.000_001, worldHeight)
        return CGRect(
            x: bounds.minX * scale,
            y: bounds.minY * scale,
            width: bounds.width * scale,
            height: bounds.height * scale
        )
    }
}
