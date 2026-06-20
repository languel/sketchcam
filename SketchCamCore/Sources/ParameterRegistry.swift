import Foundation

public enum AutomationValueKind: String, Codable, Sendable { case scalar, point, color, boolean, enumeration }

public struct ParameterDescriptor: Identifiable, Equatable, Sendable {
    public var component: String
    public var parameter: String
    public var name: String
    public var kind: AutomationValueKind
    public var defaultValue: AutomationValue
    public var id: String { "\(component).\(parameter)" }

    public init(component: String, parameter: String, name: String, kind: AutomationValueKind, defaultValue: AutomationValue) {
        self.component = component; self.parameter = parameter; self.name = name; self.kind = kind; self.defaultValue = defaultValue
    }
}

/// Public, label-independent automation vocabulary. UI labels can change
/// without invalidating a project because persisted addresses use these IDs.
public enum SketchParameterRegistry {
    public static let descriptors: [ParameterDescriptor] = [
        .init(component: "paper", parameter: "opacity", name: "Paper Opacity", kind: .scalar, defaultValue: .scalar(1)),
        .init(component: "paper", parameter: "response", name: "Paper Response", kind: .scalar, defaultValue: .scalar(1)),
        .init(component: "ink.environment", parameter: "flow", name: "Fluid Flow", kind: .scalar, defaultValue: .scalar(0.9)),
        .init(component: "ink.environment", parameter: "bleed", name: "Fluid Bleed", kind: .scalar, defaultValue: .scalar(0.8)),
        .init(component: "ink.environment", parameter: "dry", name: "Fluid Dry", kind: .scalar, defaultValue: .scalar(0.25)),
        .init(component: "ink.environment", parameter: "wetDecay", name: "Wet Decay", kind: .scalar, defaultValue: .scalar(1)),
        .init(component: "ink.response", parameter: "paperInfluence", name: "Paper Influence", kind: .scalar, defaultValue: .scalar(0)),
        .init(component: "ink.response", parameter: "motionForce", name: "Motion Force", kind: .scalar, defaultValue: .scalar(0)),
        .init(component: "ink.response", parameter: "motionWetness", name: "Motion Wetness", kind: .scalar, defaultValue: .scalar(0))
    ]

    public static func descriptor(component: String, parameter: String) -> ParameterDescriptor? {
        descriptors.first { $0.component == component && $0.parameter == parameter }
    }
}
