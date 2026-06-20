import Foundation
import SketchCamCore
import SketchCamShared

/// Lock-protected mirror of the UI-owned pipeline inputs.
///
/// The UI (main thread) writes; the camera/processing queues read. This
/// replaces the previous `DispatchQueue.main.sync` snapshots, which made
/// every frame wait on a main thread that was itself busy rendering the
/// previous frame's preview — the feedback loop behind the ~1 fps collapse
/// (see notes/performance-plan.md).
final class PipelineStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _settings = ProcessingSettings()
    private var _outputFormat = SketchCamFormats.defaultFormat
    private var _permission = CameraPermissionManager.state
    private var _canvasCamera = CanvasCamera()

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

    var canvasCamera: CanvasCamera {
        get { lock.withLock { _canvasCamera } }
        set { lock.withLock { _canvasCamera = newValue } }
    }
}
