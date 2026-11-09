import Foundation
import Combine

enum AgendaEditorNavigation {
    static func dayAfterSave(browsingDay: Date, editedDay: Date, isExisting: Bool, schedulingChecklist: Bool) -> Date {
        AgendaClock.startOfDay(isExisting && !schedulingChecklist ? browsingDay : editedDay)
    }

    static func dayAfterMidnight(browsingDay: Date, now: Date, wasViewingToday: Bool) -> Date {
        AgendaClock.startOfDay(wasViewingToday ? now : browsingDay)
    }
}

struct AgendaSettings: Codable, Equatable {
    var floating: Bool = true
    var compact: Bool = false
    var sound: Bool = true
    var notifications: Bool = true
    var leadMinutes: Int = 10
    var showCompleted: Bool = true
    var theme: String = "light"
    // Optional Codable fields remain readable when older documents omit them.
    var pinnedOccurrenceID: String? = nil
    var accentName: String? = nil
    var feishuSyncEnabled: Bool? = nil
    var compactFollowsPinned: Bool? = nil
    var scheduleIntervals: Bool? = nil
    var languageCode: String? = nil
    var language: AppLanguage {
        get { languageCode.flatMap(AppLanguage.init(rawValue:)) ?? .chinese }
        set { languageCode = newValue.rawValue }
    }
    var scheduleIntervalsVisible: Bool {
        get { scheduleIntervals ?? true }
        set { scheduleIntervals = newValue }
    }
    var appearanceMode: AgendaAppearanceMode {
        get { AgendaAppearanceMode(rawValue: theme) ?? .light }
        set { theme = newValue.rawValue }
    }
    var accentColor: AgendaAccentColor {
        get { accentName.flatMap(AgendaAccentColor.init(rawValue:)) ?? .green }
        set { accentName = newValue.rawValue }
    }
}

private struct AgendaDocument: Codable {
    var version: Int = 1
    var items: [AgendaItem]
    var settings: AgendaSettings
    var captureReceipts: [String: AgendaCaptureReceipt]? = nil
    var feishuSyncState: FeishuSyncState? = nil
    var changeReceipts: [String: AgendaChangeReceipt]? = nil
    var changeLog: [AgendaChangeRecord]? = nil
}

private struct AgendaUndoStep {
    var items: [AgendaItem]
    var settings: AgendaSettings
    /// Set when undoing this step reverts an external `--change` record.
    var changeID: UUID? = nil
    /// Set when undoing this step re-applies a record that was undone from Settings.
    var reopensChangeID: UUID? = nil
}

@MainActor final class AgendaStore: ObservableObject {
    @Published var items: [AgendaItem] = []
    @Published var settings = AgendaSettings()
    @Published var error: String?
    @Published var selectedDay = AgendaClock.startOfDay(Date())
    @Published private(set) var feishuSyncState: FeishuSyncState?
    let fileURL: URL
    private(set) var recoveryBackupURL: URL?
    var isDataLocked: Bool { locked }
    private var locked = false
    private var savedItems: [AgendaItem] = []
    private var savedSettings = AgendaSettings()
    private var savedCaptureReceipts: [String: AgendaCaptureReceipt] = [:]
    private var savedChangeReceipts: [String: AgendaChangeReceipt] = [:]
    /// Persisted log of external changes, newest last.
    @Published private(set) var externalChanges: [AgendaChangeRecord] = []
    private var history: [AgendaUndoStep] = []
    private var pendingUndoChangeID: UUID?
    private var pendingReopenChangeID: UUID?
    private var draftRegistry: [UUID: Set<UUID>] = [:]
    /// Items that an open window editor holds as an unsaved draft.
    var draftItemIDs: Set<UUID> { draftRegistry.values.reduce(into: Set<UUID>()) { $0.formUnion($1) } }
    func registerDraft(_ token: UUID, ids: Set<UUID>) { if ids.isEmpty { draftRegistry.removeValue(forKey: token) } else { draftRegistry[token] = ids } }
    func releaseDraft(_ token: UUID) { draftRegistry.removeValue(forKey: token) }
    var captureReceiptsSnapshot: [String: AgendaCaptureReceipt] { savedCaptureReceipts }

