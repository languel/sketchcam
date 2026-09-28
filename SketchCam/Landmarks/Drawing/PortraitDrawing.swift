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
        let maximumCount: Int
    }

    private struct SemanticRoute {
        let points: [CGPoint]
        let kind: RouteKind
        let renderStrokes: [RenderStroke]
        let isUnified: Bool
        let hasSuppressedBridge: Bool
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
        let strokes = rawStrokes(groups: groups, landmarks: landmarks)
        guard landmarks.resolvedPortraitApproach == .landmarks,
              landmarks.resolvedPortraitStyle == .cubist,
              landmarks.resolvedPortraitConstructivist > 0 else { return strokes }
        let face = groups.first { $0.region == .jaw && $0.points.count >= 3 }?.points ?? []
        let faceX = face.map(\.x), faceY = face.map(\.y)
        let faceWidth = (faceX.max() ?? 0) - (faceX.min() ?? 0)
        let faceBounds = CGRect(x: faceX.min() ?? 0, y: faceY.min() ?? 0,
                                width: faceWidth, height: (faceY.max() ?? 0) - (faceY.min() ?? 0))
        return strokes.map { source in
            var stroke = source
            let xs = source.points.map(\.x), ys = source.points.map(\.y)
            let center = CGPoint(x: ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2,
                                 y: ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2)
            let nearFace = faceWidth > 0 && faceBounds.insetBy(dx: -faceWidth * 0.25,
                                                                dy: -faceWidth * 0.3).contains(center)
            stroke.points = PortraitPathBuilder.constructivistPath(
                nearFace ? PortraitPathBuilder.simplifiedFeaturePath(
                    source.points, faceWidth: faceWidth, amount: landmarks.resolvedPortraitConstructivist
                ) : source.points,
                amount: landmarks.resolvedPortraitConstructivist)
            return stroke
        }
    }

    private func rawStrokes(groups: [MappedGroup], landmarks: LandmarkSettings) -> [StrokeTessellator.Stroke] {
        if landmarks.resolvedPortraitApproach != .landmarks {
            var paths = landmarks.resolvedPortraitApproach == .aaron
                ? PortraitPathBuilder.subdivideLongest(
                    authoredVisiblePaths(AaronPortrait.paths(groups: groups, settings: landmarks),
                                         landmarks: landmarks),
                    additional: landmarks.resolvedPortraitSegments - 1)
                : GesturePortrait.paths(groups: groups, settings: landmarks)
            if landmarks.resolvedPortraitApproach == .gesture,
               landmarks.resolvedPortraitPoseBodyEnabled && landmarks.resolvedPortraitBodyEnabled,
               let rig = PortraitPathBuilder.poseBodyComponent(
                   from: groups, scalp: nil, seed: landmarks.resolvedPortraitSeed &+ 113
               ) {
                // Gesture owns the head and bust itinerary; the shared rig
                // contributes the same articulated arm contours as Landmarks.
                let disconnected = landmarks.resolvedPortraitSeparateFeatures
                    || landmarks.resolvedPortraitConnectorWidth == 0
                paths.append(contentsOf: disconnected ? [rig.points] : rig.sleeveFills)
            }
            paths.append(contentsOf: handOutlinePaths(groups: groups, landmarks: landmarks))
            return paths.enumerated().flatMap { index, path in
                DrawingSupport.ribbonStrokes(path, color: landmarks.resolvedPortraitColor,
                    baseWidth: CGFloat(max(0.4, landmarks.resolvedPortraitWidth)),
                    widthVariation: landmarks.resolvedPortraitWidthVariation,
                    halo: landmarks.resolvedPortraitHalo, seed: landmarks.resolvedPortraitSeed &+ index)
            }
        }
        return semanticRouteModels(groups: groups, landmarks: landmarks).enumerated().flatMap { index, model in
            let isOutline = model.kind == .outline
            var color = landmarks.resolvedPortraitColor
            if isOutline {
                color.alpha *= max(0, min(1, landmarks.resolvedPortraitOutlineStrength))
            }
            if model.isUnified && !model.hasSuppressedBridge {
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
        if landmarks.resolvedPortraitApproach == .gesture {
            var paths = GesturePortrait.paths(groups: groups, settings: landmarks)
            if landmarks.resolvedPortraitPoseBodyEnabled && landmarks.resolvedPortraitBodyEnabled,
               let rig = PortraitPathBuilder.poseBodyComponent(
                   from: groups, scalp: nil, seed: landmarks.resolvedPortraitSeed &+ 113
               ) {
                let disconnected = landmarks.resolvedPortraitSeparateFeatures
                    || landmarks.resolvedPortraitConnectorWidth == 0
                paths.append(contentsOf: disconnected ? [rig.points] : rig.sleeveFills)
            }
            paths.append(contentsOf: handOutlinePaths(groups: groups, landmarks: landmarks))
            return paths
        }
        if landmarks.resolvedPortraitApproach == .aaron {
            return PortraitPathBuilder.subdivideLongest(
                authoredVisiblePaths(AaronPortrait.paths(groups: groups, settings: landmarks),
                                     landmarks: landmarks),
                additional: landmarks.resolvedPortraitSegments - 1)
                + handOutlinePaths(groups: groups, landmarks: landmarks)
        }
        return semanticRouteModels(groups: groups, landmarks: landmarks).map(\.points)
    }

    private func handOutlinePaths(groups: [MappedGroup], landmarks: LandmarkSettings) -> [[CGPoint]] {
        guard landmarks.portraitLineVisible(.hands) else { return [] }
        return groups.filter { $0.region == .hands }.flatMap { hand -> [[CGPoint]] in
            if let outline = PortraitPathBuilder.fingerContourComponent(
                from: hand, fullness: landmarks.resolvedPortraitFingerFullness
            ) { return [outline.points] }
            return PortraitPathBuilder.components(hand).map(\.points).filter { $0.count >= 2 }
        }
    }

    private func authoredVisiblePaths(_ paths: [[CGPoint]], landmarks: LandmarkSettings) -> [[CGPoint]] {
        paths.enumerated().compactMap { index, path in
            let feature: PortraitLineFeature?
            switch index {
            case 1: feature = .faceContour
            case 2, 3: feature = .brows
            case 4, 5: feature = .eyes
            case 6, 7: feature = .pupils
            case 8: feature = .nose
            case 9: feature = .mouth
            default: feature = nil
            }
            return path.count >= 2 && (feature.map { landmarks.portraitLineVisible($0) } ?? true) ? path : nil
        }
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
        let components = routeGroups.flatMap { group in
            if landmarks.resolvedPortraitFingerContoursEnabled,
               let contour = PortraitPathBuilder.fingerContourComponent(
                   from: group, fullness: landmarks.resolvedPortraitFingerFullness
               ) {
                return [contour]
            }
            return PortraitPathBuilder.components(group)
        }
        let componentsByRegion = Dictionary(grouping: components, by: \.region)
        var routes: [SemanticRoute] = []

        let faceOrder: [LandmarkRegion] = [
            .leftBrow, .leftEye, .nose, .rightEye, .rightBrow, .jaw, .mouth
        ]
        var faceFeatures: [PortraitPathBuilder.Component] = []
        for region in faceOrder {
            let visible: Bool
            switch region {
            case .leftBrow, .rightBrow: visible = landmarks.portraitLineVisible(.brows)
            case .leftEye, .rightEye:
                visible = landmarks.portraitLineVisible(.eyes) || landmarks.portraitLineVisible(.pupils)
            case .nose: visible = landmarks.portraitLineVisible(.nose)
            case .mouth: visible = landmarks.portraitLineVisible(.mouth)
            case .jaw: visible = landmarks.portraitLineVisible(.faceContour)
            default: visible = true
            }
            guard visible else { continue }
            let candidates = (componentsByRegion[region] ?? []).sorted { $0.points.count > $1.points.count }
            if region == .mouth {
                faceFeatures.append(contentsOf: PortraitPathBuilder.mouthFeatures(
                    candidates,
                    connection: landmarks.resolvedPortraitMouthConnection,
                    innerEnabled: landmarks.resolvedPortraitInnerMouthEnabled,
                    centerline: landmarks.resolvedPortraitMouthCenterlineEnabled,
                    leftEye: componentsByRegion[.leftEye] ?? [],
                    rightEye: componentsByRegion[.rightEye] ?? []
                ))
            } else if region == .leftBrow || region == .rightBrow {
                if let brow = landmarks.resolvedPortraitBrowCenterlineEnabled
                    ? PortraitPathBuilder.browCenterline(candidates) : candidates.first {
                    faceFeatures.append(brow)
                }
            } else if region == .leftEye || region == .rightEye {
                // Eye rings and isolated pupil marks are separate semantic
                // components. Keep both so the pupil cannot disappear when
                // the ring wins a single-component sort.
                faceFeatures.append(contentsOf: candidates.filter {
                    $0.isPupil ? landmarks.portraitLineVisible(.pupils)
                               : landmarks.portraitLineVisible(.eyes)
                })
            } else if let first = candidates.first {
                faceFeatures.append(region == .jaw && landmarks.resolvedPortraitEarsEnabled
                    ? PortraitPathBuilder.jawWithEars(first) : first)
            }
        }
        let hair = landmarks.resolvedPortraitHairEnabled
            ? PortraitPathBuilder.hairComponent(
               from: groups,
               style: landmarks.resolvedPortraitHairStyle,
               amount: landmarks.resolvedPortraitHairAmount,
               seed: landmarks.resolvedPortraitSeed &+ 71,
               expansion: landmarks.resolvedPortraitHairExpansion,
               hairdo: landmarks.resolvedPortraitHairdo
            ) : nil
        if let hair {
            faceFeatures.append(hair)
            faceFeatures.append(contentsOf: hair.hairSideFills.map {
                PortraitPathBuilder.Component(region: .head, points: $0 + [$0[0]], closed: true,
                          handedness: .unknown, isCrown: true)
            })
        }
        faceFeatures = PortraitPathBuilder.anchorFaceConnections(
            faceFeatures,
            seed: landmarks.resolvedPortraitSeed &+ 29
        )
        let bodyFeatures = PortraitPathBuilder.orderedBodyFeatures(components).filter {
            ($0.region != .hands || landmarks.portraitLineVisible(.hands)) &&
            (!landmarks.resolvedPortraitPoseBodyEnabled ||
                ![LandmarkRegion.head, .torso, .leftArm, .rightArm].contains($0.region))
        }
        let outline = landmarks.resolvedPortraitPoseBodyEnabled
            ? PortraitPathBuilder.poseBodyComponent(from: groups, scalp: hair,
                                                    seed: landmarks.resolvedPortraitSeed &+ 113)
            : (landmarks.resolvedPortraitOutlineEnabled
                ? PortraitPathBuilder.outlineComponent(from: groups, scalp: hair) : nil)
        // Unified mode keeps topology fixed while landmarks move. Variety is
        // supplied by the editable seed, nose/pupil selection, and explicit
        // subsampling; the legacy route-variation control remains for the
        // separate face route without introducing live reorder noise.
        let unifiedTopologyVariation: Float = 0

        if landmarks.resolvedPortraitSeparateFeatures || landmarks.resolvedPortraitConnectorWidth == 0 {
            for (index, feature) in faceFeatures.enumerated() {
                if let separate = route(features: [feature], style: landmarks.resolvedPortraitStyle,
                                        follow: landmarks.resolvedPortraitFollow,
                                        flourish: landmarks.resolvedPortraitFlourish,
                                        variation: landmarks.resolvedPortraitVariation,
                                        routeVariation: 0, connectorWidth: 0,
                                        subsample: landmarks.resolvedPortraitSubsample,
                                        hairAmount: landmarks.resolvedPortraitHairAmount,
                                        kind: .face,
                                        seed: landmarks.resolvedPortraitSeed &+ 17 &+ index &* 101) {
                    routes.append(separate)
                }
            }
            for (index, feature) in bodyFeatures.enumerated() {
                if let separate = route(features: [feature], style: landmarks.resolvedPortraitStyle,
                                        follow: landmarks.resolvedPortraitFollow,
                                        flourish: landmarks.resolvedPortraitFlourish,
                                        variation: landmarks.resolvedPortraitVariation,
                                        routeVariation: 0, connectorWidth: 0,
                                        subsample: landmarks.resolvedPortraitSubsample,
                                        kind: .body,
                                        seed: landmarks.resolvedPortraitSeed &+ 53 &+ index &* 101) {
                    routes.append(separate)
                }
            }
            if let outline,
               let separate = route(features: [outline], style: landmarks.resolvedPortraitStyle,
                                    follow: landmarks.resolvedPortraitFollow,
                                    flourish: landmarks.resolvedPortraitFlourish * 0.45,
                                    variation: landmarks.resolvedPortraitVariation * 0.65,
                                    routeVariation: 0, connectorWidth: 0,
                                    subsample: landmarks.resolvedPortraitSubsample,
                                    kind: .outline,
                                    seed: landmarks.resolvedPortraitSeed &+ 97) {
                routes.append(separate)
            }
            return routes
        }

        if landmarks.resolvedPortraitUnifiedRoute {
            let unified = PortraitPathBuilder.unifiedItinerary(
                face: faceFeatures,
                body: bodyFeatures,
                outline: outline,
                variation: unifiedTopologyVariation,
                detailPriority: landmarks.resolvedPortraitDetailPriority,
                preferNearbyBody: landmarks.resolvedPortraitPoseBodyEnabled,
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
                hairAmount: landmarks.resolvedPortraitHairAmount,
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
                hairAmount: landmarks.resolvedPortraitHairAmount,
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
        hairAmount: Float = 0,
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
                hairAmount: hairAmount,
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
        hairAmount: Float = 0,
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
        var hasSuppressedBridge = false

        for (index, feature) in usable.enumerated() {
            // Hand graphs are already sparse (roughly one point per joint),
            // so keep every detected joint while allowing the global
            // subsampling control to simplify denser face/outline sources.
            let featureSubsample: Float = feature.region == .hands ? 1 : subsample
            let hairSampleLimit = feature.isCrown
                ? min(720, 160 + Int((max(0, hairAmount - 4) * 35).rounded()))
                : min(480, 160 * max(1, Int(subsample.rounded(.up))))
            var sourcePoints = PortraitPathBuilder.sampledLandmarks(
                feature.points,
                closed: feature.closed,
                variation: feature.isHandContour ? 0 : routeVariation,
                subsample: featureSubsample,
                minimumCount: feature.isPupil || feature.region == .nose ? 4 : 2,
                maximumCount: hairSampleLimit,
                seed: seed &+ index &* 31
            )
            if feature.region == .nose {
                sourcePoints = PortraitPathBuilder.noseVariant(
                    sourcePoints,
                    closed: feature.closed,
                    seed: seed &+ index &* 43
                )
            }
            // Keep face handoffs on their semantic ports: brows end at their
            // nose-side end, eyes begin/end at the inner canthus, nose begins
            // at the bridge, and both lip loops begin at one mouth corner.
            // This prevents proximity-only routing from drawing across the
            // outer eye corners or across the middle of the lips.
            if feature.closed && (feature.region == .leftEye || feature.region == .rightEye),
               !feature.isPupil, let anchor = feature.points.first {
                sourcePoints = PortraitPathBuilder.closedPathStartingNear(sourcePoints, anchor: anchor)
            } else if feature.closed && feature.region == .mouth, let anchor = feature.points.first {
                sourcePoints = PortraitPathBuilder.closedPathStartingNear(sourcePoints, anchor: anchor)
            } else if feature.region == .nose, !feature.closed, let bridge = feature.points.first {
                sourcePoints = PortraitPathBuilder.openPathStartingNear(sourcePoints, anchor: bridge)
            } else if feature.region == .leftBrow || feature.region == .rightBrow,
                      !feature.closed, let inner = feature.points.last {
                let nextFeature = index + 1 < usable.count ? usable[index + 1] : nil
                func isMedialNeighbor(_ other: PortraitPathBuilder.Component?) -> Bool {
                    guard let other else { return false }
                    if other.region == .nose { return true }
                    return (feature.region == .leftBrow && other.region == .leftEye)
                        || (feature.region == .rightBrow && other.region == .rightEye)
                }
                if isMedialNeighbor(nextFeature) || previousFeature == nil {
                    sourcePoints = PortraitPathBuilder.openPathEndingNear(sourcePoints, anchor: inner)
                } else {
                    sourcePoints = PortraitPathBuilder.openPathStartingNear(sourcePoints, anchor: inner)
                }
            } else if let from = result.last {
                // Other components can still choose the nearer endpoint; the
                // face-specific features above deliberately use their anchors.
                sourcePoints = PortraitPathBuilder.connectedStart(
                    sourcePoints,
                    closed: feature.closed,
                    toward: from
                )
            }
            var points = PortraitPathBuilder.stylize(
                sourcePoints,
                closed: feature.closed,
                style: style,
                follow: feature.isHandContour ? max(follow, 0.9) : follow,
                flourish: feature.isHandContour ? flourish * 0.2 : flourish,
                variation: feature.isHandContour ? variation * 0.25 : variation,
                scale: scale,
                seed: seed &+ index &* 31
            )
            if (feature.isCrown || feature.isHandContour || feature.region == .jaw || feature.region == .contour), !feature.closed,
               points.count >= 2, let first = sourcePoints.first, let last = sourcePoints.last {
                points[0] = first
                points[points.count - 1] = last
            }
            guard !points.isEmpty else { continue }
            if let from = result.last, let to = points.first {
                if connectorWidth > 0 && PortraitPathBuilder.shouldBridge(previousFeature, feature) {
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
                        widthScale: sameSemanticPart ? 1 : CGFloat(min(1, connectorWidth)),
                        widthVariationScale: sameSemanticPart ? 1 : 0.72,
                        alphaScale: 1,
                        seed: seed &+ index &* 37,
                        maximumCount: 160
                    ))
                    result.append(contentsOf: bridge)
                } else {
                    hasSuppressedBridge = true
                }
            }
            result.append(contentsOf: points)
            renderStrokes.append(RenderStroke(
                points: points,
                widthScale: 1,
                widthVariationScale: 1,
                alphaScale: (feature.region == .contour || feature.region == .bodyHull)
                    ? 0.82 * silhouetteAlpha : 1,
                seed: seed &+ index &* 53,
                maximumCount: hairSampleLimit
            ))
            previousFeature = feature
        }

        guard result.count >= 2 else { return nil }
        // Predictive tracking can rebuild the route at display cadence. Bound
        // pathological contour/multi-person inputs while leaving ordinary
        // face/body routes untouched. Uniform sampling preserves the semantic
        // itinerary, endpoints, and incoming motion.
        let routeLimit = usable.contains(where: \.isCrown)
            ? min(900, 320 + Int((max(0, hairAmount - 4) * 36).rounded()))
            : min(640, 320 * max(1, Int(subsample.rounded(.up))))
        let bounded = PortraitPathBuilder.uniformlySample(result, maximumCount: routeLimit)
        let fit: CurveFit = style == .cubist ? .polyline : .hobby
        let fittedStrokes = renderStrokes.map { stroke in
            let boundedStroke = PortraitPathBuilder.uniformlySample(stroke.points, maximumCount: stroke.maximumCount)
            return RenderStroke(
                points: DrawingSupport.curvePoints(
                    boundedStroke,
                    fit: fit,
                    samplesPerSegment: style == .ornate ? 4 : 3
                ),
                widthScale: stroke.widthScale,
                widthVariationScale: stroke.widthVariationScale,
                alphaScale: stroke.alphaScale,
                seed: stroke.seed,
                maximumCount: stroke.maximumCount
            )
        }
        return SemanticRoute(
            points: DrawingSupport.curvePoints(bounded, fit: fit, samplesPerSegment: style == .ornate ? 4 : 3),
            kind: kind,
            renderStrokes: fittedStrokes,
            isUnified: isUnified,
            hasSuppressedBridge: hasSuppressedBridge
        )
    }
}

enum PortraitPathBuilder {
    /// Add deliberate pen lifts to authored routes without changing a single
    /// vertex. Each split duplicates its shared endpoint so the figure shape
    /// remains stable as the Segments slider moves.
    static func subdivideLongest(_ paths: [[CGPoint]], additional: Int) -> [[CGPoint]] {
        var result = paths
        for _ in 0..<max(0, min(15, additional)) {
            guard let index = result.indices.filter({ result[$0].count >= 4 })
                .max(by: { result[$0].count < result[$1].count }) else { break }
            let path = result.remove(at: index)
            let middle = path.count / 2
            result.insert(Array(path[middle...]), at: index)
            result.insert(Array(path[...middle]), at: index)
        }
        return result
    }

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
        var isHandContour: Bool = false
        /// Paint geometry is separate from the pen itinerary: a raised wrist
        /// must not enlarge the torso fill into a giant convex triangle.
        var torsoFill: [CGPoint]? = nil
        var neckFill: [CGPoint]? = nil
        var sleeveFills: [[CGPoint]] = []
        /// Outer hair mass used by paint; the scalp arc remains independent.
        var hairFillOutline: [CGPoint]? = nil
        /// Narrow side locks are painted separately so the crown cannot become
        /// a broad triangle hanging from each temple.
        var hairSideFills: [[CGPoint]] = []
        /// Geometry reference for joining an optional person contour. Wild
        /// hair need not draw a smooth roof just to supply its apex.
        var scalpApex: CGPoint? = nil
    }

    /// A small loop at each side of the open jaw contour suggests an ear
    /// without asking the detector for an ear landmark. Its width and tilt
    /// follow the head frame, so the ears turn with the face instead of
    /// becoming fixed screen-space ornaments.
    static func jawWithEars(_ jaw: Component) -> Component {
        guard jaw.points.count >= 5, let first = jaw.points.first,
              let last = jaw.points.last else { return jaw }
        let span = max(1, hypot(last.x - first.x, last.y - first.y))
        let across = CGPoint(x: (last.x - first.x) / span, y: (last.y - first.y) / span)
        let middle = CGPoint(x: (first.x + last.x) * 0.5, y: (first.y + last.y) * 0.5)
        let chin = jaw.points[jaw.points.count / 2]
        let chinDelta = CGPoint(x: chin.x - middle.x, y: chin.y - middle.y)
        let chinLength = hypot(chinDelta.x, chinDelta.y)
        let down = chinLength > span * 0.08
            ? CGPoint(x: chinDelta.x / chinLength, y: chinDelta.y / chinLength)
            : CGPoint(x: -across.y, y: across.x)
        func ear(at anchor: CGPoint, outward: CGFloat) -> [CGPoint] {
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: anchor.x + across.x * span * x * outward + down.x * span * y,
                        y: anchor.y + across.y * span * x * outward + down.y * span * y)
            }
            return [anchor, point(0.045, -0.025), point(0.075, 0.035),
                    point(0.07, 0.115), point(0.03, 0.175),
                    point(0, 0.15), anchor]
        }
        var result = jaw
        result.points = ear(at: first, outward: -1) + jaw.points.dropFirst()
            + ear(at: last, outward: 1).dropFirst()
        return result
    }

    static func isArticulatedBodyRegion(_ region: LandmarkRegion) -> Bool {
        switch region {
        case .torso, .leftArm, .rightArm, .leftLeg, .rightLeg, .hands: return true
        default: return false
        }
    }

    /// Replace each edge with a diagonal plus an axis-aligned leg. Keeping
    /// both endpoints fixed avoids cumulative drift and preserves closed loops.
    static func constructivistPath(_ points: [CGPoint], amount: Float) -> [CGPoint] {
        let blend = CGFloat(min(1, max(0, amount)))
        guard blend > 0, let first = points.first else { return points }
        var result = [first]
        result.reserveCapacity(points.count * 2)
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let diagonal = min(abs(dx), abs(dy))
            let corner = CGPoint(x: a.x + (dx < 0 ? -diagonal : diagonal),
                                 y: a.y + (dy < 0 ? -diagonal : diagonal))
            let total = hypot(dx, dy)
            guard total > 0.0001 else { continue }
            // Start the intermediate vertex on the original edge so the dial
            // moves continuously without changing the feature's endpoints.
            let fraction = min(1, hypot(corner.x - a.x, corner.y - a.y) / total)
            let straight = CGPoint(x: a.x + dx * fraction, y: a.y + dy * fraction)
            let elbow = CGPoint(x: straight.x + (corner.x - straight.x) * blend,
                                y: straight.y + (corner.y - straight.y) * blend)
            if hypot(elbow.x - a.x, elbow.y - a.y) > 0.0001,
               hypot(elbow.x - b.x, elbow.y - b.y) > 0.0001 { result.append(elbow) }
            result.append(b)
        }
        return result
    }

    static func simplifiedFeaturePath(_ points: [CGPoint], faceWidth: CGFloat, amount: Float) -> [CGPoint] {
        guard points.count > 3, faceWidth > 0, amount > 0 else { return points }
        let xs = points.map(\.x), ys = points.map(\.y)
        let localSize = hypot((xs.max() ?? 0) - (xs.min() ?? 0),
                              (ys.max() ?? 0) - (ys.min() ?? 0))
        let tolerance = min(faceWidth * 0.085, max(faceWidth * 0.018, localSize * 0.12))
            * CGFloat(amount * amount)
        func reduce(_ path: [CGPoint]) -> [CGPoint] {
            guard path.count > 2, let first = path.first, let last = path.last else { return path }
            let dx = last.x - first.x, dy = last.y - first.y
            let denominator = max(0.0001, dx * dx + dy * dy)
            let candidate = path.indices.dropFirst().dropLast().map { index -> (Int, CGFloat) in
                let point = path[index]
                let t = max(0, min(1, ((point.x - first.x) * dx + (point.y - first.y) * dy) / denominator))
                return (index, hypot(point.x - first.x - t * dx, point.y - first.y - t * dy))
            }.max { $0.1 < $1.1 }
            guard let candidate, candidate.1 > tolerance else { return [first, last] }
            return reduce(Array(path[...candidate.0])).dropLast()
                + reduce(Array(path[candidate.0...]))
        }
        if let first = points.first, let last = points.last,
           hypot(first.x - last.x, first.y - last.y) < 0.001 {
            let open = Array(points.dropLast())
            guard let split = open.indices.max(by: {
                hypot(open[$0].x - first.x, open[$0].y - first.y)
                    < hypot(open[$1].x - first.x, open[$1].y - first.y)
            }), split > 0 else { return points }
            return reduce(Array(open[...split])).dropLast()
                + reduce(Array(open[split...]) + [first])
        }
        return reduce(points)
    }

    static func shouldBridge(_ previous: Component?, _ next: Component) -> Bool {
        // Two separately tracked hands can pass close to each other without
        // becoming one anatomical contour. Let the stroke lift there.
        if previous?.region == .hands && next.region == .hands { return false }
        // With no jaw observation there is no reliable ear-side entry for the
        // scalp. A pen lift looks better than a line through the face.
        if next.isCrown && previous?.region != .jaw { return false }
        return true
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

    /// Convert the labeled 0...20 hand skeleton into one continuous ink
    /// contour. Each finger is visited out along one side, rounded at the tip,
    /// and returned along the other side before crossing its palm web. The
    /// wrist is both endpoints so an arm can join without a jump to a claw tip.
    static func fingerContourComponent(from group: MappedGroup, fullness: Float) -> Component? {
        guard group.region == .hands else { return nil }
        var joints: [Int: CGPoint] = [:]
        for (label, point) in zip(group.labels, group.points) {
            guard let label, let prefix = label.first,
                  prefix == "L" || prefix == "R" || prefix == "E",
                  let index = Int(label.dropFirst()), (0...20).contains(index) else { continue }
            joints[index] = point
        }
        guard let wrist = joints[0] else { return nil }

        struct Finger {
            let centers: [CGPoint]
            let index: Int
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(a.x - b.x, a.y - b.y)
        }
        func interpolate(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let fingers: [Finger] = (0..<5).compactMap { finger in
            let baseIndex = 1 + finger * 4
            guard let base = joints[baseIndex], let tip = joints[baseIndex + 3],
                  distance(base, tip) > 3 else { return nil }
            return Finger(centers: [
                base,
                joints[baseIndex + 1] ?? interpolate(base, tip, 1 / 3),
                joints[baseIndex + 2] ?? interpolate(base, tip, 2 / 3),
                tip
            ], index: finger)
        }
        guard fingers.count >= 3 else { return nil }

        let palmLeft = joints[5] ?? fingers[0].centers[0]
        let palmRight = joints[17] ?? fingers[fingers.count - 1].centers[0]
        let palmSpan = max(8, distance(palmLeft, palmRight))
        let across = CGPoint(x: (palmRight.x - palmLeft.x) / palmSpan,
                             y: (palmRight.y - palmLeft.y) / palmSpan)
        let width = CGFloat(max(0.5, min(2, fullness)))
        var path: [CGPoint] = [wrist]
        path.reserveCapacity(fingers.count * 11 + 2)

        for (position, finger) in fingers.enumerated() {
            let centers = finger.centers
            let base = centers[0], tip = centers[3]
            let length = max(1, distance(base, tip))
            let forward = CGPoint(x: (tip.x - base.x) / length,
                                  y: (tip.y - base.y) / length)
            var acrossFinger = CGPoint(x: -forward.y, y: forward.x)
            if acrossFinger.x * across.x + acrossFinger.y * across.y < 0 {
                acrossFinger = CGPoint(x: -acrossFinger.x, y: -acrossFinger.y)
            }
            let previousGap = position > 0
                ? distance(base, fingers[position - 1].centers[0]) : .greatestFiniteMagnitude
            let nextGap = position + 1 < fingers.count
                ? distance(base, fingers[position + 1].centers[0]) : .greatestFiniteMagnitude
            let neighborGap = min(previousGap, nextGap)
            let fingerScale: CGFloat = finger.index == 0 ? 1.15 : finger.index == 4 ? 0.78 : 1
            let halfWidth = max(1.2, min(palmSpan * 0.105 * width * fingerScale,
                                         length * 0.2, neighborGap * 0.43))
            let widths: [CGFloat] = [1.05, 1, 0.86, 0.72]
            func side(_ point: CGPoint, _ offset: CGFloat) -> CGPoint {
                CGPoint(x: point.x + acrossFinger.x * offset,
                        y: point.y + acrossFinger.y * offset)
            }

            for joint in 0..<4 {
                path.append(side(centers[joint], -halfWidth * widths[joint]))
            }
            // A short rounded cap, not an angular spike at the tracked tip.
            path.append(CGPoint(x: tip.x + forward.x * halfWidth * 0.48 - acrossFinger.x * halfWidth * 0.34,
                                y: tip.y + forward.y * halfWidth * 0.48 - acrossFinger.y * halfWidth * 0.34))
            path.append(CGPoint(x: tip.x + forward.x * halfWidth * 0.62,
                                y: tip.y + forward.y * halfWidth * 0.62))
            path.append(CGPoint(x: tip.x + forward.x * halfWidth * 0.48 + acrossFinger.x * halfWidth * 0.34,
                                y: tip.y + forward.y * halfWidth * 0.48 + acrossFinger.y * halfWidth * 0.34))
            for joint in (0..<4).reversed() {
                path.append(side(centers[joint], halfWidth * widths[joint]))
            }
            if position + 1 < fingers.count {
                let nextBase = fingers[position + 1].centers[0]
                let web = interpolate(base, nextBase, 0.5)
                path.append(CGPoint(x: web.x + forward.x * min(halfWidth * 0.45, neighborGap * 0.12),
                                    y: web.y + forward.y * min(halfWidth * 0.45, neighborGap * 0.12)))
            }
        }
        path.append(wrist)
        return Component(region: .hands, points: path, closed: false,
                         handedness: handedness(group), isHandContour: true)
    }

    /// A persistent 2-D figure rig under the drawing. Missing pose joints are
    /// inferred from the face frame, not replaced by direct torso-to-hand
    /// links. Observed shoulders, elbows, wrists, and hands steer the same
    /// neck/torso/two-bone arm structure when they become available.
    static func poseBodyComponent(from groups: [MappedGroup], scalp: Component?, seed: Int) -> Component? {
        let torso = groups.first { $0.region == .torso }
        func joint(_ label: String) -> CGPoint? {
            guard let torso else { return nil }
            return zip(torso.labels, torso.points).first { $0.0 == label }?.1
        }
        let jaw = groups.first { $0.region == .jaw && $0.points.count >= 3 }
        let scalpEnds = scalp.flatMap({ component -> (CGPoint, CGPoint)? in
            guard let first = component.points.first, let last = component.points.last else { return nil }
            return (first, last)
        })
        // Scalp ends sit beside the brow/eyes. A neck starting there reads as
        // two long cheek-to-shoulder diagonals. Attach below the cheekbones,
        // on the lower quarters of the jaw contour, when it is available.
        guard let endpoints = jaw.flatMap({ group -> (CGPoint, CGPoint)? in
            let count = group.points.count
            guard count >= 5 else { return nil }
            return (group.points[max(1, (count - 1) / 4)],
                    group.points[min(count - 2, (count - 1) * 3 / 4)])
        }) ?? scalpEnds ?? jaw.flatMap({ group -> (CGPoint, CGPoint)? in
            guard let first = group.points.first, let last = group.points.last else { return nil }
            return (first, last)
        }) else { return nil }

        // Close-up camera framing often loses pose detection before the face
        // or hands. Infer a persistent bust from the moving ear/chin frame,
        // rather than dropping the neck and body completely on that frame.
        let earMiddle = CGPoint(x: (endpoints.0.x + endpoints.1.x) * 0.5,
                                y: (endpoints.0.y + endpoints.1.y) * 0.5)
        let earWidth = max(10, hypot(endpoints.1.x - endpoints.0.x,
                                     endpoints.1.y - endpoints.0.y))
        let faceAcross = CGPoint(x: (endpoints.1.x - endpoints.0.x) / earWidth,
                                 y: (endpoints.1.y - endpoints.0.y) / earWidth)
        let chin = jaw.map { $0.points[$0.points.count / 2] }
        let upperMiddle = scalpEnds.map {
            CGPoint(x: ($0.0.x + $0.1.x) * 0.5, y: ($0.0.y + $0.1.y) * 0.5)
        } ?? earMiddle
        let faceVector = chin.map { CGPoint(x: $0.x - upperMiddle.x, y: $0.y - upperMiddle.y) }
            ?? CGPoint(x: -faceAcross.y, y: faceAcross.x)
        let faceLength = max(1, hypot(faceVector.x, faceVector.y))
        let faceDown = CGPoint(x: faceVector.x / faceLength, y: faceVector.y / faceLength)
        let neckOrigin = chin ?? earMiddle
        let inferredCenter = CGPoint(x: neckOrigin.x + faceDown.x * faceLength * 0.38,
                                     y: neckOrigin.y + faceDown.y * faceLength * 0.38)
        let inferredHalfWidth = earWidth * 0.86
        let inferredLeft = CGPoint(x: inferredCenter.x - faceAcross.x * inferredHalfWidth,
                                   y: inferredCenter.y - faceAcross.y * inferredHalfWidth)
        let inferredRight = CGPoint(x: inferredCenter.x + faceAcross.x * inferredHalfWidth,
                                    y: inferredCenter.y + faceAcross.y * inferredHalfWidth)
        let leftShoulder = joint("Lsho") ?? inferredLeft
        let rightShoulder = joint("Rsho") ?? inferredRight

        // Vision labels describe anatomy, not screen position. Pair each ear
        // with its nearest shoulder so camera mirroring and yaw cannot swap the
        // two sides of the silhouette.
        let same = hypot(endpoints.0.x - leftShoulder.x, endpoints.0.y - leftShoulder.y)
                 + hypot(endpoints.1.x - rightShoulder.x, endpoints.1.y - rightShoulder.y)
        let crossed = hypot(endpoints.0.x - rightShoulder.x, endpoints.0.y - rightShoulder.y)
                    + hypot(endpoints.1.x - leftShoulder.x, endpoints.1.y - leftShoulder.y)
        var shoulders = same <= crossed
            ? (leftShoulder, rightShoulder) : (rightShoulder, leftShoulder)
        // Pose estimates occasionally put shoulders below the crop or attach
        // them to the wrong person. Keep a short, legible neck while retaining
        // shoulder width and lateral head motion.
        if let chin {
            let shoulderMid = CGPoint(x: (shoulders.0.x + shoulders.1.x) * 0.5,
                                      y: (shoulders.0.y + shoulders.1.y) * 0.5)
            let depth = (shoulderMid.x - chin.x) * faceDown.x
                + (shoulderMid.y - chin.y) * faceDown.y
            let bounded = min(faceLength * 0.62, max(faceLength * 0.18, depth))
            let correction = bounded - depth
            let shift = CGPoint(x: faceDown.x * correction, y: faceDown.y * correction)
            shoulders.0 = CGPoint(x: shoulders.0.x + shift.x, y: shoulders.0.y + shift.y)
            shoulders.1 = CGPoint(x: shoulders.1.x + shift.x, y: shoulders.1.y + shift.y)
        }
        let earSpan = max(10, hypot(endpoints.1.x - endpoints.0.x, endpoints.1.y - endpoints.0.y))
        let shoulderSpan = max(earSpan, hypot(shoulders.1.x - shoulders.0.x, shoulders.1.y - shoulders.0.y))
        let midShoulder = CGPoint(x: (shoulders.0.x + shoulders.1.x) * 0.5,
                                  y: (shoulders.0.y + shoulders.1.y) * 0.5)
        let neck = joint("neck") ?? CGPoint(x: earMiddle.x + faceDown.x * earWidth * 0.85,
                                            y: earMiddle.y + faceDown.y * earWidth * 0.85)
        let root = joint("root") ?? CGPoint(x: midShoulder.x + faceDown.x * shoulderSpan * 0.78,
                                            y: midShoulder.y + faceDown.y * shoulderSpan * 0.78)
        let downDelta = CGPoint(x: root.x - neck.x, y: root.y - neck.y)
        let downLength = max(1, hypot(downDelta.x, downDelta.y))
        let down = CGPoint(x: downDelta.x / downLength, y: downDelta.y / downLength)
        let across = CGPoint(x: -down.y, y: down.x)
        let orientation: CGFloat = (shoulders.1.x - shoulders.0.x) * across.x
            + (shoulders.1.y - shoulders.0.y) * across.y >= 0 ? 1 : -1
        let side = CGPoint(x: across.x * orientation, y: across.y * orientation)
        let leftHip = joint(same <= crossed ? "Lhip" : "Rhip")
        let rightHip = joint(same <= crossed ? "Rhip" : "Lhip")
        let waistDepth = max(shoulderSpan * 0.65, min(shoulderSpan * 1.45, downLength))
        let leftWaist = leftHip ?? CGPoint(x: root.x - side.x * shoulderSpan * 0.37,
                                          y: root.y - side.y * shoulderSpan * 0.37)
        let rightWaist = rightHip ?? CGPoint(x: root.x + side.x * shoulderSpan * 0.37,
                                            y: root.y + side.y * shoulderSpan * 0.37)
        let lower = CGPoint(x: midShoulder.x + down.x * waistDepth,
                            y: midShoulder.y + down.y * waistDepth)
        var random = PortraitPRNG(seed: seed)
        let bow = (random.unit() - 0.5) * shoulderSpan * 0.08
        func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x * (1 - t) + b.x * t, y: a.y * (1 - t) + b.y * t)
        }
        func displaced(_ p: CGPoint, along v: CGPoint, by d: CGFloat) -> CGPoint {
            CGPoint(x: p.x + v.x * d, y: p.y + v.y * d)
        }
        let trackedWrists: [CGPoint] = groups.filter { $0.region == .hands }.compactMap { hand in
            zip(hand.labels, hand.points).first { label, _ in
                label == "L0" || label == "R0" || label == "E0"
            }?.1
        }
        func armPoints(_ region: LandmarkRegion, shoulder: CGPoint,
                       otherShoulder: CGPoint, outward: CGFloat) -> [CGPoint] {
            let group = groups.first(where: { $0.region == region })
            let labeled = Dictionary(uniqueKeysWithValues: zip(group?.labels ?? [], group?.points ?? []).compactMap {
                label, point -> (String, CGPoint)? in label.map { ($0, point) }
            })
            let prefix = region == .leftArm ? "L" : "R"
            let nearbyHand = trackedWrists.min {
                hypot($0.x - shoulder.x, $0.y - shoulder.y)
                    < hypot($1.x - shoulder.x, $1.y - shoulder.y)
            }.flatMap { wrist -> CGPoint? in
                let near = hypot(wrist.x - shoulder.x, wrist.y - shoulder.y)
                let far = hypot(wrist.x - otherShoulder.x, wrist.y - otherShoulder.y)
                return near <= far && near < shoulderSpan * 2.8 ? wrist : nil
            }
            let wrist = labeled["\(prefix)wri"] ?? nearbyHand
                ?? labeled["\(prefix)elb"].map({ displaced($0, along: down, by: shoulderSpan * 0.60) })
                ?? displaced(displaced(shoulder, along: down, by: shoulderSpan * 1.15),
                             along: side, by: outward * shoulderSpan * 0.38)
            // When the elbow detector disappears, preserve a bent upper and
            // lower arm. A midpoint on the shoulder→wrist chord made raised
            // hands look like a single diagonal tether from the shirt.
            let elbow = labeled["\(prefix)elb"]
                ?? displaced(displaced(mix(shoulder, wrist, 0.52), along: side,
                                       by: outward * shoulderSpan * 0.22),
                             along: down, by: shoulderSpan * 0.07)
            let upperWidth = shoulderSpan * 0.105, lowerWidth = shoulderSpan * 0.055
            // A sleeve is one out-and-back stroke, not a line down the bone.
            // Width tapers towards the wrist; both arcs share the pose joints.
            return [displaced(mix(shoulder, elbow, 0.45), along: side, by: outward * upperWidth),
                    displaced(elbow, along: side, by: outward * upperWidth * 0.8),
                    displaced(mix(elbow, wrist, 0.52), along: side, by: outward * lowerWidth),
                    displaced(wrist, along: down, by: lowerWidth * 0.55),
                    displaced(mix(elbow, wrist, 0.52), along: side, by: -outward * lowerWidth),
                    displaced(elbow, along: side, by: -outward * upperWidth * 0.68)]
        }
        let firstRegion: LandmarkRegion = same <= crossed ? .leftArm : .rightArm
        let secondRegion: LandmarkRegion = same <= crossed ? .rightArm : .leftArm
        let firstArm = armPoints(firstRegion, shoulder: shoulders.0,
                                 otherShoulder: shoulders.1, outward: -1)
        let secondArm = armPoints(secondRegion, shoulder: shoulders.1,
                                  otherShoulder: shoulders.0, outward: 1)
        let torsoOutline = [shoulders.0,
                            displaced(mix(shoulders.0, leftWaist, 0.48), along: side,
                                      by: -shoulderSpan * 0.04 + bow),
                            leftWaist,
                            displaced(mix(leftWaist, lower, 0.5), along: down,
                                      by: shoulderSpan * 0.08),
                            lower,
                            displaced(mix(lower, rightWaist, 0.5), along: down,
                                      by: shoulderSpan * 0.08),
                            rightWaist,
                            displaced(mix(rightWaist, shoulders.1, 0.48), along: side,
                                      by: shoulderSpan * 0.04 + bow), shoulders.1]
        // The colored neck ends at a narrow collar between the shoulders.
        // Stretching the head color all the way to both shoulder tips made a
        // broad triangle that visually erased the neck.
        let collarCenter = displaced(midShoulder, along: down, by: -shoulderSpan * 0.10)
        let collarHalfWidth = min(earSpan * 0.35, shoulderSpan * 0.24)
        let collarLeft = displaced(collarCenter, along: side, by: -collarHalfWidth)
        let collarRight = displaced(collarCenter, along: side, by: collarHalfWidth)
        var points = [endpoints.0,
                      mix(endpoints.0, collarLeft, 0.52), collarLeft,
                      mix(collarLeft, shoulders.0, 0.65), shoulders.0]
        points += firstArm
        points += torsoOutline.dropFirst()
        points += secondArm
        points += [mix(shoulders.1, collarRight, 0.35), collarRight,
                   mix(collarRight, endpoints.1, 0.48), endpoints.1]
        var component = Component(region: .torso, points: points,
                                  closed: false, handedness: .unknown)
        component.torsoFill = torsoOutline
        component.neckFill = [endpoints.0, collarLeft, collarRight, endpoints.1]
        component.sleeveFills = [firstArm.isEmpty ? [] : [shoulders.0] + firstArm,
                                 secondArm.isEmpty ? [] : [shoulders.1] + secondArm]
            .filter { $0.count >= 4 }
        return component
    }

    /// Prefer an explicit segmentation contour, then an explicit hull. When
    /// neither is available, make a lightweight hull from the detected face
    /// and body markers so Portrait can add a scalp/shoulder silhouette without
    /// changing the shared detection groups used by the other algorithms.
    static func outlineComponent(from groups: [MappedGroup], scalp: Component? = nil) -> Component? {
        let explicit = groups
            .filter { $0.region == .contour || $0.region == .bodyHull }
            .sorted {
                if $0.region != $1.region { return $0.region == .contour }
                return $0.points.count > $1.points.count
            }
        if let group = explicit.first, group.points.count >= 3 {
            if group.region == .contour, let scalp,
               let bodyArc = bodyContourJoinedToScalp(group.points, scalp: scalp) {
                return Component(region: .contour, points: bodyArc, closed: false,
                                 handedness: .unknown)
            }
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

    /// Keep the lower/person side of the segmentation boundary and replace
    /// its head arc with the face-anchored scalp. Both remaining ends are the
    /// exact ear points, so the two drawn components meet as the head turns.
    private static func bodyContourJoinedToScalp(_ contour: [CGPoint], scalp: Component) -> [CGPoint]? {
        guard let leftEar = scalp.points.first, let rightEar = scalp.points.last,
              let crownPoint = scalp.scalpApex ?? (scalp.points.count > 8 ? scalp.points[8] : nil)
        else { return nil }
        var ring = contour
        if ring.first == ring.last { ring.removeLast() }
        guard ring.count >= 8 else { return nil }
        let earMiddle = CGPoint(x: (leftEar.x + rightEar.x) * 0.5,
                                y: (leftEar.y + rightEar.y) * 0.5)
        let crownDelta = CGPoint(x: crownPoint.x - earMiddle.x,
                                 y: crownPoint.y - earMiddle.y)
        let crownLength = hypot(crownDelta.x, crownDelta.y)
        let earSpan = hypot(rightEar.x - leftEar.x, rightEar.y - leftEar.y)
        guard crownLength > 8, earSpan > 8 else { return nil }
        let up = CGPoint(x: crownDelta.x / crownLength, y: crownDelta.y / crownLength)
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        guard let leftIndex = ring.indices.min(by: { distance(ring[$0], leftEar) < distance(ring[$1], leftEar) }),
              let rightIndex = ring.indices.min(by: { distance(ring[$0], rightEar) < distance(ring[$1], rightEar) }),
              leftIndex != rightIndex,
              distance(ring[leftIndex], leftEar) < earSpan * 0.5,
              distance(ring[rightIndex], rightEar) < earSpan * 0.5 else { return nil }
        func arc(step: Int) -> [CGPoint] {
            var result = [ring[leftIndex]]
            var index = leftIndex
            while index != rightIndex && result.count <= ring.count {
                index = (index + step + ring.count) % ring.count
                result.append(ring[index])
            }
            return result
        }
        func rise(_ point: CGPoint) -> CGFloat {
            (point.x - earMiddle.x) * up.x + (point.y - earMiddle.y) * up.y
        }
        let forward = arc(step: 1), backward = arc(step: -1)
        guard forward.count >= 3, backward.count >= 3 else { return nil }
        let forwardMean = forward.map(rise).reduce(0, +) / CGFloat(forward.count)
        let backwardMean = backward.map(rise).reduce(0, +) / CGFloat(backward.count)
        let headArc = forwardMean > backwardMean ? forward : backward
        let bodyArc = forwardMean > backwardMean ? backward : forward
        guard bodyArc.count >= 4,
              (headArc.map(rise).max() ?? 0) > earSpan * 0.2,
              abs(forwardMean - backwardMean) > earSpan * 0.1 else { return nil }
        return [leftEar] + bodyArc + [rightEar]
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

        // Trace the jaw into its ear, then enter the crown at that same side.
        // Placing the crown before the jaw can drag a brow/eye connector
        // diagonally across the face to reach the opposite temple.
        if let jawIndex = result.firstIndex(where: { $0.region == .jaw }) {
            result.insert(contentsOf: crowns, at: jawIndex + 1)
        } else {
            result.append(contentsOf: crowns)
        }
        return result
    }

    /// Prepares stable entry points for the meaningful face-to-face links.
    /// Vision's loop starts are arbitrary, so geometric proximity alone can
    /// attach brows to the outer eye corners or put the two lip loops on
    /// opposite sides. The chosen anchors move with the tracked face.
    static func mouthFeatures(
        _ components: [Component],
        connection: PortraitMouthConnection,
        innerEnabled: Bool,
        centerline: Bool = false,
        leftEye: [Component],
        rightEye: [Component]
    ) -> [Component] {
        let ranked = components.sorted {
            let lhsArea = enclosedArea($0)
            let rhsArea = enclosedArea($1)
            if abs(lhsArea - rhsArea) > 0.001 { return lhsArea > rhsArea }
            return $0.points.count > $1.points.count
        }
        guard let outer = ranked.first else { return [] }
        if centerline, let inner = ranked.dropFirst().first,
           let midpoint = averagedLipRing(outer: outer, inner: inner) {
            return [midpoint]
        }
        guard innerEnabled, let inner = ranked.dropFirst().first else { return [outer] }
        guard outer.closed, inner.closed else { return [outer, inner] }
        guard connection == .pairedCorners else { return [outer, inner] }
        guard let paired = pairedMouthContour(
            outer: outer,
            inner: inner,
            leftEye: leftEye,
            rightEye: rightEye
        ) else { return [outer, inner] }
        return [paired]
    }

    /// Vision can supply a brow as two edge-connected strands (or as two
    /// separate components). A true single open curve is already a centerline.
    static func browCenterline(_ components: [Component]) -> Component? {
        guard let first = components.first else { return nil }
        if components.count > 1,
           let averaged = averagedOpenPaths(first.points, components[1].points) {
            return Component(region: first.region, points: averaged,
                             closed: false, handedness: first.handedness)
        }
        let points = first.closed && first.points.first == first.points.last
            ? Array(first.points.dropLast()) : first.points
        guard points.count >= 5 else { return first }
        let firstPoint = points[0]
        let farthest = points.indices.max { lhs, rhs in
            hypot(points[lhs].x - firstPoint.x, points[lhs].y - firstPoint.y)
                < hypot(points[rhs].x - firstPoint.x, points[rhs].y - firstPoint.y)
        } ?? 0
        guard farthest >= 2, farthest <= points.count - 3 else { return first }
        let span = hypot(points[farthest].x - firstPoint.x, points[farthest].y - firstPoint.y)
        guard span > 0.001,
              hypot(points.last!.x - firstPoint.x, points.last!.y - firstPoint.y) < span * 0.5,
              let averaged = averagedOpenPaths(Array(points[0...farthest]),
                                               Array(points[farthest...].reversed())) else { return first }
        return Component(region: first.region, points: averaged,
                         closed: false, handedness: first.handedness)
    }

    private static func averagedOpenPaths(_ first: [CGPoint], _ second: [CGPoint]) -> [CGPoint]? {
        guard first.count >= 2, second.count >= 2 else { return nil }
        let same = hypot(first[0].x - second[0].x, first[0].y - second[0].y)
            + hypot(first.last!.x - second.last!.x, first.last!.y - second.last!.y)
        let reversed = hypot(first[0].x - second.last!.x, first[0].y - second.last!.y)
            + hypot(first.last!.x - second[0].x, first.last!.y - second[0].y)
        let alignedSecond = reversed < same ? Array(second.reversed()) : second
        let count = min(96, max(16, first.count, second.count))
        return zip(resamplePath(first, count: count, closed: false),
                   resamplePath(alignedSecond, count: count, closed: false))
            .map { CGPoint(x: ($0.x + $1.x) * 0.5, y: ($0.y + $1.y) * 0.5) }
    }

    private static func averagedLipRing(outer: Component, inner: Component) -> Component? {
        guard outer.closed, inner.closed else { return nil }
        func ring(_ component: Component) -> [CGPoint] {
            component.points.first == component.points.last
                ? Array(component.points.dropLast()) : component.points
        }
        var outerPoints = ring(outer), innerPoints = ring(inner)
        guard outerPoints.count >= 4, innerPoints.count >= 4 else { return nil }
        func area(_ points: [CGPoint]) -> CGFloat {
            points.indices.reduce(0) { sum, i in
                let next = points[(i + 1) % points.count]
                return sum + points[i].x * next.y - next.x * points[i].y
            }
        }
        if area(outerPoints) * area(innerPoints) < 0 { innerPoints.reverse() }
        func startingAtLeft(_ points: [CGPoint]) -> [CGPoint] {
            let start = points.indices.min { lhs, rhs in
                points[lhs].x < points[rhs].x
            } ?? 0
            return Array(points[start...]) + Array(points[..<start])
        }
        outerPoints = startingAtLeft(outerPoints)
        innerPoints = startingAtLeft(innerPoints)
        let count = min(96, max(24, outerPoints.count, innerPoints.count))
        var middle = zip(resamplePath(outerPoints, count: count, closed: true),
                         resamplePath(innerPoints, count: count, closed: true))
            .map { CGPoint(x: ($0.x + $1.x) * 0.5, y: ($0.y + $1.y) * 0.5) }
        if let first = middle.first { middle.append(first) }
        return Component(region: .mouth, points: middle, closed: true, handedness: .unknown)
    }

    private static func resamplePath(_ points: [CGPoint], count: Int, closed: Bool) -> [CGPoint] {
        let segmentCount = closed ? points.count : points.count - 1
        guard segmentCount > 0 else { return points }
        var distances = [CGFloat](repeating: 0, count: segmentCount + 1)
        for i in 0..<segmentCount {
            let a = points[i], b = points[(i + 1) % points.count]
            distances[i + 1] = distances[i] + hypot(b.x - a.x, b.y - a.y)
        }
        let total = distances[segmentCount]
        guard total > 0.001 else { return Array(repeating: points[0], count: count) }
        var segment = 0
        return (0..<count).map { index in
            let target = total * CGFloat(index) / CGFloat(closed ? count : count - 1)
            while segment < segmentCount - 1 && distances[segment + 1] < target { segment += 1 }
            let length = max(0.0001, distances[segment + 1] - distances[segment])
            let t = (target - distances[segment]) / length
            let a = points[segment], b = points[(segment + 1) % points.count]
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    private static func enclosedArea(_ component: Component) -> CGFloat {
        guard component.closed, component.points.count >= 4 else { return 0 }
        let ring = component.points.first == component.points.last
            ? Array(component.points.dropLast()) : component.points
        guard ring.count >= 3 else { return 0 }
        let twiceArea = ring.indices.reduce(CGFloat.zero) { total, index in
            let next = ring[(index + 1) % ring.count]
            return total + ring[index].x * next.y - next.x * ring[index].y
        }
        return abs(twiceArea) * 0.5
    }

    /// Weaves the upper/lower arcs of inner and outer lip rings together at
    /// both mouth corners. One closed semantic path lets the existing route
    /// planner treat this as a single feature without adding cross-mouth jumps.
    private static func pairedMouthContour(
        outer: Component,
        inner: Component,
        leftEye: [Component],
        rightEye: [Component]
    ) -> Component? {
        func ring(_ component: Component) -> [CGPoint] {
            component.points.first == component.points.last
                ? Array(component.points.dropLast()) : component.points
        }
        func center(_ components: [Component]) -> CGPoint? {
            let points = components.filter { !$0.isPupil }.flatMap(\.points)
            guard !points.isEmpty else { return nil }
            return CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
                           y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count))
        }
        let outerRing = ring(outer), innerRing = ring(inner)
        guard outerRing.count >= 4, innerRing.count >= 4 else { return nil }
        let leftCenter = center(leftEye), rightCenter = center(rightEye)
        let axisDelta: CGPoint
        if let leftCenter, let rightCenter {
            axisDelta = CGPoint(x: rightCenter.x - leftCenter.x, y: rightCenter.y - leftCenter.y)
        } else {
            axisDelta = CGPoint(x: 1, y: 0)
        }
        let axisLength = max(0.001, hypot(axisDelta.x, axisDelta.y))
        let axis = CGPoint(x: axisDelta.x / axisLength, y: axisDelta.y / axisLength)
        let mouthCenter = CGPoint(x: outerRing.reduce(0) { $0 + $1.x } / CGFloat(outerRing.count),
                                  y: outerRing.reduce(0) { $0 + $1.y } / CGFloat(outerRing.count))
        let eyeMid: CGPoint
        if let leftCenter, let rightCenter {
            eyeMid = CGPoint(x: (leftCenter.x + rightCenter.x) * 0.5,
                             y: (leftCenter.y + rightCenter.y) * 0.5)
        } else {
            eyeMid = leftCenter ?? rightCenter
                ?? CGPoint(x: mouthCenter.x, y: mouthCenter.y - 1)
        }
        let downDelta = CGPoint(x: mouthCenter.x - eyeMid.x, y: mouthCenter.y - eyeMid.y)
        let downLength = max(0.001, hypot(downDelta.x, downDelta.y))
        let up = CGPoint(x: -downDelta.x / downLength, y: -downDelta.y / downLength)

        func arcs(_ points: [CGPoint]) -> (upper: [CGPoint], lower: [CGPoint])? {
            let projection: (CGPoint) -> CGFloat = { $0.x * axis.x + $0.y * axis.y }
            guard let left = points.indices.min(by: { projection(points[$0]) < projection(points[$1]) }),
                  let right = points.indices.max(by: { projection(points[$0]) < projection(points[$1]) }),
                  left != right else { return nil }
            func walk(step: Int) -> [CGPoint] {
                var result = [points[left]]
                var index = left
                while index != right {
                    index = (index + step + points.count) % points.count
                    result.append(points[index])
                }
                return result
            }
            let forward = walk(step: 1)
            let backward = walk(step: -1)
            func height(_ arc: [CGPoint]) -> CGFloat {
                arc.reduce(CGFloat.zero) { $0 + $1.x * up.x + $1.y * up.y }
                    / CGFloat(max(1, arc.count))
            }
            return height(forward) >= height(backward)
                ? (upper: forward, lower: backward)
                : (upper: backward, lower: forward)
        }
        guard let outerArcs = arcs(outerRing), let innerArcs = arcs(innerRing) else { return nil }

        var points = outerArcs.upper
        points.append(contentsOf: innerArcs.upper.reversed().dropFirst())
        points.append(contentsOf: innerArcs.lower.dropFirst())
        points.append(contentsOf: outerArcs.lower.reversed().dropFirst())
        if let first = points.first, points.last != first { points.append(first) }
        guard points.count >= 5 else { return nil }
        return Component(region: .mouth, points: points, closed: true, handedness: .unknown)
    }

    static func anchorFaceConnections(_ features: [Component], seed: Int) -> [Component] {
        func center(_ components: [Component]) -> CGPoint? {
            let points = components.filter { !$0.isPupil }.flatMap(\.points)
            guard !points.isEmpty else { return nil }
            return CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
                           y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count))
        }
        func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
            hypot(lhs.x - rhs.x, lhs.y - rhs.y)
        }

        let noseCenter = center(features.filter { $0.region == .nose })
        let leftEyeCenter = center(features.filter { $0.region == .leftEye })
        let rightEyeCenter = center(features.filter { $0.region == .rightEye })
        let bridge = noseCenter ?? {
            guard let leftEyeCenter, let rightEyeCenter else { return nil }
            return CGPoint(x: (leftEyeCenter.x + rightEyeCenter.x) * 0.5,
                           y: (leftEyeCenter.y + rightEyeCenter.y) * 0.5)
        }()

        let eyeAxis: CGPoint? = {
            guard let leftEyeCenter, let rightEyeCenter else { return nil }
            let dx = rightEyeCenter.x - leftEyeCenter.x
            let dy = rightEyeCenter.y - leftEyeCenter.y
            let length = hypot(dx, dy)
            guard length > 0.001 else { return nil }
            return CGPoint(x: dx / length, y: dy / length)
        }()
        let mouthPoints = features.filter { $0.region == .mouth }.flatMap(\.points)
        let mouthCorner: CGPoint? = {
            guard !mouthPoints.isEmpty else { return nil }
            guard let eyeAxis else {
                return mouthPoints.min(by: { $0.x < $1.x })
            }
            let projection: (CGPoint) -> CGFloat = { $0.x * eyeAxis.x + $0.y * eyeAxis.y }
            if seed & 1 == 0 {
                return mouthPoints.min(by: { projection($0) < projection($1) })
            }
            return mouthPoints.max(by: { projection($0) < projection($1) })
        }()

        return features.map { original in
            var feature = original
            switch feature.region {
            case .leftBrow, .rightBrow:
                guard !feature.closed, feature.points.count >= 2, let bridge else { return feature }
                let first = feature.points[0], last = feature.points[feature.points.count - 1]
                // Store every brow outer-to-inner. route() enters at the inner
                // endpoint when another face feature precedes it.
                if distance(first, bridge) < distance(last, bridge) {
                    feature.points.reverse()
                }
            case .nose:
                guard !feature.closed, feature.points.count >= 2,
                      let target = leftEyeCenter.flatMap({ left in
                          rightEyeCenter.map { CGPoint(x: (left.x + $0.x) * 0.5, y: (left.y + $0.y) * 0.5) }
                      }) ?? bridge else { return feature }
                let first = feature.points[0], last = feature.points[feature.points.count - 1]
                // The eye-line end is the bridge; keep it as the route entry.
                if distance(last, target) < distance(first, target) {
                    feature.points.reverse()
                }
            case .leftEye, .rightEye:
                guard feature.closed, !feature.isPupil, let bridge else { return feature }
                feature.points = closedPathStartingNear(feature.points, anchor: bridge)
            case .mouth:
                guard feature.closed, let mouthCorner else { return feature }
                feature.points = closedPathStartingNear(feature.points, anchor: mouthCorner)
            default:
                break
            }
            return feature
        }
    }

    static func closedPathStartingNear(_ points: [CGPoint], anchor: CGPoint) -> [CGPoint] {
        guard points.count >= 4 else { return points }
        let unique = points.first == points.last ? Array(points.dropLast()) : points
        guard unique.count >= 3,
              let start = unique.indices.min(by: { distance(unique[$0], anchor) < distance(unique[$1], anchor) })
        else { return points }
        let rotated = Array(unique[start...]) + Array(unique[..<start])
        return rotated + [rotated[0]]
    }

    static func openPathStartingNear(_ points: [CGPoint], anchor: CGPoint) -> [CGPoint] {
        guard let first = points.first, let last = points.last else { return points }
        return distance(last, anchor) < distance(first, anchor) ? Array(points.reversed()) : points
    }

    static func openPathEndingNear(_ points: [CGPoint], anchor: CGPoint) -> [CGPoint] {
        guard let first = points.first, let last = points.last else { return points }
        return distance(first, anchor) < distance(last, anchor) ? Array(points.reversed()) : points
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
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
        preferNearbyBody: Bool = false,
        seed: Int
    ) -> [Component] {
        let faceItinerary = faceItinerary(face, variation: variation, seed: seed)
        let crowns = faceItinerary.filter { $0.isCrown && $0.points.count >= 2 }
        let faceWithoutCrown = faceItinerary.filter { !$0.isCrown }
        func attachCrown(to planned: [Component]) -> [Component] {
            guard !crowns.isEmpty else { return planned }
            var result = planned
            if let jawIndex = result.firstIndex(where: { $0.region == .jaw }) {
                result.insert(contentsOf: crowns, at: jawIndex + 1)
            } else {
                result.append(contentsOf: crowns)
            }
            return result
        }
        // Plan other parts first, then attach the scalp to its matching jaw
        // endpoint. Detail priority must not pull the crown into an eye or brow.
        var pool = faceWithoutCrown + body
        if let outline,
           !body.contains(where: { $0.region == outline.region && $0.points == outline.points }) {
            pool.append(outline)
        }
        pool = pool.filter { $0.points.count >= 2 }
        guard pool.count > 1 else { return attachCrown(to: pool) }

        let priority = CGFloat(max(0, min(1, detailPriority)))
        let clampedVariation = CGFloat(max(0, min(1, variation)))
        let travelWeight = 0.08 + clampedVariation * 0.5
        let allPoints = pool.flatMap(\.points)
        let bounds = allPoints.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let scale = max(8, max(bounds.width, bounds.height))
        var random = PortraitPRNG(seed: seed &+ 0x6B)
        let initialJitter = (0..<max(1, faceWithoutCrown.count)).map { _ in random.unit() }

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
        let faceCount = min(faceWithoutCrown.count, pool.count)
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
                    let bodyTransition = preferNearbyBody &&
                        (isArticulatedBodyRegion(current.region) || isArticulatedBodyRegion(candidate.region)
                         || current.region == .bodyHull || candidate.region == .bodyHull
                         || current.region == .contour || candidate.region == .contour)
                    let handJumpPenalty: CGFloat = !shouldBridge(current, candidate) ? 4 : 0
                    return travel * (bodyTransition ? max(0.55, travelWeight) : travelWeight)
                        + (1 - affinity) * (bodyTransition ? 0.12 : 0.28)
                        + silhouettePenalty
                        + handJumpPenalty
                        - priority * detail * 0.22
                        + seededJitter
                }
                return score(pool[lhs], jitter: candidateJitter[lhs])
                    < score(pool[rhs], jitter: candidateJitter[rhs])
            } ?? 0
            route.append(pool.remove(at: nextIndex))
            candidateJitter.remove(at: nextIndex)
        }
        return attachCrown(to: route)
    }

    private static func canonicalFaceOrder(_ features: [Component]) -> [Component] {
        let order: [LandmarkRegion] = [
            .leftBrow, .leftEye, .nose, .rightEye, .rightBrow, .jaw, .mouth
        ]
        let byRegion = Dictionary(grouping: features, by: \.region)
        var result = order.flatMap { byRegion[$0] ?? [] }
        let crowns = features.filter(\.isCrown)
        if let jawIndex = result.firstIndex(where: { $0.region == .jaw }) {
            result.insert(contentsOf: crowns, at: jawIndex + 1)
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
        let target = max(1, min(16, requestedCount))
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
        if (lhs.isCrown || rhs.isCrown) && pair.contains(.jaw) { return 0.97 }
        if lhs.isCrown || rhs.isCrown { return 0.5 }
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
        maximumCount: Int = 160,
        seed: Int
    ) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        let clamped = CGFloat(max(0, min(1, variation)))
        let sourceRatio = CGFloat(max(0.05, min(4, subsample)))
        if sourceRatio > 1.001 {
            let unique = closed && points.first == points.last ? Array(points.dropLast()) : points
            guard unique.count >= 2 else { return points }
            let segments = closed ? unique.count : unique.count - 1
            let subdivisions = max(1, min(4, Int(sourceRatio.rounded(.up))))
            var dense: [CGPoint] = []
            dense.reserveCapacity(min(maximumCount, segments * subdivisions + 1))
            for index in 0..<segments {
                let from = unique[index], to = unique[(index + 1) % unique.count]
                for step in 0..<subdivisions {
                    let t = CGFloat(step) / CGFloat(subdivisions)
                    dense.append(CGPoint(x: from.x + (to.x - from.x) * t,
                                         y: from.y + (to.y - from.y) * t))
                }
            }
            if closed { dense.append(dense[0]) } else { dense.append(unique[unique.count - 1]) }
            return uniformlySample(dense, maximumCount: maximumCount)
        }
        guard clamped > 0.001 || sourceRatio < 0.999 else {
            return uniformlySample(points, maximumCount: maximumCount)
        }

        var random = PortraitPRNG(seed: seed)
        let unique = closed && points.first == points.last ? Array(points.dropLast()) : points
        guard unique.count >= (closed ? 3 : 2) else { return points }
        let ratio = sourceRatio * (0.98 - clamped * 0.5 + (random.unit() - 0.5) * clamped * 0.18)
        let proposed = Int((CGFloat(unique.count) * ratio).rounded())
        let minimum = closed ? max(3, minimumCount) : max(2, minimumCount)
        let target = min(unique.count, maximumCount, max(minimum, proposed))

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

    /// A scalp arc between the two ends of Vision's open face contour (the
    /// cheek/ear junctions). The face frame moves those anchors with head roll
    /// and yaw; the person contour can lend shape without owning the position.
    static func hairComponent(
        from groups: [MappedGroup],
        style: PortraitHairStyle,
        amount: Float,
        seed: Int,
        expansion: Float = 0,
        hairdo: PortraitHairdo = .rounded
    ) -> Component? {
        let faceRegions: Set<LandmarkRegion> = [
            .jaw, .nose, .mouth, .leftBrow, .rightBrow, .leftEye, .rightEye
        ]
        let faceGroups = groups.filter { faceRegions.contains($0.region) }
        let facePoints = faceGroups.flatMap(\.points)
        guard facePoints.count >= 3 else { return nil }

        func center(of regions: Set<LandmarkRegion>) -> CGPoint? {
            let points = faceGroups.filter { regions.contains($0.region) }.flatMap(\.points)
            guard !points.isEmpty else { return nil }
            let sum = points.reduce(CGPoint.zero) { partial, point in
                CGPoint(x: partial.x + point.x, y: partial.y + point.y)
            }
            return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
        }

        let jaw = faceGroups.first { $0.region == .jaw && $0.points.count >= 3 }
        let jawEnds = jaw.flatMap { group -> (CGPoint, CGPoint)? in
            guard let first = group.points.first, let last = group.points.last else { return nil }
            return (first, last)
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
        } else if let jawEnds {
            axisDelta = CGPoint(x: jawEnds.1.x - jawEnds.0.x, y: jawEnds.1.y - jawEnds.0.y)
        } else {
            axisDelta = CGPoint(x: 1, y: 0)
        }
        let axisLength = max(0.001, hypot(axisDelta.x, axisDelta.y))
        let across = CGPoint(x: axisDelta.x / axisLength, y: axisDelta.y / axisLength)
        let perpendicular = CGPoint(x: -across.y, y: across.x)
        let roughEarMiddle = jawEnds.map {
            CGPoint(x: ($0.0.x + $0.1.x) * 0.5, y: ($0.0.y + $0.1.y) * 0.5)
        }
        let lowerDirection = lowerCenter.flatMap { lower -> CGPoint? in
            guard let reference = upperCenter ?? roughEarMiddle else { return nil }
            return CGPoint(x: lower.x - reference.x, y: lower.y - reference.y)
        }
        let down: CGPoint
        if let lowerDirection, lowerDirection.x * perpendicular.x + lowerDirection.y * perpendicular.y < 0 {
            down = CGPoint(x: -perpendicular.x, y: -perpendicular.y)
        } else {
            down = perpendicular
        }
        let up = CGPoint(x: -down.x, y: -down.y)
        let origin = roughEarMiddle ?? upperCenter ?? facePoints[0]
        let projected = facePoints.map { point in
            let offset = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            return (across: offset.x * across.x + offset.y * across.y,
                    down: offset.x * down.x + offset.y * down.y)
        }
        let faceWidth = (projected.map(\.across).max() ?? 0) - (projected.map(\.across).min() ?? 0)
        let faceHeight = (projected.map(\.down).max() ?? 0) - (projected.map(\.down).min() ?? 0)
        guard faceWidth > 8, faceHeight > 8 else { return nil }
        let faceScale = max(12, faceWidth, faceHeight)

        // Hair fill is intentionally allowed above the slider's old 0...1
        // range. The first unit preserves the previous density; additional
        // units add samples without changing the face-proportional scalp.
        let clamped = CGFloat(max(0, min(20, amount)))
        let fallbackSpan = max(axisLength * 1.4, faceWidth * 0.86)
        let fallbackMiddle = CGPoint(
            x: (upperCenter ?? origin).x + down.x * faceHeight * 0.08,
            y: (upperCenter ?? origin).y + down.y * faceHeight * 0.08
        )
        let fallbackLeft = CGPoint(x: fallbackMiddle.x - across.x * fallbackSpan * 0.5,
                                   y: fallbackMiddle.y - across.y * fallbackSpan * 0.5)
        let fallbackRight = CGPoint(x: fallbackMiddle.x + across.x * fallbackSpan * 0.5,
                                    y: fallbackMiddle.y + across.y * fallbackSpan * 0.5)
        let earPair = jawEnds ?? (fallbackLeft, fallbackRight)
        let earDelta = CGPoint(x: earPair.1.x - earPair.0.x, y: earPair.1.y - earPair.0.y)
        let ordered = earDelta.x * across.x + earDelta.y * across.y >= 0
            ? earPair : (earPair.1, earPair.0)
        let leftEar = ordered.0, rightEar = ordered.1
        let earMiddle = CGPoint(x: (leftEar.x + rightEar.x) * 0.5,
                                y: (leftEar.y + rightEar.y) * 0.5)
        let earSpan = max(8, abs((rightEar.x - leftEar.x) * across.x
                                 + (rightEar.y - leftEar.y) * across.y))
        let chinDepth = jaw?.points.map { point in
            (point.x - earMiddle.x) * down.x + (point.y - earMiddle.y) * down.y
        }.max() ?? faceHeight * 0.7
        let browRise = upperCenter.map { point in
            max(0, (point.x - earMiddle.x) * up.x + (point.y - earMiddle.y) * up.y)
        } ?? 0
        // A scalp occupies substantial space above the eyes. The old crown
        // rose only ~10% of face size and read as another brow.
        let geometricLift = max(earSpan * 0.44, chinDepth * 0.72,
                                browRise + faceScale * 0.28)
        // Hair amount controls fill density, not skull size. Keep the dome
        // linked to facial proportions and optional contour guidance.
        let lift = min(faceScale * 0.95, max(faceScale * 0.30, geometricLift * 0.98))
        // Read only the head-sized upper region of the person silhouette.
        // Its two side extents can widen the visible back of a turned head.
        let contour = groups.filter { $0.region == .contour }.max { $0.points.count < $1.points.count }
        let outlineSamples: [(side: CGFloat, rise: CGFloat)] = (contour?.points ?? []).compactMap { point in
            let dx = point.x - earMiddle.x, dy = point.y - earMiddle.y
            let side = dx * across.x + dy * across.y
            let rise = dx * up.x + dy * up.y
            guard abs(side) < faceScale * 0.85,
                  rise > lift * 0.2, rise < lift * 1.6 else { return nil }
            return (side, rise)
        }
        let contourTop = outlineSamples.map(\.rise).max() ?? 0
        let useContour = outlineSamples.count >= 5
            && contourTop > lift * 0.58 && contourTop < lift * 1.45
        let leftExcess = useContour
            ? max(0, -earSpan * 0.5 - (outlineSamples.map(\.side).min() ?? 0)) : 0
        let rightExcess = useContour
            ? max(0, (outlineSamples.map(\.side).max() ?? 0) - earSpan * 0.5) : 0
        let defaultExpansion = max(earSpan * 0.05, (faceWidth - earSpan) * 0.16)
        // The face-attached scalp stays independent of the person matte.
        // Any contour excess belongs to the outer hair mass and its ink
        // samples, never to this inner roof.
        let leftExpansion = min(faceScale * 0.22, defaultExpansion)
        let rightExpansion = min(faceScale * 0.22, defaultExpansion)
        let noseSide = center(of: [.nose]).map { point in
            (point.x - earMiddle.x) * across.x + (point.y - earMiddle.y) * across.y
        } ?? 0
        let skew = max(-faceScale * 0.12, min(faceScale * 0.12, -noseSide * 0.3))

        func dome(_ t: CGFloat) -> CGFloat {
            let turn = max(0, min(1, t + (skew / faceScale) * sin(.pi * t)))
            return sqrt(max(0, 1 - pow(2 * turn - 1, 2)))
        }
        func side(_ t: CGFloat) -> CGFloat {
            let expansion = t < 0.5 ? leftExpansion : rightExpansion
            return -expansion * 0.75 * sin(2 * .pi * t) + skew * sin(.pi * t)
        }
        func scalpPoint(_ t: CGFloat, rise: CGFloat) -> CGPoint {
            let base = CGPoint(x: leftEar.x + (rightEar.x - leftEar.x) * t,
                               y: leftEar.y + (rightEar.y - leftEar.y) * t)
            return CGPoint(x: base.x + across.x * side(t) + up.x * rise,
                           y: base.y + across.y * side(t) + up.y * rise)
        }
        let overhangLevel = CGFloat(max(0, min(2, expansion)))
        let partSide: CGFloat = seed.isMultiple(of: 2) ? 1 : -1
        func hairExtension(_ t: CGFloat, depth: CGFloat) -> CGPoint {
            let sideDistance = abs(2 * t - 1)
            let left = t < 0.5
            let silhouetteSide = (left ? leftExcess : rightExcess) * 0.55
            let shapeSide: CGFloat
            let shapeRise: CGFloat
            switch hairdo {
            case .rounded:
                shapeSide = 1
                shapeRise = 1
            case .swept:
                shapeSide = (left ? -partSide : partSide) > 0 ? 1.55 : 0.65
                shapeRise = 0.75
            case .shag:
                shapeSide = 1.45
                shapeRise = 0.55
            }
            let intrinsicSide: CGFloat = hairdo == .rounded ? 0 : faceScale * 0.045
            let endpointTaper = pow(max(0, sin(.pi * t)), 0.45)
            let lateral = (overhangLevel * faceScale * 0.28 * shapeSide
                           + silhouetteSide + intrinsicSide)
                * pow(sideDistance, 0.68) * endpointTaper
                * (0.38 + 0.62 * depth * depth)
            let lateralSign: CGFloat = left ? -1 : 1
            // Keep crown growth modest; most of the added mass sits around
            // the temples and can overlap the outer half of the ears.
            let rise = overhangLevel * faceScale * 0.11 * shapeRise
                * dome(t) * pow(depth, 3)
            return CGPoint(x: across.x * lateral * lateralSign + up.x * rise,
                           y: across.y * lateral * lateralSign + up.y * rise)
        }
        func hairPoint(_ t: CGFloat, depth: CGFloat) -> CGPoint {
            let roofRise = lift * dome(t)
            let browClearance = browRise + faceScale * 0.07
            let minimumRise = min(roofRise * 0.94, max(roofRise * 0.42, browClearance))
            let base = scalpPoint(t, rise: max(minimumRise, roofRise * depth))
            let extra = hairExtension(t, depth: depth)
            return CGPoint(x: base.x + extra.x, y: base.y + extra.y)
        }

        // The contour's upper envelope lends broad shape, within a bounded
        // range. The face tracker still owns the exact ear endpoints.
        let count = 16
        let unsmoothed: [CGFloat] = (0...count).map { index in
            guard index > 0, index < count else { return 0 }
            let t = CGFloat(index) / CGFloat(count)
            let ideal = lift * dome(t)
            guard useContour else { return ideal }
            let target = (scalpPoint(t, rise: 0).x - earMiddle.x) * across.x
                + (scalpPoint(t, rise: 0).y - earMiddle.y) * across.y
            let nearby = outlineSamples.filter { abs($0.side - target) < max(8, faceScale * 0.075) }
            guard let observed = nearby.map(\.rise).max() else { return ideal }
            let bounded = max(ideal * 0.72, min(ideal * 1.3, observed))
            return ideal * 0.42 + bounded * 0.58
        }
        let outerHeights: [CGFloat] = unsmoothed.indices.map { index in
            guard index > 0, index < count else { return 0 }
            return unsmoothed[index - 1] * 0.18 + unsmoothed[index] * 0.64
                + unsmoothed[index + 1] * 0.18
        }
        var random = PortraitPRNG(seed: seed)
        let roof = (0...count).map { index -> CGPoint in
            guard index > 0, index < count else { return index == 0 ? leftEar : rightEar }
            let t = CGFloat(index) / CGFloat(count)
            return scalpPoint(t, rise: lift * dome(t))
        }
        let outerRoof = (0...count).map { index -> CGPoint in
            let t = CGFloat(index) / CGFloat(count)
            let extra = hairExtension(t, depth: 1)
            let silhouettePoint = scalpPoint(t, rise: outerHeights[index])
            return CGPoint(x: silhouettePoint.x + extra.x,
                           y: silhouettePoint.y + extra.y)
        }
        func along(_ contour: [CGPoint], _ t: CGFloat) -> CGPoint {
            let position = min(CGFloat(count), max(0, t * CGFloat(count)))
            let index = min(count - 1, Int(position))
            let blend = position - CGFloat(index)
            return CGPoint(x: contour[index].x * (1 - blend) + contour[index + 1].x * blend,
                           y: contour[index].y * (1 - blend) + contour[index + 1].y * blend)
        }
        func sampledHairPoint(_ t: CGFloat, depth: CGFloat) -> CGPoint {
            guard depth > 1 else { return hairPoint(t, depth: depth) }
            // The outer person contour is hair territory, not another hard
            // scalp line. Sample the band between the face-attached scalp and
            // that silhouette so Wild/Wrap/Hatch ink occupies the added mass.
            let inner = along(roof, t), outer = along(outerRoof, t)
            let blend = min(1, max(0, depth - 1))
            return CGPoint(x: inner.x * (1 - blend) + outer.x * blend,
                           y: inner.y * (1 - blend) + outer.y * blend)
        }
        let points: [CGPoint]
        switch style {
        case .clean:
            points = roof
        case .wild, .wrap, .hatch, .hatchVertical:
            // Always draw the scalp arc first so dense hair supplements the
            // head shape instead of replacing it. The route then fills the
            // cap and returns to the far ear, keeping both face anchors.
            // Preserve the established 0...4 look, then grow more gently at
            // high densities so a 20x fill does not flood the live pipeline.
            let sampleCount = 32 + Int((min(clamped, 1) * 100
                + max(0, min(clamped, 4) - 1) * 220
                + max(0, clamped - 4) * 80).rounded())
            var interior = (0..<sampleCount).map { _ -> (t: CGFloat, depth: CGFloat) in
                let t = 0.045 + random.unit() * 0.91
                // Keep the low edge of the fill well above the brow shelf.
                let depth = 0.42 + random.unit() * 0.52
                return (t, depth)
            }
            if useContour || overhangLevel > 0 || hairdo != .rounded {
                let shellCount = max(16, sampleCount / 3)
                interior += (0..<shellCount).map { index -> (t: CGFloat, depth: CGFloat) in
                    let t = 0.025 + (CGFloat(index) + random.unit() * 0.65)
                        / CGFloat(shellCount) * 0.95
                    return (min(0.975, t), 1.12 + random.unit() * 0.86)
                }
            }

            // The seed chooses a route once in normalized scalp coordinates.
            // Routing in live screen pixels made nearly equidistant samples
            // exchange neighbors as the head moved, visibly shuffling Wild
            // and Wrap every frame while Hatch stayed stable.
            func stableHairWalk() -> [CGPoint] {
                let reference = [CGPoint(x: 1, y: 0.42)] + interior.map {
                    CGPoint(x: $0.t, y: $0.depth * 0.55)
                }
                return WrapDrawing.nearestNeighborIndices(reference).map { index in
                    index == 0 ? rightEar : sampledHairPoint(interior[index - 1].t,
                                                              depth: interior[index - 1].depth)
                }
            }

            let fill: [CGPoint]
            switch style {
            case .clean:
                fill = []
            case .wild:
                // Loose proximity walk with occasional hand-drawn flicks.
                let ordered = stableHairWalk()
                var walk: [CGPoint] = []
                walk.reserveCapacity(ordered.count + sampleCount / 7 * 3 + 1)
                for (index, point) in ordered.enumerated() {
                    walk.append(point)
                    guard index > 0, index.isMultiple(of: 7) else { continue }
                    let radius = min(faceScale * 0.017, lift * 0.038)
                    walk.append(CGPoint(x: point.x + across.x * radius + up.x * radius,
                                        y: point.y + across.y * radius + up.y * radius))
                    walk.append(CGPoint(x: point.x - across.x * radius + up.x * radius,
                                        y: point.y - across.y * radius + up.y * radius))
                    walk.append(point)
                }
                walk.append(rightEar)
                fill = walk
            case .wrap:
                // A tighter linewalk: sample the whole cap, then interrupt
                // the proximity route with angular wraps around selected
                // anchors rather than adding the same repeated curl everywhere.
                let ordered = stableHairWalk()
                var walk: [CGPoint] = []
                walk.reserveCapacity(ordered.count + sampleCount / 5 * 4 + 1)
                for (index, point) in ordered.enumerated() {
                    walk.append(point)
                    guard index > 0, index.isMultiple(of: 5) else { continue }
                    let radius = min(faceScale * 0.024, lift * 0.052)
                    let offsets: [(CGFloat, CGFloat)] = [(1, 0), (0, 1), (-1, 0), (0, -1), (1, 0)]
                    for (x, y) in offsets {
                        walk.append(CGPoint(x: point.x + across.x * radius * x + up.x * radius * y,
                                            y: point.y + across.y * radius * x + up.y * radius * y))
                    }
                }
                walk.append(rightEar)
                fill = walk
            case .hatch:
                // Alternating, gently irregular temple-to-temple passes form
                // a comb/hatching texture. An even row count ends at the right
                // ear, so the fill flows back into the face contour cleanly.
                let rows = 6 + Int((clamped * 2).rounded())
                let stepsPerRow = max(5, min(24, sampleCount / rows))
                var walk: [CGPoint] = [rightEar]
                walk.reserveCapacity(rows * (stepsPerRow + 1) + 1)
                for row in 0..<rows {
                    let outerDepth: CGFloat = useContour || overhangLevel > 0 || hairdo != .rounded ? 1.85 : 0.94
                    let depth = 0.42 + (outerDepth - 0.42) * CGFloat(row) / CGFloat(max(1, rows - 1))
                    for step in 0...stepsPerRow {
                        let progress = CGFloat(step) / CGFloat(stepsPerRow)
                        let t = row.isMultiple(of: 2) ? 0.96 - progress * 0.92 : 0.04 + progress * 0.92
                        let jitter = (random.unit() - 0.5) * 0.025
                        walk.append(sampledHairPoint(t, depth: min(1.85, max(0.05, depth + jitter))))
                    }
                }
                walk.append(rightEar)
                fill = walk
            case .hatchVertical:
                // Lean each alternating pass across the cap. The serpentine
                // route now traces diagonal zigzags rather than a square wave
                // of vertical strokes with flat connectors at its ends.
                let columns = 6 + Int((clamped * 2).rounded())
                let stepsPerColumn = max(6, min(24, sampleCount / columns))
                var walk: [CGPoint] = [rightEar]
                walk.reserveCapacity(columns * (stepsPerColumn + 1) + 1)
                for column in 0..<columns {
                    let position = CGFloat(column) / CGFloat(max(1, columns - 1))
                    let baseT = 0.96 - position * 0.92
                    let lean = min(0.12, 0.035 + clamped * 0.012)
                    let drift = (random.unit() - 0.5) * 0.012
                    let outerDepth: CGFloat = useContour || overhangLevel > 0 || hairdo != .rounded ? 1.85 : 0.94
                    for step in 0...stepsPerColumn {
                        let progress = CGFloat(step) / CGFloat(stepsPerColumn)
                        let t = min(0.97, max(0.03, baseT + drift + (progress - 0.5) * lean))
                        let depth = column.isMultiple(of: 2)
                            ? 0.42 + progress * (outerDepth - 0.42)
                            : outerDepth - progress * (outerDepth - 0.42)
                        walk.append(sampledHairPoint(t, depth: depth))
                    }
                }
                walk.append(rightEar)
                fill = walk
            }
            points = roof + fill
        }
        let sideLength: CGFloat = hairdo == .shag ? 0.42 : (hairdo == .swept ? 0.30 : 0.19)
        let lockLength = faceScale * sideLength * min(1.2, 0.48 + overhangLevel * 0.38)
        let lockWidth = faceScale * min(0.13, 0.045 + overhangLevel * 0.045)
        let sideFills: [[CGPoint]] = [-1.0, 1.0].map { sign in
            let ear = sign < 0 ? leftEar : rightEar
            func at(_ outward: CGFloat, _ down: CGFloat) -> CGPoint {
                CGPoint(x: ear.x + across.x * outward * sign - up.x * down,
                        y: ear.y + across.y * outward * sign - up.y * down)
            }
            return [at(0, -faceScale * 0.06), at(lockWidth * 0.72, -faceScale * 0.05),
                    at(lockWidth, lockLength * 0.40), at(lockWidth * 0.48, lockLength),
                    at(lockWidth * 0.12, lockLength * 0.66), at(0, 0)]
        }
        return Component(region: .head, points: points, closed: false,
                         handedness: .unknown, isCrown: true,
                         hairFillOutline: outerRoof, hairSideFills: sideFills,
                         scalpApex: roof[8])
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
struct PortraitPRNG {
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
