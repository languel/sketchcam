import AppKit
import CoreImage
import SketchCamCore
import WebKit

/// Hosts an off-screen, transparent `WKWebView` (sized to the output) and
/// snapshots it on a timer into a `CIImage` the frame pipeline composites as a
/// layer. The web view lives on the main thread; `currentImage()` is read from
/// the processing queue under a lock.
final class WebLayerController: NSObject {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var timer: Timer?

    private let lock = NSLock()
    private var latest: CIImage?
    private var snapshotInFlight = false

    private var enabled = false
    private var loadedURL = ""
    private var loadedTransparent = true
    private var currentSize: CGSize = .zero
    private var opacity: Float = 1

    /// Snapshot rate — decoupled from the pipeline; the pipeline reuses the
    /// latest snapshot every frame.
    private let snapshotFPS = 20.0

    // MARK: - Driven from the main thread on settings / output changes.

    func update(settings: WebLayerSettings, outputSize: CGSize) {
        opacity = settings.opacity

        guard settings.enabled else {
            enabled = false
            stopTimer()
            lock.lock(); latest = nil; lock.unlock()
            return
        }
        enabled = true
        ensureWebView(size: outputSize)
        if currentSize != outputSize, outputSize.width > 0, outputSize.height > 0 {
            currentSize = outputSize
            webView?.frame = CGRect(origin: .zero, size: outputSize)
            window?.setContentSize(outputSize)
        }
        if settings.urlString != loadedURL || settings.transparentBackground != loadedTransparent {
            loadedURL = settings.urlString
            loadedTransparent = settings.transparentBackground
            reload()
        }
        startTimer()
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
        // Transparent web-view background (the page CSS is handled separately).
        wv.setValue(false, forKey: "drawsBackground")
        wv.layer?.backgroundColor = NSColor.clear.cgColor

        // An off-screen, invisible window so the web content actually renders.
        let win = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: frame.size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        win.contentView = wv
        win.orderFrontRegardless()

        webView = wv
        window = win
        currentSize = frame.size
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

    // MARK: - Snapshotting

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / snapshotFPS, repeats: true) { [weak self] _ in self?.snapshot() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
