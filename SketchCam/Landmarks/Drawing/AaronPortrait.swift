import CoreGraphics
import SketchCamCore

/// An authored figure, not a tour of landmark points. Tracking supplies a
/// moving head frame and a few measurements (proportions, expression, pose);
/// the same small set of template curves is drawn on every frame.
enum AaronPortrait {
    static func paths(groups: [MappedGroup], settings: LandmarkSettings) -> [[CGPoint]] {
        func points(_ region: LandmarkRegion) -> [CGPoint] {
            groups.filter { $0.region == region }.flatMap(\.points)
                .filter { $0.x.isFinite && $0.y.isFinite }
        }
        func center(_ values: [CGPoint]) -> CGPoint? {
            guard !values.isEmpty else { return nil }
            return CGPoint(x: values.reduce(0) { $0 + $1.x } / CGFloat(values.count),
                           y: values.reduce(0) { $0 + $1.y } / CGFloat(values.count))
        }
        let jaw = points(.jaw)
        let leftEye = points(.leftEye), rightEye = points(.rightEye)
        let left = center(leftEye) ?? center(points(.leftBrow)) ?? jaw.first
        let right = center(rightEye) ?? center(points(.rightBrow)) ?? jaw.last
        guard let left, let right else { return [] }
        let eyeSpan = max(1, hypot(right.x - left.x, right.y - left.y))
        let origin = CGPoint(x: (left.x + right.x) * 0.5, y: (left.y + right.y) * 0.5)
        let across = CGPoint(x: (right.x - left.x) / eyeSpan, y: (right.y - left.y) / eyeSpan)
        var down = CGPoint(x: -across.y, y: across.x)
        if let chin = jaw.isEmpty ? center(points(.mouth)) : jaw[jaw.count / 2],
           (chin.x - origin.x) * down.x + (chin.y - origin.y) * down.y < 0 {
            down = CGPoint(x: -down.x, y: -down.y)
        }
        let scale = eyeSpan / 0.84
        func local(_ point: CGPoint) -> CGPoint {
            let dx = point.x - origin.x, dy = point.y - origin.y
            return CGPoint(x: (dx * across.x + dy * across.y) / scale,
                           y: (dx * down.x + dy * down.y) / scale)
        }
        func world(_ point: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + scale * (point.x * across.x + point.y * down.x),
                    y: origin.y + scale * (point.x * across.y + point.y * down.y))
        }
        func clamp(_ value: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            min(hi, max(lo, value))
        }
        func measuredBox(_ region: LandmarkRegion) -> CGRect? {
            let observed = points(region).map(local)
            guard !observed.isEmpty else { return nil }
            return observed.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        func shoulder(_ region: LandmarkRegion, label: String) -> CGPoint? {
            guard let group = groups.first(where: { $0.region == region }) else { return nil }
            return zip(group.labels, group.points).first(where: { $0.0 == label })?.1
                ?? group.points.first
        }
        var random = PortraitPRNG(seed: settings.resolvedPortraitSeed &+ 7_341)
        let variation = clamp(CGFloat(settings.resolvedPortraitShapeVariation), 0, 1)
        let expression = clamp(CGFloat(settings.resolvedPortraitExpression), 0, 2)
        // Even at the most observational setting, the detector changes only
        // a bounded proportion; it never supplies a path vertex directly.
        let observation = (1 - clamp(CGFloat(settings.resolvedPortraitAbstraction), 0, 1)) * 0.42
        func adjusted(_ authored: CGFloat, _ observed: CGFloat?) -> CGFloat {
            guard let observed else { return authored }
            return authored + (observed - authored) * observation
        }
        let jawLocal = jaw.map(local)
        let observedWidth = jawLocal.map { abs($0.x) }.max()
        let observedChin = jawLocal.map(\.y).max()
        let width = clamp(adjusted(0.87 + (random.unit() - 0.5) * 0.38 * variation,
                                   observedWidth), 0.70, 1.32)
        let chin = clamp(adjusted(1.48 + (random.unit() - 0.5) * 0.42 * variation,
                                  observedChin), 1.16, 1.96)
        let noseObserved = center(points(.nose)).map(local)
        let yaw = clamp((noseObserved?.x ?? 0) * 1.6, -0.55, 0.55)
        let leftWidth = width * (1 + yaw * 0.30)
        let rightWidth = width * (1 - yaw * 0.30)
        let browLift = (random.unit() - 0.5) * 0.16 * variation
        let eyeOpenL = clamp((measuredBox(.leftEye)?.height ?? 0.12) * expression, 0.025, 0.23)
        let eyeOpenR = clamp((measuredBox(.rightEye)?.height ?? 0.12) * expression, 0.025, 0.23)
        let mouthObserved = measuredBox(.mouth)
        let mouthOpen = clamp((mouthObserved?.height ?? 0.10) * expression * 0.62, 0.018, 0.30)
        let mouthWidth = clamp(adjusted(0.30 + random.unit() * 0.12 * variation,
                                         mouthObserved.map { $0.width * 0.5 }), 0.20, 0.54)
        let mouthY = clamp(adjusted(0.94, center(points(.mouth)).map { local($0).y }), 0.75, 1.15)
        let noseY = clamp(adjusted(0.52, noseObserved?.y), 0.38, 0.72)
        let noseX = yaw * 0.16

        func quad(_ a: CGPoint, _ control: CGPoint, _ b: CGPoint, steps: Int = 10) -> [CGPoint] {
            (0...steps).map { index in
                let t = CGFloat(index) / CGFloat(steps), u = 1 - t
                return CGPoint(x: u*u*a.x + 2*u*t*control.x + t*t*b.x,
                               y: u*u*a.y + 2*u*t*control.y + t*t*b.y)
            }
        }
        func ellipse(_ center: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> [CGPoint] {
            (0...16).map { index in
                let t = CGFloat(index) / 16 * .pi * 2
                return CGPoint(x: center.x + cos(t) * rx, y: center.y + sin(t) * ry)
            }
        }
        func eye(_ x: CGFloat, _ openness: CGFloat) -> [CGPoint] {
            let half = 0.27 * (x < 0 ? 1 + yaw * 0.24 : 1 - yaw * 0.24)
            let a = CGPoint(x: x - half, y: 0), b = CGPoint(x: x + half, y: 0)
            return quad(a, CGPoint(x: x, y: -openness), b)
                + quad(b, CGPoint(x: x, y: openness * 0.88), a).dropFirst()
        }
        let leftX: CGFloat = -0.42, rightX: CGFloat = 0.42
        let forehead = -0.96 - random.unit() * 0.16 * variation
        let face = [
            CGPoint(x: -leftWidth * 0.76, y: -0.36),
            CGPoint(x: -leftWidth * 0.74, y: -0.73),
            CGPoint(x: -leftWidth * 0.38, y: forehead),
            CGPoint(x: yaw * 0.09, y: forehead - 0.09),
            CGPoint(x: rightWidth * 0.45, y: forehead),
            CGPoint(x: rightWidth * 0.83, y: -0.56),
            CGPoint(x: rightWidth, y: 0.08),
            CGPoint(x: rightWidth * 0.84, y: 0.77),
            CGPoint(x: rightWidth * 0.54, y: chin * 0.89),
            CGPoint(x: yaw * 0.10, y: chin),
            CGPoint(x: -leftWidth * 0.60, y: chin * 0.87),
            CGPoint(x: -leftWidth * 0.94, y: 0.65),
            CGPoint(x: -leftWidth, y: 0.04),
            CGPoint(x: -leftWidth * 0.76, y: -0.36)
        ]
        func ear(_ side: CGFloat, _ halfWidth: CGFloat) -> [CGPoint] {
            let x = side * halfWidth * 0.98
            return [CGPoint(x: x, y: 0.08), CGPoint(x: x + side * 0.10, y: -0.01),
                    CGPoint(x: x + side * 0.15, y: 0.25),
                    CGPoint(x: x + side * 0.08, y: 0.41),
                    CGPoint(x: x + side * 0.05, y: 0.33), CGPoint(x: x, y: 0.08)]
        }
        let browL = quad(CGPoint(x: -0.70, y: -0.30 + browLift),
                         CGPoint(x: -0.43, y: -0.46 + browLift),
                         CGPoint(x: -0.16, y: -0.32 + browLift))
        let browR = quad(CGPoint(x: 0.17, y: -0.32 - browLift),
                         CGPoint(x: 0.45, y: -0.47 - browLift),
                         CGPoint(x: 0.72, y: -0.28 - browLift))
        let nose = quad(CGPoint(x: noseX + 0.02, y: 0.10),
                        CGPoint(x: noseX - 0.09, y: noseY * 0.84),
                        CGPoint(x: noseX - 0.13, y: noseY))
            + quad(CGPoint(x: noseX - 0.13, y: noseY),
                   CGPoint(x: noseX + 0.06, y: noseY + 0.12),
                   CGPoint(x: noseX + 0.18, y: noseY + 0.01)).dropFirst()
        let mouthLeft = CGPoint(x: -mouthWidth + yaw * 0.08, y: mouthY)
        let mouthRight = CGPoint(x: mouthWidth + yaw * 0.08, y: mouthY)
        let mouth = quad(mouthLeft, CGPoint(x: yaw * 0.08, y: mouthY - mouthOpen), mouthRight)
            + quad(mouthRight, CGPoint(x: yaw * 0.08, y: mouthY + mouthOpen), mouthLeft).dropFirst()
        let innerMouth = quad(CGPoint(x: mouthLeft.x * 0.78, y: mouthY),
                              CGPoint(x: yaw * 0.08, y: mouthY - mouthOpen * 0.35),
                              CGPoint(x: mouthRight.x * 0.78, y: mouthY))
            + quad(CGPoint(x: mouthRight.x * 0.78, y: mouthY),
                   CGPoint(x: yaw * 0.08, y: mouthY + mouthOpen * 0.35),
                   CGPoint(x: mouthLeft.x * 0.78, y: mouthY)).dropFirst()
        let mouthPath = settings.resolvedPortraitMouthCenterlineEnabled
            ? (PortraitPathBuilder.mouthFeatures([
                .init(region: .mouth, points: mouth, closed: true, handedness: .unknown),
                .init(region: .mouth, points: innerMouth, closed: true, handedness: .unknown)
            ], connection: .sharedCorner, innerEnabled: true, centerline: true,
               leftEye: [], rightEye: []).first?.points ?? mouth)
            : mouth

        // The figure below the head is also authored. Pose shoulders and
        // tracked wrists pull its control points, but no torso/arm polyline is
        // copied into the drawing.
        let shoulderL = CGPoint(x: adjusted(-1.12, shoulder(.leftArm, label: "Lsho").map { local($0).x }),
                                y: chin + 0.63)
        let shoulderR = CGPoint(x: adjusted(1.12, shoulder(.rightArm, label: "Rsho").map { local($0).x }),
                                y: chin + 0.63)
        let authoredBody = [CGPoint(x: -leftWidth * 0.42, y: chin * 0.86),
                    CGPoint(x: -0.37, y: chin + 0.37), shoulderL,
                    CGPoint(x: shoulderL.x - 0.29, y: chin + 1.00),
                    CGPoint(x: -1.35, y: chin + 2.03),
                    CGPoint(x: 1.30, y: chin + 2.03),
                    CGPoint(x: shoulderR.x + 0.29, y: chin + 1.00), shoulderR,
                    CGPoint(x: 0.37, y: chin + 0.37),
                    CGPoint(x: rightWidth * 0.42, y: chin * 0.86)]
        let body = !settings.resolvedPortraitBodyEnabled ? [] : settings.resolvedPortraitPoseBodyEnabled
            ? (PortraitPathBuilder.poseBodyComponent(
                from: groups, scalp: nil, seed: settings.resolvedPortraitSeed &+ 113
              )?.points.map(local) ?? authoredBody)
            : authoredBody
        var curves = [body, face,
                      browL, browR, eye(leftX, eyeOpenL), eye(rightX, eyeOpenR),
                      ellipse(CGPoint(x: leftX + yaw * 0.04, y: 0), 0.055, 0.075),
                      ellipse(CGPoint(x: rightX + yaw * 0.04, y: 0), 0.055, 0.075),
                      nose, mouthPath]
        if settings.resolvedPortraitEarsEnabled {
            curves.append(contentsOf: [ear(-1, leftWidth), ear(1, rightWidth)])
        }
        if settings.resolvedPortraitHairEnabled {
            let overhang = CGFloat(settings.resolvedPortraitHairExpansion)
            let hair = quad(CGPoint(x: -leftWidth * (0.73 + overhang * 0.06), y: -0.55),
                            CGPoint(x: 0, y: forehead - 0.24 - overhang * 0.35),
                            CGPoint(x: rightWidth * (0.79 + overhang * 0.06), y: -0.50), steps: 16)
            curves.append(hair)
        }
        return curves.map { curve in
            DrawingSupport.curvePoints(curve.map(world), fit: .catmull, samplesPerSegment: 3)
        }
    }
}
