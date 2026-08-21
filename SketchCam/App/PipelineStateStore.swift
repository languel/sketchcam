import Foundation
import SketchCamCore
import SketchCamShared

/// Codable state for the last live session. The OS owns camera permission, so
/// it is intentionally not serialized; the next launch re-queries AVFoundation
/// and either resumes the camera or presents the permission affordance.
struct SketchCamSessionSnapshot: Codable {
    var version: Int = 1
    var settings: ProcessingSettings
    var outputFormatID: String
    var selectedDeviceID: String?
    var frameSource: SketchCamViewModel.FrameSource
    var movieURLString: String?
    var movieBookmark: Data?
    var webBookmark: Data?
    var movieRate: Double
    var inputResolution: CameraInputResolution
}

/// Lock-protected mirror of the UI-owned pipeline inputs.
///
/// The UI (main thread) writes; the camera/processing queues read. This
/// replaces the previous `DispatchQueue.main.sync` snapshots, which made
/// every frame wait on a main thread that was itself busy rendering the
/// previous frame's preview — the feedback loop behind the ~1 fps collapse
/// (see notes/performance-plan.md).
final class PipelineStateStore: @unchecked Sendable {
    static let sessionKey = "sketchcam.session.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var _settings = ProcessingSettings()
    private var _outputFormat = SketchCamFormats.defaultFormat
    private var _permission = CameraPermissionManager.state

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSession() -> SketchCamSessionSnapshot? {
        lock.withLock {
            guard let data = defaults.data(forKey: Self.sessionKey) else { return nil }
            return try? JSONDecoder().decode(SketchCamSessionSnapshot.self, from: data)
        }
    }

    func saveSession(_ snapshot: SketchCamSessionSnapshot) {
        lock.withLock {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            defaults.set(data, forKey: Self.sessionKey)
        }
    }

    func removeSession() {
        lock.withLock { defaults.removeObject(forKey: Self.sessionKey) }
    }

    var settings: ProcessingSettings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }

    var outputFormat: FrameFormat {
        get { lock.withLock { _outputFormat } }
        set { lock.withLock { _outputFormat = newValue } }
    }

    var permission: CameraPermissionState {
        get { lock.withLock { _permission } }
        set { lock.withLock { _permission = newValue } }
    }
}
