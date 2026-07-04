import SwiftUI
import AppKit

enum OutputWindowSource: Equatable, Identifiable {
    case activeViewport
    case camera
    case movie
    case texture(nodeID: UUID, name: String)

    var id: String {
        switch self {
        case .activeViewport: return "activeViewport"
        case .camera: return "camera"
        case .movie: return "movie"
        case .texture(let nodeID, _): return "texture.\(nodeID.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .activeViewport: return "Active viewport"
        case .camera: return "Camera"
        case .movie: return "Movie"
        case .texture(_, let name): return name
        }
    }
}

final class OutputWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private static let windowIdentifier = NSUserInterfaceItemIdentifier("SketchCam.OutputWindow")

    @Published var selectedWindowName = "Output 1"
    @Published var source: OutputWindowSource = .activeViewport
    @Published private(set) var isOpen = false
    @Published var fullscreen = false { didSet { applyFullscreenIfNeeded(oldValue: oldValue) } }
    @Published var borderless = false { didSet { applyChrome() } }
    @Published var transparent = false { didSet { applyChrome() } }
    @Published var alwaysOnTop = false { didSet { applyChrome() } }
    @Published var clickThrough = false { didSet { applyChrome() } }
    @Published var opacity: Double = 1 { didSet { applyChrome() } }
    @Published var scale: Double = 0.5
    @Published var x: Double = 0 { didSet { applyFrameFromControls() } }
    @Published var y: Double = 0 { didSet { applyFrameFromControls() } }
    @Published var width: Double = 960 { didSet { applyFrameFromControls() } }
    @Published var height: Double = 540 { didSet { applyFrameFromControls() } }

    weak var window: NSWindow? {
        didSet {
            guard oldValue !== window else { return }
            if let oldWindow = oldValue,
               (oldWindow.delegate as AnyObject?) === self {
                oldWindow.delegate = nil
            }
            window?.delegate = self
            isOpen = window != nil && window?.isMiniaturized == false
            updateGeometryFromWindow()
            applyChrome()
        }
    }

    private var syncingGeometry = false
    private var closeShortcutMonitor: Any?

    override init() {
        super.init()
        closeShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.charactersIgnoringModifiers?.lowercased() == "w",
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option),
                  self.isOpen,
                  self.alwaysOnTop || self.window?.isKeyWindow == true else {
                return event
            }
            self.close()
            return nil
        }
    }

    deinit {
        if let closeShortcutMonitor {
            NSEvent.removeMonitor(closeShortcutMonitor)
        }
    }

    func close() {
        guard let window else {
            isOpen = false
            return
        }
        window.close()
        if self.window === window {
            self.window = nil
        }
        isOpen = false
    }

    func attachWindow(_ window: NSWindow) {
        window.identifier = Self.windowIdentifier
        window.title = "SketchCam Output"
        self.window = window
        isOpen = !window.isMiniaturized
    }

    func recoverWindowReference() {
        if let window, window.isVisible {
            isOpen = !window.isMiniaturized
            applyChrome()
            return
        }
        if let found = NSApp.windows.first(where: { window in
            window.identifier == Self.windowIdentifier || window.title == "SketchCam Output"
        }) {
            attachWindow(found)
        } else {
            isOpen = false
        }
    }

    func recoverWindowReferenceAfterOpen() {
        for delay in [0.0, 0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.recoverWindowReference()
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            isOpen = true
            updateGeometryFromWindow()
        }
    }

    func windowDidMove(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            updateGeometryFromWindow()
        }
    }

    func windowDidResize(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            updateGeometryFromWindow()
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            isOpen = false
        }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            isOpen = true
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        isOpen = false
        window = nil
    }

    func centerOnScreen() {
        guard let window else { return }
        window.center()
        updateGeometryFromWindow()
    }

    func bringToFront() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        isOpen = true
    }

    func applyScale(outputSize: CGSize) {
        guard outputSize.width > 0, outputSize.height > 0 else { return }
        let newSize = CGSize(width: outputSize.width * scale, height: outputSize.height * scale)
        setWindowSize(newSize, preservingCenter: true)
    }

    func updateGeometryFromWindow() {
        guard let window else { return }
        syncingGeometry = true
        let frame = window.frame
        x = frame.origin.x
        y = frame.origin.y
        width = frame.width
        height = frame.height
        syncingGeometry = false
    }

    private func applyFrameFromControls() {
        guard !syncingGeometry,
              let window,
              width.isFinite, height.isFinite,
              width >= 80, height >= 60 else { return }
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func setWindowSize(_ size: CGSize, preservingCenter: Bool) {
        guard let window else { return }
        var frame = window.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        frame.size = NSSize(width: max(80, size.width), height: max(60, size.height))
        if preservingCenter {
            frame.origin.x = center.x - frame.width * 0.5
            frame.origin.y = center.y - frame.height * 0.5
        }
        window.setFrame(frame, display: true)
        updateGeometryFromWindow()
    }

    private func applyChrome() {
        guard let window else { return }
        if borderless {
            window.styleMask = [.borderless, .resizable]
            window.isMovableByWindowBackground = true
        } else {
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
        }
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : .black
        window.hasShadow = !transparent
        window.alphaValue = 1
        window.level = alwaysOnTop ? .floating : .normal
        window.ignoresMouseEvents = clickThrough
        if alwaysOnTop {
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.orderFrontRegardless()
        } else {
            window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
        }
        window.contentMinSize = NSSize(width: 80, height: 60)
        window.invalidateShadow()
    }

    private func applyFullscreenIfNeeded(oldValue: Bool) {
        guard fullscreen != oldValue,
              let window,
              window.styleMask.contains(.fullScreen) != fullscreen else { return }
        window.toggleFullScreen(nil)
    }
}

