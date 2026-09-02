import SwiftUI
import AppKit

/// Colour and metric constants for the whole interface.
///
/// One accent, no second decorative colour. Measurement colours are data and
/// live in `OverlayCompositor`; nothing here overrides them.
enum Theme {
    // MARK: - Surfaces

    static let windowBackground = Color(hex: 0x0F1115)
    static let emptyBackground = Color(hex: 0x0B0D10)
    static let titleBar = Color(red: 18 / 255, green: 21 / 255, blue: 26 / 255, opacity: 0.86)
    static let glass = Color(red: 13 / 255, green: 16 / 255, blue: 20 / 255, opacity: 0.60)

    static let hairline = Color.white.opacity(0.10)
    static let hairlineStrong = Color.white.opacity(0.13)

    // MARK: - Accent

    static let accent = Color(hex: 0x5980A6)
    static let accentLine = Color(hex: 0x749DC4)
    static let accentBright = Color(hex: 0x94BCE3)
    static let accentTint = Color(red: 116 / 255, green: 157 / 255, blue: 196 / 255, opacity: 0.14)
    static let accentTintStrong = Color(red: 116 / 255, green: 157 / 255, blue: 196 / 255, opacity: 0.20)

    // MARK: - Text

    static let text = Color(hex: 0xE8EAED)
    static let textSecondary = Color(hex: 0x8B939C)
    static let label = Color(hex: 0x6B737C)
    static let warmValue = Color(hex: 0xFFD9D6)

    // MARK: - State

    static let stateStreaming = Color(hex: 0x30D158)
    static let stateConnecting = Color(hex: 0xFF9F0A)
    static let stateIdle = Color(hex: 0x6B737C)
    static let stateError = Color(hex: 0xFF453A)

    static let hover = Color.white.opacity(0.07)
    static let blueprintGrid = Color(red: 148 / 255, green: 188 / 255, blue: 227 / 255, opacity: 0.045)
    static let plotBackground = Color(red: 148 / 255, green: 188 / 255, blue: 227 / 255, opacity: 0.03)
    static let plotGrid = Color(red: 148 / 255, green: 188 / 255, blue: 227 / 255, opacity: 0.25)

    // MARK: - Metrics

    static let titleBarHeight: CGFloat = 46
    static let inspectorWidth: CGFloat = 320
    static let readoutWidth: CGFloat = 268
    static let scaleBarWidth: CGFloat = 12
    static let scaleBarHeight: CGFloat = 360
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// The three type families used across the interface.
extension Font {
    /// Section headings and control labels: condensed, letterspaced capitals.
    static func hpLabel(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .custom(weight == .semibold ? "BarlowCondensed-SemiBold" : "BarlowCondensed-Medium",
                size: size)
    }

    /// Large measurement values.
    static func hpReadout(_ size: CGFloat) -> Font {
        .custom("BarlowCondensed-Medium", size: size)
    }

    /// Running text and hints.
    static func hpBody(_ size: CGFloat) -> Font {
        .custom("Barlow-Regular", size: size)
    }

    /// Inline numbers, identifiers and times.
    static func hpMono(_ size: CGFloat) -> Font {
        .custom("IBMPlexMono-Regular", size: size)
    }
}

extension Text {
    /// Applies the letterspacing that goes with the condensed label face.
    func hpTracked(_ tracking: CGFloat) -> Text { self.tracking(tracking) }
}
