import CoreGraphics
import Foundation

/// "Taking a line for a walk." Plans one or more continuous polylines through
/// landmark features and perturbs them, in the spirit of Klee / William Ngan —
/// the line as a moving point modulated by noise and oscillation. Pure
/// geometry, deterministic from `seed`; curve fitting and stroke styling happen
/// in the render layer.
///
/// Pipeline: extract features (edge components → ordered polylines) → sample
/// each (density, curvature-biased) → partition into K paths (continuity) →
/// tour each group into one polyline → perturb (2D wildness × scale).
///
/// Continuity = 1 with zero wildness reproduces the original unicursal line.
public enum LineWalk {
    /// One structural shape (typically one landmark region): points + the edge
    /// chains over them, plus an opaque caller `tag` carried to output vertices.
    public struct Shape: Sendable {
        public var points: [CGPoint]
        public var edges: [(Int, Int)]
        public var tag: Int

        public init(points: [CGPoint], edges: [(Int, Int)], tag: Int) {
            self.points = points
            self.edges = edges
            self.tag = tag
        }
    }

    /// One vertex of a path. `featureIndex` increments per source feature within
    /// the path; `tag` is the source shape's tag.
    public struct Vertex: Equatable, Sendable {
        public var point: CGPoint
        public var featureIndex: Int
        public var tag: Int

        public init(point: CGPoint, featureIndex: Int, tag: Int) {
            self.point = point
            self.featureIndex = featureIndex
            self.tag = tag
        }
    }

    /// Builds the drawing as an array of continuous paths.
    /// - density: 0 = minimal (few points) → 1 = dense + subdivided.
    /// - continuity: 1 = one continuous line → 0 = many disjoint paths /
    ///   fragmented segments.
    /// - wildnessAlong / wildnessOrtho: perturbation amplitude along the path
    ///   tangent and orthogonal to it (the XY pad).
    /// - scale: wildness frequency, 0 = local (fine) → 1 = global (coarse).
    public static func build(
        shapes: [Shape],
        density: Float,
        continuity: Float,
        wildnessAlong: Float,
        wildnessOrtho: Float,
        scale: Float,
        seed: Int
    ) -> [[Vertex]] {
        let d = clamp01(density)
        var features = shapes.flatMap { extractFeatures(from: $0) }
        if d < 0.25 {
            features = features.filter { $0.points.count > 1 }
        }
        let sampled = features
            .map { sample(feature: $0, density: d, seed: seed) }
            .filter { !$0.points.isEmpty }
        guard !sampled.isEmpty else { return [] }

        let frag = clamp01(1 - continuity)
        let groups = partition(sampled, fragmentation: frag)

        var paths: [[Vertex]] = []
        for (groupIndex, group) in groups.enumerated() {
            let groupFeatures = group.map { sampled[$0] }
            let order = tour(features: groupFeatures, seed: seed &+ groupIndex &* 17)
            let stitched = stitch(features: groupFeatures, order: order)
            let walked = perturb(
                stitched,
                along: wildnessAlong, ortho: wildnessOrtho, scale: scale,
                seed: seed &+ groupIndex &* 9173
            )
            if frag > 0.85 {
                paths.append(contentsOf: fragment(walked, fragmentation: frag))
            } else {
                paths.append(walked)
            }
        }
        return paths.filter { !$0.isEmpty }
    }

    // MARK: - Features

    struct Feature {
        var points: [CGPoint]
        var tag: Int
        var isLoop: Bool
    }

