import Foundation
import AppKit
import SwiftUI

// Only compile-time palette enums are substituted in the isolated harness.
// The real Appearance.swift and TimeInput.swift are compiled unchanged.
#if TIME_INPUT_ISOLATED
enum AgendaAppearanceMode { case light, dark, system }
enum AgendaAccentColor { case green, blue, purple, orange, graphite }
#endif

@MainActor private final class ReactiveClock: ObservableObject { @Published var text = "00:30" }
private struct ReactiveTimeInput: View {
    @ObservedObject var clock: ReactiveClock
    var body: some View { TimeInput(text: $clock.text, label: "键盘验收") }
}

@main struct TimeInputTests {
    @MainActor static func main() {
        var checked = 0
        func expect(_ condition: Bool, _ message: String) {
            checked += 1
            if !condition { fatalError(message) }
        }
        func minutes(_ text: String) -> Int? {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return hour * 60 + minute
        }
        // Simulate the two bound fields used by both consumers, then validate
        // their output with the unchanged consumer's accepted clock grammar.
        var typed = ""
        typed = TimeInputValue(typed).replacing(.hour, with: "00")
        expect(minutes(typed) == nil, "Missing minute must remain invalid")
        typed = TimeInputValue(typed).replacing(.minute, with: "00")
        expect(typed == "00:00" && minutes(typed) == 0, "Typed midnight")
        typed = TimeInputValue(typed).replacing(.hour, with: "23")
        typed = TimeInputValue(typed).replacing(.minute, with: "59")
        expect(typed == "23:59" && minutes(typed) == 1439, "Typed last minute")
        expect(TimeInputValue(typed).adjusting(.minute, by: 1) == "23:59", "Minute must not carry to next day")
        expect(TimeInputValue(typed).adjusting(.hour, by: 1) == "23:59", "Hour must not carry to next day")
        expect(TimeInputValue("00:00").adjusting(.minute, by: -1) == "00:00", "Minute floor")
        expect(TimeInputValue("00:00").adjusting(.hour, by: -1) == "00:00", "Hour floor")
        expect(TimeInputValue("09:58").adjusting(.minute, by: 1) == "09:59", "Single minute, no five-minute rounding")
        expect(TimeInputValue("09:37").adjusting(.hour, by: 1) == "10:37", "Hour adjustment preserves minute")
        expect(TimeInputValue("09:37").adjusting(.minute, by: -1) == "09:36", "Minute adjustment preserves hour")
        for bad in ["25:30", "12:60", "wrong", "09:bad", "12:34:56"] {
            expect(minutes(bad) == nil, "Invalid incoming clock must not save")
            let value = TimeInputValue(bad)
            expect(value.hour + ":" + value.minute != "09:00", "No fallback default for invalid value")
        }
        expect(TimeInputValue("25:30").adjusting(.hour, by: -1) == nil, "Cannot silently clamp an invalid hour")
        expect(TimeInputValue("12:60").adjusting(.minute, by: -1) == nil, "Cannot silently clamp an invalid minute")
        let corrected = TimeInputValue("25:30").replacing(.hour, with: "22")
        expect(minutes(corrected) == 22 * 60 + 30, "Explicit correction can save")
        expect(TimeInputValue("").adjusting(.hour, by: 1) == "00:", "Explicit hour choice leaves minute unset")
        expect(TimeInputValue("").adjusting(.minute, by: 1) == ":00", "Explicit minute choice leaves hour unset")
        expect(TimeInputValue("23:59").adjusting(.minute, by: Int.max) == "23:59", "Large scroll step stays bounded")
        expect(TimeInputValue("00:00").adjusting(.hour, by: Int.min) == "00:00", "Large negative step stays bounded")
        // Dispatch wheel events to the actual native fields. This caught the
        // hover-to-edit bug, including when one gesture crosses several rows.
        _ = NSApplication.shared
        var clocks = ["23:30", "07:30"]
        let originalClocks = clocks
        let host = NSHostingView(rootView: VStack {
            TimeInput(text: Binding(get: { clocks[0] }, set: { clocks[0] = $0 }), label: "睡觉")
            TimeInput(text: Binding(get: { clocks[1] }, set: { clocks[1] = $0 }), label: "起床")
        })
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func controls(in view: NSView) -> [NSControl] {
            (view as? NSControl).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
        }
        let actualControls = controls(in: host)
        let fields = actualControls.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        expect(fields.count == 4, "Exercise both real hour/minute fields in two rows")
        for control in actualControls {
            for units in [CGScrollEventUnit.pixel, .line] {
                for delta: Int32 in [40, -40] {
                    let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
                    control.scrollWheel(with: NSEvent(cgEvent: cg)!)
                    expect(clocks == originalClocks, "Wheel must never edit any time, including across multiple fields")
                }
            }
        }
        let sleepHour = fields.first { $0.accessibilityLabel() == "睡觉，小时" }!
        sleepHour.stringValue = "0023"
        sleepHour.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: sleepHour))
        expect(sleepHour.stringValue == "23" && clocks[0] == "23:30", "Appending 23 to 00 displays and binds hour 23")
        sleepHour.stringValue = "0025"
        sleepHour.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: sleepHour))
        expect(sleepHour.stringValue == "25" && minutes(clocks[0]) == nil, "Out-of-range hours remain visibly invalid, never silently clamped")
        sleepHour.stringValue = "7"
        sleepHour.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: sleepHour))
        sleepHour.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: sleepHour))
        expect(sleepHour.stringValue == "07" && clocks[0] == "07:30", "Single digit pads on blur and preserves minute")
        let editor = NSTextView()
        _ = sleepHour.delegate?.control?(sleepHour, textView: editor, doCommandBy: NSSelectorFromString("moveUp:"))
        expect(clocks[0] == "06:30", "Actual Up key delegate reduces the hour")
        _ = sleepHour.delegate?.control?(sleepHour, textView: editor, doCommandBy: NSSelectorFromString("moveDown:"))
        expect(clocks[0] == "07:30", "Actual Down key delegate increases the hour")
        sleepHour.stringValue = ""
        sleepHour.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: sleepHour))
        expect(clocks[0] == ":30" && TimeInputValue(clocks[0]).minutes == 30, "Deleting every digit stays editable and means zero")
        sleepHour.stringValue = "23"
        sleepHour.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: sleepHour))
        expect(clocks[0] == "23:30", "Typing into a cleared field is direct, with no forced leading zero")
        sleepHour.stringValue = ""
        sleepHour.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: sleepHour))
        expect(sleepHour.stringValue == "00" && clocks[0] == "00:30", "Blank normalizes to 00 when editing ends")
        expect(TimeInputValue(":").minutes == 0 && TimeInputValue("23:").minutes == 1380, "Blank components are zero")
        expect(TimeInputValue("24:00").minutes == nil && TimeInputValue("23:60").minutes == nil, "Wheel ranges match valid clock input")
        let hours = ClockWheelScrollView(); hours.frame = NSRect(x: 0, y: 0, width: 72, height: 150); hours.configure(range: 0...23)
        let minuteWheel = ClockWheelScrollView(); minuteWheel.frame = NSRect(x: 0, y: 0, width: 72, height: 150); minuteWheel.configure(range: 0...59)
        window.contentView?.addSubview(hours); window.contentView?.addSubview(minuteWheel)
        hours.layoutSubtreeIfNeeded(); minuteWheel.layoutSubtreeIfNeeded()
        var wheelHour = 0, wheelMinute = 30
        hours.onSelect = { wheelHour = $0 }; minuteWheel.onSelect = { wheelMinute = $0 }
        hours.display(0); minuteWheel.display(30)
        hours.select(23, animated: true)
        expect(wheelHour == 23 && wheelMinute == 30, "Hour wheel changes only its own component")
        minuteWheel.select(59, animated: true)
        expect(wheelHour == 23 && wheelMinute == 59, "Minute wheel changes only its own component")
        hours.select(24, animated: true); minuteWheel.select(60, animated: true)
        expect(wheelHour == 23 && wheelMinute == 59, "Native wheels cannot choose 24 or 60")
        hours.select(-1, animated: true); minuteWheel.select(-1, animated: true)
        expect(wheelHour == 0 && wheelMinute == 0, "Native wheel lower boundary is 00")
        hours.contentView.scroll(to: NSPoint(x: 0, y: 9 * 30))
        expect(wheelHour == 9 && wheelMinute == 0, "Actual clip scrolling chooses the centered hour without altering minutes")
        let mounting = ClockWheelScrollView()
        mounting.configure(range: 0...59)
        var mountedMinute = 30
        mounting.onSelect = { mountedMinute = $0 }
        mounting.display(30)
        mounting.frame = NSRect(x: 0, y: 0, width: 72, height: 150)
        window.contentView?.addSubview(mounting)
        mounting.layoutSubtreeIfNeeded()
        expect(mountedMinute == 30 && mounting.accessibilityValue() as? String == "30", "Mounting a picker at a nonzero value must never reset it to 00")
        let wheelEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0)!
        hours.scrollWheel(with: NSEvent(cgEvent: wheelEvent)!)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        expect(wheelHour > 9 && wheelMinute == 0, "Real scroll-wheel events change only the selected hour wheel")
        let reactive = ReactiveClock()
        let typingHost = NSHostingView(rootView: ReactiveTimeInput(clock: reactive))
        let typingWindow = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 250, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        typingWindow.contentView = typingHost; typingHost.layoutSubtreeIfNeeded()
        let reactiveHour = controls(in: typingHost).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "键盘验收，小时" }!
        expect(typingWindow.makeFirstResponder(reactiveHour), "Use a real AppKit field editor for reactive typing")
        let typingEditor = reactiveHour.currentEditor() as! NSTextView
        typingEditor.setSelectedRange(NSRange(location: 0, length: typingEditor.string.utf16.count))
        typingEditor.insertText("2", replacementRange: typingEditor.selectedRange())
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        typingEditor.insertText("3", replacementRange: typingEditor.selectedRange())
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        expect(typingEditor.string == "23" && reactive.text == "23:30", "Sequential keyboard digits survive SwiftUI rerenders without reversing or duplicating")
        typingEditor.setSelectedRange(NSRange(location: 0, length: typingEditor.string.utf16.count))
        typingEditor.deleteBackward(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        expect(typingEditor.string.isEmpty && TimeInputValue(reactive.text).minutes == 30, "Deleting all text remains empty while editing and means 00")
        typingWindow.makeFirstResponder(nil)
        expect(reactiveHour.stringValue == "00", "Leaving a cleared reactive field displays 00")
        expect(DurationInputValue.minutes("") == 0 && DurationInputValue.minutes("37") == 37, "Duration accepts cleared and arbitrary exact minutes")
        expect(DurationInputValue.minutes("1440") == 1440 && DurationInputValue.minutes("1441") == nil && DurationInputValue.minutes("-1") == nil, "Duration boundaries are explicit")
        var durationText = "5"
        let durationHost = NSHostingView(rootView: DurationInput(text: Binding(get: { durationText }, set: { durationText = $0 })))
        let durationWindow = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 280, height: 110), styleMask: .borderless, backing: .buffered, defer: false)
        durationWindow.contentView = durationHost; durationHost.layoutSubtreeIfNeeded()
        let durationField = controls(in: durationHost).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        expect(!controls(in: durationHost).contains { $0 is NSStepper }, "Duration no longer has tiny stacked arrows")
        durationField.stringValue = "37"
        durationField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: durationField))
        durationField.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: durationField))
        expect(durationText == "37", "Actual duration field preserves exact minute entry")
        durationField.stringValue = ""
        durationField.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: durationField))
        expect(durationText == "0", "Cleared duration normalizes to zero")
        let disabledHost = NSHostingView(rootView: DurationInput(text: Binding(get: { durationText }, set: { durationText = $0 })).disabled(true))
        let disabledWindow = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 280, height: 110), styleMask: .borderless, backing: .buffered, defer: false)
        disabledWindow.contentView = disabledHost; disabledHost.layoutSubtreeIfNeeded()
        let disabledFields = controls(in: disabledHost).compactMap { $0 as? NSTextField }.filter { $0.accessibilityLabel() == "时长，分钟" }
        expect(disabledFields.count == 1 && disabledFields.allSatisfy { !$0.isEnabled && !$0.isEditable && !$0.isSelectable }, "No-time events disable the actual native duration field")
        print("Time input: \(checked) checks passed")
    }
}
