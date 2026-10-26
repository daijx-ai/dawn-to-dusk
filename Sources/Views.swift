import SwiftUI
import AppKit

private func agendaSystemColorScheme(fallback: ColorScheme) -> ColorScheme {
    // A sheet's colorScheme may still reflect the explicit mode being replaced.
    // AppController owns the app appearance; system mode clears its override.
    guard let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) else { return fallback }
    return appearance == .darkAqua ? .dark : .light
}

private func parseClockInput(_ text: String) -> Int? {
    TimeInputValue(text.trimmingCharacters(in: .whitespaces)).minutes
}

final class DragGripView: NSView {
    var gripColor = NSColor.secondaryLabelColor
    private var initialOrigin: NSPoint?
    private var initialScreenPoint: NSPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        gripColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: (bounds.width - 28) / 2, y: (bounds.height - 3) / 2, width: 28, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialOrigin = window.frame.origin
        initialScreenPoint = window.convertPoint(toScreen: event.locationInWindow)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let origin = initialOrigin, let start = initialScreenPoint else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y))
    }
    override func mouseUp(with event: NSEvent) { initialOrigin = nil; initialScreenPoint = nil }
}

struct DragGrip: NSViewRepresentable {
    @Environment(\.agendaPalette) private var palette
    func makeNSView(context: Context) -> DragGripView { let view = DragGripView(); view.setAccessibilityElement(true); view.setAccessibilityRole(.group); view.setAccessibilityLabel(L("拖动日程面板")); view.toolTip = L("按住小横线，拖到喜欢的位置"); return view }
    func updateNSView(_ nsView: DragGripView, context: Context) { nsView.gripColor = NSColor(palette.secondary); nsView.needsDisplay = true }
}

final class ResizeGripView: NSView {
    var gripColor = NSColor.labelColor
    private var start: NSPoint?
    private var initialFrame: NSRect?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        gripColor.setStroke()
        for inset in [5.0, 10.0, 15.0] {
            let line = NSBezierPath(); line.lineWidth = 1.5
            line.move(to: NSPoint(x: bounds.width - inset, y: 5))
            line.line(to: NSPoint(x: bounds.width - 5, y: inset)); line.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }; start = window.convertPoint(toScreen: event.locationInWindow); initialFrame = window.frame
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let start, let initialFrame else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let width = max(window.minSize.width, initialFrame.width + point.x - start.x)
        let height = max(window.minSize.height, initialFrame.height - point.y + start.y)
        window.setFrame(NSRect(x: initialFrame.minX, y: initialFrame.maxY - height, width: width, height: height), display: true)
    }
    override func mouseUp(with event: NSEvent) { start = nil; initialFrame = nil }
}
struct ResizeGrip: NSViewRepresentable {
    @Environment(\.agendaPalette) private var palette
    func makeNSView(context: Context) -> ResizeGripView {
        let view = ResizeGripView(); view.toolTip = L("拖动调整宽度和高度"); view.setAccessibilityElement(true); view.setAccessibilityLabel(L("调整日程窗口大小")); return view
    }
    func updateNSView(_ nsView: ResizeGripView, context: Context) { nsView.gripColor = NSColor(palette.accent.opacity(0.65)); nsView.needsDisplay = true }
}

struct IconButton: View {
    @Environment(\.agendaPalette) private var palette
    let symbol: String
    let label: String
    var active: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 30, height: 30)
                .background(active ? palette.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

private struct PanelActionButton: View {
    @Environment(\.agendaPalette) private var palette
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) { Image(systemName: symbol).font(.system(size: 10)); Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.9) }
                .frame(width: 50, height: 36).contentShape(Rectangle())
                .background(active ? palette.accent.opacity(0.16) : hovered ? palette.controlFill : palette.controlFill.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).foregroundStyle(palette.accent).onHover { hovered = $0 }.accessibilityLabel(label).help(label)
    }
}

private struct EditorSession: Identifiable {
    let id = UUID()
    var item: AgendaItem?
    var source: String?
    var schedulingChecklist = false
    var occurrence: Occurrence? = nil
    var restoreCompactOnDismiss = false
}
private enum AgendaSection: Hashable { case agenda, checklist }
private enum AgendaModal: Identifiable {
    case editor(EditorSession), checklistEditor(EditorSession), settings
    var id: String { switch self { case .editor(let s), .checklistEditor(let s): return s.id.uuidString; case .settings: return "settings" } }
}

