import AppKit
import CoreGraphics
import Foundation
import SketchCamCore

/// Portrait: a semantic line through facial and body features. Unlike
/// Yarn/LineWalk it never solves a frame-by-frame nearest-neighbour tour, so a
/// moving landmark deforms the seeded itinerary instead of rewiring every
/// frame. Route variation deliberately explores a different itinerary only
/// when the user changes the seed or its control.
struct PortraitDrawing: DrawingAlgorithm {
    private enum RouteKind {
        case face
        case body
        case outline
    }

    private struct RenderStroke {
        let points: [CGPoint]
        let widthScale: CGFloat
        let widthVariationScale: Float
        let alphaScale: CGFloat
        let seed: Int
    }

    private struct SemanticRoute {
        let points: [CGPoint]
        let kind: RouteKind
        let renderStrokes: [RenderStroke]
        let isUnified: Bool
    }

    func isEnabled(_ landmarks: LandmarkSettings) -> Bool {
        landmarks.resolvedPortraitEnabled
    }

    func render(groups: [MappedGroup], landmarks: LandmarkSettings, into context: CGContext) {
        for stroke in strokes(groups: groups, landmarks: landmarks) {
            DrawingSupport.renderStroke(stroke, bead: landmarks.beadStroke, into: context)
        }
    }

    func strokes(groups: [MappedGroup], landmarks: LandmarkSettings) -> [StrokeTessellator.Stroke] {
        semanticRouteModels(groups: groups, landmarks: landmarks).enumerated().flatMap { index, model in
            let isOutline = model.kind == .outline
            var color = landmarks.resolvedPortraitColor
            if isOutline {
                color.alpha *= max(0, min(1, landmarks.resolvedPortraitOutlineStrength))
            }
            if model.isUnified {
                return DrawingSupport.ribbonStrokes(
                    model.points,
                    color: color,
                    baseWidth: CGFloat(max(0.4, landmarks.resolvedPortraitWidth)),
                    widthVariation: landmarks.resolvedPortraitWidthVariation,
                    halo: landmarks.resolvedPortraitHalo,
                    seed: 401 + index * 17
                )
            }
            return model.renderStrokes.enumerated().flatMap { strokeIndex, stroke in
                var strokeColor = color
                strokeColor.alpha *= Float(max(0, min(1, stroke.alphaScale)))
                return DrawingSupport.ribbonStrokes(
                    stroke.points,
                    color: strokeColor,
                    baseWidth: CGFloat(max(0.4, landmarks.resolvedPortraitWidth))
                        * (isOutline ? 0.72 : 1) * stroke.widthScale,
                    widthVariation: landmarks.resolvedPortraitWidthVariation
                        * (isOutline ? 0.65 : 1) * stroke.widthVariationScale,
                    halo: landmarks.resolvedPortraitHalo,
                    seed: stroke.seed &+ 401 &+ index &* 17 &+ strokeIndex &* 7
                )
            }
        }
    }

    /// Exposed internally for geometry tests. The default mode retains a stable
    /// face (including optional crown) → body → optional outline route order;
    /// unified mode intentionally returns one connected itinerary. Any route
    /// may be absent when its markers are unavailable.
    func semanticRoutes(groups: [MappedGroup], landmarks: LandmarkSettings) -> [[CGPoint]] {
        semanticRouteModels(groups: groups, landmarks: landmarks).map(\.points)
    }

    private func semanticRouteModels(groups: [MappedGroup], landmarks: LandmarkSettings) -> [SemanticRoute] {
        // A segmentation contour can contain hundreds of points. It is only a
        // fallback silhouette when no articulated body route exists, so do not
        // build its connectivity graph just to discard it below. Prefer Hull
        // over Contour to match the established body-order fallback.
        let hasArticulatedBody = groups.contains {
            PortraitPathBuilder.isArticulatedBodyRegion($0.region) && $0.points.count >= 2
        }
        let hasHull = groups.contains { $0.region == .bodyHull && $0.points.count >= 2 }
        let routeGroups = groups.filter { group in
            switch group.region {
            case .bodyHull: return !hasArticulatedBody
            case .contour: return !hasArticulatedBody && !hasHull
            default: return true
            }
        }
        let components = routeGroups.flatMap(PortraitPathBuilder.components)
        let componentsByRegion = Dictionary(grouping: components, by: \.region)
        var routes: [SemanticRoute] = []

        let faceOrder: [LandmarkRegion] = [
            .leftBrow, .leftEye, .nose, .rightEye, .rightBrow, .jaw, .mouth
        ]
        var faceFeatures: [PortraitPathBuilder.Component] = []
        for region in faceOrder {
            let candidates = (componentsByRegion[region] ?? []).sorted { $0.points.count > $1.points.count }
            if region == .mouth {
                faceFeatures.append(contentsOf: candidates.prefix(2))
            } else if region == .leftEye || region == .rightEye {
                // Eye rings and isolated pupil marks are separate semantic
                // components. Keep both so the pupil cannot disappear when
                // the ring wins a single-component sort.
                faceFeatures.append(contentsOf: candidates)
            } else if let first = candidates.first {
                faceFeatures.append(first)
            }
        }
        if landmarks.resolvedPortraitHairEnabled,
           let hair = PortraitPathBuilder.hairComponent(
               from: groups,
               style: landmarks.resolvedPortraitHairStyle,
               amount: landmarks.resolvedPortraitHairAmount,
               seed: landmarks.resolvedPortraitSeed &+ 71
           ) {
            faceFeatures.append(hair)
        }
        let bodyFeatures = PortraitPathBuilder.orderedBodyFeatures(components)
        let outline = landmarks.resolvedPortraitOutlineEnabled
            ? PortraitPathBuilder.outlineComponent(from: groups)
            : nil
        // Unified mode keeps topology fixed while landmarks move. Variety is
        // supplied by the editable seed, nose/pupil selection, and explicit
        // subsampling; the legacy route-variation control remains for the
        // separate face route without introducing live reorder noise.
        let unifiedTopologyVariation: Float = 0

        if landmarks.resolvedPortraitUnifiedRoute {
            let unified = PortraitPathBuilder.unifiedItinerary(
                face: faceFeatures,
                body: bodyFeatures,
                outline: outline,
                variation: unifiedTopologyVariation,
                detailPriority: landmarks.resolvedPortraitDetailPriority,
                seed: landmarks.resolvedPortraitSeed &+ 11
            )
            if let unifiedRoute = route(
                features: unified,
                style: landmarks.resolvedPortraitStyle,
                follow: landmarks.resolvedPortraitFollow,
                flourish: landmarks.resolvedPortraitFlourish,
                variation: landmarks.resolvedPortraitVariation,
                routeVariation: unifiedTopologyVariation,
                connectorWidth: landmarks.resolvedPortraitConnectorWidth,
                subsample: landmarks.resolvedPortraitSubsample,
                silhouetteAlpha: CGFloat(landmarks.resolvedPortraitOutlineStrength),
                kind: .face,
                isUnified: true,
                seed: landmarks.resolvedPortraitSeed &+ 17
            ) {
                // Unified mode intentionally stays one connected route. The
                // existing Segments control remains available for the normal
                // face-only planner, where breaks are meaningful.
                routes.append(unifiedRoute)
            }
        } else {
            let faceItinerary = PortraitPathBuilder.faceItinerary(
                faceFeatures,
                variation: landmarks.resolvedPortraitRouteVariation,
                seed: landmarks.resolvedPortraitSeed &+ 11
            )
            routes.append(contentsOf: routeSegments(
                features: faceItinerary,
                count: landmarks.resolvedPortraitSegments,
                style: landmarks.resolvedPortraitStyle,
                follow: landmarks.resolvedPortraitFollow,
                flourish: landmarks.resolvedPortraitFlourish,
                variation: landmarks.resolvedPortraitVariation,
                routeVariation: landmarks.resolvedPortraitRouteVariation,
                connectorWidth: landmarks.resolvedPortraitConnectorWidth,
                subsample: landmarks.resolvedPortraitSubsample,
                kind: .face,
                seed: landmarks.resolvedPortraitSeed &+ 17
            ))

            if let body = route(
                features: bodyFeatures,
                style: landmarks.resolvedPortraitStyle,
                follow: landmarks.resolvedPortraitFollow,
                flourish: landmarks.resolvedPortraitFlourish,
                variation: landmarks.resolvedPortraitVariation,
                routeVariation: landmarks.resolvedPortraitRouteVariation * 0.35,
                connectorWidth: landmarks.resolvedPortraitConnectorWidth,
                subsample: landmarks.resolvedPortraitSubsample,
                kind: .body,
                seed: landmarks.resolvedPortraitSeed &+ 53
            ) {
                routes.append(body)
            }

            if let outline,
               let outlineRoute = route(
                   features: [outline],
                   style: landmarks.resolvedPortraitStyle,
                   follow: min(1, landmarks.resolvedPortraitFollow + 0.16),
                   flourish: landmarks.resolvedPortraitFlourish * 0.45,
                   variation: landmarks.resolvedPortraitVariation * 0.65,
                   routeVariation: landmarks.resolvedPortraitRouteVariation * 0.15,
                   connectorWidth: landmarks.resolvedPortraitConnectorWidth,
                   subsample: landmarks.resolvedPortraitSubsample,
                   silhouetteAlpha: 1,
                   kind: .outline,
                   seed: landmarks.resolvedPortraitSeed &+ 97
               ) {
                routes.append(outlineRoute)
            }
        }
        return routes
    }