    /// Splits a shape into ordered polylines, one per connected component of
    /// its edge graph (isolated points become singletons).
    static func extractFeatures(from shape: Shape) -> [Feature] {
        let n = shape.points.count
        guard n > 0 else { return [] }

        var adjacency = Array(repeating: Set<Int>(), count: n)
        for (a, b) in shape.edges where a != b && a >= 0 && a < n && b >= 0 && b < n {
            adjacency[a].insert(b)
            adjacency[b].insert(a)
        }

        var visited = Array(repeating: false, count: n)
        var features: [Feature] = []
        for start in 0..<n where !visited[start] {
            var component: [Int] = []
            var queue = [start]
            visited[start] = true
            while let v = queue.popLast() {
                component.append(v)
                for neighbor in adjacency[v] where !visited[neighbor] {
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }
            if component.count == 1 {
                features.append(Feature(points: [shape.points[start]], tag: shape.tag, isLoop: false))
                continue
            }
            let (order, isLoop) = orderComponent(component, adjacency: adjacency)
            features.append(Feature(points: order.map { shape.points[$0] }, tag: shape.tag, isLoop: isLoop))
        }
        return features
    }

    /// Orders a component into a polyline. Paths walk endpoint→endpoint; cycles
    /// walk around (isLoop); branching graphs get a DFS Euler walk.
    static func orderComponent(_ component: [Int], adjacency: [Set<Int>]) -> (order: [Int], isLoop: Bool) {
        let inComponent = Set(component)
        let maxDegree = component.map { adjacency[$0].count }.max() ?? 0
        let endpoints = component.filter { adjacency[$0].count == 1 }.sorted()

        if maxDegree > 2 {
            let start = endpoints.first ?? component.min() ?? component[0]
            return (eulerWalk(from: start, adjacency: adjacency, inComponent: inComponent), false)
        }

        let isLoop = endpoints.isEmpty
        let start = endpoints.first ?? component.min() ?? component[0]
        var order: [Int] = [start]
        var seen: Set<Int> = [start]
        var current = start
        while order.count < component.count {
            guard let next = adjacency[current].sorted().first(where: { !seen.contains($0) }) else { break }
            order.append(next)
            seen.insert(next)
            current = next
        }
        return (order, isLoop)
    }

    private static func eulerWalk(from start: Int, adjacency: [Set<Int>], inComponent: Set<Int>) -> [Int] {
        var order: [Int] = []
        var visited = Set<Int>()
        func visit(_ v: Int) {
            visited.insert(v)
            order.append(v)
            for neighbor in adjacency[v].sorted() where inComponent.contains(neighbor) && !visited.contains(neighbor) {
                visit(neighbor)
                order.append(v)
            }
        }
        visit(start)
        return order
    }

    // MARK: - Sampling

    /// Curvature-biased, density-driven resample. Endpoints and high-curvature
    /// vertices survive to low density; high density subdivides.
    static func sample(feature: Feature, density d: Float, seed: Int) -> Feature {
        let pts = feature.points
        let n = pts.count
        guard n > 1 else { return feature }

        let minKeep = feature.isLoop ? min(4, n) : 2
        let frac = clamp01(d * 1.4)
        let targetKeep = max(minKeep, min(n, Int((Float(n) * frac).rounded())))
        let kept = curvatureBiasedSelect(pts, target: targetKeep, isLoop: feature.isLoop, tag: feature.tag, seed: seed)

        let subdivisions = d > 0.7 ? Int((((d - 0.7) / 0.3) * 2).rounded()) : 0
        let finalPoints = subdivisions > 0 ? catmullRom(kept, isLoop: feature.isLoop, subdivisions: subdivisions) : kept
        return Feature(points: finalPoints, tag: feature.tag, isLoop: feature.isLoop)
    }

    static func curvatureBiasedSelect(_ pts: [CGPoint], target: Int, isLoop: Bool, tag: Int, seed: Int) -> [CGPoint] {
        let n = pts.count
        guard target < n else { return pts }
        guard target >= 2 else { return [pts[0]] }

        var importance = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if !isLoop && (i == 0 || i == n - 1) {
                importance[i] = .greatestFiniteMagnitude
                continue
            }
            let prev = pts[(i - 1 + n) % n]
            let next = pts[(i + 1) % n]
            importance[i] = turning(prev, pts[i], next) + noise(seed, tag &* 131 &+ i) * 0.05
        }
        let chosen = (0..<n).sorted { importance[$0] > importance[$1] }
            .prefix(target)
            .sorted()
        return chosen.map { pts[$0] }
    }

