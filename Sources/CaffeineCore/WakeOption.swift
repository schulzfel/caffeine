import Foundation

/// A keep-awake behavior that can be selected independently.
public enum WakeOption: String, CaseIterable, Codable, Hashable, Sendable {
    case systemAwake
    case displayOn
    case screenSaver
    case lidClosed

    public static let ordinaryCases = allCases.filter {
        $0 != .lidClosed
    }

    public var title: String {
        switch self {
        case .systemAwake:
            return "Keep Mac Awake (Display Can Sleep)"
        case .displayOn:
            return "Keep Display On"
        case .screenSaver:
            return "Prevent Screen Saver"
        case .lidClosed:
            return "Stay Awake When Lid Closed"
        }
    }
}