    private func routeSegments(
        features: [PortraitPathBuilder.Component],
        count: Int,
        style: PortraitStyle,
        follow: Float,
        flourish: Float,
        variation: Float,
        routeVariation: Float,
        connectorWidth: Float,
        subsample: Float,
        kind: RouteKind,
        seed: Int
    ) -> [SemanticRoute] {
        PortraitPathBuilder.segmentFeatures(features, count: count, seed: seed).enumerated().compactMap { index, segment in
            route(
                features: segment,
                style: style,
                follow: follow,
                flourish: flourish,
                variation: variation,
                routeVariation: routeVariation,
                connectorWidth: connectorWidth,
                subsample: subsample,
                kind: kind,
                seed: seed &+ index &* 101
            )
        }
    }

    private func route(
        features: [PortraitPathBuilder.Component],
        style: PortraitStyle,
        follow: Float,
        flourish: Float,
        variation: Float,
        routeVariation: Float,
        connectorWidth: Float,
        subsample: Float = 1,
        silhouetteAlpha: CGFloat = 1,
        kind: RouteKind,
        isUnified: Bool = false,
        seed: Int
    ) -> SemanticRoute? {
        let usable = features.filter { $0.points.count >= 2 }
        guard !usable.isEmpty else { return nil }
        let bounds = usable.reduce(CGRect.null) { partial, feature in
            feature.points.reduce(partial) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        let scale = max(8, max(bounds.width, bounds.height))
        var result: [CGPoint] = []
        result.reserveCapacity(usable.reduce(0) { $0 + $1.points.count * 2 })
        var renderStrokes: [RenderStroke] = []
        renderStrokes.reserveCapacity(usable.count * 2)
        var previousFeature: PortraitPathBuilder.Component?

        for (index, feature) in usable.enumerated() {
            var sourcePoints = PortraitPathBuilder.sampledLandmarks(
                feature.points,
                closed: feature.closed,
                variation: routeVariation,
                subsample: subsample,
                minimumCount: feature.isPupil || feature.region == .nose ? 4 : 2,
                seed: seed &+ index &* 31
            )
            if feature.region == .nose {
                sourcePoints = PortraitPathBuilder.noseVariant(
                    sourcePoints,
                    closed: feature.closed,
                    seed: seed &+ index &* 43
                )
            }
            // Let each component hand off at its closest endpoint. This keeps
            // the unified face/body/silhouette route visually continuous even
            // when seeded sampling reverses an open landmark chain.
            if let from = result.last {
                sourcePoints = PortraitPathBuilder.connectedStart(
                    sourcePoints,
                    closed: feature.closed,
                    toward: from
                )
            }
            let points = PortraitPathBuilder.stylize(
                sourcePoints,
                closed: feature.closed,
                style: style,
                follow: follow,
                flourish: flourish,
                variation: variation,
                scale: scale,
                seed: seed &+ index &* 31
            )
            guard !points.isEmpty else { continue }
            if let from = result.last, let to = points.first {
                let bridge = PortraitPathBuilder.bridge(
                    from: from,
                    to: to,
                    style: style,
                    flourish: flourish,
                    scale: scale,
                    index: index,
                    seed: seed
                )
                let bridgePath = [from] + bridge + [to]
                let sameSemanticPart = previousFeature?.region == feature.region
                renderStrokes.append(RenderStroke(
                    points: bridgePath,
                    widthScale: sameSemanticPart ? 1 : CGFloat(max(0.12, min(1, connectorWidth))),
                    widthVariationScale: sameSemanticPart ? 1 : 0.72,
                    alphaScale: 1,
                    seed: seed &+ index &* 37
                ))
                result.append(contentsOf: bridge)
            }
            result.append(contentsOf: points)
            renderStrokes.append(RenderStroke(
                points: points,
                widthScale: 1,
                widthVariationScale: 1,
                alphaScale: (feature.region == .contour || feature.region == .bodyHull)
                    ? 0.82 * silhouetteAlpha : 1,
                seed: seed &+ index &* 53
            ))
            previousFeature = feature
        }

        guard result.count >= 2 else { return nil }
        // Predictive tracking can rebuild the route at display cadence. Bound
        // pathological contour/multi-person inputs while leaving ordinary
        // face/body routes untouched. Uniform sampling preserves the semantic
        // itinerary, endpoints, and incoming motion.
        let bounded = PortraitPathBuilder.uniformlySample(result, maximumCount: 320)
        let fit: CurveFit = style == .cubist ? .polyline : .hobby
        let fittedStrokes = renderStrokes.map { stroke in
            let boundedStroke = PortraitPathBuilder.uniformlySample(stroke.points, maximumCount: 160)
            return RenderStroke(
                points: DrawingSupport.curvePoints(
                    boundedStroke,
                    fit: fit,
                    samplesPerSegment: style == .ornate ? 4 : 3
                ),
                widthScale: stroke.widthScale,
                widthVariationScale: stroke.widthVariationScale,
                alphaScale: stroke.alphaScale,
                seed: stroke.seed
            )
        }
        return SemanticRoute(
            points: DrawingSupport.curvePoints(bounded, fit: fit, samplesPerSegment: style == .ornate ? 4 : 3),
            kind: kind,
            renderStrokes: fittedStrokes,
            isUnified: isUnified
        )
    }
}

enum PortraitPathBuilder {
    enum Handedness: Equatable {
        case left
        case right
        case unknown
    }

