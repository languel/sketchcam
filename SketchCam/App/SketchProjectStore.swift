import AppKit
import Foundation
import SketchCamCore
import UniformTypeIdentifiers

extension UTType {
    static let sketchCamProject = UTType(exportedAs: "io.github.languel.sketchcam.project", conformingTo: .package)
}

/// Atomic reader/writer for the versioned `.sketchcam` package. Large raster
/// state lives in subdirectories; the manifest remains compact and diffable.
final class SketchProjectStore {
    enum StoreError: LocalizedError {
        case unsupportedVersion(Int)
        case invalidPackage

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version): return "This project uses unsupported format version \(version)."
            case .invalidPackage: return "The selected item is not a valid SketchCam project."
            }
        }
    }

    static let manifestName = "manifest.json"
    static let tileDirectory = "Tiles"
    static let checkpointDirectory = "Checkpoints"
    static let mediaDirectory = "Media"
    static let previewDirectory = "Previews"

    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return value
    }()

    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }()

    func read(from packageURL: URL) throws -> SketchProjectManifest {
        let manifestURL = packageURL.appendingPathComponent(Self.manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw StoreError.invalidPackage }
        let manifest = try decoder.decode(SketchProjectManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version <= SketchProjectManifest.currentVersion else {
            throw StoreError.unsupportedVersion(manifest.version)
        }
        return manifest
    }

    func write(_ source: SketchProjectManifest, to packageURL: URL) throws {
        var manifest = source
        manifest.modifiedAt = Date()
        let fm = FileManager.default
        let parent = packageURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".\(packageURL.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for directory in [Self.tileDirectory, Self.checkpointDirectory, Self.mediaDirectory, Self.previewDirectory] {
                let destination = staging.appendingPathComponent(directory, isDirectory: true)
                let existing = packageURL.appendingPathComponent(directory, isDirectory: true)
                if fm.fileExists(atPath: existing.path) {
                    try fm.copyItem(at: existing, to: destination)
                } else {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                }
            }
            try encoder.encode(manifest).write(to: staging.appendingPathComponent(Self.manifestName), options: .atomic)
            if fm.fileExists(atPath: packageURL.path) {
                _ = try fm.replaceItemAt(packageURL, withItemAt: staging, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: staging, to: packageURL)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    func makeSavePanel(title: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.sketchCamProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".sketchcam"
        return panel
    }

    func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.sketchCamProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel
    }
}
