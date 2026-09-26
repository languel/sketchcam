import CoreGraphics
import SketchCamCore

/// A stable, authored pen itinerary whose recognizable features are fitted to
/// the live semantic contours. Connectors and missing anatomy stay expressive
/// and inferred; the eyes, brows, nose, jaw and lips deform from their trackers.
enum GesturePortrait {
    private static let contourSamples = 32

    static func paths(groups: [MappedGroup], settings: LandmarkSettings) -> [[CGPoint]] {
        func selectedPoints(_ region: LandmarkRegion, part: String? = nil) -> [CGPoint] {
            groups.filter { $0.region == region }.flatMap { group in
                group.points.indices.compactMap { index in
                    let label = group.labels.indices.contains(index) ? group.labels[index] : nil
                    let unlabeledFallback = group.labels.isEmpty && part != "pL" && part != "pR"
                    guard part == nil || matches(label, part!) || unlabeledFallback else { return nil }
                    return group.points[index]
                }
            }.filter { $0.x.isFinite && $0.y.isFinite }
        }
        func center(_ points: [CGPoint]) -> CGPoint? {
            guard !points.isEmpty else { return nil }
            return CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
                           y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count))
        }
        func components(_ region: LandmarkRegion, part: String) -> [PortraitPathBuilder.Component] {
            groups.filter { $0.region == region }.flatMap { group -> [PortraitPathBuilder.Component] in
                let indices = group.points.indices.filter { index in
                    let label = group.labels.indices.contains(index) ? group.labels[index] : nil
                    return matches(label, part)
                }
                guard !indices.isEmpty else {
                    // Older/synthetic fixtures can have no semantic labels.
                    guard group.labels.isEmpty else { return [] }
                    return PortraitPathBuilder.components(group)
                }
                let remap = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($1, $0) })
                let points = indices.map { group.points[$0] }
                let labels = indices.map { group.labels.indices.contains($0) ? group.labels[$0] : nil }
                let edges = group.edges.compactMap { a, b -> (Int, Int)? in
                    guard let a = remap[a], let b = remap[b] else { return nil }
                    return (a, b)
                }
                return PortraitPathBuilder.components(MappedGroup(region: region, points: points, edges: edges, labels: labels))
            }.sorted { $0.points.count > $1.points.count }
        }
        func feature(_ region: LandmarkRegion, _ part: String) -> [CGPoint]? {
            components(region, part: part).first(where: { $0.points.count >= 3 })?.points
        }
        // Semantic eye points give a head-aligned frame. Pupil samples are
        // excluded so gaze cannot pull the whole face frame off-center.
        guard let left = center(selectedPoints(.leftEye, part: "eL")) ?? center(selectedPoints(.leftBrow)),
              let right = center(selectedPoints(.rightEye, part: "eR")) ?? center(selectedPoints(.rightBrow)) else { return [] }
        let distance = hypot(right.x - left.x, right.y - left.y)
        guard distance > 0.001 else { return [] }
        let origin = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        let xAxis = CGPoint(x: (right.x - left.x) / distance, y: (right.y - left.y) / distance)
        var yAxis = CGPoint(x: -xAxis.y, y: xAxis.x)
        if let lower = center(selectedPoints(.mouth)) ?? center(selectedPoints(.nose)),
           (lower.x - origin.x) * yAxis.x + (lower.y - origin.y) * yAxis.y < 0 {
            yAxis = CGPoint(x: -yAxis.x, y: -yAxis.y)
        }
        let scale = distance / 0.84
        func local(_ p: CGPoint) -> CGPoint {
            let dx = p.x - origin.x, dy = p.y - origin.y
            return CGPoint(x: (dx * xAxis.x + dy * xAxis.y) / scale,
                           y: (dx * yAxis.x + dy * yAxis.y) / scale)
        }
        func localPoints(_ region: LandmarkRegion, _ part: String? = nil) -> [CGPoint] {
            selectedPoints(region, part: part).map(local)
        }
        func localFeature(_ region: LandmarkRegion, _ part: String) -> [CGPoint]? {
            feature(region, part).map { $0.map(local) }
        }
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, v)) }
        let abstraction = clamp(CGFloat(settings.resolvedPortraitAbstraction), 0, 1)
        let liveWeight = 1 - abstraction
        let expression = clamp(CGFloat(settings.resolvedPortraitExpression), 0, 2)
        func mix(_ authored: CGFloat, _ measured: CGFloat, _ amount: CGFloat = liveWeight) -> CGFloat {
            authored + (measured - authored) * amount
        }
        func attract(_ region: LandmarkRegion, _ fallback: CGPoint) -> CGPoint {
            guard let observed = center(localPoints(region)) else { return fallback }
            return CGPoint(x: mix(fallback.x, observed.x), y: mix(fallback.y, observed.y))
        }

        // Seed choices are constant across frames; no geometry-dependent random
        // decisions means expression and head motion never reshuffle topology.
        let seed = UInt64(bitPattern: Int64(settings.resolvedPortraitSeed))
        func random(_ salt: UInt64) -> CGFloat {
            var n = seed &+ salt &* 0x9e3779b97f4a7c15
            n = (n ^ (n >> 30)) &* 0xbf58476d1ce4e5b9
            n = (n ^ (n >> 27)) &* 0x94d049bb133111eb
            return CGFloat((n ^ (n >> 31)) & 0xffff) / 65535
        }
        let drift = CGFloat(settings.resolvedPortraitVariation) * 0.12
        let asymmetry = (random(1) - 0.5) * drift
        let shapeVariation = clamp(CGFloat(settings.resolvedPortraitShapeVariation), 0, 1)
        let jawPoints = localPoints(.jaw, "c")
        let jaw = localFeature(.jaw, "c")
        let chinBase = clamp((jawPoints.map(\.y).max() ?? 1.6) * liveWeight + 1.6 * abstraction, 1.1, 2)
        let chin = mix(chinBase, 1.2 + random(12) * 0.75, shapeVariation * 0.65)
        let measuredHalfWidth = clamp((jawPoints.map { abs($0.x) }.max() ?? 1) * liveWeight + abstraction, 0.8, 1.3)
        let headWidth = 0.78 + random(10) * 0.46
        let leftHalfWidth = clamp(measuredHalfWidth * mix(1, headWidth, shapeVariation), 0.65, 1.55)
        let rightHalfWidth = clamp(measuredHalfWidth * mix(1, 1.78 - headWidth, shapeVariation), 0.65, 1.55)
        let noseCenter = attract(.nose, CGPoint(x: -0.18 + random(13) * 0.36 + asymmetry,
                                                y: 0.55 + random(14) * 0.25))
        let mouthCenter = attract(.mouth, CGPoint(x: -0.14 + random(15) * 0.28, y: 0.95 + random(16) * 0.22))

        func fit(_ contour: [CGPoint]?, center target: CGPoint, rx authoredRX: CGFloat,
                 ry authoredRY: CGFloat, closed: Bool, expressionSensitive: Bool = false) -> [CGPoint] {
            guard let contour, contour.count >= 3 else {
                return authoredContour(center: target, rx: authoredRX, ry: authoredRY, closed: closed)
            }
            let source = resample(contour, count: contourSamples, closed: closed)
            guard !source.isEmpty else { return authoredContour(center: target, rx: authoredRX, ry: authoredRY, closed: closed) }
            let box = source.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            let observed = CGPoint(x: box.midX, y: box.midY)
            let measuredRX = max(0.008, box.width * 0.5)
            let measuredRY = max(0.008, box.height * 0.5)
            let responsiveRY = expressionSensitive
                ? clamp(authoredRY + (measuredRY - authoredRY) * expression, 0.008, authoredRY * 2.5)
                : measuredRY
            let rx = mix(authoredRX, measuredRX)
            let ry = mix(authoredRY, responsiveRY)
            let fittedCenter = CGPoint(x: mix(target.x, observed.x), y: mix(target.y, observed.y))
            return source.map { p in
                CGPoint(x: fittedCenter.x + (p.x - observed.x) / measuredRX * rx,
                        y: fittedCenter.y + (p.y - observed.y) / measuredRY * ry)
            }
        }

        let eyeWidthL = CGFloat(mix(0.25 + random(3) * 0.20, 0.32, shapeVariation * 0.5))
        let eyeWidthR = CGFloat(mix(0.25 + random(4) * 0.20, 0.32, shapeVariation * 0.5))
        let eyeL = fit(localFeature(.leftEye, "eL"), center: CGPoint(x: -0.42, y: 0),
                       rx: eyeWidthL, ry: 0.14, closed: true, expressionSensitive: true)
        let eyeR = fit(localFeature(.rightEye, "eR"), center: CGPoint(x: 0.42, y: 0),
                       rx: eyeWidthR, ry: 0.14, closed: true, expressionSensitive: true)
        let browL = fit(localFeature(.leftBrow, "bL"), center: CGPoint(x: -0.47, y: -0.43),
                        rx: 0.2 + random(17) * 0.22 * shapeVariation, ry: 0.04 + random(18) * 0.10 * shapeVariation, closed: false)
        let browR = fit(localFeature(.rightBrow, "bR"), center: CGPoint(x: 0.47, y: -0.43),
                        rx: 0.2 + random(19) * 0.22 * shapeVariation, ry: 0.04 + random(20) * 0.10 * shapeVariation, closed: false)
        let outerMouth = fit(localFeature(.mouth, "oL"), center: mouthCenter,
                             rx: 0.20 + random(21) * 0.26 * shapeVariation,
                             ry: 0.075 + random(22) * 0.12 * shapeVariation, closed: true, expressionSensitive: true)
        // Always keep an inner-lip gesture. Vision's inner contour expands and
        // changes shape with speech; the small authored loop is a fallback when
        // that contour is not currently returned.
        let innerMouth = fit(localFeature(.mouth, "iL"), center: mouthCenter,
                             rx: 0.12 + random(23) * 0.16 * shapeVariation,
                             ry: 0.018 + random(24) * 0.09 * shapeVariation, closed: true, expressionSensitive: true)
        let nosePath = fit(localFeature(.nose, "n"), center: noseCenter,
                           rx: 0.09 + random(25) * 0.18 * shapeVariation,
                           ry: 0.20 + random(26) * 0.30 * shapeVariation, closed: false)

        let crown = -mix(1.08 + random(2) * 0.32, 0.82 + random(27) * 0.88, shapeVariation)
        let templeL = CGPoint(x: -leftHalfWidth * (0.76 + random(28) * 0.38), y: -0.52 - random(29) * 0.24)
        let templeR = CGPoint(x: rightHalfWidth * (0.76 + random(30) * 0.38), y: 0.46 + random(31) * 0.34)
        func firstLandmark(_ region: LandmarkRegion) -> CGPoint? {
            groups.first(where: { $0.region == region })?.points.first.map(local)
        }
        let defaultShoulderL = CGPoint(x: -0.95 - random(32) * 0.4, y: chin + 1.0)
        let defaultShoulderR = CGPoint(x: 0.95 + random(33) * 0.4, y: chin + 0.9)
        let shoulderL = firstLandmark(.leftArm).map { CGPoint(x: mix(defaultShoulderL.x, $0.x), y: mix(defaultShoulderL.y, $0.y)) } ?? defaultShoulderL
        let shoulderR = firstLandmark(.rightArm).map { CGPoint(x: mix(defaultShoulderR.x, $0.x), y: mix(defaultShoulderR.y, $0.y)) } ?? defaultShoulderR
        let torso = attract(.torso, CGPoint(x: 0, y: chin + 1))
        let bustY = max(chin + 0.5, (shoulderL.y + shoulderR.y + torso.y) / 3)
        let measuredBustWidth = max(abs(shoulderL.x), abs(shoulderR.x))
        let bustWidth = mix(1.25 + random(5) * 0.6, clamp(measuredBustWidth, 1.0, 2.6), liveWeight)
        let leftBrowAnchor = browL.first ?? CGPoint(x: -0.42 - eyeWidthL, y: -0.28)
        let leftEyeAnchor = eyeL.first ?? CGPoint(x: -0.42 - eyeWidthL, y: 0)
        var pen = Pen(start: leftBrowAnchor)

        pen.followOpen(browL)
        pen.connect(leftEyeAnchor)
        pen.followLoop(eyeL)
        pen.visitIris(center: localPoints(.leftEye, "pL").first,
                      fallback: CGPoint(x: -0.42, y: 0), radius: min(eyeWidthL, 0.14) * 0.32)
        pen.curve(CGPoint(x: -0.98, y: 0.25), CGPoint(x: -leftHalfWidth, y: -0.25), templeL)
        pen.curve(CGPoint(x: -leftHalfWidth * 0.76, y: crown), CGPoint(x: 0.3 + random(34) * shapeVariation,
                  y: crown - 0.22 - random(35) * 0.45 * shapeVariation),
                  CGPoint(x: rightHalfWidth * 0.82, y: -0.67 - random(36) * 0.22 * shapeVariation))
        pen.curve(CGPoint(x: rightHalfWidth * 1.1, y: 0.17), CGPoint(x: rightHalfWidth * 0.8, y: 0.15), templeR)
        pen.curve(CGPoint(x: 0.83, y: 1.08), CGPoint(x: 0.43, y: 1.16), CGPoint(x: 0.45, y: chin + 0.37))
        pen.curve(CGPoint(x: 0.43, y: bustY + 0.15), CGPoint(x: shoulderR.x - 0.2, y: shoulderR.y - 0.34), shoulderR)
        pen.curve(CGPoint(x: shoulderR.x + 0.52, y: shoulderR.y + 0.14),
                  CGPoint(x: bustWidth + 0.25, y: bustY + 0.9), CGPoint(x: bustWidth + random(37) * 0.32, y: bustY + 1.02))
        pen.curve(CGPoint(x: bustWidth + 0.35, y: bustY + 1.22),
                  CGPoint(x: -bustWidth - 0.35, y: bustY + 1.05), CGPoint(x: shoulderL.x - 0.25, y: shoulderL.y + 0.15))
        pen.curve(CGPoint(x: shoulderL.x + 0.18, y: shoulderL.y - 0.30),
                  CGPoint(x: -0.54, y: bustY - 0.42), CGPoint(x: -0.52, y: chin + 0.03))
        pen.breaks.append(pen.points.count - 1)

        // Prefer the measured cheek/chin arc when Vision provides the open
        // face contour. Blend it against a clean authored jaw so turns are
        // legible while poor contours cannot collapse the whole portrait.
        let jawTemplate = canonicalJaw(leftHalfWidth: leftHalfWidth, rightHalfWidth: rightHalfWidth,
                                       chin: chin, cheek: 0.62 + random(38) * 0.62 * shapeVariation, count: 49)
        if let jaw, jaw.count >= 4, jaw.first != jaw.last {
            let oriented = jaw.first!.x <= jaw.last!.x ? jaw : Array(jaw.reversed())
            let measured = resample(oriented, count: jawTemplate.count, closed: false)
            pen.followOpen(zip(jawTemplate, measured).map { ideal, observed in
                CGPoint(x: mix(ideal.x, observed.x), y: mix(ideal.y, observed.y))
            })
        } else {
            pen.followOpen(jawTemplate)
        }

        // Closed outer and inner lip contours remain explicit parts of the
        // same route. Their actual geometry is tracked independently, so a
        // changing mouth is visible without changing the connection order.
        pen.connect(outerMouth.first ?? mouthCenter)
        pen.followLoop(outerMouth)
        pen.visitLoop(innerMouth, returnTo: outerMouth.first ?? mouthCenter)
        pen.breaks.append(pen.points.count - 1)
        pen.connect(nosePath.first ?? noseCenter)
        pen.followOpen(nosePath)
        let rightEyeAnchor = eyeR.first ?? CGPoint(x: 0.42 - eyeWidthR, y: 0)
        pen.connect(rightEyeAnchor)
        pen.followLoop(eyeR)
        pen.visitIris(center: localPoints(.rightEye, "pR").first,
                      fallback: CGPoint(x: 0.42, y: 0), radius: min(eyeWidthR, 0.14) * 0.32)
        pen.connect(browR.first ?? CGPoint(x: 0.42 + eyeWidthR, y: -0.28))
        pen.followOpen(browR)
        let flourish = clamp(CGFloat(settings.resolvedPortraitFlourish), 0, 1)
        pen.curve(CGPoint(x: 1.1, y: -0.2 - flourish), CGPoint(x: 0.22, y: -1 - flourish * 0.3), CGPoint(x: 0.34, y: -0.48))

        let desired = min(3, settings.resolvedPortraitSegments)
        let boundaries = [0] + Array(pen.breaks.prefix(desired - 1)) + [pen.points.count - 1]
        return zip(boundaries, boundaries.dropFirst()).map { a, b in
            Array(pen.points[a...b]).map { p in
                CGPoint(x: origin.x + scale * (p.x * xAxis.x + p.y * yAxis.x),
                        y: origin.y + scale * (p.x * xAxis.y + p.y * yAxis.y))
            }
        }
    }

    private static func matches(_ label: String?, _ part: String) -> Bool {
        guard let label else { return false }
        return label.hasPrefix(part) || label.contains(".\(part).") || label.contains(".\(part)")
    }

    private static func ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, count: Int) -> [CGPoint] {
        (0...count).map { i in
            let angle = CGFloat(i) / CGFloat(count) * .pi * 2
            return CGPoint(x: center.x + cos(angle) * rx, y: center.y + sin(angle) * ry)
        }
    }

    private static func authoredContour(center: CGPoint, rx: CGFloat, ry: CGFloat, closed: Bool) -> [CGPoint] {
        if closed { return ellipse(center: center, rx: rx, ry: ry, count: contourSamples) }
        return (0...contourSamples).map { i in
            let t = CGFloat(i) / CGFloat(contourSamples)
            return CGPoint(x: center.x - rx + 2 * rx * t,
                           y: center.y + sin(.pi * t) * ry)
        }
    }

    /// Catmull-Rom smoothing followed by constant-distance sampling. Returning
    /// a fixed count keeps the line's topology stable as observed contours flex.
    private static func resample(_ input: [CGPoint], count: Int, closed: Bool) -> [CGPoint] {
        var source = input.filter { $0.x.isFinite && $0.y.isFinite }
        if closed, source.count > 1, source.first == source.last { source.removeLast() }
        guard source.count >= 3 else { return source }
        let segmentCount = closed ? source.count : source.count - 1
        var dense: [CGPoint] = [source[0]]
        let steps = 5
        for i in 0..<segmentCount {
            let p0 = source[closed ? (i - 1 + source.count) % source.count : max(0, i - 1)]
            let p1 = source[i]
            let p2 = source[closed ? (i + 1) % source.count : min(source.count - 1, i + 1)]
            let p3 = source[closed ? (i + 2) % source.count : min(source.count - 1, i + 2)]
            for step in 1...steps {
                if !closed && i == segmentCount - 1 && step == steps { continue }
                let t = CGFloat(step) / CGFloat(steps), t2 = t * t, t3 = t2 * t
                dense.append(CGPoint(
                    x: 0.5 * ((2*p1.x) + (-p0.x+p2.x)*t + (2*p0.x-5*p1.x+4*p2.x-p3.x)*t2 + (-p0.x+3*p1.x-3*p2.x+p3.x)*t3),
                    y: 0.5 * ((2*p1.y) + (-p0.y+p2.y)*t + (2*p0.y-5*p1.y+4*p2.y-p3.y)*t2 + (-p0.y+3*p1.y-3*p2.y+p3.y)*t3)
                ))
            }
        }
        if closed, let first = dense.first { dense.append(first) }
        guard dense.count > 1, count > 1 else { return dense }
        var cumulative = [CGFloat](repeating: 0, count: dense.count)
        for i in 1..<dense.count { cumulative[i] = cumulative[i - 1] + hypot(dense[i].x - dense[i - 1].x, dense[i].y - dense[i - 1].y) }
        let total = cumulative.last ?? 0
        guard total > 0.00001 else { return Array(repeating: dense[0], count: count + (closed ? 1 : 0)) }
        let outputCount = count + (closed ? 1 : 0)
        return (0..<outputCount).map { index in
            let target = total * CGFloat(index) / CGFloat(count)
            var hi = cumulative.partitioningIndex { $0 >= target }
            hi = min(dense.count - 1, max(1, hi))
            let lo = hi - 1
            let fraction = (target - cumulative[lo]) / max(0.000001, cumulative[hi] - cumulative[lo])
            return CGPoint(x: dense[lo].x + (dense[hi].x - dense[lo].x) * fraction,
                           y: dense[lo].y + (dense[hi].y - dense[lo].y) * fraction)
        }
    }

    private static func canonicalJaw(leftHalfWidth: CGFloat, rightHalfWidth: CGFloat, chin: CGFloat,
                                     cheek: CGFloat, count: Int) -> [CGPoint] {
        let left: [CGPoint] = (0...count/2).map { i in
            let t = CGFloat(i) / CGFloat(count / 2), u = 1 - t
            return CGPoint(x: -leftHalfWidth * u * u * u + 3 * (-cheek) * u * u * t + 3 * (-cheek) * u * t * t,
                           y: 0.15 * u * u * u + 3 * 0.35 * u * u * t + 3 * (chin - 0.22) * u * t * t + chin * t * t * t)
        }
        let right: [CGPoint] = (1...count/2).map { i in
            let t = CGFloat(i) / CGFloat(count / 2), u = 1 - t
            return CGPoint(x: 3 * cheek * u * u * t + 3 * cheek * u * t * t + rightHalfWidth * t * t * t,
                           y: chin * u * u * u + 3 * (chin - 0.22) * u * u * t + 3 * 0.35 * u * t * t + 0.15 * t * t * t)
        }
        return left + right
    }

    private struct Pen {
        var points: [CGPoint]
        var breaks: [Int] = []
        init(start: CGPoint) { points = [start] }
        mutating func connect(_ end: CGPoint) {
            guard let start = points.last else { points.append(end); return }
            let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
            curve(CGPoint(x: start.x + delta.x * 0.32, y: start.y + delta.y * 0.32),
                  CGPoint(x: start.x + delta.x * 0.68, y: start.y + delta.y * 0.68), end)
        }
        mutating func followOpen(_ path: [CGPoint]) {
            guard let first = path.first else { return }
            if points.last != first { connect(first) }
            points.append(contentsOf: path.dropFirst())
        }
        mutating func followLoop(_ path: [CGPoint]) {
            guard let first = path.first else { return }
            if points.last != first { connect(first) }
            points.append(contentsOf: path.dropFirst())
            if points.last != first { points.append(first) }
        }
        mutating func visitLoop(_ path: [CGPoint], returnTo anchor: CGPoint) {
            followLoop(path)
            connect(anchor)
        }
        mutating func visitIris(center: CGPoint?, fallback: CGPoint, radius: CGFloat) {
            let center = center ?? fallback
            guard let anchor = points.last else { return }
            let loop = GesturePortrait.ellipse(center: center, rx: radius, ry: radius * 0.85, count: 12)
            followLoop(loop)
            connect(anchor)
        }
        mutating func curve(_ c1: CGPoint, _ c2: CGPoint, _ end: CGPoint) {
            let start = points.last!
            for i in 1...20 {
                let t = CGFloat(i) / 20, u = 1 - t
                points.append(CGPoint(x: u*u*u*start.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*end.x,
                                      y: u*u*u*start.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*end.y))
            }
        }
    }
}

private extension Array where Element == CGFloat {
    func partitioningIndex(where predicate: (CGFloat) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
