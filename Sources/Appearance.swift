import SwiftUI

struct AgendaPalette {
    let background: Color
    let ink: Color
    let secondary: Color
    let accent: Color
    let warning: Color
    let heroBackground: Color
    let heroEnd: Color
    let heroInk: Color
    let heroSecondary: Color
    let controlFill: Color
    let primaryFill: Color
    let primaryInk: Color
    let border: Color
    let divider: Color
    let isDark: Bool
    let preferredColorScheme: ColorScheme?

    init(mode: AgendaAppearanceMode, accent: AgendaAccentColor, systemScheme: ColorScheme) {
        isDark = mode == .dark || (mode == .system && systemScheme == .dark)
        preferredColorScheme = mode == .system ? nil : (isDark ? .dark : .light)
        let values: (background: UInt32, hero: UInt32, end: UInt32, ink: UInt32, secondary: UInt32, accent: UInt32, control: UInt32, border: UInt32, divider: UInt32)
        switch (accent, isDark) {
        case (.green, false):
            values = (0xF3F6F1, 0xE3EDE0, 0xF0F5ED, 0x17251C, 0x354536, 0x2F6746, 0xEAF0E6, 0xBACAB5, 0xD7E1D2)
        case (.blue, false):
            values = (0xF1F5F8, 0xDEEAF4, 0xEDF3F9, 0x17232F, 0x364959, 0x315F89, 0xE7EEF5, 0xB6C8D8, 0xD2DFE9)
        case (.purple, false):
            values = (0xF6F3F8, 0xEADFF3, 0xF4EEF8, 0x251B2D, 0x4C3B57, 0x6F4D91, 0xEEE7F4, 0xCDBDD8, 0xDFD5E8)
        case (.orange, false):
            values = (0xF8F4EE, 0xF4E4D2, 0xFBF2E7, 0x2A2018, 0x57402E, 0x965423, 0xF4EADF, 0xD8C2AA, 0xE8DAC9)
        case (.graphite, false):
            values = (0xF4F4F3, 0xE4E7E6, 0xF0F2F1, 0x1D2424, 0x3E4848, 0x4C6061, 0xE9ECEB, 0xC0C9C7, 0xD8DEDC)
        case (.green, true):
            values = (0x161D18, 0x24362A, 0x1C2920, 0xEDF4EA, 0xAFBFAC, 0x9DCF9F, 0x202C23, 0x465B49, 0x344638)
        case (.blue, true):
            values = (0x161C24, 0x203245, 0x1A2634, 0xEDF3FA, 0xA9BDCE, 0x9CC9F3, 0x1F2A38, 0x425B72, 0x324658)
        case (.purple, true):
            values = (0x1E1824, 0x332541, 0x291F33, 0xF4EDF9, 0xBEAECB, 0xCBB0EA, 0x2A2135, 0x5D486F, 0x463654)
        case (.orange, true):
            values = (0x231C16, 0x402C20, 0x32231A, 0xFBF2E8, 0xCFB9A1, 0xEEC193, 0x34271D, 0x725540, 0x553E2E)
        case (.graphite, true):
            values = (0x1B1E1F, 0x2C3336, 0x242A2D, 0xF0F4F5, 0xB4C0C4, 0xBDCACE, 0x272E31, 0x526065, 0x3D494D)
        }
        background = Self.color(values.background)
        ink = Self.color(values.ink)
        secondary = Self.color(values.secondary)
        self.accent = Self.color(values.accent)
        warning = Self.color(isDark ? 0xF2BD63 : 0x865214)
        heroBackground = Self.color(values.hero)
        heroEnd = Self.color(values.end)
        heroInk = ink
        heroSecondary = secondary
        controlFill = Self.color(values.control)
        primaryFill = self.accent
        primaryInk = Self.color(isDark ? 0x17201B : 0xFFFFFF)
        border = Self.color(values.border)
        divider = Self.color(values.divider)
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

private struct AgendaPaletteKey: EnvironmentKey {
    static let defaultValue = AgendaPalette(mode: .light, accent: .green, systemScheme: .light)
}

extension EnvironmentValues {
    var agendaPalette: AgendaPalette {
        get { self[AgendaPaletteKey.self] }
        set { self[AgendaPaletteKey.self] = newValue }
    }
}
