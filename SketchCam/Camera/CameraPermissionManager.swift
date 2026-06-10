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

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}

