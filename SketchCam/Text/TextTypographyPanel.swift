import AppKit
import SwiftUI
import SketchCamCore

struct TextTypographyPanel: View {
    @Binding var configuration: TextLayerConfig
    @State private var fontOpen = false
    @State private var fontSearch = ""
    private static let families = NSFontManager.shared.availableFontFamilies.sorted()
    private var family: String { NSFont(name: configuration.fontName, size: 12)?.familyName ?? configuration.fontName }
    private var faces: [(name: String, style: String)] {
        (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap {
            guard $0.count > 1, let name = $0[0] as? String, let style = $0[1] as? String else { return nil }
            return (name, style)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup("Font") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Family").frame(width: 64, alignment: .leading)
                        Button(family) { fontOpen.toggle() }.popover(isPresented: $fontOpen) {
                            VStack(spacing: 6) {
                                TextField("Find installed font", text: $fontSearch).help("Filter the fonts installed on this Mac by family name.")
                                List(Self.families.filter { fontSearch.isEmpty || $0.localizedCaseInsensitiveContains(fontSearch) }, id: \.self) { family in
                                    Button(family) {
                                        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
                                        let regular = members.first { member in
                                            guard member.count > 1, let style = member[1] as? String else { return false }
                                            return ["Regular", "Roman", "Book"].contains(style)
                                        } ?? members.first
                                        if let name = regular?.first as? String { configuration.fontName = name }
                                        fontOpen = false
                                    }.buttonStyle(.plain).help("Use this installed family, starting with its Regular, Roman or Book face when available.")
                                }
                            }.padding(8).frame(width: 290, height: 320)
                        }.help("Choose an installed font family. This does not download or bundle fonts.")
                    }
                    if !faces.isEmpty {
                        Picker("Face", selection: Binding(
                            get: { NSFont(name: configuration.fontName, size: 12)?.fontName ?? configuration.fontName },
                            set: { configuration.fontName = $0 }
                        )) {
                            ForEach(faces, id: \.name) { face in Text(face.style).tag(face.name) }
                        }.help("Choose an actual face/weight provided by this font family. Bold and Italic can add supported traits to that face.")
                    }
                    TextField("Font name", text: $configuration.fontName).help("Installed PostScript or display font name. Fonts aren't bundled in presets.")
                    HStack {
                        Toggle("Bold", isOn: boolean(\.bold)).help("Add bold to the selected face when the family supports it.")
                        Toggle("Italic", isOn: boolean(\.italic)).help("Add italic to the selected face when the family supports it.")
                    }
                    Picker("Case", selection: option(\.letterCase, default: .original)) {
                        Text("Original").tag(TextLetterCase.original)
                        Text("UPPERCASE").tag(TextLetterCase.uppercase)
                        Text("lowercase").tag(TextLetterCase.lowercase)
                    }.help("Change letter case for rendering only; preserve the original script/transcript text.")
                    row("Size % H", value: Binding(get: { configuration.fontSize * 100 }, set: { configuration.fontSize = $0 / 100 }), range: 1.5...50)
                    row("Tracking", value: option(\.letterSpacing, default: 0), range: -0.1...0.5)
                        .help("Additional letter spacing in em units.")
                    row("Leading", value: option(\.lineSpacing, default: 1), range: 0.6...3)
                        .help("Line-height multiplier.")
                }.padding(.top, 4)
            }
            DisclosureGroup("Layout") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Align", selection: option(\.alignment, default: .automatic)) {
                        Text("Mode default").tag(TextHorizontalAlignment.automatic)
                        Text("Left").tag(TextHorizontalAlignment.left)
                        Text("Center").tag(TextHorizontalAlignment.center)
                        Text("Right").tag(TextHorizontalAlignment.right)
                        Text("Justified").tag(TextHorizontalAlignment.justified)
                    }.help("Horizontal alignment inside the padded text box. Mode default is Left for Type-on and Center otherwise. Justified distributes spacing to fill a line.")
                    if configuration.alignment == .justified {
                        Toggle("Justify last line", isOn: boolean(\.justifyLastLine))
                            .help("Stretch even the last line across the available width. This can move letters as words arrive.")
                    }
                    row("X", value: $configuration.x, range: 0...1)
                    row("Y", value: $configuration.y, range: 0...1)
                    row("Width", value: $configuration.width, range: 0.05...1)
                    Stepper("Lines: \(configuration.lineLimit)", value: $configuration.lineLimit, in: 1...12).help("Maximum rows in the caption area. Type-on reserves these rows from its first word. New pages begin when the capacity is filled.")
                    Toggle("Fixed box height", isOn: Binding(get: { configuration.height != nil }, set: { enabled in
                        configuration.height = enabled ? 0.35 : nil
                        if !enabled { configuration.fontFit = .fixed }
                    })).help("Reserve an explicit box height instead of deriving height from text rows; enables vertical alignment and proportional font fitting.")
                    if configuration.height != nil {
                        row("Height", value: option(\.height, default: 0.35), range: 0.02...1)
                        Picker("Vertical", selection: option(\.verticalAlignment, default: .top)) {
                            Text("Top").tag(TextVerticalAlignment.top)
                            Text("Center").tag(TextVerticalAlignment.center)
                            Text("Bottom").tag(TextVerticalAlignment.bottom)
                        }.help("Position the text block vertically within the fixed-height box, respecting vertical padding.")
                        Picker("Font size", selection: option(\.fontFit, default: .fixed)) {
                            Text("Fixed").tag(TextFontFit.fixed)
                            Text("Shrink to fit").tag(TextFontFit.shrink)
                            Text("Fit box").tag(TextFontFit.fit)
                        }.help("Fit box changes font size as content grows; Fixed retains steady glyph size.")
                    }
                    row("Pad X em", value: option(\.paddingHorizontal, default: configuration.style == .trail ? 0.15 : 0.25), range: 0...3)
                    row("Pad Y em", value: option(\.paddingVertical, default: configuration.style == .trail ? 0.15 : 0.25), range: 0...3)
                    row("Radius em", value: option(\.cornerRadius, default: configuration.paddingHorizontal ?? 0.25), range: 0...2)
                }.padding(.top, 4)
            }
        }
    }
    private func option<T>(_ key: WritableKeyPath<TextLayerConfig, T?>, default fallback: T) -> Binding<T> {
        Binding(get: { configuration[keyPath: key] ?? fallback }, set: { configuration[keyPath: key] = $0 })
    }
    private func boolean(_ key: WritableKeyPath<TextLayerConfig, Bool?>) -> Binding<Bool> { option(key, default: false) }
    private func row(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range)
            TextField(label, value: value, format: .number.precision(.fractionLength(2)))
                .frame(width: 48).multilineTextAlignment(.trailing)
        }.help(parameterHelp(label))
    }

    private func parameterHelp(_ label: String) -> String {
        switch label {
        case "Size % H": return "Font point size as a percentage of output height. Fit box can override it; Shrink uses it as the maximum. Glyph proportions are preserved."
        case "Tracking": return "Extra space per character cluster in em units (a fraction of font size). Negative values tighten letters; positive values spread them. Changes wrapping."
        case "Leading": return "Line-height multiplier. One uses the font's natural metrics; smaller values tighten or overlap rows, larger values spread them apart."
        case "X": return "Horizontal center of the text box: 0 is the left edge, 0.5 the frame center, 1 the right edge. Alignment determines where text sits within this box."
        case "Y": return "Vertical center of the text box, measured down from the frame top: 0 top, 0.5 center, 1 bottom. Type-on keeps its reserved rows stationary around this position."
        case "Width": return "Text-box width as a fraction of the output frame width. Together with padding, font size and row limit, this determines wrapping and pagination."
        case "Height": return "Fixed text-box height as a fraction of output height. Text is aligned or proportionally fitted within this area."
        case "Pad X em": return "Left/right inset, measured in em units relative to the resolved font size. Padding reduces the line's usable width."
        case "Pad Y em": return "Top/bottom inset, measured in em units relative to the resolved font size. Padding reduces usable box height."
        case "Radius em": return "Background-box corner radius in em units. Zero makes square corners. Fading words uses individual word backgrounds."
        default: return label
        }
    }
}
