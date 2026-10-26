import SwiftUI
import AppKit

struct TimeInput: View {
    @Binding var text: String
    var label = L("开始时间")
    var onCommit: () -> Void = {}
    @Environment(\.agendaPalette) private var palette
    @State private var wheelOpen = false

    var body: some View {
        HStack(spacing: 3) {
            number(.hour)
            Text(L("时")).font(.system(size: 9)).foregroundStyle(palette.secondary)
            number(.minute)
            Text(L("分")).font(.system(size: 9)).foregroundStyle(palette.secondary)
            Button { wheelOpen.toggle() } label: {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(palette.accent).accessibilityLabel(label + L("，滚轮选择"))
                .popover(isPresented: $wheelOpen, arrowEdge: .bottom) {
                    VStack(spacing: 12) {
                        Text(L("选择时间")).font(.system(size: 14, weight: .semibold))
                        HStack(spacing: 16) {
                            wheel(.hour, title: L("小时"))
                            Text(":").font(.system(size: 22, weight: .medium))
                            wheel(.minute, title: L("分钟"))
                        }
                        Text(L("上下滚动或点击数字，也可以直接输入")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                        Button(L("完成")) { wheelOpen = false; onCommit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }.padding(18).foregroundStyle(palette.ink).background(palette.background)
                }
        }.fixedSize(horizontal: true, vertical: false)
            .help(L("直接输入，或点右侧按钮打开滚轮；列表滚动不会改变时间"))
    }
    private func wheel(_ part: TimeInputValue.Part, title: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary)
            ClockWheel(value: Binding(get: { TimeInputValue.number(TimeInputValue(text).text(for: part), for: part) ?? 0 }, set: {
                text = TimeInputValue(text).replacing(part, with: String(format: "%02d", $0))
            }), range: TimeInputValue.range(for: part), label: label + "，" + title, ink: palette.ink, accent: palette.accent)
                .frame(width: 72, height: 150)
                .background(palette.controlFill, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(palette.accent.opacity(0.6)).frame(height: 30).allowsHitTesting(false) }
        }
    }
    private func number(_ part: TimeInputValue.Part) -> some View {
        let value = TimeInputValue(text).text(for: part)
        let invalid = !value.isEmpty && TimeInputValue.number(value, for: part) == nil
        let name = label + (part == .hour ? L("，小时") : L("，分钟"))
        return HStack(spacing: 1) {
            TimeNumberField(value: Binding(get: { TimeInputValue(text).text(for: part) }, set: { text = TimeInputValue(text).replacing(part, with: $0) }),
                            part: part, label: name, ink: palette.ink, accent: palette.accent,
                            adjust: { adjust(part, by: -$0) }, commit: onCommit)
                .frame(width: 28, height: 25)
                .background(palette.controlFill, in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(invalid ? palette.warning : palette.border, lineWidth: 1) }
        }
    }
    private func adjust(_ part: TimeInputValue.Part, by step: Int) {
        if let updated = TimeInputValue(text).adjusting(part, by: step) { text = updated }
    }
}

private final class SelectAllTimeField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        let wasEditing = currentEditor() != nil
        super.mouseDown(with: event)
        // AppKit places the caret after begin-editing; select after that first
        // click so the next digits replace the value rather than append to it.
        if !wasEditing { selectText(nil) }
    }
}

private struct TimeNumberField: NSViewRepresentable {
    @Binding var value: String
    let part: TimeInputValue.Part
    let label: String
    let ink: Color
    let accent: Color
    let adjust: (Int) -> Void
    let commit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SelectAllTimeField {
        let field = SelectAllTimeField()
        field.isBezeled = false; field.drawsBackground = false
        field.isEditable = true; field.isSelectable = true
        field.alignment = .center; field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        field.placeholderString = "00"
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: SelectAllTimeField, context: Context) {
        context.coordinator.parent = self
        // Echoing a keystroke back through stringValue resets AppKit's caret.
        // Only external changes (for example a wheel selection) replace an
        // active editor. A normal SwiftUI rerender must leave typing alone.
        if let editor = field.currentEditor() as? NSTextView {
            if context.coordinator.lastEmittedValue != value {
                let range = editor.selectedRange()
                field.stringValue = value; editor.string = value
                editor.setSelectedRange(NSRange(location: min(range.location, value.utf16.count), length: 0))
            }
        } else if field.stringValue != value { field.stringValue = value }
        context.coordinator.lastEmittedValue = value
        let color = NSColor(ink)
        if field.textColor?.isEqual(color) != true { field.textColor = color }
        field.setAccessibilityLabel(label)
        field.toolTip = label + L("：可清空后输入；空白按 00 处理")
        if let editor = field.currentEditor() as? NSTextView { editor.insertionPointColor = NSColor(accent) }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TimeNumberField
        var lastEmittedValue: String
        init(_ parent: TimeNumberField) { self.parent = parent; lastEmittedValue = parent.value }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let value = TimeInputValue.normalizedNumberInput(field.stringValue)
            if value != field.stringValue {
                field.stringValue = value
                if let editor = field.currentEditor() as? NSTextView {
                    editor.string = value
                    editor.setSelectedRange(NSRange(location: value.utf16.count, length: 0))
                }
            }
            lastEmittedValue = value
            parent.value = value
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let number = TimeInputValue.number(field.stringValue, for: parent.part) else { return }
            let value = String(format: "%02d", number)
            field.stringValue = value
            lastEmittedValue = value
            parent.value = value
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // Selecting here reenters AppKit’s begin-editing path and can
            // restore old digits between keystrokes. Mouse selection happens
            // after super.mouseDown; keyboard focus uses AppKit’s selection.
            (field.currentEditor() as? NSTextView)?.insertionPointColor = NSColor(parent.accent)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch NSStringFromSelector(commandSelector) {
            case "insertNewline:": control.window?.makeFirstResponder(nil); parent.commit(); return true
            case "moveUp:": parent.adjust(1); return true
            case "moveDown:": parent.adjust(-1); return true
            default: return false
            }
        }
    }
}