    struct Component {
        var region: LandmarkRegion
        var points: [CGPoint]
        var closed: Bool
        var handedness: Handedness
        var isCrown: Bool = false
        var isPupil: Bool = false
    }

    static func isArticulatedBodyRegion(_ region: LandmarkRegion) -> Bool {
        switch region {
        case .torso, .leftArm, .rightArm, .leftLeg, .rightLeg, .hands: return true
        default: return false
        }
    }

    static func orderedBodyFeatures(_ components: [Component]) -> [Component] {
        let byRegion = Dictionary(grouping: components, by: \.region)
        func candidates(_ region: LandmarkRegion) -> [Component] {
            (byRegion[region] ?? []).sorted { $0.points.count > $1.points.count }
        }

        var result: [Component] = []
        result.append(contentsOf: candidates(.head))
        result.append(contentsOf: candidates(.leftArm))
        // Hand labels describe anatomy, not screen side. They must follow the
        // corresponding arm even when the camera/output is horizontally
        // mirrored (or when Vision returns right-hand observations first).
        let hands = candidates(.hands)
        result.append(contentsOf: hands.filter { $0.handedness == .left })
        result.append(contentsOf: candidates(.torso))
        result.append(contentsOf: candidates(.rightArm))
        result.append(contentsOf: hands.filter { $0.handedness == .right })
        result.append(contentsOf: candidates(.rightLeg))
        result.append(contentsOf: candidates(.leftLeg))
        result.append(contentsOf: hands.filter { $0.handedness == .unknown })

        // A silhouette is an alternative body outline, not another pass over
        // an already complete skeleton. Keep it only when no body route exists.
        if result.isEmpty {
            result.append(contentsOf: candidates(.bodyHull).prefix(1))
            if result.isEmpty { result.append(contentsOf: candidates(.contour).prefix(1)) }
        }
        return result
    }

    /// Prefer an explicit segmentation contour, then an explicit hull. When
    /// neither is available, make a lightweight hull from the detected face
    /// and body markers so Portrait can add a scalp/shoulder silhouette without
    /// changing the shared detection groups used by the other algorithms.
    static func outlineComponent(from groups: [MappedGroup]) -> Component? {
        let explicit = groups
            .filter { $0.region == .contour || $0.region == .bodyHull }
            .sorted {
                if $0.region != $1.region { return $0.region == .contour }
                return $0.points.count > $1.points.count
            }
        if let group = explicit.first, group.points.count >= 3 {
            var points = group.points
            if points.first != points.last, let first = points.first { points.append(first) }
            return Component(region: group.region, points: points, closed: true, handedness: .unknown)
        }

        let faceRegions: Set<LandmarkRegion> = [
            .head, .jaw, .nose, .mouth, .leftBrow, .rightBrow, .leftEye,
            .rightEye
        ]
        let outlineRegions: Set<LandmarkRegion> = faceRegions.union([
            .torso, .leftArm, .rightArm, .leftLeg, .rightLeg, .hands
        ])
        var outlinePoints = groups
            .filter { outlineRegions.contains($0.region) }
            .flatMap(\.points)

        // The default Marks preset does not track a separate head group. Add
        // a small canonical scalp cap above the available face landmarks so a
        // hull-based outline reads as a person instead of a jawless skeleton.
        let hasHead = groups.contains { $0.region == .head && $0.points.count >= 2 }
        if !hasHead {
            let facePoints = groups
                .filter { faceRegions.contains($0.region) }
                .flatMap(\.points)
            let faceBounds = facePoints.reduce(CGRect.null) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
            if !faceBounds.isNull, faceBounds.width > 1, faceBounds.height > 1 {
                let radiusX = max(18, faceBounds.width * 0.58)
                let radiusY = max(20, faceBounds.width * 0.52)
                let center = CGPoint(x: faceBounds.midX, y: faceBounds.minY + radiusY * 0.36)
                let cap = (0...12).map { index -> CGPoint in
                    let angle = .pi + .pi * CGFloat(index) / 12
                    return CGPoint(
                        x: center.x + cos(angle) * radiusX,
                        y: center.y + sin(angle) * radiusY
                    )
                }
                outlinePoints.append(contentsOf: cap)
            }
        }
        let hull = convexHull(outlinePoints)
        guard hull.count >= 3 else { return nil }
        return Component(
            region: .bodyHull,
            points: hull + [hull[0]],
            closed: true,
            handedness: .unknown
        )
    }

