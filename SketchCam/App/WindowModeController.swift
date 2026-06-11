import AppKit
import SwiftUI

/// Owns NSWindow-level presentation state: decoration, transparency,
/// always-on-top, and the presentation-mode macro. SwiftUI doesn't expose
/// the window, so `WindowAccessor` hands it over after the view appears.
final class WindowModeController: ObservableObject {
    @Published var panelVisible = true
    @Published var decorated = true { didSet { apply() } }
    @Published var transparent = false { didSet { apply() } }
    @Published var alwaysOnTop = false { didSet { apply() } }
    @Published private(set) var presentationMode = false

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
            window.titlebarAppearsTransparent = false
            window.isMovableByWindowBackground = false
        } else {
            // keep .resizable so the borderless window can stay key
            window.styleMask = [.borderless, .resizable]
            window.isMovableByWindowBackground = true
        }
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : .windowBackgroundColor
        window.hasShadow = !transparent
        window.level = alwaysOnTop ? .floating : .normal
        if alwaysOnTop {
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        } else {
            window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
        }
        window.invalidateShadow()
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
