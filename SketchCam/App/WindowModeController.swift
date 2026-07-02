import AppKit
import SwiftUI

/// Owns NSWindow-level presentation state: decoration, transparency,
/// always-on-top, and the presentation-mode macro. SwiftUI doesn't expose
/// the window, so `WindowAccessor` hands it over after the view appears.
final class WindowModeController: ObservableObject {
    @Published var panelVisible = true
    /// true = panel sits beside the canvas and the canvas shrinks to fit;
    /// false = panel floats over the canvas (canvas full-size, partly obscured).
    @Published var panelFit = true
    @Published var decorated = true { didSet { apply() } }

    /// Show the panel in fit-beside-canvas mode (or hide if already shown that way).
    func togglePanelFit() {
        if panelVisible && panelFit { panelVisible = false }
        else { panelFit = true; panelVisible = true }
    }

    /// Show the panel floating over the canvas (or hide if already shown that way).
    func togglePanelOverlay() {
        if panelVisible && !panelFit { panelVisible = false }
        else { panelFit = false; panelVisible = true }
    }
    @Published var transparent = false { didSet { apply() } }
    @Published var alwaysOnTop = false { didSet { apply() } }
    @Published private(set) var presentationMode = false
    @Published private(set) var pipMode = false

    weak var window: NSWindow? {
        didSet { apply() }
    }

    private struct Snapshot {
        var panelVisible: Bool
        var decorated: Bool
        var transparent: Bool
        var alwaysOnTop: Bool
    }

    private var beforePresentation: Snapshot?
    private var frameBeforePIP: NSRect?
    private var dragMonitor: Any?

    deinit {
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
        }
    }

    /// Park the window as a small picture-in-picture panel in the lower
    /// right of the current screen (~1/16 screen area); toggling back
    /// restores the previous frame.
    func togglePIP() {
        guard let window else { return }
        if pipMode {
            pipMode = false
            if let frame = frameBeforePIP {
                window.setFrame(frame, display: true, animate: true)
            }
        } else {
            frameBeforePIP = window.frame
            pipMode = true
            let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let width = screen.width / 4
            let height = width * 9 / 16
            let margin: CGFloat = 16
            let frame = NSRect(
                x: screen.maxX - width - margin,
                y: screen.minY + margin,
                width: width,
                height: height
            )
            window.setFrame(frame, display: true, animate: true)
        }
    }

    /// One action into lecture mode and back: panel off, borderless,
    /// transparent, always on top — restores the prior state on exit.
    func togglePresentationMode() {
        if presentationMode {
            presentationMode = false
            if let s = beforePresentation {
                panelVisible = s.panelVisible
                decorated = s.decorated
                transparent = s.transparent
                alwaysOnTop = s.alwaysOnTop
            }
        } else {
            beforePresentation = Snapshot(
                panelVisible: panelVisible,
                decorated: decorated,
                transparent: transparent,
                alwaysOnTop: alwaysOnTop
            )
            presentationMode = true
            panelVisible = false
            decorated = false
            transparent = true
            alwaysOnTop = true
        }
    }

    private func apply() {
        guard let window else { return }
        if decorated {
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
        } else {
            // keep .resizable so the borderless window can stay key
            window.styleMask = [.borderless, .resizable]
            window.isMovableByWindowBackground = false
        }
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : .windowBackgroundColor
        window.hasShadow = !transparent
        window.level = alwaysOnTop ? .floating : .normal
        // allow very small PIP frames
        window.contentMinSize = NSSize(width: 120, height: 68)
        window.minSize = NSSize(width: 120, height: 68)
        if alwaysOnTop {
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        } else {
            window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
        }
        window.invalidateShadow()
        updateDragMonitor()
    }

    private func updateDragMonitor() {
        if presentationMode, dragMonitor == nil {
            dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self,
                      let window = self.window,
                      self.presentationMode,
                      event.window === window,
                      event.modifierFlags.contains(.control),
                      event.modifierFlags.contains(.shift)
                else { return event }
                window.performDrag(with: event)
                return nil
            }
        } else if !presentationMode, let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let controller: WindowModeController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if controller.window == nil {
                controller.window = view.window
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if controller.window == nil {
            controller.window = nsView.window
        }
    }
}
