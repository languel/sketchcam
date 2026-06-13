import AVFoundation
import CoreMedia
import CoreVideo
import SketchCamShared
import SwiftUI

/// Zero-readback preview/display: shows processed frames by wrapping their
/// `CVPixelBuffer` (IOSurface, shared) in a display `CMSampleBuffer` and
/// enqueuing it into an `AVSampleBufferDisplayLayer` — no `createCGImage`
/// GPU→CPU readback, GPU-composited, full frame rate. The preview pane is also
/// the main display in presentation mode, so this is the "full-tilt" path.
final class SampleBufferDisplayController {
    let displayLayer = AVSampleBufferDisplayLayer()

    init() {
        displayLayer.videoGravity = .resizeAspect
    }

    /// Enqueue a frame for display. Must be called on the main thread (CALayer).
    /// Uses DisplayImmediately so frames show as they arrive regardless of
    /// timestamps (a control timebase starting at 0 vs host-time PTS left the
    /// layer waiting for "future" frames → black).
    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard let sample = makeDisplaySample(pixelBuffer) else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
    }

    func flush() { displayLayer.flush() }

    private func makeDisplaySample(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        guard let sample = try? PixelBufferUtils.makeSampleBuffer(pixelBuffer: pixelBuffer) else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}

/// SwiftUI wrapper hosting the display layer.
struct SampleBufferDisplayView: NSViewRepresentable {
    let controller: SampleBufferDisplayController

    func makeNSView(context: Context) -> NSView {
        let view = LayerHostingView()
        view.wantsLayer = true
        view.hostedLayer = controller.displayLayer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Keeps the display layer sized to the view (CALayer doesn't autoresize).
private final class LayerHostingView: NSView {
    var hostedLayer: CALayer? {
        didSet {
            guard let hostedLayer else { return }
            layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            hostedLayer.frame = bounds
            layer?.addSublayer(hostedLayer)
        }
    }

    override func layout() {
        super.layout()
        hostedLayer?.frame = bounds
    }
}