    /// Split compound landmark groups (outer/inner lips, eye/pupil, hands) into
    /// stable edge-connected paths and order every path deterministically.
    static func components(_ group: MappedGroup) -> [Component] {
        guard !group.points.isEmpty else { return [] }
        guard !group.edges.isEmpty else {
            return group.points.count >= 2
                ? [Component(region: group.region, points: group.points, closed: false, handedness: handedness(group))]
                : pupilComponent(from: group, index: group.points.indices.first)
                    .map { [$0] } ?? []
        }

        var adjacency = Array(repeating: [Int](), count: group.points.count)
        var validEdges: [(Int, Int)] = []
        for (a, b) in group.edges where group.points.indices.contains(a) && group.points.indices.contains(b) && a != b {
            adjacency[a].append(b)
            adjacency[b].append(a)
            validEdges.append((a, b))
        }
        adjacency.indices.forEach { adjacency[$0].sort() }

        var unseen = Set(validEdges.flatMap { [$0.0, $0.1] })
        var output: [Component] = []
        while let seed = unseen.min() {
            var stack = [seed]
            var indices = Set<Int>()
            while let current = stack.popLast() {
                guard indices.insert(current).inserted else { continue }
                unseen.remove(current)
                stack.append(contentsOf: adjacency[current])
            }
            guard indices.count >= 2 else { continue }
            let closed = indices.allSatisfy { adjacency[$0].filter(indices.contains).count == 2 }
            let start = indices.filter { adjacency[$0].filter(indices.contains).count == 1 }.min() ?? indices.min()!
            let order = edgeWalk(start: start, allowed: indices, adjacency: adjacency)
            guard order.count >= 2 else { continue }
            var points = order.map { group.points[$0] }
            if closed, let first = points.first, points.last != first { points.append(first) }
            output.append(Component(region: group.region, points: points, closed: closed, handedness: handedness(group)))
        }
        // Vision emits each pupil as an isolated point inside its eye group.
        // Promote it to a tiny stable ring so Portrait can retain and weight
        // it instead of dropping it during graph decomposition.
        for index in group.points.indices where adjacency[index].isEmpty {
            if let pupil = pupilComponent(from: group, index: index) {
                output.append(pupil)
            }
        }
        return output
    }

    private static func pupilComponent(from group: MappedGroup, index: Int?) -> Component? {
        guard let index, group.points.indices.contains(index),
              group.region == .leftEye || group.region == .rightEye else { return nil }
        let center = group.points[index]
        let nearest = group.points.enumerated()
            .filter { $0.offset != index }
            .map { hypot($0.element.x - center.x, $0.element.y - center.y) }
            .min() ?? 8
        let radius = max(1.4, min(7, nearest * 0.16))
        let points = (0..<8).map { step -> CGPoint in
            let angle = CGFloat(step) * .pi * 2 / 8
            return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        return Component(
            region: group.region,
            points: points + [points[0]],
            closed: true,
            handedness: .unknown,
            isPupil: true
        )
    }

    /// Choose a seeded, semantically plausible face itinerary. The templates
    /// keep the line in the face (brows/eyes/nose/jaw/mouth) while allowing a
    /// seed to decide where the long bridges land. At zero variation this is
    /// the original stable order.
    static func faceItinerary(
        _ features: [Component],
        variation: Float,
        seed: Int
    ) -> [Component] {
        let byRegion = Dictionary(grouping: features.filter { !$0.isCrown }, by: \.region)
        let crowns = features.filter(\.isCrown)
        let clamped = max(0, min(1, variation))
        let templates: [[LandmarkRegion]] = [
            [.leftBrow, .leftEye, .nose, .rightEye, .rightBrow, .jaw, .mouth],
            [.jaw, .leftBrow, .leftEye, .nose, .rightEye, .rightBrow, .mouth],
            [.leftEye, .leftBrow, .nose, .rightBrow, .rightEye, .mouth, .jaw],
            [.nose, .leftBrow, .leftEye, .jaw, .mouth, .rightEye, .rightBrow],
            [.rightBrow, .rightEye, .nose, .leftEye, .leftBrow, .jaw, .mouth],
            [.mouth, .jaw, .leftBrow, .nose, .rightBrow, .rightEye, .leftEye]
        ]
        guard clamped > 0.001 else {
            return canonicalFaceOrder(features)
        }

        var random = PortraitPRNG(seed: seed)
        let templateIndex = min(templates.count - 1, Int(random.unit() * CGFloat(templates.count)))
        let optional: Set<LandmarkRegion> = [.leftBrow, .rightBrow, .leftEye, .rightEye]
        var omitted = Set<LandmarkRegion>()
        // Keep the semantic anchors. Optional features may disappear only at
        // higher route variation, and a seed still decides which ones survive.
        let omitProbability = CGFloat(clamped * clamped * 0.28)
        for region in optional where random.unit() < omitProbability {
            omitted.insert(region)
        }
        if omitted.isSuperset(of: [.leftEye, .rightEye]) {
            omitted.remove(random.unit() < 0.5 ? .leftEye : .rightEye)
        }
        if omitted.isSuperset(of: [.leftBrow, .rightBrow]) {
            omitted.remove(random.unit() < 0.5 ? .leftBrow : .rightBrow)
        }

        var result: [Component] = []
        for region in templates[templateIndex] where !omitted.contains(region) {
            result.append(contentsOf: byRegion[region] ?? [])
        }
        if result.isEmpty {
            return canonicalFaceOrder(features)
        }
        guard !crowns.isEmpty else { return result }

        // Keep the extrapolated crown in the face's unicursal itinerary. A
        // seeded placement near the brows/jaw gives the line a deliberate
        // entry/exit while still allowing different portraits to shuffle it.
        let insertionChoices = result.indices.filter { index in
            let region = result[index].region
            return region == .leftBrow || region == .leftEye || region == .rightBrow || region == .rightEye
        }
        if !insertionChoices.isEmpty {
            let offset = Int(random.unit() * CGFloat(insertionChoices.count))
            let insertion = insertionChoices[min(insertionChoices.count - 1, offset)]
            result.insert(contentsOf: crowns, at: insertion)
        } else {
            result.append(contentsOf: crowns)
        }
        return result
    }

    /// Build one seeded itinerary across face, articulated body, and optional
    /// silhouette components. Candidate cost balances geometric travel,
    /// semantic affinity, and a detail bias so eyes, nose, and mouth can be
    /// kept in the expressive/high-value part of the line without forcing the
    /// body to become a separate disconnected route.
    static func unifiedItinerary(
        face: [Component],
        body: [Component],
        outline: Component?,
        variation: Float,
        detailPriority: Float,
        seed: Int
    ) -> [Component] {
        let faceItinerary = faceItinerary(face, variation: variation, seed: seed)
        var pool = faceItinerary + body
        if let outline,
           !body.contains(where: { $0.region == outline.region && $0.points == outline.points }) {
            pool.append(outline)
        }
        pool = pool.filter { $0.points.count >= 2 }
        guard pool.count > 1 else { return pool }

        let priority = CGFloat(max(0, min(1, detailPriority)))
        let clampedVariation = CGFloat(max(0, min(1, variation)))
        let travelWeight = 0.08 + clampedVariation * 0.5
        let allPoints = pool.flatMap(\.points)
        let bounds = allPoints.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let scale = max(8, max(bounds.width, bounds.height))
        var random = PortraitPRNG(seed: seed &+ 0x6B)
        let initialJitter = (0..<max(1, faceItinerary.count)).map { _ in random.unit() }

        func detailScore(_ component: Component) -> CGFloat {
            if component.isPupil { return 1.35 }
            switch component.region {
            case .leftEye, .rightEye, .nose, .mouth: return 1
            case .leftBrow, .rightBrow, .jaw: return 0.62
            case .head: return 0.28
            default: return 0.08
            }
        }

        func endpointDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
            hypot(lhs.x - rhs.x, lhs.y - rhs.y) / scale
        }

        // Start from a face detail anchor when requested. At zero priority we
        // retain the first semantic face component, preserving the old look.
        let faceCount = min(faceItinerary.count, pool.count)
        let initialIndex: Int
        if faceCount > 0 {
            initialIndex = (0..<faceCount).min { lhs, rhs in
                    let lhsScore = CGFloat(lhs) * 0.055
                    - priority * detailScore(pool[lhs]) * 0.72
                    + initialJitter[lhs] * clampedVariation * 0.035
                    let rhsScore = CGFloat(rhs) * 0.055
                    - priority * detailScore(pool[rhs]) * 0.72
                    + initialJitter[rhs] * clampedVariation * 0.035
                return lhsScore < rhsScore
            } ?? 0
        } else {
            initialIndex = 0
        }

        var route = [pool.remove(at: initialIndex)]
        var candidateJitter = pool.map { _ in random.unit() }
        while !pool.isEmpty {
            guard let current = route.last,
                  let currentEnd = current.points.last ?? current.points.first else { break }
            let nextIndex = pool.indices.min { lhs, rhs in
                func score(_ candidate: Component, jitter: CGFloat) -> CGFloat {
                    guard let first = candidate.points.first,
                          let last = candidate.points.last else { return .greatestFiniteMagnitude }
                    let travel = min(endpointDistance(currentEnd, first), endpointDistance(currentEnd, last))
                    let affinity = semanticAffinity(current, candidate)
                    let detail = detailScore(candidate)
                    let silhouettePenalty: CGFloat = (candidate.region == .contour || candidate.region == .bodyHull) ? 0.08 : 0
                    let seededJitter = jitter * clampedVariation * 0.08
                    return travel * travelWeight
                        + (1 - affinity) * 0.28
                        + silhouettePenalty
                        - priority * detail * 0.22
                        + seededJitter
                }
                return score(pool[lhs], jitter: candidateJitter[lhs])
                    < score(pool[rhs], jitter: candidateJitter[rhs])
            } ?? 0
            route.append(pool.remove(at: nextIndex))
            candidateJitter.remove(at: nextIndex)
        }
        return route
    }

