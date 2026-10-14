import SwiftUI
import AppKit

/// A clock string stays invalid until the user corrects it; no date is involved.
struct TimeInputValue {
    enum Part { case hour, minute }
    let hour: String
    let minute: String

    init(_ text: String) {
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        if pieces.count == 2 { hour = String(pieces[0]); minute = String(pieces[1]) }
        else { hour = text; minute = "" }
    }
    func text(for part: Part) -> String { part == .hour ? hour : minute }
    static func range(for part: Part) -> ClosedRange<Int> { part == .hour ? 0...23 : 0...59 }
    static func number(_ text: String, for part: Part) -> Int? {
        guard let number = Int(text), range(for: part).contains(number) else { return nil }
        return number
    }
    func replacing(_ part: Part, with text: String) -> String {
        part == .hour ? text + ":" + minute : hour + ":" + text
    }
    func adjusting(_ part: Part, by step: Int) -> String? {
        guard step != 0 else { return nil }
        let text = self.text(for: part)
        let range = Self.range(for: part)
        let next: Int
        if text.isEmpty { next = 0 }
        else {
            guard let number = Self.number(text, for: part) else { return nil }
            let boundedStep = min(range.upperBound, max(-range.upperBound, step))
            next = min(range.upperBound, max(range.lowerBound, number + boundedStep))
        }
        return replacing(part, with: String(format: "%02d", next))
    }
}

struct TimeInput: View {
    @Binding var text: String
    var label = "开始时间"
    @Environment(\.agendaPalette) private var palette

    var body: some View {
        HStack(spacing: 3) {
            number(.hour)
            Text("时").font(.system(size: 9)).foregroundStyle(palette.secondary)
            number(.minute)
            Text("分").font(.system(size: 9)).foregroundStyle(palette.secondary)
        }.fixedSize(horizontal: true, vertical: false)
            .help("24 小时制；可填写数字、点上下箭头或在数字上滚动")
    }
    private func number(_ part: TimeInputValue.Part) -> some View {
        let value = TimeInputValue(text).text(for: part)
        let invalid = !value.isEmpty && TimeInputValue.number(value, for: part) == nil
        let name = label + (part == .hour ? "，小时" : "，分钟")
        return HStack(spacing: 1) {
            TimeNumberField(value: Binding(get: { TimeInputValue(text).text(for: part) }, set: { text = TimeInputValue(text).replacing(part, with: $0) }),
                            label: name, ink: palette.ink, accent: palette.accent,
                            adjust: { adjust(part, by: $0) })
                .frame(width: 28, height: 25)
                .background(palette.controlFill, in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(invalid ? palette.warning : palette.border, lineWidth: 1) }
            Stepper(name, onIncrement: { adjust(part, by: 1) }, onDecrement: { adjust(part, by: -1) })
                .labelsHidden().controlSize(.small).frame(width: 18, height: 25)
                .disabled(invalid).accessibilityLabel(name + "调整")
        }
    }
    private func adjust(_ part: TimeInputValue.Part, by step: Int) {
        if let updated = TimeInputValue(text).adjusting(part, by: step) { text = updated }
    }
}

private final class ScrollableTimeField: NSTextField {
    var adjust: (Int) -> Void = { _ in }
    private var scrollRemainder = 0.0
    override func scrollWheel(with event: NSEvent) {
        let delta = Double(event.scrollingDeltaY)
        guard delta.isFinite, delta != 0 else { return }
        if event.hasPreciseScrollingDeltas {
            scrollRemainder += delta
            let steps = Int(scrollRemainder / 10)
            if steps != 0 { scrollRemainder -= Double(steps) * 10; adjust(steps) }
        } else { adjust(delta > 0 ? 1 : -1) }
    }
}

private struct TimeNumberField: NSViewRepresentable {
    @Binding var value: String
    let label: String
    let ink: Color
    let accent: Color
    let adjust: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ScrollableTimeField {
        let field = ScrollableTimeField()
        field.isBezeled = false; field.drawsBackground = false
        field.isEditable = true; field.isSelectable = true
        field.alignment = .center; field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        field.placeholderString = "—"
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: ScrollableTimeField, context: Context) {
        context.coordinator.parent = self
        // Keep the field editor and caret intact during clock/palette rerenders.
        if field.stringValue != value { field.stringValue = value }
        field.textColor = NSColor(ink)
        field.setAccessibilityLabel(label)
        field.toolTip = label + "：填写数字，或滚动、按上下方向键调整"
        field.adjust = adjust
        if let editor = field.currentEditor() as? NSTextView { editor.insertionPointColor = NSColor(accent) }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TimeNumberField
        init(_ parent: TimeNumberField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.value = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            field.selectText(nil)
            (field.currentEditor() as? NSTextView)?.insertionPointColor = NSColor(parent.accent)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch NSStringFromSelector(commandSelector) {
            case "moveUp:": parent.adjust(1); return true
            case "moveDown:": parent.adjust(-1); return true
            default: return false
            }
        }
    }
}
