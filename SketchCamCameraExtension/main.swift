import CoreMediaIO
import Foundation

let providerSource = SketchCamCameraExtensionProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()

