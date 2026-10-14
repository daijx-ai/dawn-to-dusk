import Foundation
import Darwin

@main struct FeishuModelTests {
    @MainActor static var checks = 0
    struct Failure: Error { let message: String }
    @MainActor static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw Failure(message: message) }
    }
    static func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0, zone: String = "Asia/Shanghai") -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }
    static func snapshot(_ events: [FeishuEvent], calendarID: String = "primary", fetchedAt: Date = date(12, 12)) -> FeishuSnapshot {
        FeishuSnapshot(calendarID: calendarID, windowStart: date(11), windowEnd: date(20), events: events, fetchedAt: fetchedAt)
    }
    @MainActor static func main() {
        do { try run(); print("PASS: \(checks) Feishu model checks") }
        catch let failure as Failure { fputs("FAIL: \(failure.message)\n", stderr); exit(1) }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Chaoxi-FeishuModel-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = AgendaStore(directory: root.appendingPathComponent("store"), seedIfEmpty: false)
        let oldItems = AgendaClock.seed() + [AgendaItem(title: "某天未定时", date: date(12), timeMinutes: nil),
                                           AgendaItem(title: "每天用户事项", date: date(12), timeMinutes: 800, repeatRule: .daily, completedDays: ["2026-10-12"])]
        try expect(store.upsertBatch(oldItems), "legacy source-free fixtures")
        let captureRequest = AgendaCaptureRequest(requestID: "feishu-preserve-ledger", title: "用户已有清单", source: "hermes")
        let captured = store.capture(captureRequest, now: date(12, 11))
        try expect(captured.ok, "capture ledger baseline")
        let oldBytes = try Data(contentsOf: store.fileURL)
        let oldBackup = root.appendingPathComponent("old.json"); try oldBytes.write(to: oldBackup)
        let restartedOld = AgendaStore(directory: store.fileURL.deletingLastPathComponent())
        try expect(!restartedOld.isDataLocked && restartedOld.settings.feishuSyncEnabled != true && restartedOld.feishuSyncState == nil && restartedOld.items == store.items && (try Data(contentsOf: store.fileURL)) == oldBytes, "old document lacks optional mirror fields and reads without migration")
        store.settings.feishuSyncEnabled = true
        try expect(store.save() && AgendaStore(directory: store.fileURL.deletingLastPathComponent()).settings.feishuSyncEnabled == true, "sync opt-in persists")
        let localBefore = store.items
        let link = "https://applink.feishu.cn/client/calendar/event/detail?calendarId=primary&eventId=expanded-1"
        var first = FeishuEvent(calendarID: "primary", eventID: "series_20261012", title: "第一场会议", start: date(12, 9, 0, 17).addingTimeInterval(0.125), end: date(12, 10, 0, 19).addingTimeInterval(0.375), appLink: link)
        let second = FeishuEvent(calendarID: "primary", eventID: "series_20261013", title: "第二场会议", start: date(13, 9), end: date(13, 10))
        var multi = FeishuEvent(calendarID: "primary", eventID: "multi", title: "跨日活动", start: date(12, 23, 0, 45), end: date(14, 2, 15, 5), timezone: "UTC")
        var allDay = FeishuEvent(calendarID: "primary", eventID: "all-day", title: "全天安排", start: date(12, zone: "Asia/Tokyo"), end: date(14, zone: "Asia/Tokyo"), isAllDay: true, timezone: "Asia/Tokyo")
        try expect(store.applyFeishuSnapshot(snapshot([first, second, multi, allDay])), "initial source snapshot applies atomically")
        let mirrors = store.items.filter { $0.feishu != nil }
        try expect(mirrors.count == 4 && Set(mirrors.map(\.id)).count == 4 && mirrors.allSatisfy { $0.repeatRule == .none && !$0.isChecklist }, "expanded repeat IDs stay four distinct one-off source events")
        try expect(store.items.filter { $0.feishu == nil } == localBefore, "sync preserves all nine user items repeat and independent checklist")
        try expect(store.capture(captureRequest).status == "already_processed" && store.capture(captureRequest).itemID == captured.itemID, "source sync preserves capture ledger")
        try expect(store.feishuSyncState?.calendarID == "primary" && store.feishuSyncState?.lastSuccess == date(12, 12), "successful transaction records source binding and timestamp")
        let firstID = mirrors.first(where: { $0.feishu?.eventID == first.eventID })!.id
        let multiID = mirrors.first(where: { $0.feishu?.eventID == "multi" })!.id
        let allDayID = mirrors.first(where: { $0.feishu?.eventID == "all-day" })!.id
        let firstRow = store.occurrences(on: date(12)).first(where: { $0.item.id == firstID })!
        try expect(firstRow.due == first.start && firstRow.end == first.end && firstRow.item.feishu?.timezone == first.timezone && firstRow.item.feishu?.appLink == link, "exact source seconds timezone and official link survive projection")
        let initialMulti = store.items.first(where: { $0.id == multiID })!
        try expect(initialMulti.durationMinutes > 1440 && initialMulti.feishu?.end == multi.end, "multi-day duration is not clamped to one day")
        for day in [12, 13, 14] {
            let row = store.occurrences(on: date(day)).first(where: { $0.item.id == multiID })
            try expect(row?.due == multi.start && row?.end == multi.end, "continuing event shows exact interval on each overlapped day")
            try expect(day == 12 ? row?.remindAt == multi.start : row?.remindAt == nil, "only actual initial day can produce a timed reminder")
        }
        try expect(!store.occurrences(on: date(15)).contains(where: { $0.item.id == multiID }), "continuing event disappears after exact end")
        try expect(!store.occurrences(on: date(11)).contains(where: { $0.item.id == allDayID }) && !store.occurrences(on: date(14)).contains(where: { $0.item.id == allDayID }), "all-day source timezone date boundaries avoid shifted previous or end day")
        for day in [12, 13] {
            let row = store.occurrences(on: date(day)).first(where: { $0.item.id == allDayID })!
            try expect(row.due == nil && row.remindAt == nil && !row.item.reminderEnabled && row.end == allDay.end, "all-day span is visible and silent on its nominal source dates")
        }
        try expect(!AgendaClock.earlierUnscheduled(items: mirrors, now: date(20)).contains(where: { $0.item.feishu != nil }), "all-day events do not leak into overdue undated task carryover")
        try expect(Set(store.feishuMirroredEventIDs(calendarID: "primary")) == Set([first.eventID, second.eventID, multi.eventID, allDay.eventID]), "reader receives exact source instance IDs")
        try expect(Set(store.feishuMirroredEventIDs(calendarID: "primary", windowStart: date(13), windowEnd: date(14))) == Set([second.eventID, multi.eventID, allDay.eventID]), "reader missing-ID checks are limited to overlapping mirror window")
        try expect(store.feishuMirroredEventIDs(calendarID: "other").isEmpty, "reader cannot mix mirror IDs from another calendar")
        let beforeAbsence = store.items
        try expect(store.applyFeishuSnapshot(snapshot([], fetchedAt: date(12, 13))) && store.items == beforeAbsence, "absence alone never cancels or deletes mirrored events")
        try expect(store.applyFeishuSnapshot(snapshot([first, second, multi, allDay], fetchedAt: date(12, 14))) && store.items.map(\.id) == beforeAbsence.map(\.id), "repeated source snapshot updates same UUIDs instead of app-created duplicates")
        var illegalEdit = store.items.first(where: { $0.id == firstID })!; illegalEdit.title = "本地偷改源标题"
        let beforeLocalGuard = try Data(contentsOf: store.fileURL)
        try expect(!store.upsert(illegalEdit), "source-owned fields reject ordinary local edits")
        store.delete(firstID)
        try expect((try Data(contentsOf: store.fileURL)) == beforeLocalGuard, "source-owned deletion is refused without local disappearance")
        store.items[store.items.firstIndex(where: { $0.id == firstID })!].title = "直接突变"
        try expect(!store.save() && store.items.first(where: { $0.id == firstID })!.title == first.title && (try Data(contentsOf: store.fileURL)) == beforeLocalGuard, "raw published mutations cannot bypass source edit protection")

        store.toggle(firstRow)
        try expect(store.items.first(where: { $0.id == firstID })!.completedDays == ["2026-10-12"], "source event completion remains local")
        first.title = "移动后的会议"; first.start = date(15, 14, 0, 33); first.end = date(15, 15, 0, 47)
        try expect(store.applyFeishuSnapshot(snapshot([first], fetchedAt: date(12, 15))), "source moves completed event")
        let moved = store.items.first(where: { $0.id == firstID })!
        try expect(moved.title == first.title && moved.feishu?.start == first.start && moved.completedDays == ["2026-10-15"] && store.occurrences(on: date(15)).first(where: { $0.item.id == firstID })!.isCompleted, "move preserves UUID and maps completion to new source start day")
        try expect(!store.occurrences(on: date(12)).contains(where: { $0.item.id == firstID }), "old date occurrence disappears after move")
        store.undo()
        let undoneLocal = store.items.first(where: { $0.id == firstID })!
        try expect(undoneLocal.title == first.title && undoneLocal.feishu?.start == first.start && undoneLocal.completedDays.isEmpty && store.feishuSyncState?.lastSuccess == date(12, 15), "undo local completion preserves latest source update and sync state")
        let multiStartRow = store.occurrences(on: date(12)).first(where: { $0.item.id == multiID })!
        store.snooze(multiStartRow, minutes: 10)
        let snooze = store.items.first(where: { $0.id == multiID })!.snoozes
        try expect(!snooze.isEmpty, "local source snooze is allowed on initial occurrence")
        let beforeContinuingSnooze = try Data(contentsOf: store.fileURL)
        store.snooze(store.occurrences(on: date(13)).first(where: { $0.item.id == multiID })!, minutes: 10)
        try expect((try Data(contentsOf: store.fileURL)) == beforeContinuingSnooze, "continuing day cannot create a false midnight snooze reminder")
        multi.title = "跨日活动改标题"; multi.end = date(14, 3)
        try expect(store.applyFeishuSnapshot(snapshot([multi])) && store.items.first(where: { $0.id == multiID })!.snoozes == snooze, "unchanged source start preserves local snooze")
        store.toggle(store.occurrences(on: date(13)).first(where: { $0.item.id == multiID })!)
        try expect([12, 13, 14].allSatisfy { store.occurrences(on: date($0)).first(where: { $0.item.id == multiID })!.isCompleted }, "completing any continuing day completes the whole source event")
        multi.start = date(13, 18); multi.end = date(15, 1)
        try expect(store.applyFeishuSnapshot(snapshot([multi])) && store.items.first(where: { $0.id == multiID })!.snoozes.isEmpty && store.items.first(where: { $0.id == multiID })!.completedDays == ["2026-10-13"], "changed source start cancels stale snooze and preserves completion")
        store.toggle(store.occurrences(on: date(13)).first(where: { $0.item.id == allDayID })!)
        allDay.start = date(14, zone: "Asia/Tokyo"); allDay.end = date(16, zone: "Asia/Tokyo")
        try expect(store.applyFeishuSnapshot(snapshot([allDay])) && store.items.first(where: { $0.id == allDayID })!.completedDays == ["2026-10-14"], "moved all-day event stays completed by nominal source date")
        try expect(store.addChecklistItem(title: "同步前本地操作"), "local undo action before explicit cancellation")
        try expect(store.applyFeishuSnapshot(snapshot([FeishuEvent(calendarID: "primary", eventID: second.eventID, status: .cancelled)])), "explicit cancellation removes only exact expanded source instance")
        store.undo()
        try expect(!store.items.contains(where: { $0.feishu?.eventID == second.eventID }) && !store.items.contains(where: { $0.title == "同步前本地操作" }), "undo local action cannot resurrect source cancellation")
        try expect(store.capture(captureRequest).itemID == captured.itemID && store.capture(captureRequest).itemExists == true, "undo after source refresh retains capture ledger and item")

        let beforeInvalid = try Data(contentsOf: store.fileURL)
        var invalids: [FeishuSnapshot] = []
        var invalid = first; invalid.end = nil; invalids.append(snapshot([invalid]))
        invalid = first; invalid.timezone = "not-a-zone"; invalids.append(snapshot([invalid]))
        invalid = first; invalid.start = Date(timeIntervalSince1970: .nan); invalids.append(snapshot([invalid]))
        invalid = first; invalid.end = date(11); invalids.append(snapshot([invalid]))
        invalid = first; invalid.title = String(repeating: "字", count: 201); invalids.append(snapshot([invalid]))
        invalid = first; invalid.title = ""; invalids.append(snapshot([invalid]))
        invalid = first; invalid.calendarID = "foreign"; invalids.append(snapshot([invalid]))
        invalid = first; invalid.appLink = "https://evil.example/client/calendar/event/detail"; invalids.append(snapshot([invalid]))
        invalid = first; invalid.appLink = "https://user:secret@applink.feishu.cn/client/calendar/event/detail"; invalids.append(snapshot([invalid]))
        invalid = allDay; invalid.start = date(14, 3); invalids.append(snapshot([invalid]))
        invalids.append(snapshot([first, first]))
        var invalidRange = snapshot([]); invalidRange.windowEnd = invalidRange.windowStart; invalids.append(invalidRange)
        let legitimateNew = FeishuEvent(calendarID: "primary", eventID: "new-before-invalid", title: "不得部分保存", start: date(16, 9), end: date(16, 10))
        invalid = first; invalid.end = nil; invalids.append(snapshot([legitimateNew, invalid]))
        for invalidSnapshot in invalids { try expect(!store.applyFeishuSnapshot(invalidSnapshot) && (try Data(contentsOf: store.fileURL)) == beforeInvalid, "invalid or partial source snapshot aborts whole transaction") }
        let foreign = FeishuEvent(calendarID: "foreign", eventID: "other-event", title: "不得混账号", start: date(16, 9), end: date(16, 10))
        try expect(!store.applyFeishuSnapshot(snapshot([foreign], calendarID: "foreign")) && (try Data(contentsOf: store.fileURL)) == beforeInvalid, "primary calendar change cannot silently mix account sources")
        let sourceBackup = root.appendingPathComponent("source.json"); try beforeInvalid.write(to: sourceBackup)
        let failItems = store.items, failState = store.feishuSyncState
        try fm.removeItem(at: store.fileURL); try fm.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        first.title = "保存失败不得显示"
        try expect(!store.applyFeishuSnapshot(snapshot([first], fetchedAt: date(19))) && store.items == failItems && store.feishuSyncState == failState, "failed atomic sync preserves source items and last-success state")
        try fm.removeItem(at: store.fileURL); try beforeInvalid.write(to: store.fileURL)
        try expect(store.applyFeishuSnapshot(snapshot([first], fetchedAt: date(19))) && AgendaStore(directory: store.fileURL.deletingLastPathComponent()).items == store.items, "source update retries and survives restart after write recovery")
        try expect(store.restore(from: sourceBackup) && store.items == failItems && store.feishuSyncState == failState && store.capture(captureRequest).status == "already_processed", "source backup restores exact metadata state and receipt ledger")
        try expect(store.restore(from: oldBackup) && store.feishuSyncState == nil && store.items == localBefore && store.settings.feishuSyncEnabled != true, "legacy backup resets optional mirror state without affecting original captured item")
        try expect(store.applyFeishuSnapshot(snapshot([first])), "source can first-bind after explicit legacy restore")
        try expect(store.applyFeishuSnapshot(snapshot([FeishuEvent(calendarID: "primary", eventID: first.eventID, status: .declined)])) && store.items.allSatisfy({ $0.feishu == nil }), "explicit declined tombstone removes source event")
        try expect(!store.applyFeishuSnapshot(snapshot([foreign], calendarID: "foreign")), "binding persists after all source events are removed")
        try expect(!AgendaStore(directory: store.fileURL.deletingLastPathComponent()).applyFeishuSnapshot(snapshot([foreign], calendarID: "foreign")), "empty source binding survives restart and still rejects account mixing")
        try expect(store.items.filter { $0.feishu == nil } == localBefore && store.capture(captureRequest).itemID == captured.itemID, "source lifecycle never overwrites local data or capture identity")
        try expect(store.restore(from: sourceBackup), "valid mirror fixture for corruption test")
        let corruptDir = root.appendingPathComponent("corrupt"); try fm.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptFile = corruptDir.appendingPathComponent("agenda.json")
        var document = try JSONSerialization.jsonObject(with: beforeInvalid) as! [String: Any]
        var rows = document["items"] as! [[String: Any]]
        let sourceIndex = rows.firstIndex(where: { $0["feishu"] != nil })!
        var metadata = rows[sourceIndex]["feishu"] as! [String: Any]; metadata["timezone"] = "invalid"
        rows[sourceIndex]["feishu"] = metadata; document["items"] = rows
        let corruptBytes = try JSONSerialization.data(withJSONObject: document); try corruptBytes.write(to: corruptFile)
        let corrupt = AgendaStore(directory: corruptDir)
        try expect(corrupt.isDataLocked && !corrupt.applyFeishuSnapshot(snapshot([])) && !corrupt.save() && (try Data(contentsOf: corruptFile)) == corruptBytes, "corrupt mirror metadata protects entire document instead of silently rebuilding")
        try expect(!store.restore(from: corruptFile) && store.items == failItems, "invalid mirror backup cannot replace valid data")
        document = try JSONSerialization.jsonObject(with: beforeInvalid) as! [String: Any]
        rows = document["items"] as! [[String: Any]]
        var duplicate = rows[sourceIndex]; duplicate["id"] = UUID().uuidString
        rows.append(duplicate); document["items"] = rows
        let duplicateBytes = try JSONSerialization.data(withJSONObject: document); try duplicateBytes.write(to: corruptFile)
        let duplicateStore = AgendaStore(directory: corruptDir)
        try expect(duplicateStore.isDataLocked && !duplicateStore.save() && (try Data(contentsOf: corruptFile)) == duplicateBytes, "duplicate source identity with different local UUID protects corrupted document")

        let boundary = AgendaStore(directory: root.appendingPathComponent("boundaries"), seedIfEmpty: false)
        let midnight = FeishuEvent(calendarID: "primary", eventID: "midnight", title: "午夜结束", start: date(13, 23), end: date(14))
        let point = FeishuEvent(calendarID: "primary", eventID: "point", title: "瞬间事项", start: date(15), end: date(15))
        var dstCalendar = Calendar(identifier: .gregorian); dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstStart = dstCalendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let dstEnd = dstCalendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let dst = FeishuEvent(calendarID: "primary", eventID: "dst", title: "夏令时全天", start: dstStart, end: dstEnd, isAllDay: true, timezone: "America/Los_Angeles")
        try expect(boundary.applyFeishuSnapshot(snapshot([midnight, point, dst])), "boundary source intervals apply")
        try expect(boundary.occurrences(on: date(13)).contains(where: { $0.item.feishu?.eventID == "midnight" }) && !boundary.occurrences(on: date(14)).contains(where: { $0.item.feishu?.eventID == "midnight" }), "exclusive timed midnight end never creates an extra next-day occurrence")
        try expect(boundary.occurrences(on: date(15)).contains(where: { $0.item.feishu?.eventID == "point" }) && !boundary.occurrences(on: date(16)).contains(where: { $0.item.feishu?.eventID == "point" }), "zero-duration source point stays on its actual date")
        let dstRow = AgendaClock.occurrences(items: boundary.items, on: AgendaClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!).first(where: { $0.item.feishu?.eventID == "dst" })!
        try expect(dstRow.item.durationMinutes == 1500 && dstRow.due == nil && dstRow.remindAt == nil && dstRow.end == dstEnd, "25-hour DST all-day interval preserves exact timestamps while showing one silent nominal day")

        let failureHistory = AgendaStore(directory: root.appendingPathComponent("failed-history"), seedIfEmpty: false)
        try expect(failureHistory.applyFeishuSnapshot(snapshot([midnight])) && failureHistory.addChecklistItem(title: "应可撤销本地项"), "failed sync history baseline")
        let failedHistoryBytes = try Data(contentsOf: failureHistory.fileURL)
        try fm.removeItem(at: failureHistory.fileURL); try fm.createDirectory(at: failureHistory.fileURL, withIntermediateDirectories: true)
        var rejectedUpdate = midnight; rejectedUpdate.title = "未保存源更新"
        try expect(!failureHistory.applyFeishuSnapshot(snapshot([rejectedUpdate])), "failed source update is not adopted")
        try fm.removeItem(at: failureHistory.fileURL); try failedHistoryBytes.write(to: failureHistory.fileURL)
        failureHistory.undo()
        try expect(failureHistory.checklistItems().isEmpty && failureHistory.items.first?.title == midnight.title, "failed sync does not prematurely rebase local undo onto rejected source data")
    }
}
