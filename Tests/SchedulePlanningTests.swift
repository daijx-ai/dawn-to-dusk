import Foundation

@main struct SchedulePlanningTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(value(), message)
        }
        func date(_ d: Int, _ h: Int = 0, _ m: Int = 0) -> Date {
            AgendaClock.calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chaoxi-planning-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgendaStore(directory: root, seedIfEmpty: false)
        let wake = AgendaItem(title: "起床", date: date(25), timeMinutes: 450, repeatRule: .daily)
        let read = AgendaItem(title: "睡前阅读", date: date(25), timeMinutes: 1350, repeatRule: .daily)
        var sleep = AgendaItem(title: "睡觉", date: date(25), timeMinutes: 1380, repeatRule: .daily)
        sleep.completedDays = ["2026-10-25"]
        sleep.snoozes = ["2026-10-26": date(26, 23, 5)]
        check(store.upsertBatch([wake, read, sleep]), "Save synthetic daily fixtures")
        var drafts = [wake, read, sleep].map(ScheduleDraft.init)
        drafts[2].timeInput = "23:30"
        let proposed = drafts.compactMap(\.prepared)
        check(store.items.first { $0.id == sleep.id }!.timeMinutes == 1380, "Draft preview never writes live data")
        var rows = AgendaClock.occurrences(items: proposed, on: date(25))
        var readingGap = ScheduleInterval.following(rows.first { $0.item.id == read.id }!, items: proposed, on: date(25))!
        var night = ScheduleInterval.following(rows.first { $0.item.id == sleep.id }!, items: proposed, on: date(25))!
        check(readingGap.minutes == 60 && readingGap.text.contains("1 小时"), "22:30 reading to 23:30 sleep is one hour")
        check(night.crossesMidnight && night.minutes == 480 && night.text.contains("次日 07:30 起床") && night.text.contains("8 小时"), "23:30 sleep to next day 07:30 is eight hours")
        drafts[0].timeInput = "06:30"
        let earlierWake = drafts.compactMap(\.prepared)
        night = ScheduleInterval.following(rows.first { $0.item.id == sleep.id }!, items: earlierWake, on: date(25))!
        check(night.minutes == 420 && night.text.contains("7 小时"), "06:30 wake updates cross-night preview to seven hours")
        check(store.upsertBatch(earlierWake), "Save all planned times atomically")
        check(store.items.first { $0.id == sleep.id }!.completedDays == sleep.completedDays, "Batch edits preserve completion records")
        check(store.items.first { $0.id == sleep.id }!.snoozes.isEmpty, "Changed time clears stale reminders")
        let reloaded = AgendaStore(directory: root, seedIfEmpty: false)
        check(reloaded.items.first { $0.id == wake.id }?.timeMinutes == 390 && reloaded.items.first { $0.id == sleep.id }?.timeMinutes == 1410, "Saved plan survives reload")
        store.undo()
        check(store.items.first { $0.id == sleep.id } == sleep && store.items.first { $0.id == wake.id } == wake, "One undo restores complete batch including snooze and completion")
        drafts[1].item.durationMinutes = 60
        let withDuration = drafts.compactMap(\.prepared)
        rows = AgendaClock.occurrences(items: withDuration, on: date(25))
        readingGap = ScheduleInterval.following(rows.first { $0.item.id == read.id }!, items: withDuration, on: date(25))!
        check(readingGap.remainingMinutes == 0 && readingGap.text.contains("结束后"), "Explicit one-hour reading uses end time for remaining interval")
        drafts[1].item.durationMinutes = 90
        let overlapping = drafts.compactMap(\.prepared)
        let overlapRows = AgendaClock.occurrences(items: overlapping, on: date(25))
        readingGap = ScheduleInterval.following(overlapRows.first { $0.item.id == read.id }!, items: overlapping, on: date(25))!
        check(readingGap.remainingMinutes == -30 && readingGap.text.contains("重叠 30 分钟"), "Overlapping duration is not presented as free time")
        for invalid in ["25:00", "22:60", "", "hello"] {
            var draft = drafts[0]; draft.timeInput = invalid
            check(draft.prepared == nil, "Reject invalid draft clock")
        }
        var cleared = drafts[0]; cleared.timeInput = ":"
        check(cleared.prepared?.timeMinutes == 0, "Cleared hour and minute mean midnight")
        cleared.timeInput = "22:"
        check(cleared.prepared?.timeMinutes == 1320, "Cleared minute means zero")
        var empty = drafts[0]; empty.item.title = " "
        check(empty.prepared == nil, "Reject empty title before batch write")
        var untimed = drafts[0]; untimed.hasTime = false
        check(untimed.prepared?.timeMinutes == nil && untimed.prepared?.reminderEnabled == false, "Untimed editing disables impossible reminders")
        var overridden = sleep
        overridden.postponedTimes = ["2026-10-26": date(26, 22, 45)]
        let unchanged = ScheduleDraft(overridden)
        check(unchanged.prepared?.postponedTimes == overridden.postponedTimes, "Unchanged drafts preserve occurrence exceptions")
        var changed = unchanged; changed.timeInput = "23:30"
        check(changed.prepared?.postponedTimes == nil, "Changed series preview clears exceptions just as store does")
        var weekly = AgendaItem(title: "每周回顾", date: date(25), timeMinutes: 1200, repeatRule: .weekly)
        var weeklyDraft = ScheduleDraft(weekly)
        weeklyDraft.selectWeekday(2)
        check(weeklyDraft.item.date == date(26), "Choose next Monday without backdating anchor")
        weeklyDraft.selectWeekday(1)
        check(weeklyDraft.item.date == date(25), "Changing weekday again does not drift a week forward")
        weeklyDraft.setStartDay(date(27))
        weeklyDraft.selectWeekday(4)
        check(weeklyDraft.item.date == date(28), "Explicit start date becomes weekday selection baseline")
        check(AgendaClock.occurrences(items: [weekly], on: date(24)).isEmpty, "Weekly excludes before anchor")
        check(AgendaClock.occurrences(items: [weekly], on: date(25)).count == 1, "Weekly includes anchor Sunday")
        check(AgendaClock.occurrences(items: [weekly], on: date(26)).isEmpty, "Weekly excludes Monday")
        check(AgendaClock.occurrences(items: [weekly], on: date(1)).isEmpty, "Weekly excludes earlier matching weekday")
        let november1 = AgendaClock.calendar.date(byAdding: .day, value: 7, to: date(25))!
        check(AgendaClock.occurrences(items: [weekly], on: november1).count == 1, "Weekly repeats across month boundary")
        check(AgendaClock.next(items: [weekly], now: date(25, 21))?.day == november1, "Next weekly occurrence searches seven days")
        weekly.completedDays = [AgendaClock.dayKey(november1)]
        let november8 = AgendaClock.calendar.date(byAdding: .day, value: 14, to: date(25))!
        check(AgendaClock.next(items: [weekly], now: date(25, 21))?.day == november8, "Completed weekly occurrence does not hide following week")
        check(store.upsert(weekly), "Weekly saves using existing data schema")
        let decoded = AgendaStore(directory: root, seedIfEmpty: false)
        check(!decoded.isDataLocked && decoded.items.first { $0.id == weekly.id }?.repeatRule == .weekly, "Weekly reloads correctly")
        let query = try AgendaQueryReader.query(data: Data(contentsOf: store.fileURL), on: november8)
        check(query.schedule.contains { $0.id == weekly.id && $0.time == "20:00" }, "Real query consumer returns weekly event")
        let plans = ReminderPlanner.plans(items: [weekly], settings: store.settings, now: november8.addingTimeInterval(19 * 3600))
        check(plans.contains { $0.occurrenceID.hasSuffix(AgendaClock.dayKey(november8)) }, "Reminder consumer supports weekly recurrence")
        let singleton = AgendaItem(title: "单次", date: date(25), timeMinutes: 720)
        let singleRow = AgendaClock.occurrences(items: [singleton], on: date(25))[0]
        check(ScheduleInterval.following(singleRow, items: [singleton], on: date(25)) == nil, "Missing next-day event does not invent overnight duration")
        let oldData = try JSONEncoder().encode(sleep)
        let oldDecoded = try JSONDecoder().decode(AgendaItem.self, from: oldData)
        check(oldDecoded == sleep, "Existing daily item roundtrip unchanged")
        var legacySettings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgendaSettings())) as! [String: Any]
        legacySettings.removeValue(forKey: "scheduleIntervals")
        let legacy = try JSONDecoder().decode(AgendaSettings.self, from: JSONSerialization.data(withJSONObject: legacySettings))
        check(legacy.scheduleIntervalsVisible, "Older settings preserve the previous visible-interval default")
        let itemsBeforeSettings = store.items
        store.settings.scheduleIntervalsVisible = false
        check(store.save(), "Save hidden intervals preference")
        let hidden = AgendaStore(directory: root, seedIfEmpty: false)
        check(!hidden.isDataLocked && !hidden.settings.scheduleIntervalsVisible, "Interval preference survives app restart")
        check(hidden.items == itemsBeforeSettings, "Display setting never changes schedule contents")
        store.settings.scheduleIntervalsVisible = true
        check(store.save(), "Restore visible intervals preference")
        check(AgendaStore(directory: root, seedIfEmpty: false).settings.scheduleIntervalsVisible, "Both preference states reload correctly")
        var interview = AgendaItem(title: "已完成面试", date: date(26), timeMinutes: 900)
        interview.completedDays = ["2026-10-26"]
        check(!ScheduleEditing.visible(interview), "Completed one-off interviews are hidden from the editor")
        interview.repeatRule = .daily
        check(ScheduleEditing.visible(interview), "Completed repeat occurrences do not hide the series")
        var clockIn = AgendaItem(title: "上班打卡", date: date(26), timeMinutes: 540, repeatRule: .weekly)
        clockIn.weeklyTimes = ["2": 540, "3": 600, "4": 600, "5": 600, "6": 600]
        check(store.upsert(clockIn), "Save Monday 9 and Tuesday–Friday 10 as one event")
        func due(_ day: Date) -> Date? { AgendaClock.occurrences(items: store.items, on: day).first { $0.item.id == clockIn.id }?.due }
        check(due(date(26)) == date(26, 9), "Monday has its own time")
        check(due(date(27)) == date(27, 10) && due(date(30)) == date(30, 10), "Tuesday–Friday use 10")
        check(due(date(31)) == nil && due(date(25)) == nil, "Weekends and dates before anchor are excluded")
        var customDraft = ScheduleDraft(clockIn)
        customDraft.weeklyInputs?["2"] = "08:45"
        check(customDraft.prepared?.weeklyTimes?["2"] == 525 && customDraft.prepared?.weeklyTimes?["3"] == 600, "Editing Monday leaves Tuesday unchanged")
        customDraft.weeklyInputs = [:]
        check(customDraft.prepared == nil, "Reject a custom week with no selected day")
        customDraft.weeklyInputs = ["2": "25:00"]
        check(customDraft.prepared == nil, "Reject invalid per-weekday time")
        let tuesday = AgendaClock.occurrences(items: store.items, on: date(27)).first { $0.item.id == clockIn.id }!
        var exception = ScheduleOccurrenceDraft(tuesday); exception.timeInput = "09:00"
        check(store.upsertBatch([], rescheduling: [tuesday.id: exception.target!]), "Save one-day exception through the same atomic editor transaction")
        check(due(date(27)) == date(27, 9) && due(date(28)) == date(28, 10), "Tomorrow 9 does not alter Wednesday 10")
        let nextTuesday = AgendaClock.calendar.date(byAdding: .day, value: 7, to: date(27))!
        check(AgendaClock.occurrences(items: store.items, on: nextTuesday).first { $0.item.id == clockIn.id }?.due == nextTuesday.addingTimeInterval(10 * 3600), "One-day exception does not alter next Tuesday")
        let customQuery = try AgendaQueryReader.query(data: Data(contentsOf: store.fileURL), on: date(27))
        check(customQuery.schedule.contains { $0.id == clockIn.id && $0.time == "09:00" && $0.baseTime == "10:00" }, "Query reports override and weekday base time separately")
        let customPlans = ReminderPlanner.plans(items: store.items, settings: store.settings, now: date(27, 8))
        check(customPlans.contains { $0.occurrenceID == tuesday.id && $0.due == date(27, 9) }, "Reminders use the exceptional time")
        let weekdayReload = AgendaStore(directory: root, seedIfEmpty: false)
        check(weekdayReload.items.first { $0.id == clockIn.id }?.weeklyTimes == clockIn.weeklyTimes && !weekdayReload.isDataLocked, "Per-weekday schedule and exception survive reload")
        check(store.upsertBatch([], rescheduling: [tuesday.id: date(27, 10)]), "Restore one occurrence to its weekly time")
        check(store.items.first { $0.id == clockIn.id }?.postponedTimes == nil, "Restoring base time removes the override")
        let beforeBatch = store.items
        let added = AgendaItem(title: "理发", date: date(27), timeMinutes: 480)
        var updated = clockIn; updated.title = "上班打卡（已修改）"
        check(store.upsertBatch([added, updated], removing: [read.id]), "Add, edit, and delete in one save")
        check(store.items.contains { $0.id == added.id } && !store.items.contains { $0.id == read.id }, "Atomic batch applies all changes")
        store.undo()
        check(store.items == beforeBatch, "One undo restores the whole edit transaction")
        check(!store.upsertBatch([added], removing: [UUID()]), "Reject stale deletion")
        check(store.items == beforeBatch, "Rejected deletion cannot partially add items")
        check(!store.upsertBatch([added], rescheduling: ["missing": date(27, 9)]), "Reject invalid exception")
        check(store.items == beforeBatch, "Rejected exception cannot partially add items")
        var invalidWeek = clockIn; invalidWeek.weeklyTimes = ["8": 600]
        check(!store.upsert(invalidWeek), "Reject an invalid weekday key")
        invalidWeek.weeklyTimes = ["2": 1440]
        check(!store.upsert(invalidWeek), "Reject 24:00 in a weekday time")
        invalidWeek.weeklyTimes = [:]
        check(!store.upsert(invalidWeek), "Reject an empty saved weekly pattern")
        var invalidException = ScheduleOccurrenceDraft(tuesday); invalidException.timeInput = "25:00"
        check(ScheduleEditing.applicable([tuesday.id: invalidException], to: [wake]).isEmpty, "A removed event cannot leave an invisible invalid override blocking save")
        var noTuesday = clockIn; noTuesday.weeklyTimes?.removeValue(forKey: "3")
        check(ScheduleEditing.applicable([tuesday.id: exception], to: [noTuesday]).isEmpty, "Disabling Tuesday drops its now-inapplicable draft exception")
        noTuesday = clockIn; noTuesday.date = date(28)
        check(ScheduleEditing.applicable([tuesday.id: exception], to: [noTuesday]).isEmpty, "Moving the series anchor drops earlier draft exceptions")
        print("Passed \(checks) schedule planning checks")
    }
}
