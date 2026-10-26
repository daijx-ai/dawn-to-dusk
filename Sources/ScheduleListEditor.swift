import SwiftUI

/// Edits stay local until the single batch save succeeds.
struct ScheduleListEditor: View {
    @Environment(\.agendaPalette) private var palette
    @ObservedObject var store: AgendaStore
    @Binding var showsIntervals: Bool
    let close: () -> Void
    @State private var drafts: [ScheduleDraft] = []
    @State private var orderingTimes: [UUID: Int] = [:]
    @State private var initialIDs: Set<UUID> = []
    @State private var removedDrafts: [ScheduleDraft] = []
    @State private var occurrenceDrafts: [String: ScheduleOccurrenceDraft] = [:]
    @State private var editingOccurrenceID: String?
    @State private var addedDraftID: UUID?
    @FocusState private var focusedTitle: UUID?
    @State private var error: String?
    @State private var showingSaveImpact = false

    private var applicableOccurrenceDrafts: [String: ScheduleOccurrenceDraft] {
        ScheduleEditing.applicable(occurrenceDrafts, to: drafts.compactMap(\.prepared))
    }
    private var previewItems: [AgendaItem] {
        store.items.filter { $0.feishu != nil } + drafts.map { draft in
            var item = draft.prepared ?? draft.item
            for edit in applicableOccurrenceDrafts.values where edit.original.item.id == item.id {
                if let target = edit.target { var times = item.postponedTimes ?? [:]; times[edit.original.completionKey] = target; item.postponedTimes = times }
            }
            return item
        }
    }
    private var rows: [Occurrence] { AgendaClock.occurrences(items: previewItems, on: store.selectedDay) }
    private var orderedItems: [AgendaItem] {
        let visible = drafts.map(\.item) + rows.filter { $0.item.feishu != nil && !$0.isCompleted }.map(\.item)
        return visible.sorted {
            let a = orderingTimes[$0.id] ?? $0.timeMinutes ?? 1440
            let b = orderingTimes[$1.id] ?? $1.timeMinutes ?? 1440
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
    }
    private func finishTimeEdit(_ id: UUID) {
        guard let draft = drafts.first(where: { $0.id == id }), draft.prepared != nil else { return }
        let minutes = proposedOrderingTime(draft)
        if orderingTimes[id] != minutes { orderingTimes[id] = minutes }
    }
    private func proposedOrderingTime(_ draft: ScheduleDraft) -> Int {
        let id = draft.id
        let override = applicableOccurrenceDrafts.values.first { $0.original.item.id == id && AgendaClock.dayKey($0.original.displayDay) == AgendaClock.dayKey(store.selectedDay) }?.target
        if let override { return AgendaClock.calendar.component(.hour, from: override) * 60 + AgendaClock.calendar.component(.minute, from: override) }
        guard let value = draft.prepared else { return draft.item.timeMinutes ?? 1440 }
        return value.timeMinutes(on: store.selectedDay) ?? value.timeMinutes ?? 1440
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("编辑日程")).font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Toggle(L("显示间隔"), isOn: $showsIntervals).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                }
                Text(L("输入时位置固定；回车或点“完成”后排序。")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                Text(L("在这里修改每周规律；临时变动请选日期，点“仅改这一次”。")).font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                Button { addDraft() } label: { Label(L("添加日程"), systemImage: "plus") }.buttonStyle(.borderless).font(.system(size: 12))
            }.padding(.horizontal, 16).padding(.vertical, 10)
            ScrollViewReader { proxy in
              ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    DatePicker(L("预览日期"), selection: $store.selectedDay, displayedComponents: .date)
                        .environment(\.timeZone, AgendaClock.calendar.timeZone).font(.system(size: 12))
                    if orderedItems.isEmpty { Text(L("还没有日程，点下方添加一项安排。")).font(.system(size: 12)).foregroundStyle(palette.secondary) }
                    ForEach(orderedItems) { item in
                        let occurrence = rows.first(where: { $0.item.id == item.id })
                        if let index = drafts.firstIndex(where: { $0.id == item.id }) {
                            draftRow(index)
                            if item.repeatRule == .none {
                                Text(item.date, formatter: AgendaView.fullDayFormatter).font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.horizontal, 12)
                            }
                        } else {
                            HStack {
                                Text(item.title).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text(occurrence?.due.map(AgendaClock.timeText) ?? L("全天")).monospacedDigit()
                            }.padding(12).background(palette.controlFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            Text(L("飞书日程 · 请在飞书修改")).font(.system(size: 10)).foregroundStyle(palette.secondary)
                        }
                        if let occurrence {
                            if occurrence.item.feishu == nil, occurrence.item.repeatRule != .none, occurrence.due != nil {
                                occurrenceAdjustment(occurrence)
                            }
                            if occurrence.postponedUntil != nil && occurrenceDrafts[occurrence.id] == nil {
                                Text(L("这一次另设为 \(occurrence.due.map(AgendaClock.timeText) ?? L("未定时"))；修改重复时间会清除单次调整。"))
                                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                            }
                            if showsIntervals, let gap = ScheduleInterval.following(occurrence, items: previewItems, on: store.selectedDay) {
                                HStack(spacing: 6) {
                                    Image(systemName: gap.crossesMidnight ? "moon" : "arrow.down")
                                    Text(gap.text).fixedSize(horizontal: false, vertical: true)
                                }.font(.system(size: 11)).foregroundStyle(gap.remainingMinutes < 0 ? palette.warning : palette.secondary).padding(.horizontal, 12).padding(.vertical, 3)
                            }
                        } else {
                            Text(L("预览当天无此安排")).font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.horizontal, 12)
                        }
                    }
                    Button { addDraft() } label: { Label(L("添加一项安排"), systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                        .buttonStyle(.plain).foregroundStyle(palette.accent)
                }.padding(.horizontal, 16).padding(.bottom, 12)
              }.onChange(of: addedDraftID) {
                  if let id = addedDraftID { proxy.scrollTo(id, anchor: .center); focusedTitle = id }
              }
            }
            VStack(spacing: 8) {
                if !removedDrafts.isEmpty {
                    HStack {
                        Text(L("已移除 \(removedDrafts.count) 项，保存后生效")).font(.system(size: 11))
                        Spacer()
                        Button(L("撤回移除")) { drafts.append(contentsOf: removedDrafts); removedDrafts = [] }.controlSize(.small)
                    }.foregroundStyle(palette.secondary)
                }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Button(L("取消")) { close() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L("保存修改")) { validateAndSave() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }.padding(16).background(palette.controlFill.opacity(0.5))
        }
        .padding(.top, 18)
        .background(palette.background)
        .onAppear {
            drafts = store.items.filter(ScheduleEditing.visible).sorted {
                if $0.timeMinutes != $1.timeMinutes { return ($0.timeMinutes ?? 1440) < ($1.timeMinutes ?? 1440) }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }.map(ScheduleDraft.init)
            refreshOrdering()
            initialIDs = Set(drafts.map(\.id))
        }
        .onChange(of: store.selectedDay) { refreshOrdering() }
        .confirmationDialog(L("修改重复安排"), isPresented: $showingSaveImpact, titleVisibility: .visible) {
            Button(L("修改每一次并保存")) { save() }
            Button(L("继续编辑"), role: .cancel) { }
        } message: {
            Text(L("重复事项会应用到所有日期，历史完成记录保留。修改重复事项的日期、时间或周期，会清除该事项已有的单次时间调整。"))
        }
    }
    private func refreshOrdering() {
        orderingTimes = Dictionary(uniqueKeysWithValues: drafts.map { draft in
            let time = rows.first { $0.item.id == draft.id }?.due
            let minutes = time.map { AgendaClock.calendar.component(.hour, from: $0) * 60 + AgendaClock.calendar.component(.minute, from: $0) } ?? proposedOrderingTime(draft)
            return (draft.id, minutes)
        })
    }
    private func occurrenceAdjustment(_ occurrence: Occurrence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if editingOccurrenceID == occurrence.id {
                HStack {
                    Text(L("仅改 \(AgendaClock.dayKey(occurrence.displayDay))")).font(.system(size: 11))
                    Spacer()
                    TimeInput(text: Binding(get: { occurrenceDrafts[occurrence.id]?.timeInput ?? "00:00" }, set: { occurrenceDrafts[occurrence.id]?.timeInput = $0 }), label: L("仅这一天的时间"), onCommit: { finishTimeEdit(occurrence.item.id); editingOccurrenceID = nil })
                    Button(L("完成")) { finishTimeEdit(occurrence.item.id); editingOccurrenceID = nil }.controlSize(.small).disabled(occurrenceDrafts[occurrence.id]?.target == nil)
                }
            } else {
                Button(L("仅改 \(AgendaClock.dayKey(occurrence.displayDay)) 这一次")) {
                    if occurrenceDrafts[occurrence.id] == nil { occurrenceDrafts[occurrence.id] = ScheduleOccurrenceDraft(occurrence) }
                    editingOccurrenceID = occurrence.id
                }.buttonStyle(.borderless).font(.system(size: 11))
            }
            if let edit = occurrenceDrafts[occurrence.id] {
                HStack {
                    Text(L("仅此日 \(edit.timeInput)，其他日期仍按原规律")).font(.system(size: 10))
                    Spacer()
                    Button(L("撤回这次调整")) { occurrenceDrafts.removeValue(forKey: occurrence.id); editingOccurrenceID = nil; refreshOrdering() }.controlSize(.mini)
                }
            }
        }.foregroundStyle(palette.accent).padding(.horizontal, 12)
    }
    private func draftRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField(L("事项名称"), text: $drafts[index].item.title).textFieldStyle(.plain).font(.system(size: 14, weight: .medium))
                    .focused($focusedTitle, equals: drafts[index].id)
                    .accessibilityLabel(L("日程名称 \(drafts[index].item.title)"))
                Spacer(minLength: 0)
                if drafts[index].hasTime && drafts[index].weeklyInputs == nil { TimeInput(text: $drafts[index].timeInput, label: drafts[index].item.title + L(" 的时间"), onCommit: { finishTimeEdit(drafts[index].id) }) }
                else if drafts[index].hasTime { Text(L("分星期设置")).font(.system(size: 11)).foregroundStyle(palette.secondary) }
                else { Text(L("未定时")).font(.system(size: 12)).foregroundStyle(palette.secondary) }
                Button(role: .destructive) { removeDraft(drafts[index].id) } label: {
                    Image(systemName: "trash").frame(width: 24, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(palette.secondary)
                    .accessibilityLabel(L("删除日程 \(drafts[index].item.title)")).help(L("移除整项日程，保存后生效；取消可撤回"))
            }
            if editingOccurrenceID.flatMap({ occurrenceDrafts[$0]?.original.item.id }) != drafts[index].id && (drafts[index].prepared == nil || orderingTimes[drafts[index].id] != proposedOrderingTime(drafts[index])) {
                HStack {
                    Text(L("时间调整中")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Spacer()
                    Button(L("完成")) { finishTimeEdit(drafts[index].id) }.controlSize(.small).disabled(drafts[index].prepared == nil)
                }
            }
            Picker(L("重复方式"), selection: $drafts[index].item.repeatRule) {
                ForEach(RepeatRule.allCases, id: \.self) { Text($0 == .none ? L("单次") : $0.label).tag($0) }
            }.pickerStyle(.segmented).controlSize(.small).id(Localization.language).labelsHidden().accessibilityLabel(drafts[index].item.title + L(" 的重复方式"))
                .onChange(of: drafts[index].item.repeatRule) { if drafts[index].item.repeatRule != .weekly { drafts[index].weeklyInputs = nil } }
            if drafts[index].hasTime && drafts[index].item.repeatRule != .none {
                WeeklyTimeEditor(inputs: $drafts[index].weeklyInputs, rule: $drafts[index].item.repeatRule, anchor: drafts[index].item.date, defaultTime: drafts[index].timeInput, title: drafts[index].item.title, onCommit: { finishTimeEdit(drafts[index].id) })
            }
            if drafts[index].item.repeatRule == .weekly && drafts[index].weeklyInputs == nil {
                HStack(spacing: 6) {
                    Text(L("每周")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Picker(L("每周几"), selection: Binding(get: { AgendaClock.calendar.component(.weekday, from: drafts[index].item.date) }, set: { weekday in
                        drafts[index].selectWeekday(weekday)
                    })) {
                        ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { weekday in Text(["", L("日"), L("一"), L("二"), L("三"), L("四"), L("五"), L("六")][weekday]).tag(weekday) }
                    }.pickerStyle(.segmented).controlSize(.small).id(Localization.language).labelsHidden().accessibilityLabel(drafts[index].item.title + L(" 的星期"))
                }
            }
            DisclosureGroup(L("日期、时长与提醒")) {
                VStack(alignment: .leading, spacing: 9) {
                    DatePicker(drafts[index].item.repeatRule == .none ? L("日期") : L("从这天开始"), selection: Binding(get: { drafts[index].item.date }, set: { drafts[index].setStartDay($0) }), displayedComponents: .date)
                        .environment(\.timeZone, AgendaClock.calendar.timeZone)
                    Toggle(L("设置时间"), isOn: $drafts[index].hasTime)
                    DurationInput(text: $drafts[index].durationInput).disabled(!drafts[index].hasTime)
                    Toggle(L("到点提醒"), isOn: $drafts[index].item.reminderEnabled).disabled(!drafts[index].hasTime || drafts[index].item.isTentative)
                    if drafts[index].item.isTentative { Text(L("时间待确认，当前不提醒。可返回日程打开事项确认。")).foregroundStyle(palette.secondary) }
                }.padding(.top, 8)
            }.font(.system(size: 11)).foregroundStyle(palette.secondary)
            durationFooter(drafts[index])
        }.padding(12).background(palette.controlFill, in: RoundedRectangle(cornerRadius: 12))
    }
    private func durationFooter(_ draft: ScheduleDraft) -> some View {
        let duration = draft.hasTime ? DurationInputValue.minutes(draft.durationInput) : 0
        let label: String
        if let duration { label = duration > 0 ? L("持续 \(ScheduleInterval.duration(duration))") : L("不设时长") }
        else { label = L("时长待修正") }
        return HStack {
            Spacer(minLength: 0)
            Text(label).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(duration == nil ? palette.warning : palette.secondary)
        }
    }
    private func addDraft() {
        var draft = ScheduleDraft(AgendaItem(title: "", date: AgendaClock.startOfDay(store.selectedDay), timeMinutes: 21 * 60, repeatRule: .daily))
        draft.timeInput = "21:00"
        drafts.append(draft)
        orderingTimes[draft.id] = 21 * 60
        addedDraftID = draft.id
    }
    private func removeDraft(_ id: UUID) {
        guard let draft = drafts.first(where: { $0.id == id }) else { return }
        if initialIDs.contains(id) { removedDrafts.append(draft) }
        drafts.removeAll { $0.id == id }
    }
    private var changedDrafts: [ScheduleDraft] { drafts.filter { $0.prepared != $0.original || !initialIDs.contains($0.id) } }
    private func validateAndSave() {
        guard drafts.allSatisfy({ $0.prepared != nil }), applicableOccurrenceDrafts.values.allSatisfy({ $0.target != nil }) else { error = L("请检查事项名称、时间和时长。尚未保存任何修改。"); return }
        // Surface destructive override reset only when such an override actually exists.
        let resetsOverrides = changedDrafts.contains { draft in
            let value = draft.prepared!
            return !(draft.original.postponedTimes ?? [:]).isEmpty && value.postponedTimes == nil
        }
        error = nil
        if resetsOverrides { showingSaveImpact = true } else { save() }
    }
    private func save() {
        let changes = changedDrafts
        let exceptionIDs = Set(applicableOccurrenceDrafts.values.map { $0.original.item.id })
        let changedIDs = Set(changes.map(\.id)).union(exceptionIDs)
        for draft in drafts.filter({ initialIDs.contains($0.id) && changedIDs.contains($0.id) }) + removedDrafts {
            guard let current = store.items.first(where: { $0.id == draft.id }) else { error = L("有事项已被移除，请取消后重新打开编辑。"); return }
            var original = draft.original
            // Completion and reminder snoozes may legitimately change while editing.
            original.completedDays = current.completedDays
            original.snoozes = current.snoozes
            guard original == current else { error = L("有日程已在编辑期间更新，请取消后重新打开，避免覆盖新内容。"); return }
        }
        let targets = applicableOccurrenceDrafts.compactMapValues(\.target)
        if store.upsertBatch(changes.compactMap(\.prepared), removing: Set(removedDrafts.map(\.id)), rescheduling: targets) { close() }
        else { error = store.error ?? L("保存失败，修改未生效。") }
    }
}