    private static func canonicalFaceOrder(_ features: [Component]) -> [Component] {
        let order: [LandmarkRegion] = [
            .leftBrow, .leftEye, .nose, .rightEye, .rightBrow, .jaw, .mouth
        ]
        let byRegion = Dictionary(grouping: features, by: \.region)
        var result = order.flatMap { byRegion[$0] ?? [] }
        let crowns = features.filter(\.isCrown)
        if let firstBrow = result.firstIndex(where: { $0.region == .leftBrow || $0.region == .rightBrow }) {
            result.insert(contentsOf: crowns, at: firstBrow)
        } else {
            result.append(contentsOf: crowns)
        }
        return result
    }

    /// Partition a semantic itinerary at seeded boundaries. Boundaries inside
    /// one semantic region are never selected, so compound features (most
    /// notably inner/outer lips) remain a single segment. Among legal cuts,
    /// larger semantic distance is preferred while a small seeded jitter keeps
    /// repeated looks from converging on one fixed partition.
    static func segmentFeatures(
        _ features: [Component],
        count requestedCount: Int,
        seed: Int
    ) -> [[Component]] {
        let usable = features.filter { $0.points.count >= 2 }
        let target = max(1, min(6, requestedCount))
        guard target > 1, usable.count > 1 else { return usable.isEmpty ? [] : [usable] }

        var random = PortraitPRNG(seed: seed &+ 0x2D)
        let candidates = (1..<usable.count).filter { index in
            usable[index - 1].region != usable[index].region
                || usable[index - 1].isCrown != usable[index].isCrown
        }
        guard !candidates.isEmpty else { return [usable] }

        let cutsNeeded = min(target - 1, candidates.count)
        let ranked = candidates.map { index -> (index: Int, score: CGFloat) in
            let affinity = semanticAffinity(usable[index - 1], usable[index])
            let jitter = random.unit() * 0.22
            return (index, (1 - affinity) + jitter)
        }.sorted { $0.score > $1.score }
        let cuts = Set(ranked.prefix(cutsNeeded).map(\.index))

        var segments: [[Component]] = []
        var current: [Component] = []
        for (index, component) in usable.enumerated() {
            current.append(component)
            if cuts.contains(index + 1) {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private static func semanticAffinity(_ lhs: Component, _ rhs: Component) -> CGFloat {
        if lhs.region == rhs.region { return 1 }
        let pair = Set([lhs.region, rhs.region])
        if pair == Set([.leftBrow, .leftEye]) || pair == Set([.rightBrow, .rightEye]) { return 0.94 }
        if pair.contains(.nose) && (pair.contains(.leftEye) || pair.contains(.rightEye) || pair.contains(.leftBrow) || pair.contains(.rightBrow)) { return 0.82 }
        if pair == Set([.mouth, .jaw]) { return 0.9 }
        if lhs.isCrown || rhs.isCrown { return 0.68 }
        return 0.38
    }

    /// Sample a stable subset of a component. Open chains retain their
    /// endpoints, while closed rings get a seeded cyclic start so a mouth/eye
    /// can hand off at a different landmark without changing its shape class.
    static func sampledLandmarks(
        _ points: [CGPoint],
        closed: Bool,
        variation: Float,
        subsample: Float = 1,
        minimumCount: Int = 2,
        seed: Int
    ) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        let clamped = CGFloat(max(0, min(1, variation)))
        let sourceRatio = CGFloat(max(0.05, min(1, subsample)))
        guard clamped > 0.001 || sourceRatio < 0.999 else {
            return uniformlySample(points, maximumCount: 160)
        }

        var random = PortraitPRNG(seed: seed)
        let unique = closed && points.first == points.last ? Array(points.dropLast()) : points
        guard unique.count >= (closed ? 3 : 2) else { return points }
        let ratio = sourceRatio * (0.98 - clamped * 0.5 + (random.unit() - 0.5) * clamped * 0.18)
        let proposed = Int((CGFloat(unique.count) * ratio).rounded())
        let minimum = closed ? max(3, minimumCount) : max(2, minimumCount)
        let target = min(unique.count, max(minimum, proposed))

        func chosenIndices(count: Int, target: Int, random: inout PortraitPRNG) -> [Int] {
            guard target < count else { return Array(0..<count) }
            return (0..<count)
                .map { (score: random.unit(), index: $0) }
                .sorted { $0.score < $1.score }
                .prefix(target)
                .map(\.index)
                .sorted()
        }

        if closed {
            let selected = chosenIndices(count: unique.count, target: target, random: &random)
            guard !selected.isEmpty else { return points }
            let offset = min(selected.count - 1, Int(random.unit() * CGFloat(selected.count)))
            let rotated = Array(selected[offset...]) + Array(selected[..<offset])
            let result = rotated.map { unique[$0] }
            return result + [result[0]]
        }

        let interior = chosenIndices(count: max(0, unique.count - 2), target: max(0, target - 2), random: &random)
            .map { $0 + 1 }
        var indices = [0] + interior + [unique.count - 1]
        if random.unit() < clamped * 0.72 {
            indices.reverse()
        }
        return indices.map { unique[$0] }
    }

    /// Seeded nose-specific selection. The nose has only a few source points,
    /// so a generic sampler often reduces it to a blunt vertical hook. Keep
    /// endpoints attached but choose a different interior walk so the bridge,
    /// nostril, and tip can trade emphasis across seeds.
    static func noseVariant(_ points: [CGPoint], closed: Bool, seed: Int) -> [CGPoint] {
        guard !closed, points.count >= 4 else { return points }
        let variant = seed == Int.min ? 0 : abs(seed) % 3
        let interior = Array(points.dropFirst().dropLast())
        guard !interior.isEmpty else { return points }
        switch variant {
        case 0:
            return points
        case 1:
            let selected = interior.enumerated().filter { index, _ in
                (index + abs(seed)) % 2 == 0
            }.map(\.element)
            return [points[0]] + (selected.isEmpty ? [interior[interior.count / 2]] : selected) + [points[points.count - 1]]
        default:
            let middle = interior[interior.count / 2]
            let bridge = CGPoint(
                x: (points[0].x + middle.x + points[points.count - 1].x) / 3,
                y: (points[0].y + middle.y + points[points.count - 1].y) / 3
            )
            return [points[0], middle, bridge, points[points.count - 1]]
        }
    }

    /// Reorient one sampled component toward the preceding route endpoint.
    /// Closed paths rotate to their nearest point; open paths reverse when the
    /// opposite endpoint provides the shorter handoff.
    static func connectedStart(_ points: [CGPoint], closed: Bool, toward target: CGPoint) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        if closed {
            let unique = points.first == points.last ? Array(points.dropLast()) : points
            guard unique.count >= 3 else { return points }
            let index = unique.indices.min { lhs, rhs in
                let left = unique[lhs], right = unique[rhs]
                return hypot(left.x - target.x, left.y - target.y)
                    < hypot(right.x - target.x, right.y - target.y)
            } ?? 0
            let rotated = Array(unique[index...]) + Array(unique[..<index])
            return rotated + [rotated[0]]
        }
        guard let first = points.first, let last = points.last else { return points }
        let firstDistance = hypot(first.x - target.x, first.y - target.y)
        let lastDistance = hypot(last.x - target.x, last.y - target.y)
        return lastDistance < firstDistance ? Array(points.reversed()) : points
    }

    /// A face-only crown route. Its local coordinate frame comes from the
    /// brow/eye line and lower-face direction, so it follows head roll while
    /// remaining isolated from hands and body joints.
    static func hairComponent(
        from groups: [MappedGroup],
        style: PortraitHairStyle,
        amount: Float,
        seed: Int
    ) -> Component? {
        let faceRegions: Set<LandmarkRegion> = [
            .jaw, .nose, .mouth, .leftBrow, .rightBrow, .leftEye, .rightEye
        ]
        let faceGroups = groups.filter { faceRegions.contains($0.region) }
        let facePoints = faceGroups.flatMap(\.points)
        let bounds = facePoints.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard !bounds.isNull, bounds.width > 8, bounds.height > 8 else { return nil }

        func center(of regions: Set<LandmarkRegion>) -> CGPoint? {
            let points = faceGroups.filter { regions.contains($0.region) }.flatMap(\.points)
            guard !points.isEmpty else { return nil }
            let sum = points.reduce(CGPoint.zero) { partial, point in
                CGPoint(x: partial.x + point.x, y: partial.y + point.y)
            }
            return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
        }

        let leftAnchor = center(of: [.leftBrow, .leftEye])
        let rightAnchor = center(of: [.rightBrow, .rightEye])
        let browCenter = center(of: [.leftBrow, .rightBrow])
        let eyeCenter = center(of: [.leftEye, .rightEye])
        let upperCenter = browCenter ?? eyeCenter
        let lowerCenter = center(of: [.nose, .mouth, .jaw])

        let axisDelta: CGPoint
        if let leftAnchor, let rightAnchor {
            axisDelta = CGPoint(x: rightAnchor.x - leftAnchor.x, y: rightAnchor.y - leftAnchor.y)
        } else {
            axisDelta = CGPoint(x: 1, y: 0)
        }
        let axisLength = max(0.001, hypot(axisDelta.x, axisDelta.y))
        let across = CGPoint(x: axisDelta.x / axisLength, y: axisDelta.y / axisLength)
        let perpendicular = CGPoint(x: -across.y, y: across.x)
        let lowerDirection = lowerCenter.flatMap { lower -> CGPoint? in
            guard let upperCenter else { return nil }
            return CGPoint(x: lower.x - upperCenter.x, y: lower.y - upperCenter.y)
        }
        let down: CGPoint
        if let lowerDirection, lowerDirection.x * perpendicular.x + lowerDirection.y * perpendicular.y < 0 {
            down = CGPoint(x: -perpendicular.x, y: -perpendicular.y)
        } else {
            down = perpendicular
        }
        let up = CGPoint(x: -down.x, y: -down.y)
        let origin = upperCenter ?? CGPoint(x: bounds.midX, y: bounds.minY)
        let projected = facePoints.map { point in
            let offset = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            return (across: offset.x * across.x + offset.y * across.y,
                    down: offset.x * down.x + offset.y * down.y)
        }
        let faceWidth = (projected.map(\.across).max() ?? 0) - (projected.map(\.across).min() ?? 0)
        let faceHeight = (projected.map(\.down).max() ?? 0) - (projected.map(\.down).min() ?? 0)
        let faceScale = max(12, faceWidth, faceHeight)

        let clamped = CGFloat(max(0, min(1, amount)))
        let width = max(axisLength * 1.35, faceWidth * 0.86, faceScale * 0.62)
        // Keep the silhouette shallow. A tall sine arch above the brows reads
        // as a cone; a broad cap reads as hair even before it gains texture.
        let baselineLift = faceScale * 0.025
        let lift = max(8, faceScale * (style == .clean ? 0.09 : 0.11 + clamped * 0.10))
        var random = PortraitPRNG(seed: seed)
        let phase = random.unit() * .pi * 2
        func point(at t: CGFloat, height: CGFloat, weave: CGFloat = 0) -> CGPoint {
            let arch = sin(t * .pi)
            let side = (t - 0.5) * width
            let crownLift = baselineLift + arch * height
            var point = CGPoint(
                x: origin.x + across.x * side + up.x * crownLift,
                y: origin.y + across.y * side + up.y * crownLift
            )
            if weave > 0 {
                let wiggle = sin(t * (.pi * 3.5) + phase) * faceScale * weave * arch
                let sideways = cos(t * (.pi * 2.2) + phase * 0.7) * faceScale * weave * 0.28
                point.x += up.x * wiggle + across.x * sideways
                point.y += up.y * wiggle + across.y * sideways
            }
            return point
        }

        let points: [CGPoint]
        switch style {
        case .clean:
            points = (0..<9).map { index in
                point(at: CGFloat(index) / 8, height: lift)
            }
        case .wild:
            // A compact boustrophedon weave fills the scalp region rather than
            // tracing one tall outline. It stays one open component, so the
            // portrait planner can still position it in the unicursal shuffle.
            let rowCounts = [7, 6, 6]
            let rowHeights: [CGFloat] = [lift * 0.22, lift * 0.58, lift]
            var woven: [CGPoint] = []
            for row in rowCounts.indices {
                let count = rowCounts[row]
                let values = (0..<count).map { index -> CGFloat in
                    let t = CGFloat(index) / CGFloat(count - 1)
                    return row.isMultiple(of: 2) ? t : 1 - t
                }
                let weave = 0.012 + clamped * 0.036
                woven.append(contentsOf: values.map { t in
                    point(at: t, height: rowHeights[row], weave: weave)
                })
            }
            points = woven
        }
        return Component(region: .head, points: points, closed: false, handedness: .unknown, isCrown: true)
    }

    private static func handedness(_ group: MappedGroup) -> Handedness {
        guard group.region == .hands else { return .unknown }
        let labels = group.labels.compactMap { $0?.lowercased().first }
        if labels.contains("l") { return .left }
        if labels.contains("r") { return .right }
        return .unknown
    }

    private static func edgeWalk(start: Int, allowed: Set<Int>, adjacency: [[Int]]) -> [Int] {
        struct Edge: Hashable {
            let a: Int
            let b: Int
            init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) }
        }
        var used = Set<Edge>()
        var route = [start]

