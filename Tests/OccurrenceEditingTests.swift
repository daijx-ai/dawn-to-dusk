import Foundation

@main struct OccurrenceEditingTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(value(), message)
        }
        func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            AgendaClock.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chaoxi-occurrence-edit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgendaStore(directory: root, seedIfEmpty: false)
        for rule in [RepeatRule.daily, .weekdays] {
            var item = AgendaItem(title: "下班打卡", date: date(12), timeMinutes: 22 * 60 + 30, durationMinutes: 5, repeatRule: rule)
            item.completedDays = ["2026-10-12"]
            item.snoozes = ["2026-10-14": date(14, 23), "2026-10-15": date(15, 23)]
            check(store.upsert(item), "Create isolated recurring fixture")
            store.selectedDay = date(14)
            let occurrence = store.occurrences(on: date(14)).first { $0.item.id == item.id }!
            check(store.pinOccurrence(occurrence), "Pin occurrence before edit")
            check(store.rescheduleOccurrence(occurrence, until: date(14, 20, 30)), "Advance this occurrence from 22:30 to 20:30")
            let current = store.items.first { $0.id == item.id }!
            check(current.timeMinutes == 22 * 60 + 30 && current.date == date(12), "One-time edit preserves series anchor and base time")
            check(current.completedDays == item.completedDays && current.snoozes["2026-10-14"] == nil && current.snoozes["2026-10-15"] != nil, "Preserve completions and clear only edited snooze")
            check(store.selectedDay == date(14), "One-time edit preserves browsing day")
            let changed = store.occurrences(on: date(14)).first { $0.item.id == item.id }!
            check(changed.due == date(14, 20, 30) && changed.id == occurrence.id && store.isPinned(changed), "Timeline and pin share adjusted occurrence identity")
            check(changed.end == date(14, 20, 35), "Duration follows adjusted start")
            check(store.occurrences(on: date(13)).first { $0.item.id == item.id }!.due == date(13, 22, 30), "Past occurrence unchanged")
            check(store.occurrences(on: date(15)).first { $0.item.id == item.id }!.due == date(15, 22, 30), "Next occurrence unchanged")
            let reloaded = AgendaStore(directory: root, seedIfEmpty: false)
            check(!reloaded.isDataLocked && reloaded.occurrences(on: date(14)).first { $0.item.id == item.id }!.due == changed.due, "Earlier edit survives reload")
            let query = try AgendaQueryReader.query(data: Data(contentsOf: store.fileURL), on: date(14))
            check(query.schedule.first { $0.id == item.id }?.time == "20:30", "Real query reader accepts earlier edit")
            let plans = ReminderPlanner.plans(items: [current], settings: store.settings, now: date(14, 19))
            check(plans.contains { $0.occurrenceID == changed.id && !$0.isLead && $0.fireAt == date(14, 20, 30) }, "Due reminder uses adjusted time")
            check(plans.contains { $0.occurrenceID == changed.id && $0.isLead && $0.fireAt == date(14, 20, 20) }, "Lead reminder uses adjusted time")
            check(!ReminderPlanner.deliveredIsCurrent(occurrenceID: occurrence.id, plannedDue: occurrence.due!.timeIntervalSince1970, items: [current], settings: store.settings), "Old 22:30 notification is stale")
            check(store.rescheduleOccurrence(changed, until: date(15, 0, 30)), "Move occurrence across midnight")
            check(!store.occurrences(on: date(14)).contains { $0.item.id == item.id }, "Moved occurrence leaves original date")
            check(store.occurrences(on: date(15)).filter { $0.item.id == item.id }.count == 2, "Moved occurrence and normal repeat both visible")
            check(store.rescheduleOccurrence(changed, until: date(14, 22, 30)), "Restore base time using stable identity")
            check(store.items.first { $0.id == item.id }!.postponedTimes == nil, "Restore removes single-occurrence override")
            check(store.rescheduleOccurrence(occurrence, until: date(14, 20, 30)), "Create override before whole-series change")
            var series = store.items.first { $0.id == item.id }!
            series.timeMinutes = 20 * 60 + 30
            check(store.upsert(series), "Change every occurrence to 20:30")
            check(store.items.first { $0.id == item.id }!.postponedTimes == nil, "Whole-series time change clears old overrides")
            for day in [12, 13, 14, 15] {
                check(store.occurrences(on: date(day)).first { $0.item.id == item.id }!.due == date(day, 20, 30), "Whole-series time edit includes all dates")
            }
            check(store.occurrences(on: date(12)).first { $0.item.id == item.id }!.isCompleted, "Whole-series edit preserves completion")
            store.undo()
            check(store.items.first { $0.id == item.id }!.timeMinutes == 22 * 60 + 30 && store.items.first { $0.id == item.id }!.postponedTimes != nil, "Undo restores series and one-time override together")
            let bytes = try Data(contentsOf: store.fileURL)
            check(!store.rescheduleOccurrence(changed, until: Date(timeIntervalSince1970: .nan)), "Reject nonfinite target")
            var missing = occurrence; missing.item.id = UUID()
            check(!store.rescheduleOccurrence(missing, until: date(14, 21)), "Reject missing occurrence")
            check(!store.postpone(changed, until: date(14, 18), now: date(14, 19)), "Quick postpone still rejects earlier time")
            let afterRejection = try Data(contentsOf: store.fileURL)
            check(afterRejection == bytes, "Rejected edits leave disk unchanged")
            var silent = current; silent.isTentative = true; silent.reminderEnabled = false
            check(ReminderPlanner.plans(items: [silent], settings: store.settings, now: date(14, 19)).isEmpty, "Tentative occurrence stays silent")
            silent.isTentative = false
            check(ReminderPlanner.plans(items: [silent], settings: store.settings, now: date(14, 19)).isEmpty, "Disabled reminders stay silent")
            if rule == .weekdays {
                check(store.occurrences(on: date(17)).allSatisfy { $0.item.id != item.id }, "Weekday recurrence excludes Saturday")
            }
        }
        let checklist = AgendaItem(title: "清单", date: date(14), reminderEnabled: false, checklistState: .pending)
        check(store.upsert(checklist), "Create checklist fixture")
        check(!store.rescheduleOccurrence(Occurrence(item: checklist, day: date(14), due: date(14, 20)), until: date(14, 19)), "Reject fabricated checklist occurrence")
        try externalChangeChecks(&checks)
        print("Passed \(checks) single-occurrence, whole-series and external change checks")
    }

    /// `--change` semantics through the real Store, reminder planner and query reader (isolated temp data).
    @MainActor static func externalChangeChecks(_ checks: inout Int) throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { count += 1; precondition(value(), message) }
        defer { checks += count }
        func nov(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            AgendaClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chaoxi-external-change-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgendaStore(directory: root, seedIfEmpty: false)
        func request(_ object: [String: Any]) -> AgendaChangeRequest {
            try! AgendaChangeRequest.parse(JSONSerialization.data(withJSONObject: object))
        }
        func change(_ object: [String: Any], now: Date? = nil) -> AgendaChangeResult { store.applyChange(request(object), now: now ?? nov(9, 8)) }
        func json(_ result: AgendaChangeResult) -> [String: Any] { try! JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any] }
        func disk() -> Data { try! Data(contentsOf: store.fileURL) }
        func plans(_ now: Date? = nil) -> [ReminderPlan] { ReminderPlanner.plans(items: store.items, settings: store.settings, now: now ?? nov(9, 8)) }

        // 1 + 2: change a captured one-time item through its capture request ID.
        let captured = store.capture(AgendaCaptureRequest(requestID: "xlys-cap-1", title: "交材料", date: "2026-11-09", time: "14:00", durationMinutes: 30, source: "cli"), now: nov(9, 8))
        check(captured.status == "created", "Capture fixture")
        let id = captured.itemID!
        check(plans().contains { $0.occurrenceID == id.uuidString + ":2026-11-09" && !$0.isLead && $0.fireAt == nov(9, 14) }, "Original 14:00 reminder planned")
        let move: [String: Any] = ["request_id": "xlys-chg-1", "op": "update", "target": ["capture_request_id": "xlys-cap-1"], "fields": ["date": "2026-11-10", "time": "10:00"]]
        let moved = change(move)
        check(moved.ok && moved.status == "updated" && moved.saved && moved.itemExists == true && moved.itemID == id, "Update by capture_request_id succeeds")
        check(store.items.filter { $0.title == "交材料" }.count == 1 && store.items.count == 1, "Moving does not duplicate the item")
        let movedJSON = json(moved)
        let before = movedJSON["before"] as! [String: Any], after = movedJSON["after"] as! [String: Any]
        check(before["date"] as? String == "2026-11-09" && before["time"] as? String == "14:00", "before shows the old schedule")
        check(after["date"] as? String == "2026-11-10" && after["time"] as? String == "10:00" && after["duration_minutes"] as? Int == 30, "after shows the new schedule and keeps duration")
        check(after["source"] as? String == "cli" && after["capture_request_id"] as? String == "xlys-cap-1" && after["revision"] as? String == AgendaRevision.of(store.items[0]), "after carries source, capture id and current revision")
        check(Set(movedJSON.keys).isSuperset(of: ["ok", "status", "item_exists", "saved", "before", "after", "request_id"]), "Receipt has every agreed field")
        check(!plans().contains { $0.occurrenceID == id.uuidString + ":2026-11-09" }, "Old reminder is no longer planned")
        check(plans().contains { $0.occurrenceID == id.uuidString + ":2026-11-10" && !$0.isLead && $0.fireAt == nov(10, 10) }, "New 10:00 reminder planned")
        check(!ReminderPlanner.deliveredIsCurrent(occurrenceID: id.uuidString + ":2026-11-09", plannedDue: nov(9, 14).timeIntervalSince1970, items: store.items, settings: store.settings), "An already delivered old reminder is stale")

        // 3: idempotent replay and changed-content replay.
        let afterMove = disk()
        let replay = change(move, now: nov(9, 9))
        check(replay.ok && replay.status == "already_processed" && replay.itemExists == true && replay.after?.item.timeMinutes == 600, "Replay returns already_processed with original after")
        check(disk() == afterMove, "Replay writes nothing")
        var different = move; different["fields"] = ["time": "11:00"]
        check(change(different).status == "conflict" && disk() == afterMove, "Same request_id with other content is rejected")

        // 4: stale if_match.
        let stale = change(["request_id": "xlys-chg-2", "op": "update", "target": ["item_id": id.uuidString], "if_match": AgendaRevision.of(moved.before!.item), "fields": ["title": "不该生效"]])
        check(!stale.ok && stale.status == "conflict" && stale.current?.item.title == "交材料" && json(stale)["current"] is [String: Any], "Stale if_match returns conflict with current value")
        check(disk() == afterMove, "Conflict does not write")
        let fresh = change(["request_id": "xlys-chg-3", "op": "update", "target": ["item_id": id.uuidString], "if_match": AgendaRevision.of(store.items[0]), "fields": ["note": "带原件"]])
        check(fresh.status == "updated" && store.items[0].note == "带原件" && store.items[0].timeMinutes == 600, "Fresh if_match updates only provided field")

        // 5: an open window draft blocks the change and keeps the draft.
        let token = UUID()
        store.registerDraft(token, ids: [id])
        let draftBytes = disk()
        let blocked = change(["request_id": "xlys-chg-4", "op": "update", "target": ["item_id": id.uuidString], "fields": ["title": "外部改名"]])
        check(!blocked.ok && blocked.status == "conflict" && blocked.current != nil && disk() == draftBytes && store.items[0].title == "交材料", "Unsaved draft returns conflict")
        check(store.draftItemIDs == [id], "Draft registration remains after the conflict")
        store.releaseDraft(token)
        check(change(["request_id": "xlys-chg-4", "op": "update", "target": ["item_id": id.uuidString], "fields": ["title": "外部改名"]]).status == "updated", "Same request succeeds once the draft is closed")

        // 11: window undo reverts the latest external change; per-record undo too.
        check(store.undoRevertsExternalChange, "Window undo targets the external change")
        store.undo()
        check(store.items[0].title == "交材料" && store.externalChanges.last?.undoneAt != nil, "Window undo restores the previous title and marks the record")
        let noted = change(["request_id": "xlys-chg-5", "op": "update", "target": ["item_id": id.uuidString], "fields": ["note": ""]])
        check(store.undoExternalChange(noted.recordID!) && store.items[0].note == "带原件", "Settings list undo restores one record")
        check(!store.undoExternalChange(noted.recordID!), "A record cannot be undone twice")
        let renamed = change(["request_id": "xlys-chg-6", "op": "update", "target": ["item_id": id.uuidString], "fields": ["title": "外部改名二"]])
        var local = store.items[0]; local.title = "用户之后又改"
        check(store.upsert(local) && !store.undoExternalChange(renamed.recordID!) && store.items[0].title == "用户之后又改", "Undo refuses to overwrite a later window edit")

        // 6: delete then restore a repeating item with completion history.
        var wake = AgendaItem(title: "起床", date: nov(2), timeMinutes: 450, repeatRule: .daily)
        wake.completedDays = ["2026-11-05", "2026-11-06"]
        check(store.upsert(wake), "Daily fixture")
        let snapshot = store.items.first { $0.id == wake.id }!
        let deleted = change(["request_id": "xlys-chg-7", "op": "delete", "target": ["item_id": wake.id.uuidString]])
        check(deleted.status == "deleted" && deleted.itemExists == false && deleted.before?.item == snapshot && deleted.message?.contains("restore") == true, "Delete returns the full snapshot and a restore hint")
        check(!store.items.contains { $0.id == wake.id } && !plans().contains { $0.occurrenceID.hasPrefix(wake.id.uuidString) }, "Deleted item has no reminders")
        let restored = change(["request_id": "xlys-chg-8", "op": "restore", "target": ["item_id": wake.id.uuidString]])
        check(restored.status == "restored" && store.items.first { $0.id == wake.id } == snapshot, "Restore brings back id, completion records and repeat rule exactly")
        let noopRestore = change(["request_id": "xlys-chg-9", "op": "restore", "target": ["item_id": wake.id.uuidString]])
        check(noopRestore.status == "no_change" && noopRestore.saved && noopRestore.ok, "Restoring an existing item is a reliable no-op")
        check(change(["request_id": "xlys-chg-9", "op": "restore", "target": ["item_id": wake.id.uuidString]]).status == "already_processed", "No-op restore is idempotent")
        // Settings undo followed by window undo re-applies the change and the log says so.
        let tempDelete = change(["request_id": "xlys-chg-9a", "op": "delete", "target": ["item_id": wake.id.uuidString]])
        check(store.undoExternalChange(tempDelete.recordID!) && store.items.first { $0.id == wake.id } == snapshot, "Settings undo of a delete brings the item back")
        store.undo()
        check(!store.items.contains { $0.id == wake.id } && store.externalChanges.first { $0.id == tempDelete.recordID }?.undoneAt == nil, "Window undo after Settings undo re-deletes and reopens the record")
        check(change(["request_id": "xlys-chg-9b", "op": "restore", "target": ["item_id": wake.id.uuidString]]).status == "restored" && store.items.first { $0.id == wake.id } == snapshot, "The re-applied delete is still restorable")
        check(change(["request_id": "xlys-chg-9c", "op": "resume", "target": ["capture_request_id": "xlys-cap-1"], "occurrence_id": wake.id.uuidString + ":2026-11-10"]).status == "invalid", "occurrence_id must belong to the resolved target")

        // 7: reschedule one day of the daily item.
        let once = change(["request_id": "xlys-chg-10", "op": "reschedule_once", "target": ["item_id": wake.id.uuidString], "occurrence_id": wake.id.uuidString + ":2026-11-12", "new_time": "09:00"])
        check(once.status == "rescheduled", "reschedule_once succeeds")
        func wakeDue(_ day: Int) -> Date? { store.occurrences(on: nov(day)).first { $0.item.id == wake.id }?.due }
        check(wakeDue(12) == nov(12, 9) && wakeDue(11) == nov(11, 7, 30) && wakeDue(13) == nov(13, 7, 30), "Only 11/12 changes")
        check(store.items.first { $0.id == wake.id }!.timeMinutes == 450 && store.items.first { $0.id == wake.id }!.completedDays == snapshot.completedDays, "Series time and completions unchanged")
        check(plans(nov(12, 7)).contains { $0.occurrenceID == wake.id.uuidString + ":2026-11-12" && !$0.isLead && $0.fireAt == nov(12, 9) }, "Reminder follows the one-time change")
        let done = change(["request_id": "xlys-chg-11", "op": "complete", "target": ["occurrence_id": wake.id.uuidString + ":2026-11-10"]])
        check(done.status == "completed" && store.items.first { $0.id == wake.id }!.completedDays.contains("2026-11-10"), "complete marks one occurrence")
        check(change(["request_id": "xlys-chg-12", "op": "reopen", "target": ["occurrence_id": wake.id.uuidString + ":2026-11-10"]]).status == "reopened", "reopen clears it")
        check(change(["request_id": "xlys-chg-13", "op": "complete", "target": ["item_id": wake.id.uuidString]]).status == "invalid", "Repeating complete needs occurrence_id")

        // 8: pause a weekday clock-in for a school stay, then resume.
        let work = AgendaItem(title: "上班打卡", date: nov(2), timeMinutes: 540, repeatRule: .weekdays)
        check(store.upsert(work), "Weekday fixture")
        func hasWork(_ day: Int) -> Bool { store.occurrences(on: nov(day)).contains { $0.item.id == work.id } }
        let paused = change(["request_id": "xlys-chg-14", "op": "pause_range", "target": ["item_id": work.id.uuidString], "from": "2026-11-10", "to": "2026-11-22"])
        check(paused.status == "paused" && paused.after?.item.pausedRanges == [AgendaDayRange(from: "2026-11-10", to: "2026-11-22")], "pause_range stores one range")
        check(hasWork(9) && hasWork(23) && (10...22).allSatisfy { !hasWork($0) }, "Paused range hides every occurrence inside only")
        check(AgendaClock.skippedOccurrences(items: store.items, on: nov(11)).contains { $0.item.id == work.id } && AgendaClock.skippedOccurrences(items: store.items, on: nov(14)).isEmpty, "Skipped weekdays stay listable; weekends have nothing to skip")
        check(!plans(nov(9, 20)).contains { $0.occurrenceID.hasPrefix(work.id.uuidString) }, "No reminders during the pause")
        check(AgendaClock.next(items: store.items.filter { $0.id == work.id }, now: nov(9, 20))?.day == nov(23), "Next occurrence skips the whole pause")
        let query = try AgendaQueryReader.query(data: disk(), on: nov(11))
        check(!query.schedule.contains { $0.id == work.id } && query.skipped.first { $0.id == work.id }?.pausedUntil == "2026-11-22", "Query reports the paused day as skipped, not missing")
        let resumed = change(["request_id": "xlys-chg-15", "op": "resume", "target": ["item_id": work.id.uuidString]])
        check(resumed.status == "resumed" && (9...23).filter { ![14, 15, 21, 22].contains($0) }.allSatisfy(hasWork), "Resume brings every weekday back")
        check(plans(nov(9, 20)).contains { $0.occurrenceID == work.id.uuidString + ":2026-11-10" }, "Reminders return after resume")
        check(change(["request_id": "xlys-chg-16", "op": "skip_once", "target": ["occurrence_id": work.id.uuidString + ":2026-11-11"]]).status == "skipped" && !hasWork(11) && hasWork(12), "skip_once hides one day")
        check(change(["request_id": "xlys-chg-17", "op": "skip_once", "target": ["occurrence_id": work.id.uuidString + ":2026-11-11"]]).status == "no_change", "Skipping twice is no_change")
        let skippedRow = AgendaClock.skippedOccurrences(items: store.items, on: nov(11)).first { $0.item.id == work.id }!
        check(store.unskip(skippedRow) && hasWork(11) && store.items.first { $0.id == work.id }!.skippedDays == nil, "Window one-click restore unskips the day")
        check(change(["request_id": "xlys-chg-18", "op": "pause_range", "target": ["item_id": work.id.uuidString], "from": "2026-11-10", "to": "2026-11-22"]).status == "paused", "Pause again for split test")
        let middle = AgendaClock.skippedOccurrences(items: store.items, on: nov(16)).first { $0.item.id == work.id }!
        check(store.unskip(middle) && hasWork(16) && !hasWork(13) && !hasWork(17), "Restoring one day splits the pause")
        check(store.unskip(AgendaClock.skippedOccurrences(items: store.items, on: nov(17)).first { $0.item.id == work.id }!, wholePause: true) && hasWork(17) && hasWork(20) && !hasWork(13), "Ending a pause only removes that segment")
        check(change(["request_id": "xlys-chg-19", "op": "resume", "target": ["item_id": work.id.uuidString], "from": "2026-11-01", "to": "2026-11-30"]).status == "resumed" && hasWork(13), "Range resume clears the rest")
        var oneOff = AgendaItem(title: "临时作息", date: nov(2), timeMinutes: 600, repeatRule: .daily)
        oneOff.pausedRanges = [AgendaDayRange(from: "2026-11-10", to: "2026-11-20")]
        check(store.upsert(AgendaItem(title: oneOff.title, date: oneOff.date, timeMinutes: 600, repeatRule: .daily)), "Pause fixture")
        let pauseID = store.items.last!.id
        check(change(["request_id": "xlys-chg-19d", "op": "pause_range", "target": ["item_id": pauseID.uuidString], "from": "2026-11-10", "to": "2026-11-20"]).status == "paused", "Pause fixture applied")
        let single = change(["request_id": "xlys-chg-19e", "op": "update", "target": ["item_id": pauseID.uuidString], "fields": ["repeat_rule": "none", "date": "2026-11-15"]])
        check(single.status == "updated" && single.after?.item.hasSkips == false && store.occurrences(on: nov(15)).contains { $0.item.id == pauseID }, "Converting to one-time drops old pauses")
        var opened = store.items.first { $0.id == pauseID }!
        check(store.isUnchangedSinceOpened(opened), "Freshly opened editor copy is current")
        check(change(["request_id": "xlys-chg-19f", "op": "update", "target": ["item_id": pauseID.uuidString], "fields": ["title": "外部改过"]]).status == "updated" && !store.isUnchangedSinceOpened(opened), "Editor detects an external change before saving")
        opened = store.items.first { $0.id == pauseID }!
        check(change(["request_id": "xlys-chg-19g", "op": "complete", "target": ["item_id": pauseID.uuidString]]).status == "completed" && store.isUnchangedSinceOpened(opened), "Completion alone does not block an editor save")
        let moveThenSkip = wake.id.uuidString + ":2026-11-12"
        check(change(["request_id": "xlys-chg-19b", "op": "skip_once", "target": ["occurrence_id": moveThenSkip]]).status == "skipped" && wakeDue(12) == nil, "A rescheduled day can still be skipped")
        check((try? AgendaQueryReader.query(data: disk(), on: nov(12))) != nil && !AgendaStore(directory: root, seedIfEmpty: false).isDataLocked, "Skipped override day stays a valid document")
        check(change(["request_id": "xlys-chg-19c", "op": "resume", "target": ["occurrence_id": moveThenSkip]]).status == "resumed" && wakeDue(12) == nov(12, 9), "Resume brings back the one-time time")
        check(change(["request_id": "xlys-chg-20", "op": "skip_once", "target": ["item_id": id.uuidString], "occurrence_id": id.uuidString + ":2026-11-10"]).status == "invalid", "One-time items cannot be skipped")

        // 9: Feishu mirrors are read-only.
        check(store.applyFeishuSnapshot(FeishuSnapshot(calendarID: "cal", windowStart: nov(9), windowEnd: nov(16), events: [FeishuEvent(calendarID: "cal", eventID: "evt", title: "周会", start: nov(10, 14), end: nov(10, 15))], fetchedAt: nov(9, 8))), "Feishu fixture")
        let mirror = store.items.first { $0.feishu != nil }!
        let mirrorBytes = disk()
        for (index, op) in ["update", "delete", "complete"].enumerated() {
            var body: [String: Any] = ["request_id": "xlys-feishu-\(index)", "op": op, "target": ["item_id": mirror.id.uuidString]]
            if op == "update" { body["fields"] = ["title": "改飞书"] }
            check(change(body).status == "forbidden", "Feishu \(op) is forbidden")
        }
        check(disk() == mirrorBytes, "Forbidden requests do not write")

        // Not found and checklist behavior.
        check(change(["request_id": "xlys-chg-21", "op": "update", "target": ["item_id": UUID().uuidString], "fields": ["title": "x"]]).status == "not_found", "Unknown item is not_found")
        check(change(["request_id": "xlys-chg-22", "op": "update", "target": ["capture_request_id": "never"], "fields": ["title": "x"]]).status == "not_found", "Unknown capture id is not_found")
        check(store.addChecklistItem(title: "买充电线"), "Checklist fixture")
        let list = store.items.last!
        check(change(["request_id": "xlys-chg-23", "op": "complete", "target": ["item_id": list.id.uuidString]]).status == "completed" && store.items.last!.checklistState == .completed, "Checklist complete")
        check(change(["request_id": "xlys-chg-24", "op": "update", "target": ["item_id": list.id.uuidString], "fields": ["time": "10:00"]]).status == "invalid", "Checklist time without date is invalid")
        check(change(["request_id": "xlys-chg-25", "op": "update", "target": ["item_id": id.uuidString], "fields": ["time": NSNull()]]).status == "updated" && store.items.first { $0.id == id }!.timeMinutes == nil && store.items.first { $0.id == id }!.durationMinutes == 0, "time:null makes an untimed item and clears duration")
        check(change(["request_id": "xlys-chg-26", "op": "update", "target": ["item_id": wake.id.uuidString], "fields": ["time": NSNull()]]).status == "invalid", "Repeating item keeps a time")

        // Persistence, restart idempotency and the read-only reader.
        let reloaded = AgendaStore(directory: root, seedIfEmpty: false)
        check(!reloaded.isDataLocked && reloaded.externalChanges == store.externalChanges && reloaded.items == store.items, "Change log and items survive reload")
        check(reloaded.applyChange(request(move), now: nov(9, 10)).status == "already_processed", "Receipts survive restart")
        check((try? AgendaQueryReader.query(data: disk(), on: nov(10))) != nil, "Query reader accepts the changed document")

        // 12: dry-run predicts without writing.
        let frozen = disk()
        let preview = try AgendaQueryReader.previewChange(request(["request_id": "xlys-dry-1", "op": "update", "target": ["item_id": wake.id.uuidString], "fields": ["time": "06:30"]]), data: frozen, now: nov(9, 10))
        check(preview.ok && preview.status == "preview" && preview.expectedStatus == "updated" && !preview.saved && preview.dryRun, "Dry-run reports the expected status without saving")
        check(preview.before?.item.timeMinutes == 450 && preview.after?.item.timeMinutes == 390, "Dry-run returns before and after")
        check(disk() == frozen && !store.items.contains { $0.timeMinutes == 390 }, "Dry-run leaves the file untouched")
        check(change(["request_id": "xlys-dry-1", "op": "update", "target": ["item_id": wake.id.uuidString], "fields": ["time": "06:30"]]).status == "updated", "Dry-run consumes no request_id")
    }
}