struct WeeklyTimeEditor: View {
    @Binding var inputs: [String: String]?
    @Binding var rule: RepeatRule
    let anchor: Date
    let defaultTime: String
    let title: String
    var onCommit: () -> Void = {}
    @Environment(\.agendaPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("按星期分别设置时间"), isOn: Binding(get: { inputs != nil }, set: { enabled in
                if enabled {
                    let days = rule == .weekdays ? Array(2...6) : rule == .daily ? Array(1...7) : [AgendaClock.calendar.component(.weekday, from: anchor)]
                    inputs = Dictionary(uniqueKeysWithValues: days.map { (String($0), defaultTime) })
                    rule = .weekly
                } else { inputs = nil }
            })).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            if inputs != nil {
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                    HStack {
                        Toggle(Self.weekday(day), isOn: Binding(get: { inputs?[String(day)] != nil }, set: { enabled in
                            if enabled { inputs?[String(day)] = defaultTime }
                            else { inputs?.removeValue(forKey: String(day)) }
                        })).toggleStyle(.checkbox).font(.system(size: 12))
                        Spacer()
                        if inputs?[String(day)] != nil {
                            TimeInput(text: Binding(get: { inputs?[String(day)] ?? defaultTime }, set: { inputs?[String(day)] = $0 }), label: title + " " + Self.weekday(day), onCommit: onCommit)
                        } else { Text(L("不安排")).font(.system(size: 11)).foregroundStyle(palette.secondary) }
                    }
                }
                if inputs?.isEmpty == true { Text(L("请至少选择一天")).font(.system(size: 11)).foregroundStyle(palette.warning) }
            }
        }
    }
    static func weekday(_ value: Int) -> String {
        [L("周日"), L("周一"), L("周二"), L("周三"), L("周四"), L("周五"), L("周六")][value - 1]
    }
}
