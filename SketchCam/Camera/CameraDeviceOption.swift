import Foundation

struct CameraDeviceOption: Identifiable, Hashable {
    let id: String
    let name: String

    var isSketchCamOutput: Bool {
        name.localizedCaseInsensitiveContains("SketchCam")
    }
}

