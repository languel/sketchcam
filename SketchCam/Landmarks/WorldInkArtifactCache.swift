import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SketchCamCore

/// Sparse, LOD-aware world raster for accumulated ink artifacts. The fluid
/// solver stays viewport-bounded; settled output is materialized into 512px
/// world tiles and is therefore frozen while offscreen.
final class WorldInkArtifactCache {
    private struct TileKey: Hashable {
        var level: Int
        var x: Int
        var y: Int
    }

    private struct Tile {
        var image: CGImage
        var lastAccess: UInt64
    }

    private let context: CIContext
    private let tileSize = WorldTileLayout.pixelSize
    private let maximumResidentTiles = 256
    private var tiles: [TileKey: Tile] = [:]
    private var backedKeys: Set<TileKey> = []
    private let backingURL: URL
    private var accessCounter: UInt64 = 0
    private(set) var baseDensity: CGFloat

    init(context: CIContext = CIContext(options: [.cacheIntermediates: false]), baseDensity: CGFloat = 1080) {
        self.context = context
        self.baseDensity = max(1, baseDensity)
        backingURL = FileManager.default.temporaryDirectory.appendingPathComponent("SketchCamTiles-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: backingURL, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: backingURL) }

    func resetBaseDensity(_ value: CGFloat) {
        guard tiles.isEmpty else { return }
        baseDensity = max(1, value)
    }

    func clear() {
        tiles.removeAll(keepingCapacity: true); backedKeys.removeAll(keepingCapacity: true)
        try? FileManager.default.removeItem(at: backingURL)
        try? FileManager.default.createDirectory(at: backingURL, withIntermediateDirectories: true)
    }

    func commit(_ viewportImage: CIImage, camera: CanvasCamera, outputSize: CGSize) {
        guard outputSize.width > 0, outputSize.height > 0 else { return }
        let density = outputSize.height / max(0.000_001, camera.viewHeight)
        let level = WorldTileLayout.level(forPixelsPerWorldUnit: density, baseDensity: baseDensity)
        let levelDensity = baseDensity * pow(2, CGFloat(level))
        let worldImage = viewportImage.transformed(by: viewportToWorldRaster(camera: camera, outputSize: outputSize, density: levelDensity))
        let bounds = camera.worldBounds(aspect: outputSize.width / outputSize.height)
        let indices = WorldTileLayout.indices(intersecting: bounds, level: level, baseDensity: baseDensity)
        for index in indices {
            let key = TileKey(level: index.level, x: index.x, y: index.y)
            let rect = CGRect(x: CGFloat(index.x * tileSize), y: CGFloat(index.y * tileSize), width: CGFloat(tileSize), height: CGFloat(tileSize))
            let existing = tile(for: key).map {
                CIImage(cgImage: $0.image).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            }
            let source = worldImage.cropped(to: rect)
            let combined = existing.map { source.composited(over: $0) } ?? source
            guard let cg = context.createCGImage(combined, from: rect, format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB()) else { continue }
            touch(key, image: cg)
        }
        evictIfNeeded()
    }

    func image(camera: CanvasCamera, outputSize: CGSize) -> CIImage? {
        guard outputSize.width > 0, outputSize.height > 0, !(tiles.isEmpty && backedKeys.isEmpty) else { return nil }
        let desiredDensity = outputSize.height / max(0.000_001, camera.viewHeight)
        let desiredLevel = WorldTileLayout.level(forPixelsPerWorldUnit: desiredDensity, baseDensity: baseDensity)
        let availableLevels = Set(tiles.keys.map(\.level)).union(backedKeys.map(\.level))
        guard let level = availableLevels.min(by: { abs($0 - desiredLevel) < abs($1 - desiredLevel) }) else { return nil }
        let density = baseDensity * pow(2, CGFloat(level))
        let bounds = camera.worldBounds(aspect: outputSize.width / outputSize.height)
        let indices = WorldTileLayout.indices(intersecting: bounds, level: level, baseDensity: baseDensity)
        var world: CIImage?
        for index in indices {
            let key = TileKey(level: level, x: index.x, y: index.y)
            guard var tile = tile(for: key) else { continue }
            accessCounter &+= 1
            tile.lastAccess = accessCounter
            tiles[key] = tile
            let placed = CIImage(cgImage: tile.image).transformed(by: CGAffineTransform(
                translationX: CGFloat(index.x * tileSize), y: CGFloat(index.y * tileSize)))
            world = world.map { placed.composited(over: $0) } ?? placed
        }
        guard let world else { return nil }
        let transform = viewportToWorldRaster(camera: camera, outputSize: outputSize, density: density)
        return world.transformed(by: transform.inverted()).cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    func references() -> [ArtifactTileReference] {
        Set(tiles.keys).union(backedKeys).sorted { ($0.level, $0.y, $0.x) < ($1.level, $1.y, $1.x) }.map {
            ArtifactTileReference(level: $0.level, x: $0.x, y: $0.y,
                                  relativePath: "Tiles/L\($0.level)/\($0.x)_\($0.y).png", pixelSize: tileSize)
        }
    }

    func writeTiles(to packageURL: URL) throws {
        let fm = FileManager.default
        for key in Set(tiles.keys).union(backedKeys) {
            let directory = packageURL.appendingPathComponent("Tiles/L\(key.level)", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let image = tile(for: key)?.image else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try data.write(to: directory.appendingPathComponent("\(key.x)_\(key.y).png"), options: .atomic)
        }
    }

    func loadTiles(from packageURL: URL, references: [ArtifactTileReference]) throws {
        clear()
        for reference in references {
            let url = packageURL.appendingPathComponent(reference.relativePath)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            touch(TileKey(level: reference.level, x: reference.x, y: reference.y), image: image)
        }
        evictIfNeeded()
    }

    private func viewportToWorldRaster(camera: CanvasCamera, outputSize: CGSize, density: CGFloat) -> CGAffineTransform {
        let view = camera.viewSize(aspect: outputSize.width / outputSize.height)
        let c = cos(camera.rotation), s = sin(camera.rotation)
        return CGAffineTransform(
            a: density * c * view.width / outputSize.width,
            b: -density * s * view.width / outputSize.width,
            c: density * s * view.height / outputSize.height,
            d: density * c * view.height / outputSize.height,
            tx: density * (camera.center.x - 0.5 * c * view.width - 0.5 * s * view.height),
            ty: -density * camera.center.y + 0.5 * density * s * view.width - 0.5 * density * c * view.height
        )
    }

    private func touch(_ key: TileKey, image: CGImage) {
        accessCounter &+= 1
        tiles[key] = Tile(image: image, lastAccess: accessCounter)
    }

    private func tile(for key: TileKey) -> Tile? {
        if let value = tiles[key] { return value }
        guard backedKeys.contains(key),
              let source = CGImageSourceCreateWithURL(backingFile(for: key) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        touch(key, image: image)
        return tiles[key]
    }

    private func backingFile(for key: TileKey) -> URL {
        backingURL.appendingPathComponent("L\(key.level)-\(key.x)-\(key.y).png")
    }

    private func spill(_ key: TileKey, tile: Tile) {
        let rep = NSBitmapImageRep(cgImage: tile.image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do { try data.write(to: backingFile(for: key), options: .atomic); backedKeys.insert(key) } catch { }
    }

    private func evictIfNeeded() {
        guard tiles.count > maximumResidentTiles else { return }
        let excess = tiles.count - maximumResidentTiles
        for key in tiles.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }).prefix(excess).map(\.key) {
            if let tile = tiles.removeValue(forKey: key) { spill(key, tile: tile) }
        }
    }
}
