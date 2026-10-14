import AppKit
import Foundation

@main struct BackgroundTests {
    @MainActor static func main() {
        for glassEnabled in [false, true] {
            var previousCoverage = Double.infinity
            for percent in [0, 1, 2, 10, 42, 99, 100] {
                let transparency = Double(percent) / 100
                let opacity = AgendaBackgroundOpacity(transparency: transparency, glassEnabled: glassEnabled)
                let coverage = opacity.tint + (1 - opacity.tint) * opacity.glass
                precondition(coverage < previousCoverage, "composited layers fade monotonically")
                precondition((0...1).contains(opacity.tint) && (0...1).contains(opacity.glass), "finite layer alpha")
                precondition(glassEnabled || opacity.glass == 0, "glass off removes the material")
                if glassEnabled {
                    precondition(abs(opacity.glass - (1 - transparency)) < 1e-12, "material is no longer attenuated behind a strong tint")
                } else {
                    precondition(abs(opacity.tint - (1 - transparency)) < 1e-12, "non-glass tint retains saved transparency")
                }
                previousCoverage = coverage
            }
            let opaque = AgendaBackgroundOpacity(transparency: 0, glassEnabled: glassEnabled)
            let clear = AgendaBackgroundOpacity(transparency: 1, glassEnabled: glassEnabled)
            precondition(opaque.tint == 1, "zero transparency blocks backdrop")
            precondition(clear.tint == 0 && clear.glass == 0, "full transparency removes both layers")
            for step in 0..<1000 {
                let left = AgendaBackgroundOpacity(transparency: Double(step) / 1000, glassEnabled: glassEnabled)
                let right = AgendaBackgroundOpacity(transparency: Double(step + 1) / 1000, glassEnabled: glassEnabled)
                precondition(left.glass >= right.glass && left.tint >= right.tint, "continuous monotonic alpha")
                precondition(left.tint - right.tint <= 0.020001, "tint has no discrete endpoint jump")
                precondition(left.glass - right.glass <= 0.001001, "material has no discrete endpoint jump")
            }
            for value in [0.0, 0.01, 0.42, 1.0, .nan, .infinity, -.infinity] {
                let reduced = AgendaBackgroundOpacity(transparency: value, glassEnabled: glassEnabled, reduceTransparency: true)
                precondition(reduced.tint == 1 && reduced.glass == 0, "system reduced transparency is opaque")
            }
        }
        let everydayGlass = AgendaBackgroundOpacity(transparency: 0.1)
        precondition(everydayGlass.glass >= 0.9 && everydayGlass.tint < 0.15, "usual transparency keeps native glass visible")
        for value in [Double.nan, .infinity, -.infinity] {
            precondition(abs(AgendaBackgroundOpacity(transparency: value).glass - 0.55) < 1e-12, "invalid transparency retains the default")
        }
        precondition(AgendaBackgroundOpacity.clamp(-1) == 0 && AgendaBackgroundOpacity.clamp(2) == 1, "out of range clamp")
        precondition(AgendaBackgroundOpacity.clamp(.nan, fallback: .nan) == 0.55, "invalid fallback remains finite")

        let native = AgendaGlassSurface()
        if #available(macOS 26.0, *) {
            precondition(native.effectView is NSGlassEffectView, "supported OS instantiates real Liquid Glass")
            let glass = native.effectView as! NSGlassEffectView
            precondition(glass.style == .clear && glass.cornerRadius == 24, "native optical rim and panel corners")
            precondition(native.desktopBlurView?.blendingMode == .behindWindow && native.desktopBlurView?.state == .active, "glass really samples the desktop")
            precondition(native.rendererName == "native-liquid-glass", "live renderer evidence")
        }
        let legacy = AgendaGlassSurface(preferNativeGlass: false)
        let blur = legacy.effectView as! NSVisualEffectView
        precondition(blur.material == .popover && blur.blendingMode == .behindWindow && blur.state == .active, "legacy samples desktop when inactive")
        for surface in [native, legacy] {
            for size in [NSSize(width: 320, height: 520), NSSize(width: 400, height: 850), NSSize(width: 320, height: 82)] {
                surface.setFrameSize(size)
                precondition(surface.effectView.frame == surface.bounds, "material fills resized panel")
                if let blur = surface.desktopBlurView { precondition(blur.frame == surface.bounds, "desktop blur fills resized panel") }
            }
            for alpha in [0.0, 0.01, 0.58, 0.9, 1.0] {
                surface.configure(alpha: alpha, isDark: false)
                precondition(abs(surface.effectView.alphaValue - alpha) < 1e-12, "alpha reaches native effect view")
                precondition(surface.effectView.isHidden == (alpha == 0), "clear endpoint hides material")
                precondition(surface.effectView.appearance?.name == .aqua, "light appearance reaches material")
                surface.configure(alpha: alpha, isDark: true)
                precondition(surface.effectView.appearance?.name == .darkAqua, "dark appearance reaches material")
            }
            precondition(surface.hitTest(NSPoint(x: 20, y: 20)) != nil, "background must not leave a pointer hole")
            precondition(AgendaGlassSurface.first(in: surface) === surface, "evidence finds the actual surface")
        }
        print("PASS: native Liquid Glass and legacy renderer, alpha, light/dark, resize/compact, input containment, endpoints/continuity, reduced transparency")
        print("Not established here: on-screen refraction, desktop compositing, text readability over different backgrounds.")
    }
}
