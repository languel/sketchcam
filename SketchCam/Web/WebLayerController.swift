import AppKit
import CoreImage
import SketchCamCore
import WebKit

/// Hosts an off-screen, transparent `WKWebView` (sized to the output) and
/// snapshots it on a timer into a `CIImage` the frame pipeline composites as a
/// layer. The web view lives on the main thread; `currentImage()` is read from
/// the processing queue under a lock.
final class WebLayerController: NSObject, NSWindowDelegate {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var timer: Timer?

    private let lock = NSLock()
    private var latest: CIImage?
    private var snapshotInFlight = false

    private var enabled = false
    private var loadedURL = ""
    private var loadedSnippet = ""
    private var loadedUseSnippet = false
    private var loadedTransparent = true
    private var currentSize: CGSize = .zero
    private var opacity: Float = 1
    private var snapshotFPS: Float = 20
    private var interactive = false

    /// Called (on the main thread) when the user closes the interactive browser
    /// window, so the owner can flip the `interactive` setting back off.
    var onInteractiveClosed: (() -> Void)?

    // MARK: - Driven from the main thread on settings / output changes.

    func update(settings: WebLayerSettings, outputSize: CGSize) {
        opacity = settings.opacity

        guard settings.enabled else {
            enabled = false
            stopTimer()
            applyInteractive(false)
            lock.lock(); latest = nil; lock.unlock()
            return
        }
        enabled = true
        ensureWebView(size: outputSize)
        if currentSize != outputSize, outputSize.width > 0, outputSize.height > 0 {
            currentSize = outputSize
            window?.contentAspectRatio = outputSize
        }
        if settings.urlString != loadedURL || settings.transparentBackground != loadedTransparent
            || settings.useSnippet != loadedUseSnippet || settings.htmlSnippet != loadedSnippet {
            loadedURL = settings.urlString
            loadedSnippet = settings.htmlSnippet
            loadedUseSnippet = settings.useSnippet
            loadedTransparent = settings.transparentBackground
            reload()
        }
        if settings.interactive != interactive {
            applyInteractive(settings.interactive)
        }
        if settings.refreshFPS != snapshotFPS {
            snapshotFPS = settings.refreshFPS
            restartTimer()
        }
        startTimer()
    }

    /// Show the web view as an on-screen interactive window, or hide it
    /// off-screen (still rendering for snapshots).
    private func applyInteractive(_ on: Bool) {
        interactive = on
        guard let win = window else { return }
        if on {
            win.ignoresMouseEvents = false
            win.alphaValue = 1
            win.title = "SketchCam Web"
            // Fit within ~80% of the screen, keeping the output aspect.
            if let visible = NSScreen.main?.visibleFrame, currentSize.width > 0 {
                let scale = min(1, min(visible.width * 0.8 / currentSize.width, visible.height * 0.8 / currentSize.height))
                win.setContentSize(CGSize(width: currentSize.width * scale, height: currentSize.height * scale))
            }
            win.center()
            win.makeKeyAndOrderFront(nil)
        } else {
            win.ignoresMouseEvents = true
            win.alphaValue = 0
            win.setFrameOrigin(CGPoint(x: -20000, y: -20000))
            win.orderFrontRegardless()   // off-screen + invisible, still renders
        }
    }

    // Closing the interactive window just hides it; tell the owner to untoggle.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onInteractiveClosed?()
        applyInteractive(false)
        return false
    }

    /// Latest web snapshot with opacity applied (nil if disabled / not ready).
    func currentImage() -> CIImage? {
        lock.lock(); let img = latest; lock.unlock()
        guard let img, opacity > 0.001 else { return nil }
        if opacity >= 0.999 { return img }
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        ])
    }

    // MARK: - Web view lifecycle

    private func ensureWebView(size: CGSize) {
        guard webView == nil else { return }
        let frame = CGRect(origin: .zero, size: size.width > 0 ? size : CGSize(width: 1920, height: 1080))
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: frame, configuration: config)
        wv.autoresizingMask = [.width, .height]
        // Transparent web-view background (the page CSS is handled separately).
        wv.setValue(false, forKey: "drawsBackground")
        wv.layer?.backgroundColor = NSColor.clear.cgColor

        // A real window so the web content renders and can be made interactive.
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: frame.size),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = wv
        win.contentAspectRatio = frame.size

        webView = wv
        window = win
        currentSize = frame.size
        applyInteractive(false)   // start hidden off-screen but rendering
    }

    private func reload() {
        guard let wv = webView else { return }
        let ucc = wv.configuration.userContentController
        ucc.removeAllUserScripts()
        if loadedTransparent {
            // Strip the page's own background so it composites transparently.
            let js = "var s=document.createElement('style');s.textContent='html,body{background:transparent !important;background-color:transparent !important;}';document.head?document.head.appendChild(s):document.documentElement.appendChild(s);"
            ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        if loadedUseSnippet {
            wv.loadHTMLString(loadedSnippet, baseURL: nil)
            return
        }
        guard !loadedURL.isEmpty else {
            wv.loadHTMLString("", baseURL: nil)
            return
        }
        if loadedURL.contains("://"), let url = URL(string: loadedURL) {
            if url.isFileURL {
                wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                wv.load(URLRequest(url: url))
            }
        } else {
            let url = URL(fileURLWithPath: (loadedURL as NSString).expandingTildeInPath)
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    // MARK: - Navigation (main thread)

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reloadPage() { if loadedUseSnippet { reload() } else { webView?.reload() } }

    // MARK: - Snapshotting

    private func startTimer() {
        guard timer == nil else { return }
        let fps = Double(max(1, min(60, snapshotFPS)))
        let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.snapshot() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func restartTimer() {
        stopTimer()
        if enabled { startTimer() }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func snapshot() {
        guard enabled, let wv = webView, !snapshotInFlight else { return }
        snapshotInFlight = true
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        let target = currentSize
        wv.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self else { return }
            self.snapshotInFlight = false
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            var ci = CIImage(cgImage: cg)
            let ext = ci.extent
            // Normalize to output pixels (handles backing scale).
            if ext.width > 1, ext.height > 1, target.width > 0,
               (abs(target.width - ext.width) > 1 || abs(target.height - ext.height) > 1) {
                ci = ci.transformed(by: CGAffineTransform(scaleX: target.width / ext.width, y: target.height / ext.height))
            }
            self.lock.lock(); self.latest = ci; self.lock.unlock()
        }
    }
}
