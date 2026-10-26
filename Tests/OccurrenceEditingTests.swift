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
        print("Passed \(checks) single-occurrence and whole-series editing checks")
    }
}
