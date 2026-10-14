import Foundation

@main struct EditorNavigationTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(value(), message)
        }
        func day(_ value: Int) -> Date {
            AgendaClock.calendar.date(from: DateComponents(year: 2026, month: 10, day: value))!
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chaoxi-editor-navigation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgendaStore(directory: root, seedIfEmpty: false)
        for rule in RepeatRule.allCases {
            var item = AgendaItem(title: "隔离日期验收", date: day(12), timeMinutes: 23 * 60, repeatRule: rule)
            item.completedDays = ["2026-10-12"]
            check(store.upsert(item), "Save synthetic fixture")
            for browsing in [day(11), day(13), day(15)] {
                store.selectedDay = browsing
                let before = store.selectedDay
                item.timeMinutes! += 1
                check(store.upsert(item), "Clock-only edit saves")
                store.selectedDay = AgendaEditorNavigation.dayAfterSave(browsingDay: before, editedDay: item.date, isExisting: true, schedulingChecklist: false)
                check(store.selectedDay == browsing, "Clock-only edit must preserve any browsing date")
                let persisted = AgendaStore(directory: root, seedIfEmpty: false).items.first { $0.id == item.id }!
                check(persisted.date == day(12) && persisted.completedDays == item.completedDays && persisted.timeMinutes == item.timeMinutes, "Save changes clock without changing anchor or completion")
                let bytes = try Data(contentsOf: store.fileURL)
                var invalid = item; invalid.title = " "
                check(!store.upsert(invalid), "Invalid save rejected")
                let after = try Data(contentsOf: store.fileURL)
                check(after == bytes && store.selectedDay == browsing, "Rejected save preserves data and browsing")
            }
        }
        for selected in [day(11), day(13), day(15)] {
            check(AgendaEditorNavigation.dayAfterSave(browsingDay: day(13), editedDay: selected, isExisting: true, schedulingChecklist: false) == day(13), "Explicit anchor edit does not silently navigate")
            check(AgendaEditorNavigation.dayAfterSave(browsingDay: day(13), editedDay: selected, isExisting: false, schedulingChecklist: false) == selected, "New item opens explicitly selected date")
            check(AgendaEditorNavigation.dayAfterSave(browsingDay: day(13), editedDay: selected, isExisting: true, schedulingChecklist: true) == selected, "Checklist scheduling opens explicitly selected date")
        }
        print("Passed \(checks) editor navigation regression checks")
    }
}
