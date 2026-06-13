import AVFoundation
import CoreMedia
import SwiftUI

/// Zero-readback preview/display: shows processed frames by enqueuing their
/// `CMSampleBuffer`s straight into an `AVSampleBufferDisplayLayer` — no
/// `createCGImage` GPU→CPU readback, GPU-composited, full frame rate. The
/// preview pane is also the main display in presentation mode, so this is the
/// "full-tilt" output path.
final class SampleBufferDisplayController {
    let displayLayer = AVSampleBufferDisplayLayer()

    init() {
        displayLayer.videoGravity = .resizeAspect
        // Display frames as soon as they arrive (live), ignoring timestamps.
        let timebase = makeHostTimebase()
        displayLayer.controlTimebase = timebase
        if let timebase {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
        }
    }

    /// Enqueue a frame for display. Must be called on the main thread (CALayer).
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }

    func flush() { displayLayer.flush() }

    private func makeHostTimebase() -> CMTimebase? {
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        return timebase
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