        func visit(_ node: Int) {
            for next in adjacency[node] where allowed.contains(next) {
                let edge = Edge(node, next)
                guard used.insert(edge).inserted else { continue }
                route.append(next)
                visit(next)
                if adjacency[next].filter(allowed.contains).count > 2 {
                    route.append(node)
                }
            }
        }
        visit(start)
        return route
    }

    static func stylize(
        _ input: [CGPoint],
        closed: Bool,
        style: PortraitStyle,
        follow: Float,
        flourish: Float,
        variation: Float = 0.22,
        scale: CGFloat,
        seed: Int
    ) -> [CGPoint] {
        guard input.count >= 2 else { return input }
        let clampedFollow = CGFloat(max(0, min(1, follow)))
        let clampedFlourish = CGFloat(max(0, min(1, flourish)))
        let clampedVariation = CGFloat(max(0, min(1, variation)))
        let raw = input
        let smoothed = smooth(raw, closed: closed, passes: style == .fluid ? 2 : 1)
        let artistic: [CGPoint]
        switch style {
        case .fluid:
            artistic = smoothed
        case .cubist:
            artistic = polygonalize(smoothed, closed: closed, anchors: closed ? 7 : 5)
        case .ornate:
            artistic = wave(smoothed, amplitude: scale * (0.015 + clampedFlourish * 0.045), seed: seed)
        }

        // Even at full follow retain a trace of the selected drawing hand;
        // Follow controls likeness, while Style remains independently visible.
        let artisticWeight = 1 - clampedFollow * 0.85
        let blended = zip(raw, artistic).map { source, target in
            CGPoint(
                x: source.x + (target.x - source.x) * artisticWeight,
                y: source.y + (target.y - source.y) * artisticWeight
            )
        }
        let organic = organicize(
            blended,
            closed: closed,
            amount: clampedVariation,
            scale: scale,
            seed: seed &+ 0x51
        )
        return embellish(
            organic,
            style: style,
            amount: clampedFlourish,
            scale: scale,
            seed: seed &+ 0xA7
        )
    }