struct OutputWindowAccessor: NSViewRepresentable {
    let controller: OutputWindowController

    func makeNSView(context: Context) -> NSView {
        let view = OutputWindowProbeView()
        view.controller = controller
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window,
           controller.window !== window {
            controller.attachWindow(window)
        }
    }

    private final class OutputWindowProbeView: NSView {
        weak var controller: OutputWindowController?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.controller?.attachWindow(window)
            }
        }
    }
}

struct SecondaryOutputWindow: View {
    @ObservedObject var model: SketchCamViewModel
    @ObservedObject var outputWindow: OutputWindowController

    var body: some View {
        ZStack {
            if !outputWindow.transparent {
                Color.black
            }
            outputContent
                .opacity(outputWindow.opacity)
        }
        .background(OutputWindowAccessor(controller: outputWindow))
        .frame(
            minWidth: 320,
            idealWidth: max(320, model.outputFormat.size.width / 2),
            minHeight: 180,
            idealHeight: max(180, model.outputFormat.size.height / 2)
        )
        .background(outputWindow.transparent ? Color.clear : Color.black)
        .onAppear { updateSourcePreviewActivity(old: nil, new: outputWindow.source) }
        .onDisappear {
            updateSourcePreviewActivity(old: outputWindow.source, new: nil)
        }
        .onChange(of: outputWindow.source) { oldValue, newValue in
            updateSourcePreviewActivity(old: oldValue, new: newValue)
        }
    }

    @ViewBuilder private var outputContent: some View {
        switch outputWindow.source {
        case .activeViewport, .texture:
            SampleBufferDisplayView(controller: model.secondaryOutputDisplay)
                .aspectRatio(
                    CGFloat(model.outputFormat.width) / CGFloat(max(1, model.outputFormat.height)),
                    contentMode: .fit
                )
        case .camera:
            OutputSourcePreviewImage(previews: model.sourcePreviews, source: .camera)
        case .movie:
            OutputSourcePreviewImage(previews: model.sourcePreviews, source: .movie)
        }
    }

    private func updateSourcePreviewActivity(old: OutputWindowSource?, new: OutputWindowSource?) {
        if case .camera = old { model.setSourcePreviewActive(.camera, active: false) }
        if case .movie = old { model.setSourcePreviewActive(.movie, active: false) }
        if case .camera = new { model.setSourcePreviewActive(.camera, active: true) }
        if case .movie = new { model.setSourcePreviewActive(.movie, active: true) }
    }
}

private struct OutputSourcePreviewImage: View {
    @ObservedObject var previews: SourcePreviewReadouts
    let source: SketchCamViewModel.FrameSource

    var body: some View {
        ZStack {
            if let image {
                Image(image, scale: 1, label: Text("\(source.title) output source"))
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
            } else {
                Text("Waiting for \(source.title.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var image: CGImage? {
        switch source {
        case .camera: previews.cameraImage
        case .movie: previews.movieImage
        }
    }
}