struct AgendaView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: AgendaPalette { AgendaPalette(mode: store.settings.appearanceMode, accent: store.settings.accentColor, systemScheme: agendaSystemColorScheme(fallback: colorScheme)) }
    @ObservedObject var store: AgendaStore
    @ObservedObject var controller: AppController
    @State private var modal: AgendaModal?
    @State private var modalIsPresented = false
    @State private var queuedCaptures: [EditorSession] = []
    @State private var capturePresentation = AgendaCapturePresentation()
    @State private var panelHeight: CGFloat = 850
    @State private var showingDateControls = false
    @State private var showingHighlightedChoices = false
    @State private var showingCompactChoices = false
    @State private var editingSchedule = false
    @State private var editorShowsIntervals = true
    @State private var scrollToNowToken = 0
    @State private var section = AgendaSection.agenda
    @State private var quickChecklistTitle = ""
    @FocusState private var quickChecklistFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            let now = tick.date
            let rows = store.occurrences(on: store.selectedDay)
            let highlighted = store.highlightedFocus(now: now)
            let showsHero = section == .agenda || (highlighted.map { $0.isChecklist && store.isPinned($0) } == true)
            let earlier = (AgendaClock.overdue(items: store.items, now: now) + AgendaClock.earlierUnscheduled(items: store.items, now: now)).filter { AgendaClock.dayKey($0.displayDay) != AgendaClock.dayKey(store.selectedDay) }
            let dueAlert = AgendaClock.overdue(items: store.items, now: now).last { o in !o.item.isTentative && o.item.reminderEnabled && (o.remindAt ?? .distantFuture) <= now }
            VStack(spacing: 0) {
                if controller.isQA && !store.settings.compact {
                    Text(L("隔离验收 · 测试数据，与正式清单无关"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.orange)
                        .frame(maxWidth: .infinity).padding(.vertical, 5).background(Color.orange.opacity(0.15))
                }
                if store.settings.compact { compact(now: now) }
                else {
                    if !editingSchedule {
                        header(now: now)
                        Picker(L("内容"), selection: $section) {
                            Text(L("日程")).tag(AgendaSection.agenda)
                            Text(L("清单 \(store.checklistItems().count)")).tag(AgendaSection.checklist)
                        }.pickerStyle(.segmented).id(Localization.language).labelsHidden().font(.system(size: 11)).padding(.horizontal, 16).padding(.bottom, 6).accessibilityLabel(L("日程与独立清单"))
                    }
                    if editingSchedule {
                        ScheduleListEditor(store: store, showsIntervals: $editorShowsIntervals) { editingSchedule = false }
                    } else {
                        if showsHero { hero(now: now).padding(.horizontal, 16).padding(.bottom, 6) }
                        if let dueAlert, !showsHero || dueAlert.id != highlighted?.occurrence?.id { dueStrip(dueAlert).padding(.horizontal, 16).padding(.bottom, 4) }
                        if section == .checklist { checklistContent(); checklistFooter() }
                        else {
                            ScrollViewReader { proxy in
                                ScrollView(showsIndicators: true) {
                                    VStack(alignment: .leading, spacing: 16) {
                                        Color.clear.frame(height: 1).id("timeline-top")
                                        if rows.isEmpty { Text(L("这一天还没有安排，点下方添加日程。")).font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.vertical, 6) }
                                        compactAgenda(rows: rows, now: now)
                                        let untimed = rows.filter { $0.due == nil && (store.settings.showCompleted || !$0.isCompleted) }
                                        if !untimed.isEmpty {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(L("全天与未定时 · \(untimed.count) 件")).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.accent)
                                                ForEach(untimed) { row($0, now: now) }
                                            }.padding(.vertical, 6).id("untimed")
                                        }
                                        if !earlier.isEmpty {
                                            DisclosureGroup(L("\(earlier.count) 件之前的安排待处理")) {
                                                ForEach(earlier) { o in
                                                    VStack(alignment: .leading, spacing: 0) {
                                                        Text(o.displayDay, formatter: Self.fullDayFormatter).font(.system(size: 11)).foregroundStyle(palette.warning).padding(.top, 6)
                                                        row(o, now: now)
                                                    }
                                                }
                                            }.font(.system(size: 13, weight: .medium)).tint(palette.warning).foregroundStyle(palette.warning)
                                        }
                                    }.padding(.horizontal, 16).padding(.bottom, 16)
                                }
                                .onAppear { DispatchQueue.main.async { scrollToTime(proxy, now: now) } }
                                .onChange(of: store.selectedDay) { DispatchQueue.main.async { scrollToTime(proxy, now: Date()) } }
                                .onChange(of: scrollToNowToken) { DispatchQueue.main.async { scrollToTime(proxy, now: Date()) } }
                            }
                            footer()
                        }
                    }
                }
                if let error = store.error {
                    VStack(alignment: .leading, spacing: 7) {
                      HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle"); Text(error).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
                      if store.isDataLocked { Button(L("保留损坏文件并重建模板")) { _ = store.recoverCorruptFile() }.font(.system(size: 12)); Button(L("从备份恢复…")) { controller.restoreData() }.font(.system(size: 12)) }
                    }
                        .foregroundStyle(palette.warning).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(palette.controlFill)
                }
            }
            .foregroundStyle(palette.ink)
            .background {
                AgendaBackground(transparency: 1 - controller.glassStrength, glassEnabled: controller.glassEnabled, reduceTransparency: reduceTransparency)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(palette.border.opacity(controller.glassEnabled && !reduceTransparency ? 0.35 : 1), lineWidth: 1) }
            .overlay(alignment: .top) { DragGrip().frame(width: 56, height: 18).padding(.top, 4) }
            .overlay(alignment: .bottomTrailing) { if !store.settings.compact { ResizeGrip().frame(width: 26, height: 26).padding(3) } }
        }
        .font(.system(size: 14))
        .environment(\.locale, store.settings.language.locale)
        .environment(\.agendaPalette, palette).tint(palette.accent)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { panelHeight = $0 }
        .sheet(item: $modal, onDismiss: presentQueuedCapture) { content in
            VStack(spacing: 0) {
                if controller.isQA {
                    Text(L("隔离验收 · 测试数据，与正式清单无关"))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                        .padding(8).frame(maxWidth: .infinity).background(Color.orange.opacity(0.1))
                }
                switch content {
            case .editor(let session): ItemEditor(store: store, item: session.item, source: session.source, schedulingChecklist: session.schedulingChecklist, occurrence: session.occurrence, onScheduled: { section = .agenda }) { modal = nil }.id(session.id)
            case .checklistEditor(let session): ChecklistEditor(store: store, item: session.item, source: session.source) { modal = nil }.id(session.id)
            case .settings: SettingsView(store: store, controller: controller) { modal = nil }
                }
            }.onAppear { modalIsPresented = true }
        }
        .onChange(of: controller.captureToken, initial: true) { receiveCaptures() }
        .onChange(of: store.settings.compact) { controller.resizePanel() }
        .onChange(of: store.settings.floating) { controller.applyWindowMode() }
    }

    private func header(now: Date) -> some View {
        let rows = store.occurrences(on: store.selectedDay)
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(L("朝夕")).font(.system(size: Localization.language == .english ? 14 : 18, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.65)
                Spacer(minLength: 4)
                PanelActionButton(symbol: store.settings.floating ? "pin.fill" : "pin", label: L("置顶"), active: store.settings.floating) { store.settings.floating.toggle(); _ = store.save() }
                PanelActionButton(symbol: "rectangle.compress.vertical", label: L("小窗")) { store.settings.compact = true; _ = store.save() }
                PanelActionButton(symbol: "minus", label: L("最小化")) { controller.minimizeToMenu() }
                PanelActionButton(symbol: "slider.horizontal.3", label: L("设置")) { modal = .settings }
            }
            HStack(alignment: .center, spacing: 6) {
                if section == .checklist {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("独立清单")).font(.system(size: 12, weight: .medium))
                        Text(L("\(store.checklistItems().count) 件待办")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button { showingDateControls.toggle() } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(store.selectedDay, formatter: Self.selectedDayFormatter).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                            }
                            Text(L("\(dayRelation(store.selectedDay, now: now)) · \(rows.filter { $0.isCompleted }.count)/\(rows.count) 完成")).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(L("切换日程日期")).accessibilityLabel(L("日程日期 \(Self.fullDayFormatter.string(from: store.selectedDay))，切换日期"))
                        .popover(isPresented: $showingDateControls, arrowEdge: .bottom) { dateControls(now: now) }
                }
                VStack(alignment: .trailing, spacing: 0) {
                    Text(now, formatter: Self.clockFormatter).font(.system(size: 34, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(palette.accent).lineLimit(1).minimumScaleFactor(0.75).accessibilityLabel(L("北京时间 \(Self.clockFormatter.string(from: now))"))
                    Text(L("北京时间")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                }.layoutPriority(1).contentShape(Rectangle())
                    .onTapGesture(count: 2) { returnToNow() }
                    .help(L("双击时钟，回到今天的现在刻度"))
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(L("双击回到今天的现在刻度"))
                    .accessibilityAction(named: Text(L("回到今天的现在刻度"))) { returnToNow() }
            }
        }.padding(.horizontal, 18).padding(.top, panelHeight < 650 ? 14 : 16).padding(.bottom, 7)
    }

    private func dateControls(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("日程日期")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { changeDay(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 26, height: 26) }.help(L("前一天")).accessibilityLabel(L("前一天"))
                Button { changeDay(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 26) }.help(L("后一天")).accessibilityLabel(L("后一天"))
            }.buttonStyle(.plain)
            DatePicker(
                L("选择日期"),
                selection: Binding(
                    get: { store.selectedDay },
                    set: { selectDay($0) }
                ),
                displayedComponents: .date
            ).datePickerStyle(.compact).environment(\.timeZone, AgendaClock.calendar.timeZone)
            HStack(spacing: 8) {
                Button(L("今天")) { selectDay(AgendaClock.startOfDay(now)) }
                Button(L("明天")) { selectDay(AgendaClock.calendar.date(byAdding: .day, value: 1, to: AgendaClock.startOfDay(now))!) }
                Spacer()
            }.font(.system(size: 12)).buttonStyle(.bordered).tint(palette.accent)
        }.font(.system(size: 14)).padding(16).frame(width: 264).foregroundStyle(palette.ink).background(palette.background).environment(\.agendaPalette, palette).tint(palette.accent)
    }

    private func changeDay(by amount: Int) {
        if let day = AgendaClock.calendar.date(byAdding: .day, value: amount, to: store.selectedDay) { selectDay(day) }
    }

    private func selectDay(_ day: Date) {
        store.selectedDay = AgendaClock.startOfDay(day)
        showingDateControls = false
    }

    private func returnToNow() {
        section = .agenda
        selectDay(AgendaClock.startOfDay(Date()))
        scrollToNowToken += 1
    }

    private func dayRelation(_ day: Date, now: Date) -> String {
        let offset = AgendaClock.calendar.dateComponents([.day], from: AgendaClock.startOfDay(now), to: AgendaClock.startOfDay(day)).day ?? 0
        switch offset { case 0: return L("今天"); case 1: return L("明天"); case -1: return L("昨天"); default: return L("所选日期") }
    }

    private func hero(now: Date) -> some View {
        let highlighted = store.highlightedFocus(now: now)
        let small = panelHeight < 650
        return VStack(alignment: .leading, spacing: small ? 4 : 6) {
            HStack(spacing: 5) {
                highlightedMenu(highlighted)
                Spacer(minLength: 3)
                if let o = highlighted { Text(highlightedSchedule(o, now: now)).font(.system(size: small ? 11 : 12, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8) }
            }
            HStack(spacing: 7) {
                Text(highlighted?.title ?? L("按自己的节奏来")).font(.system(size: small ? 15 : 18, weight: .semibold)).lineLimit(small ? 1 : 2).help(highlighted?.title ?? "").frame(maxWidth: .infinity, alignment: .leading)
                if let o = highlighted {
                    Button { store.toggle(o) } label: { Image(systemName: "checkmark.circle").font(.system(size: 18)).frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help(L("完成 \(o.title)")).accessibilityLabel(L("完成 \(o.title)"))
                    Button { editFocus(o) } label: { Image(systemName: "pencil").font(.system(size: 13)).frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help(L("修改 \(o.title)")).accessibilityLabel(L("修改 \(o.title)"))
                }
            }
            if highlighted?.isChecklist != true { Text(highlighted.map { highlightedStatus($0, now: now) } ?? L("此刻，留一点空白")).font(.system(size: small ? 12 : 14, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(palette.heroSecondary).lineLimit(1).minimumScaleFactor(0.8) }
        }.foregroundStyle(palette.heroInk).padding(small ? 9 : 12).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [palette.heroBackground.opacity(controller.glassEnabled && !reduceTransparency ? 0.4 : 1), palette.heroEnd.opacity(controller.glassEnabled && !reduceTransparency ? 0.4 : 1)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: small ? 12 : 17))
    }

    private func highlightedMenu(_ highlighted: AgendaFocus?) -> some View {
        Button { showingHighlightedChoices.toggle() } label: {
            HStack(spacing: 4) {
                Text((highlighted.map { store.isPinned($0) } == true ? L("已固定") : L("自动下一件")) + L(" · 更换"))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(palette.heroInk).padding(.vertical, 2).contentShape(Rectangle())
        }.buttonStyle(.plain).fixedSize().help(L("选择固定到顶部的事项，或恢复自动下一件")).accessibilityLabel(L("更换顶部事项"))
            .popover(isPresented: $showingHighlightedChoices, arrowEdge: .bottom) { highlightedChoices() }
    }

    private func highlightedChoices(forCompact: Bool = false) -> some View {
        let choiceDay = forCompact ? AgendaClock.startOfDay(Date()) : store.selectedDay
        let scheduled = store.occurrences(on: choiceDay).filter { !$0.isCompleted }
        let checklist = store.checklistItems()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(forCompact ? L("小窗固定事项") : L("顶部事项")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L("完成")) { if forCompact { showingCompactChoices = false } else { showingHighlightedChoices = false } }.font(.system(size: 12))
            }
            Button(forCompact ? L("最近安排") : L("自动选择下一件")) {
                if forCompact {
                    if store.setCompactFollowsPinned(false) { showingCompactChoices = false }
                } else if store.clearPinnedOccurrence() { showingHighlightedChoices = false }
            }.font(.system(size: 13)).foregroundStyle(palette.accent)
            if forCompact {
                if let fixed = store.highlightedFocus(now: Date()), store.isPinned(fixed) {
                    Button {
                        if store.setCompactFollowsPinned(true) { showingCompactChoices = false }
                    } label: {
                        Label(L("固定事项 · ") + fixed.title, systemImage: store.compactUsesPinnedFocus ? "checkmark" : "pin")
                            .font(.system(size: 13)).lineLimit(2)
                    }.buttonStyle(.plain).foregroundStyle(palette.accent)
                }
                Button(L("添加待办…")) { showingCompactChoices = false; controller.beginChecklistCapture() }
                    .font(.system(size: 12)).buttonStyle(.plain)
            }
            Rectangle().fill(palette.divider).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("独立清单")).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary).padding(.top, 3)
                    if checklist.isEmpty { Text(L("没有未完成事项")).font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.vertical, 6) }
                    ForEach(checklist) { item in focusChoice(.checklist(item), label: item.title, forCompact: forCompact) }
                    Rectangle().fill(palette.divider).frame(height: 0.5).padding(.vertical, 5)
                    Text(L("\(Self.shortDayFormatter.string(from: choiceDay)) 的日程")).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary)
                    if scheduled.isEmpty { Text(L("这一天没有未完成安排")).font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.vertical, 6) }
                    ForEach(scheduled) { o in focusChoice(.scheduled(o), label: (o.due.map { AgendaClock.timeText($0) } ?? L("未定时")) + " · " + o.title, forCompact: forCompact) }
                }
            }.frame(maxHeight: 280)
        }.font(.system(size: 14)).padding(16).frame(width: 264).foregroundStyle(palette.ink).background(palette.background).environment(\.agendaPalette, palette).tint(palette.accent)
    }

    private func focusChoice(_ focus: AgendaFocus, label: String, forCompact: Bool = false) -> some View {
        Button {
            let saved: Bool
            if focus.isChecklist { saved = store.pinChecklistItem(focus.item.id, inCompact: forCompact) }
            else if let o = focus.occurrence { saved = store.pinOccurrence(o, inCompact: forCompact) }
            else { saved = false }
            if saved {
                if forCompact { showingCompactChoices = false } else { showingHighlightedChoices = false }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: store.isPinned(focus) && (!forCompact || store.compactUsesPinnedFocus) ? "checkmark.circle.fill" : "circle").foregroundStyle(palette.accent)
                Text(label).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 13)).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain).help(focus.title)
    }

    private func highlightedSchedule(_ focus: AgendaFocus, now: Date, includeTentative: Bool = true) -> String {
        if focus.isChecklist { return L("清单事项") }
        let day = (focus.occurrence?.displayDay).map { AgendaClock.dayKey($0) == AgendaClock.dayKey(now) ? "" : Self.shortDayFormatter.string(from: $0) + " " } ?? ""
        return day + (focus.occurrence?.postponedUntil != nil ? L("本次已调整 ") : "") + (includeTentative && focus.item.isTentative ? L("待确认·不提醒 · ") : "") + (focus.due.map { AgendaClock.timeText($0) } ?? L("未定时"))
    }

    private func highlightedStatus(_ focus: AgendaFocus, now: Date) -> String {
        if focus.isChecklist { return L("清单事项") }
        guard let due = focus.due else { return L("还没定时间 · 按自己的节奏安排") }
        if !focus.item.isTentative, focus.item.reminderEnabled, let occurrence = focus.occurrence, let snooze = occurrence.item.snoozes[occurrence.completionKey], snooze > now {
            return (due <= now ? L("安排已到点 · ") : "") + L("稍后提醒 ") + reminderTime(snooze, now: now)
        }
        if due <= now {
            if focus.item.durationMinutes > 0, let end = focus.occurrence?.end, end > now { return L("时段内 · 还剩 ") + AgendaClock.countdown(to: end, now: now) }
            return L("已到时间 · ") + AgendaClock.countdown(to: due, now: now)
        }
        if due.timeIntervalSince(now) <= 1 { return L("即将开始") }
        return (focus.occurrence?.postponedUntil != nil ? L("本次已调整 · 还有 ") : L("还有 ")) + AgendaClock.countdown(to: due, now: now)
    }

    private func reminderTime(_ date: Date, now: Date) -> String {
        (AgendaClock.dayKey(date) == AgendaClock.dayKey(now) ? "" : Self.shortDayFormatter.string(from: date) + " ") + AgendaClock.timeText(date)
    }

    @ViewBuilder private func delayActions(_ o: Occurrence) -> some View {
        if !o.isCompleted && o.due != nil {
            Menu(L("稍后提醒（安排时间不变）")) {
                Button(L("10 分钟后提醒")) { store.snooze(o, minutes: 10) }
                Button(L("30 分钟后提醒")) { store.snooze(o, minutes: 30) }
            }.disabled(o.item.isTentative || !o.item.reminderEnabled || o.remindAt == nil)
            if o.item.feishu == nil {
                Button(L("推迟这次 10 分钟")) { _ = store.postpone(o, minutes: 10) }
                Button(L("推迟这次 30 分钟")) { _ = store.postpone(o, minutes: 30) }
            }
        }
    }

    private func editFocus(_ focus: AgendaFocus) {
        if focus.item.feishu != nil { openScheduledItem(focus.item, occurrence: focus.occurrence); return }
        let session = EditorSession(item: focus.item, source: nil, occurrence: focus.occurrence)
        modal = focus.isChecklist ? .checklistEditor(session) : .editor(session)
    }

    private func openScheduledItem(_ item: AgendaItem, occurrence: Occurrence? = nil) {
        guard let source = item.feishu else { modal = .editor(EditorSession(item: item, source: nil, occurrence: occurrence)); return }
        guard let raw = source.appLink, let url = URL(string: raw), url.scheme == "https",
              ["applink.feishu.cn", "applink.larkoffice.com"].contains(url.host ?? ""), url.path == "/client/calendar/event/detail", url.user == nil, url.password == nil else {
            store.error = L("该日程来自飞书，请在飞书日历中查看或修改。")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func scheduledItemAccessibilityLabel(_ o: Occurrence) -> String {
        var descriptions = [(o.item.feishu == nil ? L("编辑 ") : L("在飞书中查看 ")) + o.title]
        if o.item.repeatRule != .none { descriptions.append(o.item.repeatRule.label + L("重复")) }
        if o.item.isTentative { descriptions.append(L("待确认·不提醒")) }
        else if o.item.reminderEnabled { descriptions.append(L("到点提醒已开启")) }
        return descriptions.joined(separator: "，")
    }

    private func dueStrip(_ o: Occurrence) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.badge.fill").font(.system(size: 13)).foregroundStyle(palette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(o.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true).help(o.title)
                Text(L("原安排 ") + AgendaClock.timeText(o.due!)).font(.system(size: 11)).foregroundStyle(palette.warning)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(L("完成")) { store.toggle(o) }.fixedSize().help(L("完成 \(o.title)"))
            Menu(L("延迟")) { delayActions(o) }.fixedSize().help(L("稍后提醒或推迟这次安排"))
        }.font(.system(size: 11)).buttonStyle(.bordered).tint(palette.warning).foregroundStyle(palette.ink).padding(.horizontal, 9).padding(.vertical, 7).frame(minHeight: 44).background(palette.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func scrollToTime(_ proxy: ScrollViewProxy, now: Date) {
        if AgendaClock.dayKey(store.selectedDay) == AgendaClock.dayKey(now) {
            proxy.scrollTo("compact-now", anchor: .center)
        } else { proxy.scrollTo("timeline-top", anchor: .top) }
    }

    private func eventColor(_ o: Occurrence, now: Date) -> Color {
        if o.isCompleted { return palette.secondary }
        if let due = o.due, due < now, !(o.item.durationMinutes > 0 && (o.end ?? .distantPast) > now) { return palette.warning }
        return palette.accent
    }

    private func compactAgenda(rows: [Occurrence], now: Date) -> some View {
        let timeline = CompactAgendaTimeline(rows: rows.filter { store.settings.showCompleted || !$0.isCompleted }, day: store.selectedDay, now: now, rowPitch: store.settings.scheduleIntervalsVisible ? 82 : 56)
        return VStack(spacing: 0) {
            ForEach(0...timeline.rows.count, id: \.self) { index in
                if timeline.showsNow && index == timeline.insertionIndex {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: timeline.gapOffset - 8)
                        HStack(spacing: 6) {
                            Circle().fill(palette.accent).frame(width: 9, height: 9)
                            Text(L("现在 ") + Self.clockFormatter.string(from: now)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(palette.accent).lineLimit(1)
                            Rectangle().fill(palette.accent.opacity(0.8)).frame(height: 1.5)
                        }.frame(height: 16).padding(.leading, 56.5).id("compact-now")
                        Color.clear.frame(height: timeline.nowGap - timeline.gapOffset - 8)
                    }.frame(height: timeline.nowGap)
                }
                if index < timeline.rows.count {
                    VStack(alignment: .leading, spacing: 3) {
                        compactRow(timeline.rows[index], now: now)
                        if store.settings.scheduleIntervalsVisible, let gap = ScheduleInterval.following(timeline.rows[index], items: store.items, on: store.selectedDay) {
                                Text(gap.text).font(.system(size: 10)).foregroundStyle(gap.remainingMinutes < 0 ? palette.warning : palette.secondary).lineLimit(1).help(gap.text).padding(.horizontal, 6).padding(.vertical, 2).background(palette.background, in: Capsule()).padding(.leading, 80)
                        }
                    }.frame(height: timeline.rowPitch, alignment: .top).id(timeline.rows[index].id)
                }
            }
        }.padding(.top, 10).background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(palette.accent.opacity(0.18)).frame(width: 1.5, height: timeline.height).offset(x: 60.25, y: 10)
                Rectangle().fill(palette.accent.opacity(0.8)).frame(width: 2, height: timeline.elapsedHeight).offset(x: 60, y: 10)
            }.allowsHitTesting(false)
        }
    }

    private func compactRow(_ o: Occurrence, now: Date) -> some View {
        let color = eventColor(o, now: now)
        let past = o.due! <= now
        let inSpan = past && o.item.durationMinutes > 0 && (o.end ?? .distantPast) > now
        let snooze = !o.item.isTentative && o.item.reminderEnabled ? o.item.snoozes[o.completionKey] : nil
        let status = o.isCompleted ? L("已完成") : snooze != nil && snooze! > now ? L("稍后提醒 ") + reminderTime(snooze!, now: now) : inSpan ? L("时段内 · 还剩 ") + AgendaClock.countdown(to: o.end!, now: now) : past ? L("待处理 · ") + AgendaClock.countdown(to: o.due!, now: now) : L("还有 ") + AgendaClock.countdown(to: o.due!, now: now)
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(o.due! < AgendaClock.startOfDay(o.day) ? L("持续中") : AgendaClock.timeText(o.due!)).font(.system(size: 14, weight: .medium, design: .rounded)).monospacedDigit()
                if o.item.durationMinutes > 0 { Text((AgendaClock.dayKey(o.end!) != AgendaClock.dayKey(o.day) ? Self.shortDayFormatter.string(from: o.end!) + " " : "") + AgendaClock.timeText(o.end!)).font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(palette.secondary).lineLimit(1).minimumScaleFactor(0.7) }
            }.frame(width: 44, alignment: .trailing).padding(.top, 3)
            Button { store.toggle(o) } label: { Image(systemName: o.isCompleted ? "checkmark.circle.fill" : "circle").font(.system(size: 18, weight: .light)).foregroundStyle(color).frame(width: 22, height: 26).background(Circle().fill(palette.background).frame(width: 17, height: 17)) }.buttonStyle(.plain).accessibilityLabel(o.isCompleted ? L("恢复 \(o.title)") : L("完成 \(o.title)"))
            Button { openScheduledItem(o.item, occurrence: o) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.title).font(.system(size: 15, weight: .medium)).strikethrough(o.isCompleted).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        if o.item.feishu != nil { Text(L("飞书")).foregroundStyle(palette.accent) }
                        if o.item.isTentative { Text(L("待确认·不提醒")).foregroundStyle(palette.warning).fixedSize() }
                        if o.postponedUntil != nil { Text(L("本次已调整")).foregroundStyle(palette.accent) }
                        Text(status).foregroundStyle(o.isCompleted ? palette.secondary : color).lineLimit(1).help(status)
                        if o.item.repeatRule != .none { Image(systemName: "repeat").font(.system(size: 10)).help(o.item.repeatRule.label + L("重复")).accessibilityLabel(o.item.repeatRule.label + L("重复")) }
                        if o.item.reminderEnabled && !o.item.isTentative { Image(systemName: "bell").font(.system(size: 10)).help(L("到点提醒已开启")).accessibilityLabel(L("到点提醒已开启")) }
                    }.font(.system(size: 11))
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(o.title).accessibilityLabel(scheduledItemAccessibilityLabel(o))
            Menu {
                Button(o.item.feishu == nil ? L("修改安排") : L("在飞书中查看")) { openScheduledItem(o.item, occurrence: o) }
                Button(o.isCompleted ? L("恢复待办") : L("标记完成")) { store.toggle(o) }
                if !o.isCompleted { Button(store.isPinned(o) ? L("取消顶部固定") : L("固定到顶部")) { if store.isPinned(o) { store.clearPinnedOccurrence() } else { _ = store.pinOccurrence(o) } } }
                delayActions(o)
                Rectangle().fill(palette.divider).frame(height: 0.5); if o.item.feishu == nil { Button(L("删除事项"), role: .destructive) { store.delete(o.item.id) } }
            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 26).foregroundStyle(palette.secondary) }.menuStyle(.borderlessButton).fixedSize().help(L("\(o.title) 的更多操作"))
        }.padding(.top, 4)
    }

    private func row(_ o: Occurrence, now: Date) -> some View {
        let overdue = !o.isCompleted && (o.due ?? .distantFuture) < now
        let imminent = !o.isCompleted && !overdue && (o.due?.timeIntervalSince(now) ?? .infinity) < 1800
        let running = !o.isCompleted && overdue && o.item.durationMinutes > 0 && (o.end ?? .distantPast) > now
        return HStack(alignment: .top, spacing: 10) {
            Button { store.toggle(o) } label: {
                Image(systemName: o.isCompleted ? "checkmark.circle.fill" : "circle").font(.system(size: 19, weight: .light)).foregroundStyle(o.isCompleted ? palette.accent.opacity(0.55) : overdue ? palette.warning : palette.accent.opacity(0.45)).frame(width: 24, height: 29)
            }.buttonStyle(.plain).help(o.isCompleted ? L("恢复 \(o.item.title)") : L("完成 \(o.item.title)")).accessibilityLabel(o.isCompleted ? L("恢复 \(o.item.title)") : L("完成 \(o.item.title)"))
            Button {
                openScheduledItem(o.item, occurrence: o)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(o.due.map { AgendaClock.timeText($0) } ?? (o.item.feishu?.isAllDay == true ? L("全天") : L("待定"))).font(.system(size: 15, weight: .medium, design: .rounded)).monospacedDigit()
                        if o.item.durationMinutes > 0 { Text(L("\(o.item.durationMinutes) 分钟")).font(.system(size: 11)).foregroundStyle(palette.secondary) }
                    }.frame(width: 49, alignment: .leading).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(o.item.title).font(.system(size: 15, weight: .medium)).strikethrough(o.isCompleted).lineLimit(3).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            if o.postponedUntil != nil { badge(L("本次已调整"), color: palette.accent) }
                        }
                        if o.item.isTentative { Text(L("待确认·不提醒")).font(.system(size: 11)).foregroundStyle(palette.warning) }
                        HStack(spacing: 5) {
                            Text(categoryLabel(o.item.category)).foregroundStyle(palette.secondary)
                            Text("·")
                            if o.isCompleted { Text(L("已完成")) }
                            else if running, let end = o.end { Text(L("时段内 · 还剩 \(AgendaClock.countdown(to: end, now: now))")) }
                            else if let due = o.due { Text(overdue ? L("已到时间 · \(AgendaClock.countdown(to: due, now: now))") : L("还有 \(AgendaClock.countdown(to: due, now: now))")) }
                            else { Text(o.item.feishu?.isAllDay == true ? L("全天日程") : L("还没定时间")) }
                            if o.item.repeatRule != .none { Image(systemName: "repeat").font(.system(size: 11)).help(o.item.repeatRule.label + L("重复")).accessibilityLabel(o.item.repeatRule.label + L("重复")) }
                            if o.item.reminderEnabled && !o.item.isTentative { Image(systemName: "bell").font(.system(size: 11)).help(L("到点提醒已开启")).accessibilityLabel(L("到点提醒已开启")) }
                        }.font(.system(size: 11)).foregroundStyle(overdue ? palette.warning : palette.secondary)
                        if let snooze = !o.item.isTentative && o.item.reminderEnabled ? o.item.snoozes[o.completionKey] : nil, snooze > now { Text(L("稍后提醒 \(reminderTime(snooze, now: now))")).font(.system(size: 11)).foregroundStyle(palette.accent) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(scheduledItemAccessibilityLabel(o))
            Menu {
                Button(o.item.feishu == nil ? L("修改安排") : L("在飞书中查看")) { openScheduledItem(o.item, occurrence: o) }
                delayActions(o)
                Button(o.isCompleted ? L("恢复待办") : L("标记完成")) { store.toggle(o) }
                if !o.isCompleted { Button(store.isPinned(o) ? L("取消顶部固定") : L("固定到顶部")) { if store.isPinned(o) { store.clearPinnedOccurrence() } else { _ = store.pinOccurrence(o) } } }
                Rectangle().fill(palette.divider).frame(height: 0.5)
                if o.item.feishu == nil { Button(L("删除事项"), role: .destructive) { store.delete(o.item.id) } }
            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 27).foregroundStyle(palette.secondary) }.menuStyle(.borderlessButton).fixedSize().help(L("\(o.item.title) 的更多操作"))
        }.padding(.vertical, 10).padding(.horizontal, 9)
            .background(imminent ? palette.accent.opacity(0.07) : overdue ? palette.warning.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottom) { Rectangle().fill(palette.divider).frame(height: 0.5).padding(.leading, 42) }
    }

    private func checklistContent() -> some View {
        let pending = store.checklistItems()
        let completed = store.checklistItems(includeCompleted: true).filter { $0.checklistState == .completed }
        return ScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: 3) {
                if pending.isEmpty {
                    Text(completed.isEmpty ? L("写下第一件要做的事") : L("待办已完成")).font(.system(size: 13)).foregroundStyle(palette.secondary).padding(.vertical, 16)
                }
                ForEach(Array(pending.enumerated()), id: \.element.id) { index, item in
                    checklistRow(item, number: index + 1, pendingIndex: index, pendingCount: pending.count)
                }
                if !completed.isEmpty {
                    DisclosureGroup(L("已完成 \(completed.count) 件")) {
                        ForEach(completed) { item in checklistRow(item, number: nil, pendingIndex: nil, pendingCount: pending.count) }
                    }.font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondary).tint(palette.accent).padding(.top, 10)
                }
            }.padding(.horizontal, 16).padding(.bottom, 16)
        }
    }

    private func checklistRow(_ item: AgendaItem, number: Int?, pendingIndex: Int?, pendingCount: Int) -> some View {
        let completed = item.checklistState == .completed
        let focus = AgendaFocus.checklist(item)
        return HStack(alignment: .top, spacing: 7) {
            Button { _ = store.setChecklistCompleted(item.id, completed: !completed) } label: {
                Image(systemName: completed ? "checkmark.circle.fill" : "circle").font(.system(size: 18, weight: .light)).foregroundStyle(completed ? palette.secondary : palette.accent).frame(width: 24, height: 29).contentShape(Rectangle())
            }.buttonStyle(.plain).help(completed ? L("恢复 \(item.title)") : L("完成 \(item.title)")).accessibilityLabel(completed ? L("恢复 \(item.title)") : L("完成 \(item.title)"))
            Text(number.map { "\($0)." } ?? "").font(.system(size: 13, design: .monospaced)).foregroundStyle(palette.secondary).frame(width: 23, alignment: .trailing).padding(.top, 6).accessibilityHidden(true)
            Button { modal = .checklistEditor(EditorSession(item: item, source: nil)) } label: {
                Text(item.title).font(.system(size: 15, weight: .medium)).strikethrough(completed).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 29, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(completed ? palette.secondary : palette.ink).help(item.title).accessibilityLabel(L("编辑清单事项 \(item.title)"))
            Menu {
                Button(L("编辑事项")) { modal = .checklistEditor(EditorSession(item: item, source: nil)) }
                Button(completed ? L("恢复待办") : L("标记完成")) { _ = store.setChecklistCompleted(item.id, completed: !completed) }
                if !completed {
                    Button(L("安排日期与时间…")) { modal = .editor(EditorSession(item: item, source: nil, schedulingChecklist: true)) }
                    Button(store.isPinned(focus) ? L("取消顶部固定") : L("固定到顶部")) { if store.isPinned(focus) { store.clearPinnedOccurrence() } else { _ = store.pinChecklistItem(item.id) } }
                    Button(L("上移")) { _ = store.moveChecklistItem(item.id, by: -1) }.disabled(pendingIndex == 0)
                    Button(L("下移")) { _ = store.moveChecklistItem(item.id, by: 1) }.disabled(pendingIndex == pendingCount - 1)
                }
                Divider()
                Button(L("删除事项"), role: .destructive) { store.delete(item.id) }
            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 29).foregroundStyle(palette.secondary) }.menuStyle(.borderlessButton).fixedSize().help(L("\(item.title) 的更多操作"))
        }.padding(.vertical, 5)
    }

    private func checklistFooter() -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !controller.notifications.authorized && !controller.isQA {
                Button { modal = .settings } label: { Label(L("\(controller.notifications.permissionText) · 设置"), systemImage: "bell.slash").font(.system(size: 11)).foregroundStyle(palette.warning) }.buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                TextField(L("写一件要做的事…"), text: $quickChecklistTitle).font(.system(size: 13)).textFieldStyle(.plain).focused($quickChecklistFocused).simultaneousGesture(TapGesture().onEnded { controller.focusTextEntry(); quickChecklistFocused = true }).onSubmit(addQuickChecklist).padding(.horizontal, 9).frame(height: 34).background(palette.controlFill, in: RoundedRectangle(cornerRadius: 9)).accessibilityLabel(L("新清单事项，回车添加"))
                Button { addQuickChecklist() } label: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 34).foregroundStyle(palette.primaryInk).background(palette.primaryFill, in: RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(quickChecklistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).help(L("添加清单事项")).accessibilityLabel(L("添加清单事项"))
                Menu {
                    Button(L("撤销上一步")) { store.undo() }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 34).background(palette.controlFill, in: RoundedRectangle(cornerRadius: 9)) }.menuStyle(.borderlessButton).fixedSize().help(L("清单更多操作")).padding(.trailing, 12)
            }
        }.padding(.horizontal, 18).padding(.top, 7).padding(.bottom, 10).background(palette.controlFill.opacity(0.5))
    }

    private func addQuickChecklist() {
        let title = quickChecklistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if store.addChecklistItem(title: title) { quickChecklistTitle = "" }
        quickChecklistFocused = true
    }

    private func footer() -> some View {
        VStack(spacing: 7) {
          if !controller.notifications.authorized && !controller.isQA {
            Button { modal = .settings } label: { Label(L("\(controller.notifications.permissionText) · 设置"), systemImage: "bell.slash").font(.system(size: 11)).foregroundStyle(palette.warning) }.buttonStyle(.plain)
          }
          HStack(spacing: 9) {
            Button { editingSchedule = true } label: {
                Label(L("编辑日程"), systemImage: "pencil").font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, panelHeight < 650 ? 7 : 11).background(palette.controlFill, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).help(L("直接修改所有日程的时间、每天或每周重复方式"))
            Button { add() } label: { Label(L("添加日程"), systemImage: "plus").font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, panelHeight < 650 ? 7 : 11).foregroundStyle(palette.primaryInk).background(palette.primaryFill, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
            Menu {
                Button(L("撤销上一步")) { store.undo() }
                Button(store.settings.showCompleted ? L("隐藏已完成") : L("显示已完成")) { store.settings.showCompleted.toggle(); _ = store.save() }
            } label: { Image(systemName: "ellipsis").font(.system(size: 15)).frame(width: 36, height: 36).background(palette.controlFill, in: RoundedRectangle(cornerRadius: 12)) }.menuStyle(.borderlessButton).fixedSize().help(L("更多")).padding(.trailing, 12)
          }
        }.padding(.horizontal, 18).padding(.top, panelHeight < 650 ? 6 : 9).padding(.bottom, panelHeight < 650 ? 10 : 14)
            .background(palette.controlFill.opacity(0.5))
    }

    private func compact(now: Date) -> some View {
        let displayed = store.compactFocus(now: now)
        let followsPinned = store.compactUsesPinnedFocus
        let overdue = AgendaClock.overdue(items: store.items, now: now).filter { ($0.end ?? .distantPast) <= now }.count + AgendaClock.earlierUnscheduled(items: store.items, now: now).count
        let detail = displayed.map { focus -> String in
            if focus.isChecklist { return L("固定的清单事项") }
            let status: String
            if let due = focus.due, due <= now, let end = focus.occurrence?.end, end > now {
                status = L("还剩 ") + AgendaClock.countdown(to: end, now: now)
            } else { status = highlightedStatus(focus, now: now) }
            return highlightedSchedule(focus, now: now) + " · " + status
        } ?? L("点展开查看日程")
        return HStack(spacing: 10) {
            Button { showingCompactChoices = true } label: {
                HStack(spacing: 2) {
                    Image(systemName: followsPinned ? "pin.fill" : "calendar").font(.system(size: 18))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }.frame(width: 32, height: 32).contentShape(Rectangle()).foregroundStyle(palette.accent)
            }.buttonStyle(.plain).fixedSize()
                .help(L("小窗显示：\(followsPinned ? L("固定事项") : L("最近安排"))，点击切换"))
                .accessibilityLabel(L("切换小窗显示：\(followsPinned ? L("固定事项") : L("最近安排"))"))
                .popover(isPresented: $showingCompactChoices, arrowEdge: .bottom) { highlightedChoices(forCompact: true) }
            VStack(alignment: .leading, spacing: 3) {
                Text((controller.isQA ? L("[测试] ") : "") + (displayed?.title ?? L("暂无接下来的安排"))).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1).help(displayed?.title ?? "")
                Text(detail).font(.system(size: 11)).foregroundStyle(palette.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85).help(detail)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if overdue > 0 {
                Button { store.settings.compact = false; _ = store.save() } label: {
                    Label("\(overdue)", systemImage: "bell.badge.fill").font(.system(size: 11)).foregroundStyle(palette.warning).padding(.vertical, 6)
                }.buttonStyle(.plain).help(L("\(overdue) 件安排待处理，展开查看")).accessibilityLabel(L("\(overdue) 件安排待处理，展开查看"))
            }
            HStack(spacing: 3) {
                IconButton(symbol: "minus", label: L("隐藏日程")) { controller.minimizeToMenu() }
                Button { store.settings.compact = false; _ = store.save() } label: { Text(L("展开")).font(.system(size: 11, weight: .medium)).frame(width: 44, height: 30).background(palette.controlFill, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain).help(L("展开日程"))
            }
        }.padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func add() {
        controller.expandForInput()
        if section == .checklist { quickChecklistFocused = true }
        else { modal = .editor(EditorSession(item: nil, source: nil)) }
    }
    private func takeCaptureSessions() -> [EditorSession] {
        controller.takeCaptureDrafts().map { draft in
            EditorSession(item: draft.item, source: draft.source, restoreCompactOnDismiss: draft.restoreCompactOnDismiss)
        }
    }
    private func receiveCaptures() {
        for session in takeCaptureSessions() {
            if modal != nil || modalIsPresented { queuedCaptures.append(session) }
            else { presentCapture(session) }
        }
    }
    private func presentCapture(_ session: EditorSession) {
        capturePresentation.began(originatedCompact: session.restoreCompactOnDismiss)
        if session.item?.isChecklist == true { section = .checklist; modal = .checklistEditor(session) }
        else { section = .agenda; modal = .editor(session) }
    }
    private func presentQueuedCapture() {
        queuedCaptures.append(contentsOf: takeCaptureSessions())
        let restoreCompact = capturePresentation.finished(hasQueuedCapture: !queuedCaptures.isEmpty)
        if !queuedCaptures.isEmpty {
            let next = queuedCaptures.removeFirst()
            DispatchQueue.main.async { modalIsPresented = false; presentCapture(next) }
        } else {
            modalIsPresented = false
            if restoreCompact && !store.settings.compact {
                store.settings.compact = true
                _ = store.save()
            }
        }
    }
    private func badge(_ text: String, color: Color) -> some View { Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color).padding(.horizontal, 5).padding(.vertical, 2).background(color.opacity(0.1), in: Capsule()) }
    static let clockFormatter: DateFormatter = { let f = DateFormatter(); f.timeZone = AgendaClock.calendar.timeZone; f.dateFormat = "HH:mm:ss"; return f }()
    static var selectedDayFormatter: DateFormatter { Localization.dateFormatter(chinese: "M 月 d 日 · EEE", english: "MMM d · EEE") }
    static var shortDayFormatter: DateFormatter { Localization.dateFormatter(chinese: "M/d", english: "M/d") }
    static var dayFormatter: DateFormatter { Localization.dateFormatter(chinese: "M 月 d 日 · EEEE", english: "MMM d · EEEE") }
    static var fullDayFormatter: DateFormatter { Localization.dateFormatter(chinese: "M 月 d 日 EEEE", english: "MMM d EEEE") }
}

struct ItemEditor: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: AgendaPalette { AgendaPalette(mode: store.settings.appearanceMode, accent: store.settings.accentColor, systemScheme: agendaSystemColorScheme(fallback: colorScheme)) }
    @ObservedObject var store: AgendaStore
    let item: AgendaItem?
    let source: String?
    var schedulingChecklist = false
    var occurrence: Occurrence? = nil
    var onScheduled: () -> Void = {}
    let close: () -> Void
    @State private var title = ""
    @State private var day = Date()
    @State private var timeInput = "09:00"
    @State private var weeklyInputs: [String: String]?
    @State private var hasTime = true
    @State private var tentative = false
    @State private var reminder = true
    @State private var durationInput = "0"
    @State private var category = "生活"
    @State private var repeatRule = RepeatRule.none
    @State private var note = ""
    @State private var validation: String?
    @State private var originalItem: AgendaItem?
    @State private var onlyThisTime = true
    @State private var showingDetails = false
    @FocusState private var titleFocused: Bool
    private var canChooseScope: Bool { occurrence?.due != nil && item != nil && item?.repeatRule != RepeatRule.none }
    private var editingSingleTime: Bool { canChooseScope && onlyThisTime }
    private var saveLabel: String { canChooseScope ? (onlyThisTime ? L("保存这一次") : L("保存每次修改")) : L("保存安排") }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(schedulingChecklist ? L("安排日期与时间") : item == nil ? L("安排一件事") : L("修改安排")).font(.system(size: 24, weight: .semibold))
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }.buttonStyle(.plain).accessibilityLabel(L("取消编辑"))
            }
            if editingSingleTime {
                Text(item?.title ?? title).font(.system(size: 18, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField(L("要做什么？"), text: $title).font(.system(size: 18)).textFieldStyle(.plain).padding(12).background(palette.controlFill, in: RoundedRectangle(cornerRadius: 10)).focused($titleFocused)
            }
            if canChooseScope {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L("修改范围"), selection: $onlyThisTime) {
                        Text(L("仅这一次")).tag(true)
                        Text(L("每次都修改")).tag(false)
                    }.pickerStyle(.segmented).id(Localization.language)
                    Text(onlyThisTime ? L("仅调整 \(AgendaClock.dayKey(occurrence!.day)) 这一次的日期和时间，其他日期不变。") : L("应用到整个重复安排，包含历史日期。改变日期、时间或重复方式会重置单次时间调整；完成记录保留。"))
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                DatePicker(canChooseScope && !onlyThisTime ? L("重复起始日") : L("日期"), selection: $day, displayedComponents: .date)
                    .environment(\.timeZone, AgendaClock.calendar.timeZone)
                Spacer()
                if !editingSingleTime { Toggle(L("定时"), isOn: $hasTime).toggleStyle(.switch) }
            }
            if hasTime && (editingSingleTime || weeklyInputs == nil) { HStack { Text(L("时间")); Spacer(); TimeInput(text: $timeInput, label: L("开始时间")) } }
            if !editingSingleTime {
                Picker(L("重复"), selection: $repeatRule) { ForEach(RepeatRule.allCases, id: \.self) { Text($0.label).tag($0) } }
                if hasTime && repeatRule != .none { WeeklyTimeEditor(inputs: $weeklyInputs, rule: $repeatRule, anchor: day, defaultTime: timeInput, title: title) }
                if repeatRule == .weekly && weeklyInputs == nil { Text(L("每周在所选日期的星期几重复。")).font(.system(size: 12)).foregroundStyle(palette.secondary) }
                if !tentative && hasTime { Toggle(L("提前和到点提醒"), isOn: $reminder) }
                DisclosureGroup(L("更多选项"), isExpanded: $showingDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("分类", selection: $category) { ForEach(Array(Set(["生活", "工作", "学习", "健康", category])).sorted(), id: \.self) { Text(categoryLabel($0)).tag($0) } }
                        if hasTime { DurationInput(text: $durationInput) }
                        TextField(L("备注（可选）"), text: $note, axis: .vertical).lineLimit(2...3).textFieldStyle(.roundedBorder)
                        Toggle(L("时间尚未确认，暂不提醒"), isOn: $tentative)
                    }.padding(.top, 10)
                }
            } else {
                Text(L("名称、重复方式和提醒设置可切换到“每次都修改”调整。"))
                    .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let validation { Text(validation).foregroundStyle(palette.warning).font(.system(size: 13)) }
            HStack { Button(L("取消")) { close() }.keyboardShortcut(.cancelAction); Spacer(); Button { save() } label: { Text(saveLabel).padding(.horizontal, 12).padding(.vertical, 6).background(palette.primaryFill, in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(palette.primaryInk).contentShape(Rectangle()) }.buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.font(.system(size: 14)).padding(27).frame(width: 420).foregroundStyle(palette.ink).background(palette.background).environment(\.agendaPalette, palette).tint(palette.accent)
            .onAppear { load(); titleFocused = !editingSingleTime }
            .onChange(of: onlyThisTime) {
                validation = nil
                day = onlyThisTime ? (occurrence?.displayDay ?? store.selectedDay) : (originalItem?.date ?? store.selectedDay)
                if onlyThisTime, let due = occurrence?.due { timeInput = AgendaClock.timeText(due) }
                else if let minutes = originalItem?.timeMinutes { timeInput = String(format: "%02d:%02d", minutes / 60, minutes % 60) }
                titleFocused = false
            }
            .onChange(of: tentative) { if !tentative { reminder = true } }
            .onChange(of: repeatRule) { if repeatRule != .weekly { weeklyInputs = nil } }
    }
    private func load() {
        originalItem = item
        weeklyInputs = item?.weeklyTimes?.mapValues { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
        day = schedulingChecklist ? store.selectedDay : (item?.scheduledDay ?? store.selectedDay); title = item?.title ?? ""; tentative = item?.isTentative ?? false; reminder = item?.reminderEnabled ?? true; durationInput = String(item?.durationMinutes ?? 0); category = item?.category ?? "生活"; repeatRule = item?.repeatRule ?? .none; note = item?.note ?? ""
        if schedulingChecklist {
            hasTime = false; timeInput = "00:00"; tentative = false; reminder = true
        } else {
            hasTime = item == nil || item?.timeMinutes != nil
            let mins = item?.timeMinutes ?? ((AgendaClock.calendar.component(.hour, from: Date()) * 60 + AgendaClock.calendar.component(.minute, from: Date()) + 30) % 1440)
            timeInput = String(format: "%02d:%02d", mins / 60, mins % 60)
        }
        if editingSingleTime, let due = occurrence?.due {
            day = AgendaClock.startOfDay(due)
            timeInput = AgendaClock.timeText(due)
        }
    }
    private func save() {
        if hasTime && (editingSingleTime || weeklyInputs == nil) && parseClockInput(timeInput) == nil { validation = L("请输入有效的 24 小时时间，例如 09:30。"); return }
        if editingSingleTime, let occurrence, let minutes = parseClockInput(timeInput),
           let target = AgendaClock.calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) {
            if store.rescheduleOccurrence(occurrence, until: target) { close() }
            else { validation = store.error ?? L("保存失败，请重试。") }
            return
        }
        var edited = originalItem ?? AgendaItem(title: title, date: day)
        guard !hasTime || DurationInputValue.minutes(durationInput) != nil else { validation = L("请输入 0–1440 分钟，0 表示不设时长"); return }
        edited.title = title.trimmingCharacters(in: .whitespacesAndNewlines); edited.date = AgendaClock.startOfDay(day); edited.timeMinutes = hasTime ? parseClockInput(timeInput) : nil; edited.durationMinutes = hasTime ? DurationInputValue.minutes(durationInput)! : 0; edited.category = category; edited.repeatRule = repeatRule; edited.isTentative = tentative; edited.reminderEnabled = reminder && !tentative && hasTime; edited.note = note
        if hasTime, repeatRule == .weekly, let weeklyInputs {
            let times = weeklyInputs.compactMapValues { TimeInputValue($0).minutes }
            guard !times.isEmpty, times.count == weeklyInputs.count else { validation = L("请至少选择一天，并填写有效时间。"); return }
            edited.weeklyTimes = times; edited.timeMinutes = times.values.min()
        } else { edited.weeklyTimes = nil }
        let browsingDay = store.selectedDay
        let isExisting = originalItem.map { original in store.items.contains(where: { $0.id == original.id }) } == true
        let saved = schedulingChecklist ? store.scheduleChecklistItem(edited) : store.upsert(edited)
        if saved {
            let destinationDay = AgendaEditorNavigation.dayAfterSave(browsingDay: browsingDay, editedDay: day, isExisting: isExisting, schedulingChecklist: schedulingChecklist)
            if store.selectedDay != destinationDay { store.selectedDay = destinationDay }
            if schedulingChecklist { onScheduled() }
            close()
        } else { validation = store.error ?? L("保存失败，请重试。") }
    }
}

struct ChecklistEditor: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: AgendaPalette { AgendaPalette(mode: store.settings.appearanceMode, accent: store.settings.accentColor, systemScheme: agendaSystemColorScheme(fallback: colorScheme)) }
    @ObservedObject var store: AgendaStore
    let item: AgendaItem?
    let source: String?
    let close: () -> Void
    @State private var title = ""
    @State private var note = ""
    @State private var validation: String?
    @FocusState private var titleFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(item.map { original in store.items.contains(where: { $0.id == original.id }) } == true ? L("编辑清单事项") : L("写一件要做的事")).font(.system(size: 23, weight: .semibold))
                Spacer()
                Button(L("取消")) { close() }.keyboardShortcut(.cancelAction)
            }
            if source == "clawd" { Text(L("从 Clawd 捕获")).font(.system(size: 12)).foregroundStyle(palette.secondary) }
            TextField(L("要做什么？"), text: $title).font(.system(size: 18)).textFieldStyle(.plain).padding(12).background(palette.controlFill, in: RoundedRectangle(cornerRadius: 10)).focused($titleFocused)
            TextField(L("备注（可选）"), text: $note, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            if let validation { Text(validation).font(.system(size: 12)).foregroundStyle(palette.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button { save() } label: { Text(L("保存事项")).padding(.horizontal, 12).padding(.vertical, 6).background(palette.primaryFill, in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(palette.primaryInk).contentShape(Rectangle()) }.buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.font(.system(size: 14)).padding(24).frame(width: 360).foregroundStyle(palette.ink).background(palette.background).environment(\.agendaPalette, palette).tint(palette.accent)
            .onAppear { title = item?.title ?? ""; note = item?.note ?? ""; titleFocused = true }
    }
    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let saved: Bool
        if var edited = item { edited.title = trimmed; edited.note = note; saved = store.upsert(edited) }
        else { saved = store.addChecklistItem(title: trimmed, note: note) }
        if saved { close() } else { validation = store.error ?? L("保存失败，请重试。") }
    }
}

private enum SettingsTab: String, CaseIterable { case appearance = "外观", reminders = "提醒", other = "其他" }

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: AgendaPalette { AgendaPalette(mode: store.settings.appearanceMode, accent: store.settings.accentColor, systemScheme: agendaSystemColorScheme(fallback: colorScheme)) }
    @ObservedObject var store: AgendaStore
    @ObservedObject var controller: AppController
    let close: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var tab = SettingsTab.appearance
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                HStack { Text(L("设置")).font(.system(size: 24, weight: .semibold)); Spacer(); Button(L("完成")) { _ = store.save(); close() }.keyboardShortcut(.defaultAction) }
                Picker(L("设置分类"), selection: $tab) { ForEach(SettingsTab.allCases, id: \.self) { Text(Localization.translate($0.rawValue)).tag($0) } }.pickerStyle(.segmented).id(Localization.language).labelsHidden()
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .appearance: appearanceSettings
                    case .reminders: reminderSettings
                    case .other: otherSettings
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
            .frame(width: 440, height: min(650, max(450, (NSScreen.main?.visibleFrame.height ?? 800) - 100)))
            .font(.system(size: 13)).background(palette.background).foregroundStyle(palette.ink).environment(\.agendaPalette, palette).tint(palette.accent)
            .onChange(of: store.settings) { _ = store.save() }
            .onChange(of: store.settings.notifications) { if store.settings.notifications { controller.notifications.refreshPermission(request: true) } }
    }
    private func accentChoice(_ color: AgendaAccentColor) -> some View {
        let selected = store.settings.accentColor == color
        let colorPalette = AgendaPalette(mode: store.settings.appearanceMode, accent: color, systemScheme: agendaSystemColorScheme(fallback: colorScheme))
        return Button { store.settings.accentColor = color } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(colorPalette.primaryFill).frame(width: 26, height: 26)
                    if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(colorPalette.primaryInk) }
                }
                Text(color.label).font(.system(size: 11, weight: selected ? .semibold : .regular))
            }.frame(maxWidth: .infinity).padding(.vertical, 7).background(selected ? palette.controlFill : .clear, in: RoundedRectangle(cornerRadius: 9)).overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? palette.accent : .clear, lineWidth: 1) }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(color.label + (selected ? L("，已选") : L("，未选")))
    }
    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.accent)
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(palette.controlFill.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }
    private var appearanceSettings: some View {
        Group {
            card(L("语言 / Language"), symbol: "globe") {
                Picker(L("语言 / Language"), selection: Binding(get: { store.settings.language }, set: {
                    store.settings.language = $0
                })) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).id(Localization.language)
            }
            card(L("日程显示"), symbol: "calendar") {
                Toggle(L("显示日程间隔"), isOn: $store.settings.scheduleIntervalsVisible).toggleStyle(.switch).controlSize(.small)
            }
            card(L("颜色"), symbol: "circle.lefthalf.filled") {
                Picker(L("明暗模式"), selection: $store.settings.appearanceMode) {
                    ForEach(AgendaAppearanceMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).id(Localization.language).accessibilityLabel(L("明暗模式"))
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("配色")).font(.system(size: 13))
                    HStack(spacing: 7) {
                        ForEach(AgendaAccentColor.allCases, id: \.self) { color in
                            accentChoice(color)
                        }
                    }
            }
            }
            card(L("窗口"), symbol: "macwindow") {
                Toggle(L("浮在其他窗口上方"), isOn: $store.settings.floating)
                Toggle(L("玻璃质感"), isOn: Binding(get: { controller.glassEnabled }, set: { controller.setGlassEnabled($0) })).disabled(reduceTransparency)
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(L("透明度")); Spacer(); Text("\(Int(((1 - controller.glassStrength) * 100).rounded()))%").monospacedDigit() }.font(.system(size: 13))
                    Slider(value: Binding(get: { 1 - controller.glassStrength }, set: { controller.setGlassStrength(1 - $0) }), in: 0...1).disabled(reduceTransparency)
                    Text(reduceTransparency ? L("系统减少透明度已开启，当前实色") : L("向左更实，向右更透明；文字和按钮保持清晰。")).font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            }
        }
    }
    private var reminderSettings: some View {
        Group {
            card(L("日程提醒"), symbol: "bell") {
                Toggle(L("系统通知"), isOn: $store.settings.notifications)
                Toggle(L("轻提示音"), isOn: $store.settings.sound)
                Picker(L("提前提醒"), selection: $store.settings.leadMinutes) { Text(L("只在到点")).tag(0); Text(L("提前 5 分钟")).tag(5); Text(L("提前 10 分钟")).tag(10); Text(L("提前 15 分钟")).tag(15); Text(L("提前 30 分钟")).tag(30) }
                HStack { Image(systemName: controller.notifications.authorized ? "bell.badge" : "bell.slash"); Text(controller.notifications.permissionText).font(.system(size: 13)); Spacer(); Button(L("通知设置")) { controller.notifications.openSettings() } }
            }
            DisclosureGroup(L("测试提醒与使用说明")) {
                VStack(alignment: .leading, spacing: 12) {
            Button(L("发送测试提醒")) { controller.notifications.testReminder(sound: store.settings.sound) }
            if !controller.notifications.testStatus.isEmpty { Text(controller.notifications.testStatus).font(.system(size: 12)).foregroundStyle(palette.accent).fixedSize(horizontal: false, vertical: true) }
            Text(L("优先安排接下来一天的提醒；保持朝夕运行，会持续补齐之后的日程。")).font(.system(size: 12)).foregroundStyle(palette.secondary)
                    Text(L("暂定安排默认静音；睡眠、勿扰与系统静音可能影响通知和声音。"))
                }.font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }.font(.system(size: 12))
        }
    }
    private var otherSettings: some View {
        Group {
            card(L("飞书日程"), symbol: "calendar") {
                Toggle(L("自动同步飞书日程"), isOn: Binding(get: { store.settings.feishuSyncEnabled == true }, set: { controller.feishuSync.setEnabled($0) })).disabled(controller.isQA)
                HStack {
                    Text(L("会议时间在飞书修改")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Spacer()
                    Button(L("立即同步")) { controller.feishuSync.tick(force: true) }.controlSize(.small).disabled(controller.isQA || controller.feishuSync.busy || store.settings.feishuSyncEnabled != true)
            }
            DisclosureGroup(L("同步状态与详情")) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(controller.feishuSync.statusText)
                    Text(L("主日历 · 昨天至未来 7 天。暂停同步会保留已有日程和本地完成状态。"))
                }.font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }.font(.system(size: 11))
            }
            card(L("启动"), symbol: "power") {
                Toggle(L("登录后打开朝夕"), isOn: Binding(get: { controller.loginEnabled }, set: { controller.setLoginEnabled($0) })).disabled(controller.isQA)
                DisclosureGroup(L("登记状态")) { Text(controller.loginText).font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 6) }.font(.system(size: 11))
            }
            card(L("数据与备份"), symbol: "externaldrive") {
                HStack { Text(L("数据只保存在这台 Mac")).font(.system(size: 13)); Spacer(); Button(L("导出备份…")) { controller.exportData() } }
                Button(L("从备份恢复…")) { controller.restoreData() }.font(.system(size: 12))
                DisclosureGroup(L("更多")) { Button(L("打开数据文件夹")) { NSWorkspace.shared.open(store.fileURL.deletingLastPathComponent()) }.font(.system(size: 11)).padding(.top, 6) }.font(.system(size: 11))
            }
            Text(L("朝夕 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("开发版"))")).font(.system(size: 11)).foregroundStyle(palette.secondary)
        }
    }
}
