import AppKit
import Foundation
import SwiftUI

struct SystemInputMappingPanel: View {
    @ObservedObject private var pointer: SystemPointerController

    init(model: SketchCamViewModel) {
        _pointer = ObservedObject(wrappedValue: model.systemPointer)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SYSTEM POINTER").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(pointer.live.status)
                            .font(.caption2).foregroundStyle(pointer.isArmed ? Color.accentColor : Color.secondary)
                    }
                    Spacer()
                    Button(pointer.isArmed ? "Disarm" : "Arm") {
                        if pointer.isArmed {
                            pointer.disarm()
                        } else {
                            _ = pointer.arm()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(pointer.isArmed ? .red : .accentColor)
                }

                if !pointer.isTrusted {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Accessibility access is missing or belongs to an older build. After rebuilding, toggle SketchCam off and on in System Settings. If that does not refresh it, remove SketchCam with − and add /Applications/SketchCam.app again with +, then reopen the app.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Request access") { pointer.requestAccessibility() }
                            Button("Open Settings") { pointer.openAccessibilitySettings() }
                            Button("Refresh") { pointer.refreshTrust() }
                        }
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.10)))
                }

                section("POINTER FEATURE") {
                    MediaPipeHomunculusMap(selection: $pointer.mapping.pointer)
                        .frame(minHeight: 275)
                    HStack {
                        Text(pointer.mapping.pointer.title).font(.caption)
                        Spacer()
                        if pointer.live.featureAvailable {
                            Label("live", systemImage: "circle.fill")
                                .font(.caption2).foregroundStyle(.green)
                        }
                    }
                }

                section("BEHAVIOR") {
                    Picker("Drive", selection: $pointer.mapping.driveMode) {
                        ForEach(SystemPointerDriveMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Pinch controls primary button", isOn: $pointer.mapping.clickWithPinch)
                        .help("Pinch closes the button; release opens it. A quick pinch clicks, while holding the pinch drags.")
                    valueSlider("Smoothing", value: $pointer.mapping.smoothing, range: 0...0.9, defaultValue: 0.55)
                    valueSlider("Camera width", value: $pointer.mapping.horizontalCoverage, range: 0.2...1, defaultValue: 0.75)
                    valueSlider("Camera height", value: $pointer.mapping.verticalCoverage, range: 0.2...1, defaultValue: 0.75)
                    valueSlider("Pinch", value: $pointer.mapping.pinchThreshold, range: 0.15...0.65, defaultValue: 0.35)
                }

                section("LIVE") {
                    HStack {
                        liveValue("Pointer", pointer.live.normalizedPoint.map { String(format: "%.3f, %.3f", $0.x, $0.y) } ?? "—")
                        liveValue("Pinch", pointer.live.pinchValue.map { String(format: "%.3f", $0) } ?? "—")
                        liveValue("Button", pointer.live.pinching ? "down" : "up")
                    }
                    Text(pointer.mapping.driveMode == .always
                         ? "Always continuously maps the selected landmark to the main display and can override physical mouse movement."
                         : "While pinching leaves the physical mouse alone until the gesture engages, then moves and drags from the selected landmark.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            pointer.refreshTrust()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, defaultValue: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 88, alignment: .leading)
                .onTapGesture(count: 2) { value.wrappedValue = defaultValue }
                .help("Double-click to reset")
            Slider(value: value, in: range).controlSize(.small)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                .font(.caption2.monospacedDigit()).frame(width: 34, alignment: .trailing)
        }
    }

    private func liveValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.caption.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MediaPipeHomunculusMap: View {
    @Binding var selection: MediaPipeHandFeature

    private static let edges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (5, 9), (9, 10), (10, 11), (11, 12),
        (9, 13), (13, 14), (14, 15), (15, 16),
        (13, 17), (0, 17), (17, 18), (18, 19), (19, 20)
    ]
    private static let handPoints: [CGPoint] = [
        CGPoint(x: 0.50, y: 0.90),
        CGPoint(x: 0.38, y: 0.75), CGPoint(x: 0.27, y: 0.66), CGPoint(x: 0.18, y: 0.56), CGPoint(x: 0.08, y: 0.46),
        CGPoint(x: 0.39, y: 0.60), CGPoint(x: 0.35, y: 0.43), CGPoint(x: 0.33, y: 0.27), CGPoint(x: 0.31, y: 0.10),
        CGPoint(x: 0.53, y: 0.56), CGPoint(x: 0.53, y: 0.37), CGPoint(x: 0.53, y: 0.19), CGPoint(x: 0.53, y: 0.03),
        CGPoint(x: 0.66, y: 0.61), CGPoint(x: 0.69, y: 0.43), CGPoint(x: 0.71, y: 0.27), CGPoint(x: 0.72, y: 0.12),
        CGPoint(x: 0.78, y: 0.70), CGPoint(x: 0.84, y: 0.55), CGPoint(x: 0.88, y: 0.42), CGPoint(x: 0.91, y: 0.29)
    ]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { context, _ in
                    drawBody(context: &context, size: size)
                    for side in MediaPipeHandSide.allCases {
                        for edge in Self.edges {
                            var path = Path()
                            path.move(to: point(side: side, index: edge.0, size: size))
                            path.addLine(to: point(side: side, index: edge.1, size: size))
                            context.stroke(path, with: .color(.secondary.opacity(0.48)), lineWidth: 1.4)
                        }
                    }
                }
                ForEach(MediaPipeHandFeature.allCases) { feature in
                    let selected = feature == selection
                    let pinchPoint = feature.landmark == .thumbTip || feature.landmark == .indexTip
                    Button {
                        selection = feature
                    } label: {
                        Circle()
                            .fill(selected ? Color.accentColor : (pinchPoint ? Color.orange.opacity(0.85) : Color.secondary.opacity(0.62)))
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: selected ? 2 : 1))
                            .frame(width: selected ? 14 : 10, height: selected ? 14 : 10)
                    }
                    .buttonStyle(.plain)
                    .position(point(side: feature.side, index: feature.landmark.rawValue, size: size))
                    .help(feature.title + (pinchPoint ? " · pinch landmark" : ""))
                    .accessibilityLabel(feature.title)
                }
                Text("LEFT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .position(x: size.width * 0.22, y: 12)
                Text("RIGHT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .position(x: size.width * 0.78, y: 12)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.22)))
        }
    }

    private func point(side: MediaPipeHandSide, index: Int, size: CGSize) -> CGPoint {
        let source = Self.handPoints[index]
        let localX = side == .left ? 1 - source.x : source.x
        let centerX = side == .left ? size.width * 0.22 : size.width * 0.78
        return CGPoint(
            x: centerX + (localX - 0.5) * size.width * 0.32,
            y: 32 + source.y * size.height * 0.58
        )
    }

    private func drawBody(context: inout GraphicsContext, size: CGSize) {
        let color = Color.secondary.opacity(0.23)
        let center = size.width * 0.5
        let top = size.height * 0.62
        context.stroke(Path(ellipseIn: CGRect(x: center - 13, y: top, width: 26, height: 30)), with: .color(color), lineWidth: 2)
        var body = Path()
        body.move(to: CGPoint(x: center, y: top + 30))
        body.addLine(to: CGPoint(x: center, y: size.height * 0.84))
        body.move(to: CGPoint(x: center, y: top + 48))
        body.addLine(to: CGPoint(x: center - 38, y: size.height * 0.76))
        body.move(to: CGPoint(x: center, y: top + 48))
        body.addLine(to: CGPoint(x: center + 38, y: size.height * 0.76))
        body.move(to: CGPoint(x: center, y: size.height * 0.84))
        body.addLine(to: CGPoint(x: center - 26, y: size.height - 10))
        body.move(to: CGPoint(x: center, y: size.height * 0.84))
        body.addLine(to: CGPoint(x: center + 26, y: size.height - 10))
        context.stroke(body, with: .color(color), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
    }
}
