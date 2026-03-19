import SwiftUI

enum AppTheme {
    // MARK: - Primary Colors
    static let primary = Color(hex: "#F3FFCA")
    static let primaryFixed = Color(hex: "#CAFD00")
    static let primaryDim = Color(hex: "#BEEE00")
    static let onPrimary = Color(hex: "#516700")
    static let primaryContainer = Color(hex: "#CAFD00")
    static let onPrimaryContainer = Color(hex: "#4A5E00")

    // MARK: - Secondary Colors
    static let secondary = Color(hex: "#FF7440")
    static let secondaryDim = Color(hex: "#FF7440")
    static let error = Color(hex: "#FF7351")

    // MARK: - Surface Colors
    static let surface = Color(hex: "#0E0E0E")
    static let surfaceContainer = Color(hex: "#1A1919")
    static let surfaceContainerLow = Color(hex: "#131313")
    static let surfaceContainerHigh = Color(hex: "#201F1F")
    static let surfaceContainerHighest = Color(hex: "#262626")
    static let surfaceBright = Color(hex: "#2C2C2C")
    static let surfaceContainerLowest = Color(hex: "#000000")

    // MARK: - On-Surface
    static let onSurface = Color.white
    static let onSurfaceVariant = Color(hex: "#ADAAAA")
    static let outlineVariant = Color(hex: "#494847")
    static let outline = Color(hex: "#777575")
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
