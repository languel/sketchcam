import AppKit
import SketchCamCore
import UniformTypeIdentifiers

enum CanvasClipboard {
    static let nativeType = NSPasteboard.PasteboardType("io.github.languel.sketchcam.objects")

    static func copy(_ gestures: [GestureClip]) throws {
        guard !gestures.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(try JSONEncoder().encode(gestures), forType: nativeType)
        board.setString(svg(gestures), forType: .init(UTType.svg.identifier))
        board.setString(excalidraw(gestures), forType: .init("application/vnd.excalidraw+json"))
    }

    static func paste(center: CGPoint, viewHeight: CGFloat) throws -> [GestureClip] {
        let board = NSPasteboard.general
        if let data = board.data(forType: nativeType) {
            return centered(try JSONDecoder().decode([GestureClip].self, from: data), at: center)
        }
        let excalidrawType = NSPasteboard.PasteboardType("application/vnd.excalidraw+json")
        if let string = board.string(forType: excalidrawType) ?? board.string(forType: .string),
           string.contains("\"elements\"") {
            let values = try parseExcalidraw(Data(string.utf8), viewHeight: viewHeight)
            if !values.isEmpty { return centered(values, at: center) }
        }
        if let string = board.string(forType: .init(UTType.svg.identifier)) ?? board.string(forType: .string),
           string.contains("<svg") {
            return centered(parseSVG(string, viewHeight: viewHeight), at: center)
        }
        return []
    }

    private static func centered(_ values: [GestureClip], at center: CGPoint) -> [GestureClip] {
        let points = values.flatMap { $0.curve.anchors.map(\.position) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return values }
        let delta = CGPoint(x: center.x - (minX + maxX) / 2, y: center.y - (minY + maxY) / 2)
        return values.map { source in
            var copy = source; copy.id = UUID(); copy.name += " pasted"
            copy.samples = copy.samples.map { var s = $0; s.position.x += delta.x; s.position.y += delta.y; return s }
            copy.curve.anchors = copy.curve.anchors.map { var a = $0; a.id = UUID(); a.position.x += delta.x; a.position.y += delta.y; return a }
            return copy
        }
    }

    private static func svg(_ gestures: [GestureClip]) -> String {
        let paths = gestures.map { gesture in
            let anchors = gesture.curve.anchors
            guard let first = anchors.first else { return "" }
            var d = "M \(first.position.x) \(first.position.y)"
            for index in 1..<anchors.count {
                let a = anchors[index - 1], b = anchors[index]
                let c1 = CGPoint(x: a.position.x + a.tangentOut.x, y: a.position.y + a.tangentOut.y)
                let c2 = CGPoint(x: b.position.x + b.tangentIn.x, y: b.position.y + b.tangentIn.y)
                d += " C \(c1.x) \(c1.y) \(c2.x) \(c2.y) \(b.position.x) \(b.position.y)"
            }
            return "<path d=\"\(d)\" fill=\"none\" stroke=\"black\" stroke-width=\"\(gesture.strokeProfile.size)\"/>"
        }.joined()
        return "<svg xmlns=\"http://www.w3.org/2000/svg\">\(paths)</svg>"
    }

    private static func excalidraw(_ gestures: [GestureClip]) -> String {
        let elements: [[String: Any]] = gestures.map { gesture in
            let points = gesture.samples.map { [$0.position.x, $0.position.y] }
            return ["id": gesture.id.uuidString, "type": "freedraw", "x": 0, "y": 0,
                    "points": points, "pressures": gesture.samples.map { $0.pressure },
                    "strokeColor": "#000000", "backgroundColor": "transparent"]
        }
        let root: [String: Any] = ["type": "excalidraw/clipboard", "elements": elements, "files": [:]]
        let data = try? JSONSerialization.data(withJSONObject: root)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func parseExcalidraw(_ data: Data, viewHeight: CGFloat) throws -> [GestureClip] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return [] }
        return elements.compactMap { element in
            guard ["freedraw", "line", "arrow"].contains(element["type"] as? String ?? ""),
                  let raw = element["points"] as? [[Any]], raw.count > 1 else { return nil }
            let originX = element["x"] as? Double ?? 0, originY = element["y"] as? Double ?? 0
            let scale = viewHeight / 800
            let points = raw.compactMap { p -> CGPoint? in
                guard p.count > 1, let x = p[0] as? Double, let y = p[1] as? Double else { return nil }
                return CGPoint(x: (originX + x) * scale, y: (originY + y) * scale)
            }
            return imported(points, name: "Excalidraw")
        }
    }

    private static func parseSVG(_ string: String, viewHeight: CGFloat) -> [GestureClip] {
        let pattern = #"<path[^>]*\sd=[\"']([^\"']+)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: string) else { return nil }
            let tokens = String(string[valueRange]).replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: #"([A-Za-z])"#, with: " $1 ", options: .regularExpression)
                .split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var points: [CGPoint] = [], index = 0, command = ""
            func number(_ i: Int) -> CGFloat? { i < tokens.count ? Double(tokens[i]).map { CGFloat($0) } : nil }
            while index < tokens.count {
                if tokens[index].first?.isLetter == true { command = tokens[index].uppercased(); index += 1; continue }
                let needed = command == "C" ? 6 : 2
                guard index + needed <= tokens.count else { break }
                if command == "C", let x = number(index + 4), let y = number(index + 5) { points.append(CGPoint(x: x, y: y)); index += 6 }
                else if let x = number(index), let y = number(index + 1) { points.append(CGPoint(x: x, y: y)); index += 2 }
                else { index += 1 }
            }
            let scale = viewHeight / 800
            return imported(points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }, name: "SVG")
        }
    }

    private static func imported(_ points: [CGPoint], name: String) -> GestureClip? {
        guard points.count > 1 else { return nil }
        let samples = points.enumerated().map { GestureSample(position: $0.element, time: Double($0.offset) / 60) }
        return GestureClip(name: name, duration: max(0.1, Double(points.count - 1) / 60), samples: samples,
                           curve: CurveFitter.fit(samples: samples, recipe: .bezier), timingEstimated: true)
    }
}
