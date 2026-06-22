import AVFoundation
import Foundation

enum CameraPermissionState: String {
    case unknown = "Unknown"
    case authorized = "Authorized"
    case denied = "Denied"
    case restricted = "Restricted"
}

enum CameraPermissionManager {
    static var state: CameraPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    /// Follow AVFoundation's authorization contract exactly: the system prompt
    /// is only appropriate for a genuinely undetermined app identity. Calling
    /// requestAccess unconditionally at every development launch makes camera
    /// startup depend on TCC re-evaluating a freshly installed bundle.
    static func requestAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