    static func bridge(
        from: CGPoint,
        to: CGPoint,
        style: PortraitStyle,
        flourish: Float,
        scale: CGFloat,
        index: Int,
        seed: Int
    ) -> [CGPoint] {
        let f = CGFloat(max(0, min(1, flourish)))
        let midpoint = CGPoint(x: (from.x + to.x) * 0.5, y: (from.y + to.y) * 0.5)
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(1, hypot(dx, dy))
        let normal = CGPoint(x: -dy / length, y: dx / length)
        var random = PortraitPRNG(seed: seed &+ index &* 73)
        let sign: CGFloat = random.unit() < 0.5 ? -1 : 1
        switch style {
        case .fluid:
            let amplitude = min(length * 0.18, scale * (0.015 + f * 0.03)) * sign
            return [CGPoint(x: midpoint.x + normal.x * amplitude, y: midpoint.y + normal.y * amplitude)]
        case .cubist:
            return random.unit() < 0.5
                ? [CGPoint(x: to.x, y: from.y)]
                : [CGPoint(x: from.x, y: to.y)]
        case .ornate:
            let amplitude = min(length * 0.28, scale * (0.025 + f * 0.08)) * sign
            return [
                CGPoint(x: midpoint.x + normal.x * amplitude, y: midpoint.y + normal.y * amplitude),
                CGPoint(x: midpoint.x - normal.x * amplitude * 0.8, y: midpoint.y - normal.y * amplitude * 0.8),
                CGPoint(x: midpoint.x + normal.x * amplitude * 0.35, y: midpoint.y + normal.y * amplitude * 0.35)
            ]
        }
    }

