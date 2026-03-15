import Foundation

public enum TriggerKey: String, CaseIterable {
    case fn = "fn"
    case spacebar = "spacebar"

    public var displayName: String {
        switch self {
        case .fn: return "Fn"
        case .spacebar: return "Spacebar"
        }
    }

    public var keyLabel: String {
        switch self {
        case .fn: return "fn"
        case .spacebar: return "␣"
        }
    }

    public static var saved: TriggerKey {
        let raw = UserDefaults.standard.string(forKey: "triggerKey") ?? "fn"
        return TriggerKey(rawValue: raw) ?? .fn
    }

    public func save() {
        UserDefaults.standard.set(self.rawValue, forKey: "triggerKey")
    }
}
