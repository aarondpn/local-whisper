import AppKit
import SwiftUI

enum HUDThemeID: String, CaseIterable, Identifiable, Codable {
    case midnight, ivory, neon, terminal, sunset
    var id: String { rawValue }
}

enum HUDSize: String, CaseIterable, Identifiable, Codable {
    case compact, regular, large
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .regular: return "Regular"
        case .large:   return "Large"
        }
    }

    /// Single scale factor applied to every visual dimension (panel width/height,
    /// corner radius, fonts, indicator, audio viz, padding, spacing). Keeps the
    /// HUD proportions identical across sizes while touching only one knob.
    var scale: CGFloat {
        switch self {
        case .compact: return 0.82
        case .regular: return 1.0
        case .large:   return 1.24
        }
    }
}

enum HUDIndicatorStyle {
    case dot, square, ring
}

struct HUDBlurConfig {
    let material: NSVisualEffectView.Material
    let appearance: NSAppearance.Name
}

struct HUDTheme: Identifiable, Equatable {
    let id: HUDThemeID
    let displayName: String
    let tagline: String

    // Container
    let blur: HUDBlurConfig?
    let tint: Color
    let tintOpacity: Double
    let gradientEnd: Color?
    let gradientAngle: Double // degrees; 0 = left→right, 90 = bottom→top

    let highlight: [Color]
    let border: [Color]
    let shadowColor: Color
    let shadowOpacity: Double
    let shadowRadius: Double

    // Content
    let textColor: Color
    let accent: Color
    let accentGlow: Color
    let indicator: HUDIndicatorStyle

    static func == (lhs: HUDTheme, rhs: HUDTheme) -> Bool { lhs.id == rhs.id }

    static func theme(for id: HUDThemeID) -> HUDTheme {
        switch id {
        case .midnight: return .midnight
        case .ivory:    return .ivory
        case .neon:     return .neon
        case .terminal: return .terminal
        case .sunset:   return .sunset
        }
    }

    static var all: [HUDTheme] { HUDThemeID.allCases.map { theme(for: $0) } }
}

extension HUDTheme {
    static let midnight = HUDTheme(
        id: .midnight,
        displayName: "Midnight",
        tagline: "Frosted glass, coral ember",
        blur: HUDBlurConfig(material: .hudWindow, appearance: .vibrantDark),
        tint: Color(red: 0.04, green: 0.04, blue: 0.06),
        tintOpacity: 0.55,
        gradientEnd: nil,
        gradientAngle: 0,
        highlight: [Color.white.opacity(0.10), Color.white.opacity(0.0)],
        border: [
            Color.white.opacity(0.38),
            Color.white.opacity(0.08),
            Color.white.opacity(0.22)
        ],
        shadowColor: .black,
        shadowOpacity: 0.50,
        shadowRadius: 20,
        textColor: .white,
        accent: Color(red: 1.00, green: 0.27, blue: 0.32),
        accentGlow: Color(red: 1.00, green: 0.22, blue: 0.28),
        indicator: .dot
    )

    static let ivory = HUDTheme(
        id: .ivory,
        displayName: "Ivory",
        tagline: "Warm paper, terracotta ink",
        blur: HUDBlurConfig(material: .popover, appearance: .aqua),
        tint: Color(red: 0.98, green: 0.96, blue: 0.92),
        tintOpacity: 0.75,
        gradientEnd: nil,
        gradientAngle: 0,
        highlight: [Color.white.opacity(0.55), Color.white.opacity(0.0)],
        border: [
            Color(red: 0.22, green: 0.18, blue: 0.11).opacity(0.26),
            Color(red: 0.22, green: 0.18, blue: 0.11).opacity(0.06),
            Color(red: 0.22, green: 0.18, blue: 0.11).opacity(0.16)
        ],
        shadowColor: Color(red: 0.24, green: 0.19, blue: 0.11),
        shadowOpacity: 0.22,
        shadowRadius: 18,
        textColor: Color(red: 0.16, green: 0.12, blue: 0.07),
        accent: Color(red: 0.78, green: 0.32, blue: 0.18),
        accentGlow: Color(red: 0.90, green: 0.44, blue: 0.22),
        indicator: .dot
    )

    static let neon = HUDTheme(
        id: .neon,
        displayName: "Neon",
        tagline: "Vaporwave after hours",
        blur: nil,
        tint: Color(red: 0.05, green: 0.00, blue: 0.09),
        tintOpacity: 1.0,
        gradientEnd: Color(red: 0.11, green: 0.00, blue: 0.16),
        gradientAngle: 135,
        highlight: [Color(red: 1.0, green: 0.17, blue: 0.84).opacity(0.20), Color.clear],
        border: [
            Color(red: 1.0, green: 0.17, blue: 0.84).opacity(0.90),
            Color(red: 0.0, green: 0.96, blue: 1.0).opacity(0.70),
            Color(red: 1.0, green: 0.17, blue: 0.84).opacity(0.90)
        ],
        shadowColor: Color(red: 1.0, green: 0.17, blue: 0.84),
        shadowOpacity: 0.55,
        shadowRadius: 28,
        textColor: Color(red: 0.72, green: 0.98, blue: 1.0),
        accent: Color(red: 1.0, green: 0.17, blue: 0.84),
        accentGlow: Color(red: 1.0, green: 0.17, blue: 0.84),
        indicator: .ring
    )

    static let terminal = HUDTheme(
        id: .terminal,
        displayName: "Terminal",
        tagline: "Phosphor on black, 1982",
        blur: nil,
        tint: Color(red: 0.02, green: 0.04, blue: 0.02),
        tintOpacity: 1.0,
        gradientEnd: Color(red: 0.00, green: 0.06, blue: 0.00),
        gradientAngle: 90,
        highlight: [Color(red: 0.30, green: 1.0, blue: 0.30).opacity(0.10), Color.clear],
        border: [
            Color(red: 0.30, green: 1.0, blue: 0.30).opacity(0.60),
            Color(red: 0.08, green: 0.20, blue: 0.08).opacity(0.20),
            Color(red: 0.30, green: 1.0, blue: 0.30).opacity(0.60)
        ],
        shadowColor: Color(red: 0.0, green: 1.0, blue: 0.0),
        shadowOpacity: 0.32,
        shadowRadius: 14,
        textColor: Color(red: 0.60, green: 1.0, blue: 0.60),
        accent: Color(red: 0.42, green: 1.0, blue: 0.42),
        accentGlow: Color(red: 0.42, green: 1.0, blue: 0.42),
        indicator: .square
    )

    static let sunset = HUDTheme(
        id: .sunset,
        displayName: "Sunset",
        tagline: "Amber dusk to plum",
        blur: HUDBlurConfig(material: .hudWindow, appearance: .vibrantDark),
        tint: Color(red: 1.00, green: 0.46, blue: 0.22),
        tintOpacity: 0.72,
        gradientEnd: Color(red: 0.50, green: 0.10, blue: 0.42),
        gradientAngle: 135,
        highlight: [Color.white.opacity(0.32), Color.white.opacity(0.0)],
        border: [
            Color.white.opacity(0.58),
            Color.white.opacity(0.12),
            Color(red: 1.0, green: 0.82, blue: 0.62).opacity(0.40)
        ],
        shadowColor: Color(red: 0.42, green: 0.10, blue: 0.30),
        shadowOpacity: 0.48,
        shadowRadius: 24,
        textColor: Color.white,
        accent: Color(red: 1.0, green: 0.91, blue: 0.78),
        accentGlow: Color(red: 1.0, green: 0.78, blue: 0.45),
        indicator: .dot
    )
}
