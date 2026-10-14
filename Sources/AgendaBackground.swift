import AppKit
import SwiftUI

struct AgendaBackgroundOpacity {
    let glass: Double
    let tint: Double

    init(transparency: Double, glassEnabled: Bool = true, reduceTransparency: Bool = false) {
        let coverage = reduceTransparency ? 1 : 1 - Self.clamp(transparency, fallback: 0.45)
        glass = glassEnabled && !reduceTransparency ? coverage : 0
        // Keep the material visible. A light tint carries the selected palette;
        // only the opaque end of the slider covers the glass completely.
        tint = glassEnabled && !reduceTransparency ? pow(coverage, 20) : coverage
    }

    static func clamp(_ value: Double, fallback: Double = 0.55) -> Double {
        let finiteValue = value.isFinite ? value : (fallback.isFinite ? fallback : 0.55)
        return min(1, max(0, finiteValue))
    }
}

struct AgendaBackground: View {
    let transparency: Double
    let glassEnabled: Bool
    let reduceTransparency: Bool
    @Environment(\.agendaPalette) private var palette

    var body: some View {
        let opacity = AgendaBackgroundOpacity(transparency: transparency, glassEnabled: glassEnabled, reduceTransparency: reduceTransparency)
        ZStack {
            AgendaGlassBackground(alpha: opacity.glass, isDark: palette.isDark)
            palette.background.opacity(opacity.tint)
        }
        .accessibilityHidden(true)
    }
}

// Native material bridging adapted from Maccy's VisualEffectView.swift
// (commit a92c11ae3e7a86a57dc6359bad59e330e4625ede, MIT).
// Copyright (c) 2025 Alex Rodionov. See Resources/Maccy-LICENSE.txt.
@MainActor final class AgendaGlassSurface: NSView {
    let effectView: NSView
    let desktopBlurView: NSVisualEffectView?
    let rendererName: String

    init(preferNativeGlass: Bool = true) {
        if #available(macOS 26.0, *), preferNativeGlass {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = 24
            effectView = glass
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            desktopBlurView = blur
            rendererName = "native-liquid-glass"
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            effectView = blur
            desktopBlurView = nil
            rendererName = "legacy-vibrancy"
        }
        super.init(frame: .zero)
        if let desktopBlurView {
            desktopBlurView.frame = bounds
            desktopBlurView.autoresizingMask = [.width, .height]
            addSubview(desktopBlurView)
        }
        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        addSubview(effectView)
    }

    required init?(coder: NSCoder) { nil }

    func configure(alpha: Double, isDark: Bool) {
        let alpha = AgendaBackgroundOpacity.clamp(alpha, fallback: 0)
        effectView.alphaValue = alpha
        effectView.isHidden = alpha == 0
        effectView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        desktopBlurView?.alphaValue = alpha
        desktopBlurView?.isHidden = alpha == 0
        desktopBlurView?.appearance = effectView.appearance
    }

    static func first(in view: NSView?) -> AgendaGlassSurface? {
        guard let view else { return nil }
        if let surface = view as? AgendaGlassSurface { return surface }
        return view.subviews.lazy.compactMap { first(in: $0) }.first
    }
}

// Child scroll views handle their own events first. An unhandled event from
// the header, a margin, or the end of the list stops at this window boundary.
@MainActor final class AgendaContentHostingView<Content: View>: NSHostingView<Content> {
    override func scrollWheel(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct AgendaGlassBackground: NSViewRepresentable {
    let alpha: Double
    let isDark: Bool

    func makeNSView(context: Context) -> AgendaGlassSurface {
        let view = AgendaGlassSurface()
        view.configure(alpha: alpha, isDark: isDark)
        return view
    }

    func updateNSView(_ view: AgendaGlassSurface, context: Context) {
        view.configure(alpha: alpha, isDark: isDark)
    }
}
