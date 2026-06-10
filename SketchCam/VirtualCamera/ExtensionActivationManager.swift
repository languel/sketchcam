import Foundation
import SystemExtensions

final class ExtensionActivationManager: NSObject, ObservableObject {
    static let extensionIdentifier = "io.github.languel.sketchcam.camera-extension"

    @Published private(set) var statusText = "Not requested"

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        statusText = "Activation requested"
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        statusText = "Deactivation requested"
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension ExtensionActivationManager: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        statusText = result == .completed ? "Active" : "Finished: \(result.rawValue)"
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        statusText = "Failed: \(error.localizedDescription)"
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        statusText = "Waiting for System Settings approval"
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        statusText = "Replacing installed extension"
        return .replace
    }
}