    init(directory: URL? = nil, seedIfEmpty: Bool = true) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chaoxi", isDirectory: true)
        fileURL = root.appendingPathComponent("agenda.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let document = try JSONDecoder().decode(AgendaDocument.self, from: Data(contentsOf: fileURL))
                guard document.version == 1 else { throw StoreError.invalid(L("数据版本不受支持")) }
                try Self.validate(document.items, settings: document.settings)
                try Self.validateReceipts(document.captureReceipts ?? [:])
                try Self.validateFeishuState(document.feishuSyncState, items: document.items)
                try Self.validateChangeData(document.changeReceipts ?? [:], log: document.changeLog ?? [])
                items = document.items
                settings = document.settings
                savedItems = items
                savedSettings = settings
                savedCaptureReceipts = document.captureReceipts ?? [:]
                feishuSyncState = document.feishuSyncState
                savedChangeReceipts = document.changeReceipts ?? [:]
                externalChanges = document.changeLog ?? []
                if settings.pinnedOccurrenceID != nil && Self.pinnedFocus(items: items, settings: settings) == nil {
                    _ = commit(items, settings: settings, remember: false)
                }
            } catch {
                locked = true
                self.error = L("日程文件无法读取，原文件已保留。请先恢复或移走损坏文件，再重新打开朝夕。\(error.localizedDescription)")
            }
        } else if seedIfEmpty {
            _ = commit(AgendaClock.seed(), settings: settings, remember: false)
        }
    }

    @discardableResult func save() -> Bool {
        guard items.filter({ $0.feishu != nil }) == savedItems.filter({ $0.feishu != nil }) else {
            items = savedItems; settings = savedSettings
            error = L("飞书事件由来源维护，请在飞书中修改")
            return false
        }
        return commit(items, settings: settings, remember: false)
    }
    func capture(_ request: AgendaCaptureRequest, now: Date = Date()) -> AgendaCaptureResult {
        let normalized: AgendaCaptureRequest
        do { normalized = try request.normalized() }
        catch { return AgendaCaptureResult(ok: false, requestID: request.requestID, status: "invalid", error: error.localizedDescription) }
        let fingerprint = normalized.fingerprint
        if let receipt = savedCaptureReceipts[normalized.requestID] {
            guard receipt.fingerprint == fingerprint else {
                return AgendaCaptureResult(ok: false, requestID: normalized.requestID, status: "conflict", error: L("该 request_id 已用于不同内容"))
            }
            return AgendaCaptureResult(ok: true, requestID: normalized.requestID, status: "already_processed", itemID: receipt.itemID,
                                       itemExists: savedItems.contains(where: { $0.id == receipt.itemID }))
        }
        let item: AgendaItem
        do { item = try normalized.makeItem(now: now) }
        catch { return AgendaCaptureResult(ok: false, requestID: normalized.requestID, status: "invalid", error: error.localizedDescription) }
        var receipts = savedCaptureReceipts
        receipts[normalized.requestID] = AgendaCaptureReceipt(fingerprint: fingerprint, itemID: item.id, createdAt: now, source: normalized.source!)
        guard commit(savedItems + [item], settings: settings, receipts: receipts) else {
            return AgendaCaptureResult(ok: false, requestID: normalized.requestID, status: "save_failed", error: error ?? L("捕获保存失败"))
        }
        return AgendaCaptureResult(ok: true, requestID: normalized.requestID, status: "created", itemID: item.id, itemExists: true)
    }
    /// External `--change` request. The window's draft registry blocks edits to items being edited.
    func applyChange(_ request: AgendaChangeRequest, now: Date = Date()) -> AgendaChangeResult {
        guard !locked else { return AgendaChangeResult(ok: false, status: "save_failed", requestID: request.requestID, error: L("日程文件受保护，未修改")) }
        let state = AgendaChangeState(items: savedItems, receipts: savedChangeReceipts, log: externalChanges)
        var (result, next) = AgendaChangeEngine.apply(request, state: state, captureReceipts: savedCaptureReceipts, editing: draftItemIDs, now: now)
        guard let next else { return result }
        let mutates = next.items != savedItems
        pendingUndoChangeID = mutates ? result.recordID : nil
        defer { pendingUndoChangeID = nil }
        guard commit(next.items, settings: settings, changeReceipts: next.receipts, changeLog: next.log, remember: mutates) else {
            result = AgendaChangeResult(ok: false, status: "save_failed", requestID: request.requestID, itemID: result.itemID,
                                        itemExists: savedItems.contains { $0.id == result.itemID }, error: error ?? L("保存失败，修改未生效"))
            return result
        }
        return result
    }
    /// Reverts one external change if the item is still exactly as that change left it.
    @discardableResult func undoExternalChange(_ id: UUID, now: Date = Date()) -> Bool {
        guard let position = externalChanges.firstIndex(where: { $0.id == id }), externalChanges[position].undoneAt == nil else {
            error = L("这条外部改动已撤销或不存在"); return false
        }
        let record = externalChanges[position]
        let current = savedItems.first { $0.id == record.itemID }
        guard current == record.after else { error = L("该事项在这次外部改动后又有修改，不能直接撤销；请手动调整"); return false }
        var candidate = savedItems
        if let index = candidate.firstIndex(where: { $0.id == record.itemID }) {
            if let before = record.before { candidate[index] = before } else { candidate.remove(at: index) }
        } else if let before = record.before { candidate.insert(before, at: min(record.index ?? candidate.count, candidate.count)) }
        var log = externalChanges
        log[position].undoneAt = now
        if record.op == AgendaChangeOp.restore.rawValue, let deletion = log.lastIndex(where: { $0.itemID == record.itemID && $0.after == nil && $0.before != nil && $0.undoneAt != nil && $0.id != record.id }) {
            log[deletion].undoneAt = nil
        }
        pendingReopenChangeID = record.id
        defer { pendingReopenChangeID = nil }
        return commit(candidate, settings: settings, changeLog: log)
    }
    /// Window editors: false when the saved item changed after the editor opened.
    /// Completion, skip, snooze and checklist state are live and preserved on save.
    func isUnchangedSinceOpened(_ original: AgendaItem) -> Bool {
        guard let current = savedItems.first(where: { $0.id == original.id }) else { return false }
        func content(_ item: AgendaItem) -> AgendaItem {
            var value = item
            value.completedDays = []; value.snoozes = [:]; value.skippedDays = nil; value.pausedRanges = nil; value.checklistState = item.checklistState.map { _ in .pending }
            return value
        }
        return content(current) == content(original)
    }
    /// Window action: show a skipped/paused day again (splits a pause around it).
    @discardableResult func unskip(_ occurrence: Occurrence, wholePause: Bool = false) -> Bool {
        guard let index = savedItems.firstIndex(where: { $0.id == occurrence.item.id }), savedItems[index].feishu == nil else { error = L("事项已不存在"); return false }
        let key = AgendaClock.dayKey(occurrence.day)
        var candidate = savedItems
        if wholePause, let range = (candidate[index].pausedRanges ?? []).first(where: { $0.contains(key) }) {
            candidate[index] = AgendaSkipEditing.resume(candidate[index], from: range.from, to: range.to)
        } else { candidate[index] = AgendaSkipEditing.resume(candidate[index], from: key, to: key) }
        guard candidate != savedItems else { return true }
        return commit(candidate, settings: settings)
    }
    @discardableResult func upsert(_ incoming: AgendaItem) -> Bool {
        upsertBatch([incoming])
    }
    @discardableResult func upsertBatch(_ incoming: [AgendaItem], removing removedIDs: Set<UUID> = [], rescheduling occurrenceChanges: [String: Date] = [:]) -> Bool {
        guard !incoming.isEmpty || !removedIDs.isEmpty || !occurrenceChanges.isEmpty else { return true }
        guard removedIDs.isDisjoint(with: Set(incoming.map(\.id))),
              removedIDs.allSatisfy({ id in savedItems.contains { $0.id == id && !$0.isChecklist && $0.feishu == nil } }) else {
            error = L("有日程已改变，删除未生效。请重新打开编辑。"); return false
        }
        let prepared = incoming.map { value -> AgendaItem in
            var value = value
            if let current = savedItems.first(where: { $0.id == value.id }) {
                value.postponedTimes = current.date == AgendaClock.startOfDay(value.date) && current.timeMinutes == value.timeMinutes && current.repeatRule == value.repeatRule && current.weeklyTimes == value.weeklyTimes ? current.postponedTimes : nil
            }
            return value
        }
        do { try Self.validate(prepared, settings: settings) }
        catch { self.error = L("保存失败，修改未生效：\(error.localizedDescription)"); return false }
        var candidate = savedItems.filter { !removedIDs.contains($0.id) }
        for value in prepared {
            guard value.feishu == nil, !savedItems.contains(where: { $0.id == value.id && $0.feishu != nil }) else {
                error = L("飞书事件由来源维护，请在飞书中修改")
                return false
            }
            var item = value
            item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            item.date = AgendaClock.startOfDay(item.date)
            if let index = candidate.firstIndex(where: { $0.id == item.id }) {
                guard item.isChecklist == candidate[index].isChecklist else {
                    error = L("请通过安排日期操作转换清单事项")
                    return false
                }
                item.checklistState = candidate[index].checklistState
                if item.isChecklist { item.date = candidate[index].date }
                // Completion, skip and snooze are live occurrence state, not editable draft fields.
                item.completedDays = candidate[index].completedDays
                item.skippedDays = item.repeatRule == .none ? nil : candidate[index].skippedDays
                item.pausedRanges = item.repeatRule == .none ? nil : candidate[index].pausedRanges
                if candidate[index].date != item.date || candidate[index].timeMinutes != item.timeMinutes || candidate[index].repeatRule != item.repeatRule || candidate[index].weeklyTimes != item.weeklyTimes {
                    item.snoozes = [:]
                    item.postponedTimes = nil
                } else {
                    item.snoozes = candidate[index].snoozes
                    item.postponedTimes = candidate[index].postponedTimes
                }
                candidate[index] = item
            } else { candidate.append(item) }
        }
        for (id, target) in occurrenceChanges {
            guard Self.validDate(target), let occurrence = AgendaClock.occurrence(items: candidate, id: id), occurrence.due != nil,
                  occurrence.item.feishu == nil, let index = candidate.firstIndex(where: { $0.id == occurrence.item.id }) else {
                error = L("这次安排无法调整，请重新打开事项；飞书日程需在飞书中修改"); return false
            }
            var base = candidate[index]; base.postponedTimes = nil
            guard let original = AgendaClock.occurrence(items: [base], id: id)?.due else { return false }
            var times = candidate[index].postponedTimes ?? [:]
            if target == original { times.removeValue(forKey: occurrence.completionKey) }
            else { times[occurrence.completionKey] = target }
            candidate[index].postponedTimes = times.isEmpty ? nil : times
            candidate[index].snoozes.removeValue(forKey: occurrence.completionKey)
        }
        return commit(candidate, settings: settings)
    }
    func toggle(_ occurrence: Occurrence) {
        var candidate = savedItems
        guard let current = AgendaClock.occurrence(items: candidate, id: occurrence.id),
              let index = candidate.firstIndex(where: { $0.id == occurrence.item.id }) else { error = L("该日期事项已不存在"); return }
        let key = current.completionKey
        if candidate[index].completedDays.contains(key) { candidate[index].completedDays.remove(key) }
        else { candidate[index].completedDays.insert(key) }
        candidate[index].snoozes.removeValue(forKey: key)
        _ = commit(candidate, settings: settings)
    }
    func snooze(_ occurrence: Occurrence, minutes: Int) {
        guard minutes > 0, minutes <= 1440, occurrence.due != nil else { error = L("稍后提醒需要有效时刻和 1–1440 分钟间隔"); return }
        var candidate = savedItems
        guard let current = AgendaClock.occurrence(items: candidate, id: occurrence.id), current.due != nil,
              let index = candidate.firstIndex(where: { $0.id == occurrence.item.id }), !current.isCompleted, !current.item.isTentative, current.item.reminderEnabled, current.remindAt != nil else { error = L("事项已完成、时间未确认或提醒已关闭，不能稍后提醒"); return }
        candidate[index].snoozes[current.completionKey] = Date().addingTimeInterval(Double(minutes) * 60)
        _ = commit(candidate, settings: settings)
    }
    @discardableResult func postpone(_ occurrence: Occurrence, minutes: Int, now: Date = Date()) -> Bool {
        guard minutes > 0, minutes <= 1440,
              let current = AgendaClock.occurrence(items: savedItems, id: occurrence.id), let due = current.due else {
            error = L("推迟安排需要有效时刻和 1–1440 分钟间隔"); return false
        }
        return postpone(current, until: max(due, now).addingTimeInterval(Double(minutes) * 60), now: now)
    }
    @discardableResult func postpone(_ occurrence: Occurrence, until target: Date, now: Date = Date()) -> Bool {
        var candidate = savedItems
        guard let current = AgendaClock.occurrence(items: candidate, id: occurrence.id), let due = current.due,
              !current.isCompleted, current.item.feishu == nil,
              validPostponement(target, after: max(due, now)),
              let index = candidate.firstIndex(where: { $0.id == current.item.id }) else {
            error = L("请选择晚于当前和原安排的时间；已完成、未定时或飞书日程不能在此推迟"); return false
        }
        var times = candidate[index].postponedTimes ?? [:]
        times[current.completionKey] = target
        candidate[index].postponedTimes = times
        candidate[index].snoozes.removeValue(forKey: current.completionKey)
        return commit(candidate, settings: settings)
    }
    private func validPostponement(_ target: Date, after: Date) -> Bool { Self.validDate(target) && target > after }
    // The persisted field also holds explicit single-occurrence time edits.
    // Quick postponement keeps its stricter future-only guard above.
    @discardableResult func rescheduleOccurrence(_ occurrence: Occurrence, until target: Date) -> Bool {
        var candidate = savedItems
        guard Self.validDate(target),
              let current = AgendaClock.occurrence(items: candidate, id: occurrence.id),
              current.due != nil, current.item.feishu == nil,
              let index = candidate.firstIndex(where: { $0.id == current.item.id }) else {
            error = L("这次安排无法调整，请重新打开事项；飞书日程需在飞书中修改"); return false
        }
        var base = candidate[index]
        base.postponedTimes = nil
        guard let original = AgendaClock.occurrence(items: [base], id: current.id)?.due else { return false }
        var times = candidate[index].postponedTimes ?? [:]
        if target == original { times.removeValue(forKey: current.completionKey) }
        else { times[current.completionKey] = target }
        candidate[index].postponedTimes = times.isEmpty ? nil : times
        candidate[index].snoozes.removeValue(forKey: current.completionKey)
        return commit(candidate, settings: settings)
    }
    func delete(_ id: UUID) {
        guard !savedItems.contains(where: { $0.id == id && $0.feishu != nil }) else { error = L("飞书事件请在飞书中取消"); return }
        guard savedItems.contains(where: { $0.id == id }) else { return }
        _ = commit(savedItems.filter { $0.id != id }, settings: settings)
    }
    func undo() {
        guard let previous = history.last else { return }
        var log: [AgendaChangeRecord]?
        if let id = previous.reopensChangeID, let position = externalChanges.firstIndex(where: { $0.id == id && $0.undoneAt != nil }) {
            // Undoing a Settings undo re-applies that external change; keep the log truthful.
            log = externalChanges
            log![position].undoneAt = nil
            let record = externalChanges[position]
            if record.op == AgendaChangeOp.restore.rawValue, let deletion = log!.lastIndex(where: { $0.itemID == record.itemID && $0.after == nil && $0.before != nil && $0.undoneAt == nil && $0.id != record.id }) {
                log![deletion].undoneAt = Date()
            }
        } else if let id = previous.changeID, let position = externalChanges.firstIndex(where: { $0.id == id && $0.undoneAt == nil }) {
            log = externalChanges
            log![position].undoneAt = Date()
            let record = externalChanges[position]
            if record.op == AgendaChangeOp.restore.rawValue, let deletion = log!.lastIndex(where: { $0.itemID == record.itemID && $0.after == nil && $0.before != nil && $0.undoneAt != nil && $0.id != record.id }) {
                log![deletion].undoneAt = nil
            }
        }
        if commit(previous.items, settings: previous.settings, changeLog: log, remember: false) { history.removeLast() }
    }
    /// True when the next window undo reverts an external change.
    var undoRevertsExternalChange: Bool { history.last?.changeID != nil }
    func occurrences(on date: Date) -> [Occurrence] { AgendaClock.occurrences(items: items, on: date) }
    func editableDayItems(on date: Date) -> [AgendaItem] {
        var seen = Set<UUID>()
        return occurrences(on: date).filter { $0.item.feishu == nil && seen.insert($0.item.id).inserted }.map(\.item)
    }
    func checklistItems(includeCompleted: Bool = false) -> [AgendaItem] {
        savedItems.filter { includeCompleted ? $0.isChecklist : $0.checklistState == .pending }
    }
    @discardableResult func addChecklistItem(title: String, note: String = "") -> Bool {
        upsert(AgendaItem(title: title, date: Date(), timeMinutes: nil, note: note, reminderEnabled: false, checklistState: .pending))
    }
    @discardableResult func setChecklistCompleted(_ id: UUID, completed: Bool) -> Bool {
        var candidate = savedItems
        guard let index = candidate.firstIndex(where: { $0.id == id }), candidate[index].isChecklist else {
            error = L("清单事项已不存在")
            return false
        }
        let state: ChecklistState = completed ? .completed : .pending
        if candidate[index].checklistState == state { return true }
        candidate[index].checklistState = state
        return commit(candidate, settings: settings)
    }
    @discardableResult func moveChecklistItem(_ id: UUID, by offset: Int) -> Bool {
        guard offset == -1 || offset == 1 else { error = L("每次只能向上或向下移动一项"); return false }
        let indices = savedItems.indices.filter { savedItems[$0].checklistState == .pending }
        guard let position = indices.firstIndex(where: { savedItems[$0].id == id }), indices.indices.contains(position + offset) else {
            error = L("清单事项没有可交换的相邻项")
            return false
        }
        var candidate = savedItems
        candidate.swapAt(indices[position], indices[position + offset])
        return commit(candidate, settings: settings)
    }
    @discardableResult func scheduleChecklistItem(_ incoming: AgendaItem) -> Bool {
        var candidate = savedItems
        guard incoming.feishu == nil, let index = candidate.firstIndex(where: { $0.id == incoming.id }), candidate[index].checklistState == .pending else {
            error = L("请先恢复为未完成清单事项，再安排日期")
            return false
        }
        var item = incoming
        item.checklistState = nil
        item.completedDays = []; item.snoozes = [:]; item.postponedTimes = nil
        if item.timeMinutes == nil { item.reminderEnabled = false }
        do { try Self.validate([item], settings: settings) }
        catch { self.error = L("保存失败，修改未生效：\(error.localizedDescription)"); return false }
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.date = AgendaClock.startOfDay(item.date)
        candidate[index] = item
        return commit(candidate, settings: settings)
    }
    func highlightedFocus(now: Date) -> AgendaFocus? {
        if let pinned = Self.pinnedFocus(items: savedItems, settings: savedSettings) { return pinned }
        if let next = AgendaClock.next(items: savedItems, now: now) { return .scheduled(next) }
        return savedItems.first(where: { $0.checklistState == .pending }).map(AgendaFocus.checklist)
    }
    var compactUsesPinnedFocus: Bool {
        savedSettings.compactFollowsPinned == true && Self.pinnedFocus(items: savedItems, settings: savedSettings) != nil
    }
    func compactFocus(now: Date) -> AgendaFocus? {
        if compactUsesPinnedFocus { return Self.pinnedFocus(items: savedItems, settings: savedSettings) }
        let today = AgendaClock.startOfDay(now)
        let yesterday = AgendaClock.calendar.date(byAdding: .day, value: -1, to: today)!
        let ongoing = [yesterday, today].flatMap { AgendaClock.occurrences(items: savedItems, on: $0) }
            .filter { !$0.isCompleted && ($0.due ?? .distantFuture) <= now && ($0.end ?? .distantPast) > now }
            .sorted {
                if $0.due != $1.due { return $0.due! > $1.due! }
                return $0.id < $1.id
            }.first
        if let ongoing { return .scheduled(ongoing) }
        return AgendaClock.next(items: savedItems, now: now).map(AgendaFocus.scheduled)
    }
    @discardableResult func setCompactFollowsPinned(_ pinned: Bool) -> Bool {
        guard !pinned || Self.pinnedFocus(items: savedItems, settings: savedSettings) != nil else {
            error = L("请先选择要固定的事项"); return false
        }
        if savedSettings.compactFollowsPinned == pinned { return true }
        var candidate = settings
        candidate.compactFollowsPinned = pinned
        return commit(savedItems, settings: candidate)
    }
    @discardableResult func pinChecklistItem(_ id: UUID, inCompact: Bool = false) -> Bool {
        guard let item = savedItems.first(where: { $0.id == id && $0.checklistState == .pending }) else {
            error = L("只能固定仍在清单里的未完成事项")
            return false
        }
        let focusID = AgendaFocus.checklist(item).id
        if savedSettings.pinnedOccurrenceID == focusID && (!inCompact || compactUsesPinnedFocus) { return true }
        var candidateSettings = settings
        candidateSettings.pinnedOccurrenceID = focusID
        if inCompact { candidateSettings.compactFollowsPinned = true }
        return commit(savedItems, settings: candidateSettings)
    }
    func isPinned(_ focus: AgendaFocus) -> Bool {
        Self.pinnedFocus(items: savedItems, settings: savedSettings)?.id == focus.id
    }
    func toggle(_ focus: AgendaFocus) {
        switch focus {
        case let .scheduled(occurrence): toggle(occurrence)
        case let .checklist(item):
            guard let current = savedItems.first(where: { $0.id == item.id && $0.isChecklist }) else { error = L("清单事项已不存在"); return }
            _ = setChecklistCompleted(current.id, completed: current.checklistState == .pending)
        }
    }
    func highlightedOccurrence(now: Date) -> Occurrence? {
        Self.pinnedOccurrence(items: savedItems, settings: savedSettings) ?? AgendaClock.next(items: savedItems, now: now)
    }
    @discardableResult func pinOccurrence(_ occurrence: Occurrence, inCompact: Bool = false) -> Bool {
        guard let current = AgendaClock.occurrence(items: savedItems, id: occurrence.id), !current.isCompleted else {
            error = L("只能固定仍在清单里的未完成事项")
            return false
        }
        guard !locked else { return commit(savedItems, settings: savedSettings) }
        if savedSettings.pinnedOccurrenceID == current.id && (!inCompact || compactUsesPinnedFocus) { return true }
        var candidateSettings = settings
        candidateSettings.pinnedOccurrenceID = current.id
        if inCompact { candidateSettings.compactFollowsPinned = true }
        return commit(savedItems, settings: candidateSettings)
    }
    @discardableResult func clearPinnedOccurrence() -> Bool {
        guard !locked else { return commit(savedItems, settings: savedSettings) }
        if savedSettings.pinnedOccurrenceID == nil { return true }
        var candidateSettings = settings
        candidateSettings.pinnedOccurrenceID = nil
        return commit(savedItems, settings: candidateSettings)
    }
    func isPinned(_ occurrence: Occurrence) -> Bool {
        Self.pinnedOccurrence(items: savedItems, settings: savedSettings)?.id == occurrence.id
    }
    func resetError() { error = nil }

    @discardableResult func recoverCorruptFile() -> Bool {
        guard locked else { error = L("当前日程文件未锁定，无需重建"); return false }
        do {
            guard let backup = try preserveCurrentFile(prefix: "corrupt") else { throw StoreError.invalid(L("待恢复文件已不存在")) }
            recoveryBackupURL = backup
            return commit(AgendaClock.seed(), settings: AgendaSettings(), receipts: [:], syncState: nil, replaceSyncState: true, changeReceipts: [:], changeLog: [], remember: false, allowLocked: true)
        } catch {
            self.error = L("恢复失败，原文件未替换：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult func restore(from url: URL) -> Bool {
        do {
            let document = try JSONDecoder().decode(AgendaDocument.self, from: Data(contentsOf: url))
            guard document.version == 1 else { throw StoreError.invalid(L("备份数据版本不受支持")) }
            try Self.validate(document.items, settings: document.settings)
            try Self.validateReceipts(document.captureReceipts ?? [:])
            try Self.validateFeishuState(document.feishuSyncState, items: document.items)
            try Self.validateChangeData(document.changeReceipts ?? [:], log: document.changeLog ?? [])
            recoveryBackupURL = try preserveCurrentFile(prefix: "before-restore")
            let restored = commit(document.items, settings: document.settings, receipts: document.captureReceipts ?? [:], syncState: document.feishuSyncState, replaceSyncState: true, changeReceipts: document.changeReceipts ?? [:], changeLog: document.changeLog ?? [], remember: false, allowLocked: true)
            if restored { history.removeAll() }
            return restored
        } catch {
            self.error = L("备份恢复失败，当前日程未替换：\(error.localizedDescription)")
            return false
        }
    }

    private func preserveCurrentFile(prefix: String) throws -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let original = try Data(contentsOf: fileURL)
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent("agenda.\(prefix).\(UUID().uuidString).json")
        try original.write(to: backup, options: .atomic)
        guard try Data(contentsOf: backup) == original else { throw StoreError.invalid(L("原文件备份校验失败")) }
        return backup
    }

    @discardableResult private func commit(_ candidate: [AgendaItem], settings candidateSettings: AgendaSettings, receipts candidateReceipts: [String: AgendaCaptureReceipt]? = nil, syncState candidateSyncState: FeishuSyncState? = nil, replaceSyncState: Bool = false, changeReceipts candidateChangeReceipts: [String: AgendaChangeReceipt]? = nil, changeLog candidateChangeLog: [AgendaChangeRecord]? = nil, remember: Bool = true, allowLocked: Bool = false) -> Bool {
        guard !locked || allowLocked else {
            error = L("损坏文件仍受保护。请先恢复或移走该文件，再重新打开朝夕。")
            items = savedItems; settings = savedSettings
            return false
        }
        do {
            try Self.validate(candidate, settings: candidateSettings)
            let syncState = replaceSyncState ? candidateSyncState : feishuSyncState
            try Self.validateFeishuState(syncState, items: candidate)
            let receipts = candidateReceipts ?? savedCaptureReceipts
            try Self.validateReceipts(receipts)
            let changeReceipts = candidateChangeReceipts ?? savedChangeReceipts
            let changeLog = candidateChangeLog ?? externalChanges
            try Self.validateChangeData(changeReceipts, log: changeLog)
            var candidateSettings = candidateSettings
            if Self.pinnedFocus(items: candidate, settings: candidateSettings) == nil {
                candidateSettings.pinnedOccurrenceID = nil
                if candidateSettings.compactFollowsPinned == true { candidateSettings.compactFollowsPinned = false }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(AgendaDocument(items: candidate, settings: candidateSettings, captureReceipts: receipts.isEmpty ? nil : receipts, feishuSyncState: syncState,
                                                       changeReceipts: changeReceipts.isEmpty ? nil : changeReceipts, changeLog: changeLog.isEmpty ? nil : changeLog))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            if remember { history.append(AgendaUndoStep(items: savedItems, settings: savedSettings, changeID: pendingUndoChangeID, reopensChangeID: pendingReopenChangeID)) }
            locked = false
            savedItems = candidate; savedSettings = candidateSettings
            savedCaptureReceipts = receipts
            savedChangeReceipts = changeReceipts
            if externalChanges != changeLog { externalChanges = changeLog }
            feishuSyncState = syncState
            items = candidate; settings = candidateSettings
            error = nil
            return true
        } catch {
            items = savedItems; settings = savedSettings
            self.error = L("保存失败，修改未生效：\(error.localizedDescription)")
            return false
        }
    }
    func feishuMirroredEventIDs(calendarID: String, windowStart: Date? = nil, windowEnd: Date? = nil) -> [String] {
        savedItems.compactMap { item in
            guard let source = item.feishu, source.calendarID == calendarID else { return nil }
            if let start = windowStart, let end = windowEnd {
                let lower = source.isAllDay ? source.displayStartDay : source.start
                let upper = source.isAllDay ? source.displayEndDay : source.end
                guard lower < end && (upper > start || (lower == upper && lower >= start)) else { return nil }
            }
            return source.eventID
        }
    }
    @discardableResult func applyFeishuSnapshot(_ snapshot: FeishuSnapshot) -> Bool {
        do {
            guard !snapshot.calendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  FeishuMetadata.validDate(snapshot.windowStart), FeishuMetadata.validDate(snapshot.windowEnd),
                  snapshot.windowEnd > snapshot.windowStart, FeishuMetadata.validDate(snapshot.fetchedAt),
                  Set(snapshot.events.map(\.eventID)).count == snapshot.events.count else { throw FeishuModelError.invalid(L("飞书快照范围或事件编号无效")) }
            let bound = feishuSyncState?.calendarID ?? savedItems.compactMap { $0.feishu?.calendarID }.first
            guard bound == nil || bound == snapshot.calendarID else { throw FeishuModelError.invalid(L("当前已绑定另一飞书日历，请先处理日历绑定")) }
            var candidate = savedItems
            for event in snapshot.events {
                guard event.calendarID == snapshot.calendarID, !event.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FeishuModelError.invalid(L("飞书快照包含其他日历或无效事件")) }
                let index = candidate.firstIndex { $0.feishu?.calendarID == event.calendarID && $0.feishu?.eventID == event.eventID }
                if event.status != .active {
                    if let index { candidate.remove(at: index) }
                    continue
                }
                let metadata = try event.metadata()
                guard !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, event.title.count <= 200 else { throw FeishuModelError.invalid(L("飞书标题无法完整显示，请在来源处理")) }
                var source = AgendaItem(title: event.title, date: metadata.displayStartDay, timeMinutes: metadata.timeMinutes,
                                        durationMinutes: metadata.durationMinutes, category: L("飞书"), reminderEnabled: !metadata.isAllDay, feishu: metadata)
                if let index {
                    source.id = candidate[index].id
                    candidate[index] = Self.mergeFeishuSource(source, local: candidate[index])
                } else { candidate.append(source) }
            }
            let state = FeishuSyncState(lastSuccess: snapshot.fetchedAt, calendarID: snapshot.calendarID)
            guard commit(candidate, settings: settings, syncState: state, replaceSyncState: true, remember: false) else { return false }
            // Rebase source-owned data in every local undo snapshot onto the successful source state.
            let mirrors = candidate.filter { $0.feishu != nil }
            history = history.map { previous in
                var rebased = previous.items
                rebased.removeAll { old in old.feishu != nil && !mirrors.contains(where: { $0.id == old.id }) }
                for source in mirrors {
                    if let index = rebased.firstIndex(where: { $0.id == source.id }) {
                        rebased[index] = Self.mergeFeishuSource(source, local: rebased[index])
                    } else { rebased.append(source) }
                }
                return AgendaUndoStep(items: rebased, settings: previous.settings, changeID: previous.changeID, reopensChangeID: previous.reopensChangeID)
            }
            return true
        } catch { self.error = L("飞书同步未生效：\(error.localizedDescription)"); return false }
    }
    private static func mergeFeishuSource(_ source: AgendaItem, local: AgendaItem) -> AgendaItem {
        var result = source
        guard let old = local.feishu, let new = source.feishu else { return result }
        result.completedDays = local.completedDays.contains(old.completionKey) ? [new.completionKey] : []
        result.snoozes = !new.isAllDay && old.start == new.start ? local.snoozes : [:]
        result.note = local.note
        return result
    }
    private static func validateFeishuState(_ state: FeishuSyncState?, items: [AgendaItem]) throws {
        let mirrors = items.compactMap(\.feishu)
        let calendars = Set(mirrors.map(\.calendarID))
        guard calendars.count <= 1, Set(mirrors.map(\.eventID)).count == mirrors.count else { throw FeishuModelError.invalid(L("本地镜像包含重复事件或多个日历绑定")) }
        if let state {
            guard FeishuMetadata.validDate(state.lastSuccess), !state.calendarID.isEmpty, state.status == "synced",
                  calendars.allSatisfy({ $0 == state.calendarID }) else { throw FeishuModelError.invalid(L("飞书同步状态无效")) }
        }
    }
    private static func validateReceipts(_ receipts: [String: AgendaCaptureReceipt]) throws {
        guard Set(receipts.values.map(\.itemID)).count == receipts.count else { throw StoreError.invalid(L("捕获回执事项编号重复")) }
        for (id, receipt) in receipts {
            guard AgendaCaptureRequest.validRequestID(id), receipt.fingerprint.utf8.count == 64,
                  receipt.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  AgendaCaptureRequest.validDate(receipt.createdAt), receipt.source == "hermes" || receipt.source == "cli" else {
                throw StoreError.invalid(L("捕获回执无效"))
            }
        }
    }
    private static func validateChangeData(_ receipts: [String: AgendaChangeReceipt], log: [AgendaChangeRecord]) throws {
        for (id, receipt) in receipts {
            guard AgendaCaptureRequest.validRequestID(id), receipt.fingerprint.utf8.count == 64,
                  receipt.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  validDate(receipt.createdAt), receipt.source == "hermes" || receipt.source == "cli" else { throw StoreError.invalid(L("外部修改回执无效")) }
        }
        guard log.count <= 100_000, Set(log.map(\.id)).count == log.count,
              log.allSatisfy({ validDate($0.at) && AgendaChangeOp(rawValue: $0.op) != nil && ($0.before != nil || $0.after != nil) }) else { throw StoreError.invalid(L("外部修改记录无效")) }
    }
    private static func pinnedOccurrence(items: [AgendaItem], settings: AgendaSettings) -> Occurrence? {
        pinnedFocus(items: items, settings: settings)?.occurrence
    }
    private static func pinnedFocus(items: [AgendaItem], settings: AgendaSettings) -> AgendaFocus? {
        guard let id = settings.pinnedOccurrenceID else { return nil }
        if id.hasPrefix("checklist:") {
            let suffix = String(id.dropFirst("checklist:".count))
            guard let itemID = UUID(uuidString: suffix), suffix == itemID.uuidString,
                  let item = items.first(where: { $0.id == itemID && $0.checklistState == .pending }) else { return nil }
            return .checklist(item)
        }
        guard let occurrence = AgendaClock.occurrence(items: items, id: id), !occurrence.isCompleted else { return nil }
        return .scheduled(occurrence)
    }
    private static func validate(_ items: [AgendaItem], settings: AgendaSettings) throws {
        guard (0...1440).contains(settings.leadMinutes), !settings.theme.isEmpty else { throw StoreError.invalid(L("提醒设置无效")) }
        guard Set(items.map(\.id)).count == items.count else { throw StoreError.invalid(L("事项编号重复")) }
        for item in items {
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.title.count <= 200 else { throw StoreError.invalid(L("事项标题需为 1–200 字")) }
            guard item.note.count <= 2000 else { throw StoreError.invalid(L("备注不能超过 2000 字")) }
            guard validDate(item.date) else { throw StoreError.invalid(L("事项日期无效")) }
            if let times = item.weeklyTimes {
                guard item.repeatRule == .weekly, item.feishu == nil, !item.isChecklist,
                      item.timeMinutes != nil, !times.isEmpty,
                      times.allSatisfy({ key, value in ["1", "2", "3", "4", "5", "6", "7"].contains(key) && (0...1439).contains(value) }) else {
                    throw StoreError.invalid(L("请为每周安排选择至少一天，并设置有效时间"))
                }
            }
            if let source = item.feishu {
                try source.validate()
                guard !item.isChecklist, item.repeatRule == .none, !item.isTentative, (item.postponedTimes ?? [:]).isEmpty,
                      item.date == source.displayStartDay, item.timeMinutes == source.timeMinutes,
                      item.durationMinutes == source.durationMinutes, !source.isAllDay || !item.reminderEnabled,
                      item.completedDays.isSubset(of: [source.completionKey]),
                      Set(item.snoozes.keys).isSubset(of: [source.completionKey]), !source.isAllDay || item.snoozes.isEmpty else { throw FeishuModelError.invalid(L("飞书镜像字段或本地状态无效")) }
            }
            if item.isChecklist {
                guard item.timeMinutes == nil, item.durationMinutes == 0, item.repeatRule == .none,
                      !item.reminderEnabled, !item.isTentative, item.completedDays.isEmpty, item.snoozes.isEmpty, (item.postponedTimes ?? [:]).isEmpty else {
                    throw StoreError.invalid(L("独立清单不能设置时刻、重复、提醒或日期状态"))
                }
            }
            guard item.timeMinutes.map({ (0...1439).contains($0) }) ?? true,
                  item.durationMinutes >= 0, item.feishu != nil || item.durationMinutes <= 1440 else { throw StoreError.invalid(L("事项时刻或时长无效")) }
            for key in item.completedDays.union(Set(item.snoozes.keys)).union(Set((item.postponedTimes ?? [:]).keys)) {
                let parts = key.split(separator: "-")
                guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                      let date = AgendaClock.calendar.date(from: DateComponents(year: year, month: month, day: day)),
                      AgendaClock.dayKey(date) == key else { throw StoreError.invalid(L("事项状态日期无效")) }
            }
            guard item.snoozes.values.allSatisfy(validDate) else { throw StoreError.invalid(L("稍后提醒时刻无效")) }
            if item.hasSkips {
                guard item.feishu == nil, !item.isChecklist,
                      (item.skippedDays ?? []).allSatisfy({ AgendaClock.day(fromKey: $0) != nil }),
                      (item.pausedRanges ?? []).allSatisfy({ $0.from <= $0.to && AgendaClock.day(fromKey: $0.from) != nil && AgendaClock.day(fromKey: $0.to) != nil }) else {
                    throw StoreError.invalid(L("跳过或暂停的日期无效"))
                }
            }
            for (key, target) in item.postponedTimes ?? [:] {
                var original = item; original.postponedTimes = nil; original.skippedDays = nil; original.pausedRanges = nil
                guard validDate(target), let occurrence = AgendaClock.occurrence(items: [original], id: item.id.uuidString + ":" + key),
                      occurrence.due != nil else { throw StoreError.invalid(L("单次安排时刻无效")) }
            }
        }
    }
    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= Date(timeIntervalSince1970: -62135596800) && date <= Date(timeIntervalSince1970: 253402271999)
    }
    private enum StoreError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
    }
}