    private static func turning(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
        let v1 = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let m1 = hypot(v1.x, v1.y), m2 = hypot(v2.x, v2.y)
        guard m1 > 1e-6, m2 > 1e-6 else { return 0 }
        let cosA = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / (m1 * m2)))
        return Double(acos(cosA))
    }

    static func catmullRom(_ pts: [CGPoint], isLoop: Bool, subdivisions: Int) -> [CGPoint] {
        let n = pts.count
        guard n >= 3, subdivisions > 0 else { return pts }
        var out: [CGPoint] = []
        let segments = isLoop ? n : n - 1
        for i in 0..<segments {
            let p0 = pts[(i - 1 + n) % n]
            let p1 = pts[i % n]
            let p2 = pts[(i + 1) % n]
            let p3 = pts[(i + 2) % n]
            out.append(p1)
            for s in 1...subdivisions {
                let t = CGFloat(s) / CGFloat(subdivisions + 1)
                out.append(catmull(p0, p1, p2, p3, t))
            }
        }
        if !isLoop { out.append(pts[n - 1]) }
        return out
    }

    private static func catmull(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ dd: CGFloat) -> CGFloat {
            0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - dd) * t2 + (-a + 3 * b - 3 * c + dd) * t3)
        }
        return CGPoint(x: axis(p0.x, p1.x, p2.x, p3.x), y: axis(p0.y, p1.y, p2.y, p3.y))
    }

    // MARK: - Partition (continuity)

    /// Groups feature indices into K paths. `fragmentation` = 1 - continuity:
    /// 0 → one path (all features), 1 → each feature its own path. Greedy
    /// agglomerative clustering by centroid keeps each path spatially coherent.
    static func partition(_ features: [Feature], fragmentation frag: Float) -> [[Int]] {
        let n = features.count
        guard n > 1, frag > 0.001 else { return [Array(0..<n)] }
        let k = max(1, min(n, Int((Double(n - 1) * Double(frag)).rounded()) + 1))
        guard k < n else { return (0..<n).map { [$0] } }

        let centroids = features.map { centroid(of: $0.points) }
        var groups = (0..<n).map { [$0] }
        func groupCentroid(_ g: [Int]) -> CGPoint { centroid(of: g.map { centroids[$0] }) }
        while groups.count > k {
            var bestI = 0, bestJ = 1
            var bestDist = CGFloat.greatestFiniteMagnitude
            for i in 0..<groups.count {
                let ci = groupCentroid(groups[i])
                for j in (i + 1)..<groups.count {
                    let dd = distanceSquared(ci, groupCentroid(groups[j]))
                    if dd < bestDist { bestDist = dd; bestI = i; bestJ = j }
                }
            }
            groups[bestI].append(contentsOf: groups[bestJ])
            groups.remove(at: bestJ)
        }
        return groups
    }

    /// At very high fragmentation, breaks a path into short disconnected pieces.
    static func fragment(_ path: [Vertex], fragmentation frag: Float) -> [[Vertex]] {
        guard frag > 0.85, path.count > 3 else { return [path] }
        let t = Double((frag - 0.85) / 0.15)   // 0…1 across the top band
        let chunk = max(2, Int((Double(path.count) * (1 - t)).rounded()))
        guard chunk < path.count else { return [path] }
        var pieces: [[Vertex]] = []
        var i = 0
        while i < path.count {
            let end = min(i + chunk, path.count)
            pieces.append(Array(path[i..<end]))
            i = end
        }
        return pieces
    }

    // MARK: - Tour

    static func tour(features: [Feature], seed: Int) -> [Int] {
        let count = features.count
        guard count > 1 else { return Array(0..<count) }
        let centroids = features.map { centroid(of: $0.points) }
        var rng = SeededRNG(seed: seed)
        var visited = Array(repeating: false, count: count)
        let start = rng.nextInt(below: count)
        visited[start] = true
        var order = [start]
        var current = centroids[start]
        while order.count < count {
            let remaining = (0..<count).filter { !visited[$0] }
            let next = remaining.min { distanceSquared(centroids[$0], current) < distanceSquared(centroids[$1], current) }!
            visited[next] = true
            order.append(next)
            current = centroids[next]
        }
        return order
    }

    // MARK: - Stitch

    static func stitch(features: [Feature], order: [Int]) -> [Vertex] {
        var out: [Vertex] = []
        var exit: CGPoint?
        for (position, featureIndex) in order.enumerated() {
            var pts = features[featureIndex].points
            if let exit, pts.count > 1 {
                if distanceSquared(pts.last!, exit) < distanceSquared(pts.first!, exit) { pts.reverse() }
            }
            let tag = features[featureIndex].tag
            for point in pts {
                out.append(Vertex(point: point, featureIndex: position, tag: tag))
            }
            exit = pts.last
        }
        return out
    }

    // MARK: - Perturb (2D wildness)

    /// Displaces a path by seeded 1D value noise: orthogonal (waviness/zigzag)
    /// and tangential (bunching) components, faded to zero at the path ends.
    /// `scale` sets the noise frequency (local fine → global coarse). Zero
    /// wildness returns the path unchanged.
    static func perturb(_ path: [Vertex], along: Float, ortho: Float, scale: Float, seed: Int) -> [Vertex] {
        guard along > 0 || ortho > 0, path.count >= 2 else { return path }
        let pts = path.map(\.point)
        let diag = boundingDiagonal(pts)
        guard diag > 1 else { return path }

        let spacing = max(3, diag * Double(lerp(0.015, 0.05, scale)))
        let resampled = resampleUniform(path, spacing: spacing)
        guard resampled.count >= 2 else { return path }

        let kfreq = Double(lerp(0.06, 0.008, scale))   // cycles per pixel of arc
        let ampOrtho = Double(ortho) * diag * 0.10
        let ampAlong = Double(along) * diag * 0.06
        let total = max(1, Double(resampled.count - 1))

        var arc = 0.0
        var out: [Vertex] = []
        out.reserveCapacity(resampled.count)
        for k in 0..<resampled.count {
            let v = resampled[k]
            let prev = resampled[max(0, k - 1)].point
            let next = resampled[min(resampled.count - 1, k + 1)].point
            if k > 0 { arc += Double(hypot(v.point.x - prev.x, v.point.y - prev.y)) }

            var tx = Double(next.x - prev.x), ty = Double(next.y - prev.y)
            let tm = (tx * tx + ty * ty).squareRoot()
            if tm > 1e-6 { tx /= tm; ty /= tm } else { tx = 1; ty = 0 }
            let nx = -ty, ny = tx

            // Fade to zero over the first/last 10% so path ends stay anchored.
            let t = Double(k) / total
            let envelope = min(1, min(t, 1 - t) / 0.1)

            let dispO = valueNoise1D(arc * kfreq, seed, 0x5151) * ampOrtho * envelope
            let dispA = valueNoise1D(arc * kfreq, seed, 0x2727) * ampAlong * envelope
            out.append(Vertex(
                point: CGPoint(x: v.point.x + CGFloat(nx * dispO + tx * dispA),
                               y: v.point.y + CGFloat(ny * dispO + ty * dispA)),
                featureIndex: v.featureIndex,
                tag: v.tag
            ))
        }
        return out
    }

    /// Arc-length-uniform resample carrying each sample's nearest source
    /// feature index / tag.
    static func resampleUniform(_ path: [Vertex], spacing: Double) -> [Vertex] {
        guard path.count >= 2, spacing > 0 else { return path }
        var out: [Vertex] = [path[0]]
        var carry = 0.0
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i]
            let segLen = Double(hypot(b.point.x - a.point.x, b.point.y - a.point.y))
            guard segLen > 1e-6 else { continue }
            var dist = carry
            while dist + spacing <= segLen {
                dist += spacing
                let f = CGFloat(dist / segLen)
                let p = CGPoint(x: a.point.x + (b.point.x - a.point.x) * f,
                                y: a.point.y + (b.point.y - a.point.y) * f)
                let nearer = f < 0.5 ? a : b
                out.append(Vertex(point: p, featureIndex: nearer.featureIndex, tag: nearer.tag))
            }
            carry = (dist + spacing) - segLen
        }
        if out.last?.point != path.last?.point { out.append(path[path.count - 1]) }
        return out
    }

    // MARK: - Noise

    /// 1D value noise in [-1, 1] from the integer hash, smoothstep-interpolated.
    public static func valueNoise1D(_ x: Double, _ seedA: Int, _ seedB: Int) -> Double {
        let xi = x.rounded(.down)
        let f = x - xi
        let i = Int(xi)
        let h0 = noise(i, seedA ^ seedB)
        let h1 = noise(i + 1, seedA ^ seedB)
        let u = f * f * (3 - 2 * f)
        return (h0 + (h1 - h0) * u) * 2 - 1
    }

    /// Deterministic [0,1) hash of two integers (no sequential state).
    public static func noise(_ a: Int, _ b: Int) -> Double {
        var v = UInt64(bitPattern: Int64(a &* 0x1_0000_01B3)) ^ (UInt64(bitPattern: Int64(b)) &* 0x9E37_79B9_7F4A_7C15)
        v ^= v >> 33
        v &*= 0xff51_afd7_ed55_8ccd
        v ^= v >> 33
        v &*= 0xc4ce_b9fe_1a85_ec53
        v ^= v >> 33
        return Double(v >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    // MARK: - Helpers

    private static func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private static func boundingDiagonal(_ points: [CGPoint]) -> Double {
        guard let first = points.first else { return 0 }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return Double(hypot(maxX - minX, maxY - minY))
    }

    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private static func clamp01(_ v: Float) -> Float { min(1, max(0, v)) }

    private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * clamp01(t) }
}

/// Small splitmix64 PRNG — deterministic from an Int seed.
struct SeededRNG {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextInt(below n: Int) -> Int {
        n <= 0 ? 0 : Int(next() % UInt64(n))
    }
}
