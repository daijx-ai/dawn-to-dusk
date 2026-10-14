import AppKit
import SwiftUI

@MainActor final class ScrollSink: NSResponder {
    var received = 0
    override func scrollWheel(with event: NSEvent) { received += 1 }
}

@main struct ScrollBoundaryTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var failures: [String] = []
        let sink = ScrollSink()
        #if SCROLL_BASELINE
        let host = NSHostingView(rootView: Color.clear)
        #else
        let host = AgendaContentHostingView(rootView: Color.clear)
        #endif
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 520), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.nextResponder = sink
        for phase in [Int64(0), 1, 2, 4] {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            let event = NSEvent(cgEvent: cg)!
            host.scrollWheel(with: event)
        }
        print("Unhandled/gesture scroll events reaching the outside responder: \(sink.received)")
        if sink.received != 0 { failures.append("window content lets unhandled wheel/gesture events escape") }

        let material = AgendaGlassSurface()
        material.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        for alpha in [0.0, 0.1, 0.9, 1.0] {
            material.configure(alpha: alpha, isDark: false)
            if material.hitTest(NSPoint(x: 20, y: 20)) == nil { failures.append("background leaves a mouse-hit hole at alpha \(alpha)") }
        }
        if failures.isEmpty { print("PASS: scroll boundary and full background hit region; viewport scrolling requires real UI verification") }
        else { for failure in failures { print("FAIL: " + failure) }; exit(1) }
    }
}
