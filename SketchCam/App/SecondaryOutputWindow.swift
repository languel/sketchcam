import SwiftUI
import AppKit

enum OutputWindowSource: Equatable, Identifiable {
    case activeViewport
    case presentation
    case camera
    case movie
    case texture(nodeID: UUID, name: String)

    var id: String {
        switch self {
        case .activeViewport: return "activeViewport"
        case .presentation: return "presentation"
        case .camera: return "camera"
        case .movie: return "movie"
        case .texture(let nodeID, _): return "texture.\(nodeID.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .activeViewport: return "Active viewport"
        case .presentation: return "Presentation"
        case .camera: return "Camera"
        case .movie: return "Movie"
        case .texture(_, let name): return name
        }
    }
}

final class OutputWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private static let windowIdentifier = NSUserInterfaceItemIdentifier("SketchCam.OutputWindow")

    @Published var selectedWindowName = "Output 1" { didSet { persistState() } }
    @Published var source: OutputWindowSource = .presentation { didSet { persistState() } }
    @Published private(set) var isOpen = false
    @Published var fullscreen = false { didSet { applyFullscreenIfNeeded(oldValue: oldValue) } }
    @Published var borderless = false { didSet { applyChrome(); persistState() } }
    @Published var transparent = false { didSet { applyChrome(); persistState() } }
    @Published var alwaysOnTop = false { didSet { applyChrome(); persistState() } }
    @Published var clickThrough = false { didSet { applyChrome(); persistState() } }
    @Published var opacity: Double = 1 { didSet { applyChrome(); persistState() } }
    @Published var scale: Double = 0.5 { didSet { persistState() } }
    @Published var x: Double = 0 { didSet { applyFrameFromControls(); persistState() } }
    @Published var y: Double = 0 { didSet { applyFrameFromControls(); persistState() } }
    @Published var width: Double = 960 { didSet { applyFrameFromControls(); persistState() } }
    @Published var height: Double = 540 { didSet { applyFrameFromControls(); persistState() } }

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
    private var restoringState = false
    private var closeShortcutMonitor: Any?

    override init() {
        super.init()
        restoreState()
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
        let restoredFrame = hasPersistedGeometry
            ? NSRect(x: x, y: y, width: width, height: height)
            : nil
        restoringState = true
        self.window = window
        if let restoredFrame {
            window.setFrame(restoredFrame, display: true)
        }
        restoringState = false
        if restoredFrame != nil { updateGeometryFromWindow() }
        isOpen = !window.isMiniaturized
    }

    private var hasPersistedGeometry: Bool {
        UserDefaults.standard.object(forKey: Self.key("geometry")) != nil
    }

    private static func key(_ suffix: String) -> String { "sketchcam.output.\(suffix)" }

    private func restoreState() {
        let defaults = UserDefaults.standard
        restoringState = true
        selectedWindowName = defaults.string(forKey: Self.key("windowName")) ?? selectedWindowName
        if let sourceID = defaults.string(forKey: Self.key("source")) {
            switch sourceID {
            case OutputWindowSource.activeViewport.id: source = .activeViewport
            case OutputWindowSource.camera.id: source = .camera
            case OutputWindowSource.movie.id: source = .movie
            case OutputWindowSource.presentation.id: source = .presentation
            default:
                let prefix = "texture."
                if sourceID.hasPrefix(prefix),
                   let nodeID = UUID(uuidString: String(sourceID.dropFirst(prefix.count))) {
                    // The layer graph supplies the friendly name later; keep
                    // the node identity so a saved texture source still
                    // resolves after relaunch.
                    source = .texture(nodeID: nodeID, name: "Texture")
                }
            }
        }
        borderless = defaults.object(forKey: Self.key("borderless")) as? Bool ?? borderless
        transparent = defaults.object(forKey: Self.key("transparent")) as? Bool ?? transparent
        alwaysOnTop = defaults.object(forKey: Self.key("alwaysOnTop")) as? Bool ?? alwaysOnTop
        clickThrough = defaults.object(forKey: Self.key("clickThrough")) as? Bool ?? clickThrough
        opacity = defaults.object(forKey: Self.key("opacity")) as? Double ?? opacity
        scale = defaults.object(forKey: Self.key("scale")) as? Double ?? scale
        if defaults.object(forKey: Self.key("geometry")) != nil {
            x = defaults.double(forKey: Self.key("x"))
            y = defaults.double(forKey: Self.key("y"))
            width = max(80, defaults.double(forKey: Self.key("width")))
            height = max(60, defaults.double(forKey: Self.key("height")))
        }
        restoringState = false
    }

    private func persistState() {
        guard !restoringState else { return }
        let defaults = UserDefaults.standard
        defaults.set(selectedWindowName, forKey: Self.key("windowName"))
        defaults.set(source.id, forKey: Self.key("source"))
        defaults.set(borderless, forKey: Self.key("borderless"))
        defaults.set(transparent, forKey: Self.key("transparent"))
        defaults.set(alwaysOnTop, forKey: Self.key("alwaysOnTop"))
        defaults.set(clickThrough, forKey: Self.key("clickThrough"))
        defaults.set(opacity, forKey: Self.key("opacity"))
        defaults.set(scale, forKey: Self.key("scale"))
        defaults.set(true, forKey: Self.key("geometry"))
        defaults.set(x, forKey: Self.key("x"))
        defaults.set(y, forKey: Self.key("y"))
        defaults.set(width, forKey: Self.key("width"))
        defaults.set(height, forKey: Self.key("height"))
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
        case .activeViewport, .presentation, .texture:
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
        if case .presentation = old { model.setPresentationOutputActive(false) }
        if case .presentation = new { model.setPresentationOutputActive(true) }
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
