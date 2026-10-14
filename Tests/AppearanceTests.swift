import AppKit
import SwiftUI

@main struct AppearanceTests {
    @MainActor static func main() {
        var minimumContrast = Double.infinity
        var minimumLightReadingContrast = Double.infinity
        for accent in AgendaAccentColor.allCases {
            for mode in [AgendaAppearanceMode.light, .dark] {
                let palette = AgendaPalette(mode: mode, accent: accent, systemScheme: mode == .light ? .dark : .light)
                precondition(palette.isDark == (mode == .dark), "explicit appearance ignores the system scheme")
                precondition(palette.preferredColorScheme == (mode == .dark ? .dark : .light), "explicit appearance sets its preferred scheme")
                let pairs: [(String, Color, Color)] = [
                    ("body", palette.ink, palette.background),
                    ("secondary", palette.secondary, palette.background),
                    ("hero", palette.heroInk, palette.heroBackground),
                    ("hero end", palette.heroInk, palette.heroEnd),
                    ("hero secondary", palette.heroSecondary, palette.heroBackground),
                    ("hero secondary end", palette.heroSecondary, palette.heroEnd),
                    ("control", palette.ink, palette.controlFill),
                    ("control secondary", palette.secondary, palette.controlFill),
                    ("primary", palette.primaryInk, palette.primaryFill),
                    ("accent", palette.accent, palette.background),
                    ("warning", palette.warning, palette.background),
                    ("hero warning", palette.warning, palette.heroBackground),
                    ("hero end warning", palette.warning, palette.heroEnd)
                ]
                var paletteMinimum = Double.infinity
                for (name, foreground, background) in pairs {
                    let ratio = contrast(foreground, background)
                    precondition(ratio >= 4.5, "\(accent.rawValue) \(mode.rawValue) \(name) text contrast \(ratio) is below 4.5")
                    paletteMinimum = min(paletteMinimum, ratio)
                }
                if mode == .light {
                    // Small dates, countdowns and completed rows use these neutral
                    // reading colors; keep stronger contrast on every opaque surface.
                    let readingPairs: [(Color, Color)] = [
                        (palette.ink, palette.background),
                        (palette.secondary, palette.background),
                        (palette.heroInk, palette.heroBackground),
                        (palette.heroInk, palette.heroEnd),
                        (palette.heroSecondary, palette.heroBackground),
                        (palette.heroSecondary, palette.heroEnd),
                        (palette.ink, palette.controlFill),
                        (palette.secondary, palette.controlFill)
                    ]
                    for (foreground, background) in readingPairs {
                        let ratio = contrast(foreground, background)
                        precondition(ratio >= 7, "\(accent.rawValue) light reading contrast \(ratio) is below 7")
                        minimumLightReadingContrast = min(minimumLightReadingContrast, ratio)
                    }
                    precondition(luminance(palette.ink) < luminance(palette.secondary), "body text remains darker than secondary text")
                }
                for color in [palette.background, palette.ink, palette.secondary, palette.accent, palette.warning, palette.heroBackground, palette.heroEnd, palette.heroInk, palette.heroSecondary, palette.controlFill, palette.primaryFill, palette.primaryInk, palette.border, palette.divider] {
                    precondition(abs(srgb(color).alphaComponent - 1) < 1e-6, "palette tokens are opaque; transparency belongs to the background compositor")
                }
                let heroLuminance = luminance(palette.heroBackground)
                precondition(mode == .light ? heroLuminance > 0.7 : heroLuminance < 0.1, "hero background follows the selected shallow/deep appearance")
                minimumContrast = min(minimumContrast, paletteMinimum)
                print(String(format: "%@ %@: minimum text contrast %.3f", accent.rawValue, mode.rawValue, paletteMinimum))
            }
            for systemScheme in [ColorScheme.light, .dark] {
                let palette = AgendaPalette(mode: .system, accent: accent, systemScheme: systemScheme)
                let explicit = AgendaPalette(mode: systemScheme == .dark ? .dark : .light, accent: accent, systemScheme: systemScheme)
                precondition(palette.isDark == (systemScheme == .dark) && palette.preferredColorScheme == nil, "system appearance follows the supplied scheme without overriding it")
                precondition(srgb(palette.background) == srgb(explicit.background) && srgb(palette.heroBackground) == srgb(explicit.heroBackground) && srgb(palette.accent) == srgb(explicit.accent), "system appearance selects the matching explicit palette")
                precondition(srgb(palette.ink) == srgb(explicit.ink) && srgb(palette.secondary) == srgb(explicit.secondary) && srgb(palette.heroInk) == srgb(explicit.heroInk) && srgb(palette.heroSecondary) == srgb(explicit.heroSecondary), "system appearance uses the same reading colors as its explicit palette")
            }
        }
        let defaultPalette = EnvironmentValues().agendaPalette
        let lightGreen = AgendaPalette(mode: .light, accent: .green, systemScheme: .light)
        precondition(!defaultPalette.isDark && srgb(defaultPalette.accent) == srgb(lightGreen.accent), "environment defaults to light green")
        let warningLight = AgendaPalette(mode: .light, accent: .green, systemScheme: .light).warning
        let warningDark = AgendaPalette(mode: .dark, accent: .green, systemScheme: .dark).warning
        for accent in AgendaAccentColor.allCases {
            precondition(srgb(AgendaPalette(mode: .light, accent: accent, systemScheme: .light).warning) == srgb(warningLight), "light warning color is independent of accent")
            precondition(srgb(AgendaPalette(mode: .dark, accent: accent, systemScheme: .dark).warning) == srgb(warningDark), "dark warning color is independent of accent")
        }
        print(String(format: "PASS: five accents × two explicit appearances, 130 text contrast pairs (minimum %.3f), system appearance, opaque tokens, light hero, environment default, independent warning color", minimumContrast))
        print(String(format: "PASS: 40 light reading contrast pairs ≥ 7 (minimum %.3f), distinct body/secondary hierarchy", minimumLightReadingContrast))
        print("Not verified here: contrast over a transparent desktop, window rendering, or installed-app appearance.")
    }

    @MainActor private static func srgb(_ color: Color) -> NSColor {
        guard let value = NSColor(color).usingColorSpace(.sRGB) else { preconditionFailure("palette color cannot convert to sRGB") }
        return value
    }

    @MainActor private static func luminance(_ color: Color) -> Double {
        let value = srgb(color)
        func linear(_ component: CGFloat) -> Double {
            let c = Double(component)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(value.redComponent) + 0.7152 * linear(value.greenComponent) + 0.0722 * linear(value.blueComponent)
    }

    @MainActor private static func contrast(_ first: Color, _ second: Color) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
