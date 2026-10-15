import Foundation

@main struct CompactFocusTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
            checks += 1; let passed = try value(); precondition(passed, message)
        }
        func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            AgendaClock.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chaoxi-compact-focus-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgendaStore(directory: root, seedIfEmpty: false)
        let now = date(15, 10)
        let overdue = AgendaItem(title: "旧安排", date: date(15), timeMinutes: 8 * 60)
        let ongoing = AgendaItem(title: "进行中", date: date(15), timeMinutes: 9 * 60 + 30, durationMinutes: 60)
        let next = AgendaItem(title: "下一件", date: date(15), timeMinutes: 11 * 60)
        let checklist = AgendaItem(title: "固定清单", date: date(15), reminderEnabled: false, checklistState: .pending)
        check(store.upsertBatch([overdue, ongoing, next, checklist]), "Create isolated fixtures")
        check(store.pinChecklistItem(checklist.id), "Keep expanded-view fixed checklist")
        check(store.compactFocus(now: now)?.item.id == ongoing.id, "Compact defaults to ongoing schedule despite expanded pin")
        check(store.highlightedFocus(now: now)?.item.id == checklist.id && !store.compactUsesPinnedFocus, "Expanded pin remains independent")
        check(store.compactFocus(now: date(15, 10, 30))?.item.id == next.id, "At end of duration compact advances to next")
        check(store.compactFocus(now: date(15, 11, 1)) == nil, "Overdue items cannot occupy automatic main content")
        check(store.setCompactFollowsPinned(true), "Switch to fixed content")
        check(store.compactFocus(now: now)?.item.id == checklist.id && store.compactUsesPinnedFocus, "Fixed checklist appears in compact")
        let reload = AgendaStore(directory: root, seedIfEmpty: false)
        check(reload.compactUsesPinnedFocus && reload.compactFocus(now: now)?.item.id == checklist.id, "Mode and pin survive restart")
        check(store.setCompactFollowsPinned(false), "Switch back to recent")
        check(store.highlightedFocus(now: now)?.item.id == checklist.id && store.compactFocus(now: now)?.item.id == ongoing.id, "Switch does not clear expanded pin")
        let nextRow = store.occurrences(on: date(15)).first { $0.item.id == next.id }!
        let beforePin = try Data(contentsOf: store.fileURL)
        check(store.pinOccurrence(nextRow, inCompact: true) && store.compactUsesPinnedFocus, "Select fixed schedule and compact mode atomically")
        store.undo()
        check(store.settings.pinnedOccurrenceID == AgendaFocus.checklist(checklist).id && !store.compactUsesPinnedFocus, "One undo restores both old pin and mode")
        check(store.pinChecklistItem(checklist.id, inCompact: true), "Already-pinned checklist can activate compact mode")
        store.toggle(AgendaFocus.checklist(checklist))
        check(!store.compactUsesPinnedFocus && store.settings.compactFollowsPinned == false, "Completing fixed checklist returns to recent automatically")
        check(store.compactFocus(now: now)?.item.id == ongoing.id, "Completion shows ongoing schedule")
        check(!store.setCompactFollowsPinned(true), "No fixed item cannot enable fixed mode")
        check(store.pinOccurrence(nextRow, inCompact: true), "Pin schedule for deletion case")
        store.delete(next.id)
        check(!store.compactUsesPinnedFocus && store.compactFocus(now: now)?.item.id == ongoing.id, "Deleting fixed schedule returns to recent")
        check(!store.pinOccurrence(nextRow, inCompact: true), "Stale deleted schedule cannot become a fixed item")
        let previousNight = AgendaItem(title: "跨夜安排", date: date(14), timeMinutes: 23 * 60 + 30, durationMinutes: 90)
        check(store.upsert(previousNight), "Add cross-midnight fixture")
        check(store.compactFocus(now: date(15, 0, 30))?.item.id == previousNight.id, "Ongoing previous-day span remains visible after midnight")
        check(store.compactFocus(now: date(15, 1))?.item.id == overdue.id, "Cross-midnight event retires at end")
        let repeating = AgendaItem(title: "单次调整", date: date(14), timeMinutes: 12 * 60, durationMinutes: 30, repeatRule: .daily)
        check(store.upsert(repeating), "Add recurring fixture")
        let occurrence = store.occurrences(on: date(15)).first { $0.item.id == repeating.id }!
        check(store.rescheduleOccurrence(occurrence, until: date(15, 9, 45)), "Advance one recurring occurrence")
        check(store.compactFocus(now: now)?.item.id == repeating.id, "Most recently started ongoing occurrence uses effective time")
        let currentRow = store.occurrences(on: date(15)).first { $0.item.id == repeating.id }!
        store.toggle(currentRow)
        check(store.compactFocus(now: now)?.item.id == ongoing.id, "Completed ongoing occurrence is skipped")
        var doc = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
        var settings = doc["settings"] as! [String: Any]
        settings.removeValue(forKey: "compactFollowsPinned")
        doc["settings"] = settings
        try JSONSerialization.data(withJSONObject: doc).write(to: store.fileURL)
        let legacy = AgendaStore(directory: root, seedIfEmpty: false)
        check(!legacy.isDataLocked && !legacy.compactUsesPinnedFocus, "Older documents default to recent mode")
        let emptyRoot = root.appendingPathComponent("empty")
        let empty = AgendaStore(directory: emptyRoot, seedIfEmpty: false)
        check(empty.compactFocus(now: now) == nil && !empty.setCompactFollowsPinned(true), "Empty schedule has stable empty state")
        let failRoot = root.appendingPathComponent("failure")
        let failure = AgendaStore(directory: failRoot, seedIfEmpty: false)
        check(failure.upsert(checklist) && failure.pinChecklistItem(checklist.id), "Failure fixture")
        let disk = try Data(contentsOf: failure.fileURL)
        try FileManager.default.removeItem(at: failure.fileURL)
        try FileManager.default.createDirectory(at: failure.fileURL, withIntermediateDirectories: false)
        check(!failure.setCompactFollowsPinned(true) && !failure.compactUsesPinnedFocus, "Failed mode save rolls back published state")
        try FileManager.default.removeItem(at: failure.fileURL)
        try disk.write(to: failure.fileURL)
        check(AgendaStore(directory: failRoot).compactFocus(now: now) == nil, "Failed save leaves original automatic mode on disk")
        check(!beforePin.isEmpty, "Pin undo fixture has persisted data")
        print("Passed \(checks) compact focus checks")
    }
}
