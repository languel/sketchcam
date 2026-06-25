import CoreGraphics
import Foundation

/// A small, durable camera over SketchCam's authored canvas world.
///
/// The current ink engine still simulates the active output frame only. This
/// camera lets UI/editor data live in a larger world while the renderer maps
/// only the active viewport back into the engine's 0...1 frame.
public struct CanvasCamera: Codable, Equatable, Sendable {
    public var center: CGPoint
    public var viewHeight: CGFloat
    public var rotation: CGFloat
    public var guardFraction: CGFloat

    public init(
        center: CGPoint = CGPoint(x: 0.5, y: 0.5),
        viewHeight: CGFloat = 1,
        rotation: CGFloat = 0,
        guardFraction: CGFloat = 0.05
    ) {
        self.center = center
        self.viewHeight = max(0.000_001, viewHeight)
        self.rotation = rotation
        self.guardFraction = max(0, guardFraction)
    }

    public func viewSize(aspect: CGFloat) -> CGSize {
        CGSize(width: viewHeight * max(0.000_001, aspect), height: viewHeight)
    }

    public func worldBounds(aspect: CGFloat, includeGuard: Bool = false) -> CGRect {
        let size = viewSize(aspect: aspect)
        let c = abs(cos(rotation))
        let s = abs(sin(rotation))
        var width = size.width * c + size.height * s
        var height = size.width * s + size.height * c
        if includeGuard {
            width += size.width * guardFraction * 2
            height += size.height * guardFraction * 2
        }
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    public func worldPoint(fromViewportUV uv: CGPoint, aspect: CGFloat) -> CGPoint {
        let size = viewSize(aspect: aspect)
        let local = CGPoint(x: (uv.x - 0.5) * size.width, y: (uv.y - 0.5) * size.height)
        let c = cos(rotation), s = sin(rotation)
        return CGPoint(
            x: center.x + local.x * c - local.y * s,
            y: center.y + local.x * s + local.y * c
        )
    }

    public func viewportUV(fromWorldPoint point: CGPoint, aspect: CGFloat) -> CGPoint {
        let size = viewSize(aspect: aspect)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let c = cos(rotation), s = sin(rotation)
        let local = CGPoint(x: dx * c + dy * s, y: -dx * s + dy * c)
        return CGPoint(x: local.x / size.width + 0.5, y: local.y / size.height + 0.5)
    }

    public func visibleWorldRect(aspect: CGFloat) -> CGRect {
        let size = viewSize(aspect: aspect)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }
}