/// Only an explicitly opened picker consumes wheel events. The system scroll
/// events carry tracking and momentum; we snap to a row after they settle.
struct ClockWheel: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String
    let ink: Color
    let accent: Color

    func makeNSView(context: Context) -> ClockWheelScrollView {
        let view = ClockWheelScrollView()
        view.configure(range: range)
        return view
    }
    func updateNSView(_ view: ClockWheelScrollView, context: Context) {
        view.setAccessibilityLabel(label)
        view.ink = NSColor(ink); view.accent = NSColor(accent)
        view.onSelect = { value = $0 }
        view.display(value)
    }
    static func dismantleNSView(_ view: ClockWheelScrollView, coordinator: ()) { view.settleTimer?.invalidate() }
}

final class ClockWheelScrollView: NSScrollView {
    let rowHeight: CGFloat = 30
    var ink = NSColor.labelColor
    var accent = NSColor.controlAccentColor
    var onSelect: (Int) -> Void = { _ in }
    var settleTimer: Timer?
    private var observer: NSObjectProtocol?
    private var values = 0...23
    private var lastValue: Int?
    private var positioning = false
    private let rows = ClockWheelRows()

    func configure(range: ClosedRange<Int>) {
        values = range
        drawsBackground = false; hasVerticalScroller = false; hasHorizontalScroller = false
        verticalScrollElasticity = .none; horizontalScrollElasticity = .none
        contentView.postsBoundsChangedNotifications = true
        rows.owner = self
        documentView = rows
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in self?.scrolled() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; settleTimer?.invalidate() }
    override func layout() {
        positioning = true
        defer { positioning = false }
        super.layout()
        let size = NSSize(width: contentSize.width, height: CGFloat(values.count - 1) * rowHeight + contentSize.height)
        if rows.frame.size != size {
            rows.frame.size = size
            if let lastValue { contentView.scroll(to: NSPoint(x: 0, y: CGFloat(lastValue - values.lowerBound) * rowHeight)) }
        }
        rows.needsDisplay = true
    }
    func display(_ value: Int) {
        guard lastValue != value else { rows.needsDisplay = true; return }
        select(value, animated: false)
    }
    func select(_ value: Int, animated: Bool) {
        settleTimer?.invalidate()
        let bounded = min(values.upperBound, max(values.lowerBound, value))
        lastValue = bounded
        positioning = true
        let point = NSPoint(x: 0, y: CGFloat(bounded - values.lowerBound) * rowHeight)
        // Continuous scrolling is native; this short final alignment never
        // animates the model or steals an in-flight gesture from another row.
        contentView.scroll(to: point)
        reflectScrolledClipView(contentView)
        positioning = false
        rows.needsDisplay = true
        if animated { onSelect(bounded) }
    }
    private func scrolled() {
        guard !positioning, lastValue != nil, contentSize.height > 0, rows.frame.height >= contentSize.height else { return }
        let selected = min(values.upperBound, max(values.lowerBound, Int((contentView.bounds.minY / rowHeight).rounded()) + values.lowerBound))
        if selected != lastValue { lastValue = selected; onSelect(selected) }
        rows.needsDisplay = true
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: false) { [weak self] _ in
            guard let self, let lastValue = self.lastValue else { return }
            self.select(lastValue, animated: false)
        }
    }
    override func scrollWheel(with event: NSEvent) {
        // The picker is embedded in a SwiftUI popover: AppKit's default wheel
        // forwarding can hand these events to the outer schedule ScrollView.
        // Consume them here and track native pixel/momentum deltas directly.
        guard event.scrollingDeltaY != 0, lastValue != nil else { return }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : rowHeight
        let y = min(CGFloat(values.count - 1) * rowHeight, max(0, contentView.bounds.minY - event.scrollingDeltaY * scale))
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
        scrolled()
    }
    fileprivate func drawRows() {
        let padding = (contentSize.height - rowHeight) / 2
        for value in values {
            let y = padding + CGFloat(value - values.lowerBound) * rowHeight
            let distance = abs(y + rowHeight / 2 - contentView.bounds.midY) / rowHeight
            let color = (value == lastValue ? accent : ink).withAlphaComponent(max(0.15, 1 - distance * 0.3))
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let text = String(format: "%02d", value) as NSString
            text.draw(in: NSRect(x: 0, y: y + 3, width: contentSize.width, height: rowHeight), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: value == lastValue ? .semibold : .regular), .foregroundColor: color, .paragraphStyle: style])
        }
    }
    fileprivate func choose(at point: NSPoint) {
        let padding = (contentSize.height - rowHeight) / 2
        select(Int(floor((point.y - padding) / rowHeight)) + values.lowerBound, animated: true)
    }
    override func accessibilityValue() -> Any? { lastValue.map { String(format: "%02d", $0) } }
    override func accessibilityRole() -> NSAccessibility.Role? { .incrementor }
    override func accessibilityPerformIncrement() -> Bool { select((lastValue ?? 0) + 1, animated: true); return true }
    override func accessibilityPerformDecrement() -> Bool { select((lastValue ?? 0) - 1, animated: true); return true }
}

private final class ClockWheelRows: NSView {
    weak var owner: ClockWheelScrollView?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { owner?.drawRows() }
    override func mouseDown(with event: NSEvent) { owner?.choose(at: convert(event.locationInWindow, from: nil)) }
}