    static func uniformlySample(_ points: [CGPoint], maximumCount: Int) -> [CGPoint] {
        guard maximumCount >= 2, points.count > maximumCount else { return points }
        let last = points.count - 1
        return (0..<maximumCount).map { index in
            points[Int((Double(index) * Double(last) / Double(maximumCount - 1)).rounded())]
        }
    }

    private static func smooth(_ points: [CGPoint], closed: Bool, passes: Int) -> [CGPoint] {
        var result = points
        guard result.count > 2 else { return result }
        for _ in 0..<passes {
            let source = result
            for index in source.indices {
                if !closed, index == source.startIndex || index == source.index(before: source.endIndex) { continue }
                let previous = source[(index - 1 + source.count) % source.count]
                let next = source[(index + 1) % source.count]
                result[index] = CGPoint(
                    x: previous.x * 0.22 + source[index].x * 0.56 + next.x * 0.22,
                    y: previous.y * 0.22 + source[index].y * 0.56 + next.y * 0.22
                )
            }
        }
        return result
    }

    private static func polygonalize(_ points: [CGPoint], closed: Bool, anchors target: Int) -> [CGPoint] {
        guard points.count > target else { return points }
        let last = closed && points.first == points.last ? points.count - 1 : points.count
        let anchorCount = max(2, min(target, last))
        let anchors = (0..<anchorCount).map { index -> Int in
            Int((Double(index) / Double(closed ? anchorCount : anchorCount - 1) * Double(closed ? last : last - 1)).rounded(.down)) % last
        }
        return points.indices.map { index in
            if closed && index == points.count - 1 { return points[0] }
            let position = Double(index) / Double(max(1, last - (closed ? 0 : 1))) * Double(closed ? anchorCount : anchorCount - 1)
            let lower = Int(floor(position)) % anchorCount
            let upper = closed ? (lower + 1) % anchorCount : min(anchorCount - 1, lower + 1)
            let t = CGFloat(position - floor(position))
            let a = points[anchors[lower]], b = points[anchors[upper]]
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    private static func wave(_ points: [CGPoint], amplitude: CGFloat, seed: Int) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let phase = CGFloat(abs(seed % 360)) * .pi / 180
        return points.indices.map { index in
            let previous = points[max(0, index - 1)]
            let next = points[min(points.count - 1, index + 1)]
            let dx = next.x - previous.x, dy = next.y - previous.y
            let length = max(1, hypot(dx, dy))
            let wave = sin(CGFloat(index) * 1.37 + phase) * amplitude
            return CGPoint(x: points[index].x - dy / length * wave, y: points[index].y + dx / length * wave)
        }
    }

    /// Small, seeded normal offsets keep the route organic without destroying
    /// its semantic landmarks. Open-path endpoints stay fixed so arm/hand and
    /// face/body bridges remain attached while the interior gets a gentle,
    /// repeatable hand-drawn drift.
    private static func organicize(
        _ points: [CGPoint],
        closed: Bool,
        amount: CGFloat,
        scale: CGFloat,
        seed: Int
    ) -> [CGPoint] {
        guard amount > 0.001, points.count > 2 else { return points }
        var random = PortraitPRNG(seed: seed)
        let noise = points.indices.map { _ in random.unit() * 2 - 1 }
        return points.indices.map { index in
            if !closed && (index == points.startIndex || index == points.index(before: points.endIndex)) {
                return points[index]
            }
            let previous = points[(index - 1 + points.count) % points.count]
            let next = points[(index + 1) % points.count]
            let dx = next.x - previous.x, dy = next.y - previous.y
            let length = max(1, hypot(dx, dy))
            let previousNoise = noise[max(0, index - 1)]
            let nextNoise = noise[min(noise.count - 1, index + 1)]
            let smoothNoise = noise[index] * 0.5 + (previousNoise + nextNoise) * 0.25
            let amplitude = scale * (0.002 + amount * 0.014)
            let styleLimit = min(length * 0.12, amplitude)
            let offset = smoothNoise * styleLimit
            return CGPoint(
                x: points[index].x - dy / length * offset,
                y: points[index].y + dx / length * offset
            )
        }
    }

    private static func embellish(
        _ points: [CGPoint],
        style: PortraitStyle,
        amount: CGFloat,
        scale: CGFloat,
        seed: Int
    ) -> [CGPoint] {
        guard amount > 0.001, points.count >= 2 else { return points }
        let stride = style == .ornate ? 2 : (style == .cubist ? 4 : 5)
        var result: [CGPoint] = []
        result.reserveCapacity(points.count * 2)
        var random = PortraitPRNG(seed: seed &+ 0x1D)
        let phase = seed == Int.min ? 0 : abs(seed)
        let density: CGFloat = style == .ornate
            ? min(0.92, 0.38 + amount * 0.55)
            : min(0.72, 0.16 + amount * 0.35)
        for index in 0..<(points.count - 1) {
            let a = points[index], b = points[index + 1]
            result.append(a)
            guard (index + phase) % stride == 0, random.unit() < density else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(1, hypot(dx, dy))
            let nx = -dy / length, ny = dx / length
            let amplitude = min(length * 0.45, scale * amount * (style == .ornate ? 0.06 : 0.035))
            let midpoint = CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
            if style == .cubist {
                result.append(CGPoint(x: midpoint.x + nx * amplitude, y: midpoint.y + ny * amplitude))
            } else {
                result.append(CGPoint(x: midpoint.x + nx * amplitude, y: midpoint.y + ny * amplitude))
                result.append(CGPoint(x: midpoint.x - nx * amplitude * 0.75, y: midpoint.y - ny * amplitude * 0.75))
            }
        }
        if let last = points.last { result.append(last) }
        return result
    }

    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted {
            if $0.x != $1.x { return $0.x < $1.x }
            return $0.y < $1.y
        }
        guard sorted.count >= 3 else { return [] }
        var unique: [CGPoint] = []
        unique.reserveCapacity(sorted.count)
        for point in sorted where unique.last != point { unique.append(point) }
        guard unique.count >= 3 else { return [] }

        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var lower: [CGPoint] = []
        for point in unique {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in unique.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }
}

/// Tiny deterministic generator used only by Portrait. A seed changes the
/// artistic itinerary while repeated frames with the same seed remain stable.
private struct PortraitPRNG {
    private var state: UInt64

    init(seed: Int) {
        var value = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15
        if value == 0 { value = 0xD1B5_4A32_D192_ED03 }
        state = value
    }

    mutating func unit() -> CGFloat {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 0x2545_F491_4F6C_DD1D
        return CGFloat(Double(value >> 11) / Double(1 << 53))
    }
}
