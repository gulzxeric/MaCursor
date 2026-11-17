import Foundation

enum MACPreferences {
    static let padCursorCanvasKey = "pad"
    static let handednessKey = "hand"
    static let cursorScaleKey = "scale"
    static let cursorShadowKey = "shadow"
    static let appliedCursorKey = "applied"
    static func value(forKey: String) -> Any? { nil }
    static func set(_ value: Any?, forKey: String) {}
}

enum MACCursorCapture {
    static let systemDefaultPath = ""
}
