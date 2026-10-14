import Foundation
import CoreGraphics
import Darwin

@main struct CoreTests {
    @MainActor static var checks = 0
    @MainActor static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw Failure(message: message) }
    }
    struct Failure: Error { let message: String }
    static func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 12, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        AgendaClock.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
    @MainActor static func main() {
        do { try run(); print("PASS: \(checks) core checks") }
        catch let failure as Failure { fputs("FAIL: \(failure.message)\n", stderr); exit(1) }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Chaoxi-CoreTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try expect(AgendaClock.calendar.timeZone.identifier == "Asia/Shanghai", "fixed Shanghai timezone")
        try expect(AgendaClock.dayKey(date(2026, 10, 11, 23, 59, 59)) == "2026-10-11", "day before midnight")
        try expect(AgendaClock.dayKey(date(2026, 10, 12)) == "2026-10-12", "day at midnight")
        try expect(AgendaClock.startOfDay(date(2026, 10, 12, 13)) == date(), "start of day")
        try expect(AgendaClock.timeText(date(2026, 10, 12, 9, 5)) == "09:05", "time formatting")
        try expect(AgendaClock.countdown(to: date(2026, 10, 12, 9), now: date(2026, 10, 12, 8, 59, 30)) == "30 秒", "second countdown")
        try expect(AgendaClock.countdown(to: date(2026, 10, 12, 9), now: date(2026, 10, 12, 9)) == "刚刚", "zero countdown no completion")
        try expect(AgendaClock.countdown(to: date(2026, 10, 13, 9), now: date(2026, 10, 12, 9)) == "1 天", "absolute countdown across day")
        try expect(AgendaClock.countdown(to: date(2026, 10, 12, 9), now: date(2026, 10, 12, 9, 7)) == "7 分钟前", "overdue countdown")

        let axis = AgendaTimeline(day: date(), pointsPerMinute: 1.5)
        try expect(axis.height == 2160, "full 24 hour axis at 90 points per hour")
        try expect(axis.y(date(2026, 10, 12, 9)) == 810, "nine o'clock maps to elapsed minutes")
        try expect(axis.y(date(2026, 10, 12, 9, 0, 30)) - axis.y(date(2026, 10, 12, 9)) == 0.75, "now moves with actual seconds between minute boundaries")
        try expect(axis.y(date(2026, 10, 11, 23, 59)) == 0 && axis.y(date(2026, 10, 13, 1)) == axis.height, "previous and following days clamp progress")
        try expect(axis.progress(at: date(2026, 10, 12, 12)) == 0.5, "half day elapsed does not imply completion")
        try expect(AgendaTimeline(day: date(), pointsPerMinute: 3).y(date(2026, 10, 12, 9)) == 1620, "zoom uses same proportional minute mapping")
        try expect(AgendaTimeline(day: date(), pointsPerMinute: .nan).pointsPerMinute == 1.5, "invalid scale remains finite")
        let overview = AgendaTimeline(day: date(), pointsPerMinute: 0.1)
        try expect(overview.pointsPerMinute == 0.1 && overview.height == 144, "overview accepts six points per hour and keeps a 144 point whole day")
        try expect(overview.y(hour: 12) == 72 && overview.y(date(2026, 10, 12, 12)) == overview.y(hour: 12), "overview noon now exactly matches noon tick at 72 points")
        try expect(overview.y(hour: 24) == 144 && overview.y(hour: 24) == overview.height && overview.y(date(2026, 10, 13)) == overview.height, "overview 24h tick and next midnight match axis bottom")
        let overviewLate = overview.placements(AgendaClock.occurrences(items: [AgendaItem(title: "晚间跨日时段", date: date(), timeMinutes: 1380, durationMinutes: 120)], on: date())).first!
        try expect(overviewLate.startY == 138 && overviewLate.startY == overview.y(hour: 23), "late overview event remains inside day at its exact 23h tick")
        try expect(overviewLate.endY == overview.height && overviewLate.endY - overviewLate.startY == 6, "late overview duration clips at 24h axis height instead of overflowing")
        try expect(overview.y(date(2026, 10, 12, 18)) == 108 && overview.y(date(2026, 10, 12, 18)) == overview.y(hour: 18), "evening now remains on the actual overview 18h tick")
        let denseItems = [
            AgendaItem(title: "长标题同时事项一", date: date(), timeMinutes: 540, durationMinutes: 60),
            AgendaItem(title: "同时事项二", date: date(), timeMinutes: 540, durationMinutes: 15),
            AgendaItem(title: "一分钟后", date: date(), timeMinutes: 541),
            AgendaItem(title: "午夜跨日", date: date(), timeMinutes: 1430, durationMinutes: 60),
            AgendaItem(title: "未定时", date: date())
        ]
        let denseRows = AgendaClock.occurrences(items: denseItems, on: date())
        let placed = axis.placements(denseRows, cardHeight: 82)
        try expect(placed.count == 4, "untimed items excluded from minute rail")
        try expect(placed[0].startY == placed[1].startY && placed[0].lane != placed[1].lane, "same minute remains same y using independent lanes")
        try expect(placed[2].startY - placed[0].startY == 1.5, "dense cards never stretch minute scale")
        try expect(zip(placed, placed.dropFirst()).allSatisfy { $0.1.cardY >= $0.0.cardY + 90 }, "dense detail cards cannot overlap")
        try expect(placed[0].endY - placed[0].startY == Double(placed[0].occurrence.item.durationMinutes) * 1.5, "duration bars use exact same scale")
        try expect(placed[2].endY == placed[2].startY, "point event invents no duration")
        try expect(placed.last!.endY == axis.height, "cross midnight span clips at day boundary")
        let filtered = axis.placements(denseRows.filter { $0.item.id != placed[0].occurrence.item.id })
        try expect(filtered.first!.startY == placed[1].startY, "hiding a card does not remap clock times")
        let many = (0..<40).map { AgendaItem(title: "密集 \($0)", date: date(), timeMinutes: 600, durationMinutes: 10) }
        let manyPlaced = axis.placements(AgendaClock.occurrences(items: many, on: date()))
        try expect(Set(manyPlaced.map(\.lane)).count == 40 && Set(manyPlaced.map(\.startY)) == [900], "40 simultaneous events keep independent lanes and exact anchors")
        let futureAxis = AgendaTimeline(day: date(2026, 10, 13), pointsPerMinute: 1.5)
        try expect(futureAxis.progress(at: date(2026, 10, 12, 23)) == 0, "tomorrow has no elapsed track")
        let lifeRows = AgendaClock.occurrences(items: AgendaClock.seed(), on: date())
        let compactLife = CompactAgendaTimeline(rows: lifeRows, day: date(), now: date(2026, 10, 12, 8, 30))
        try expect(compactLife.rows.count == 9 && compactLife.height == 544, "nine life items leave room for larger reading text and the live Now gap")
        try expect(compactLife.insertionIndex == 3 && compactLife.rows[2].title == "出门" && compactLife.rows[3].title == "上班", "08:30 Now belongs between 08:15 departure and 09:00 work")
        try expect(abs(compactLife.gapFraction - 1.0 / 3) < 0.000001 && compactLife.gapOffset == 16, "compact gap progress follows real fraction of adjacent appointment times")
        let compactLater = CompactAgendaTimeline(rows: lifeRows, day: date(), now: date(2026, 10, 12, 8, 30, 30))
        try expect(abs(compactLater.nowY! - compactLife.nowY! - 24.0 * 30 / 2700) < 0.000001, "compact Now moves with actual seconds rather than a static label")
        try expect(compactLife.rowY(at: 2) + compactLife.rowPitch <= compactLife.nowY! && compactLife.nowY! < compactLife.rowY(at: 3), "live marker remains in clear space between its surrounding rows")
        try expect(compactLife.rowY(at: 3) - compactLife.rowY(at: 2) == compactLife.rowPitch + compactLife.nowGap, "Now space preserves readable adjacent row heights")
        let beforeFirst = CompactAgendaTimeline(rows: lifeRows, day: date(), now: date(2026, 10, 12, 6))
        try expect(beforeFirst.insertionIndex == 0 && beforeFirst.nowY! < beforeFirst.rowY(at: 0), "early Now appears before first life item")
        let afterLast = CompactAgendaTimeline(rows: lifeRows, day: date(), now: date(2026, 10, 12, 23, 30))
        try expect(afterLast.insertionIndex == 9 && afterLast.gapFraction == 0.5 && afterLast.nowY! < afterLast.height, "late Now remains after sleep item and progresses toward midnight")
        let tomorrowCompact = CompactAgendaTimeline(rows: lifeRows, day: date(2026, 10, 13), now: date(2026, 10, 12, 8))
        try expect(!tomorrowCompact.showsNow && tomorrowCompact.nowY == nil && tomorrowCompact.elapsedHeight == 0, "future day has no false Now or past progress")
        let previousCompact = CompactAgendaTimeline(rows: lifeRows, day: date(), now: date(2026, 10, 13))
        try expect(!previousCompact.showsNow && previousCompact.elapsedHeight == previousCompact.height, "previous day has full elapsed line without inventing a current-time label")
        let sameTimeLife = [AgendaItem(title: "洗漱", date: date(), timeMinutes: 540), AgendaItem(title: "做早餐", date: date(), timeMinutes: 540), AgendaItem(title: "收拾", date: date(), timeMinutes: nil)]
        let compactSameTime = CompactAgendaTimeline(rows: AgendaClock.occurrences(items: sameTimeLife, on: date()), day: date(), now: date(2026, 10, 12, 9))
        try expect(compactSameTime.rows.count == 2 && compactSameTime.insertionIndex == 2 && Set(compactSameTime.rows.map(\.id)).count == 2, "same-time life items keep distinct identities and untimed items stay outside the timed list")
        try expect(compactSameTime.rowY(at: 1) - compactSameTime.rowY(at: 0) == 56 && compactSameTime.gapFraction.isFinite, "same-minute items leave room for larger two-line titles and remain nonoverlapping")

        let largeFrame = CGRect(x: 22, y: 40, width: 610, height: 920)
        try expect(AgendaPanelGeometry.normalized(largeFrame, compact: false) == largeFrame, "expanded custom width height and origin preserved")
        let tinyFrame = AgendaPanelGeometry.normalized(CGRect(x: 20, y: 30, width: 210, height: 100), compact: false)
        try expect(tinyFrame.width == 320 && tinyFrame.height == 520 && tinyFrame.maxY == 130, "minimum expanded size keeps top edge")
        try expect(AgendaPanelGeometry.normalized(largeFrame, compact: true).width == 610 && AgendaPanelGeometry.normalized(largeFrame, compact: true).height == 82, "capsule preserves independent width and keeps capsule height")
        try expect(AgendaPanelGeometry.normalized(CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10), compact: false).width == 400, "invalid persisted frame uses safe default")

        let seed = AgendaClock.seed(now: date(2026, 10, 11, 23, 59))
        try expect(seed.count == 9, "nine template items")
        try expect(seed.allSatisfy { $0.date == date() && $0.repeatRule == .none }, "template exact confirmed anchor and no assumed recurrence")
        try expect(seed.filter { !$0.isTentative }.map(\.title) == ["上班"], "only work confirmed")
        try expect(seed.filter(\.reminderEnabled).map(\.title) == ["上班"], "tentative seed silent")
        try expect(seed.first(where: { $0.title == "上班" })?.timeMinutes == 540, "confirmed work at nine")

        var daily = AgendaItem(title: "每天", date: date(), timeMinutes: 600, repeatRule: .daily)
        daily.completedDays = ["2026-10-12"]
        let monday = AgendaClock.occurrences(items: [daily], on: date()).first!
        let tuesday = AgendaClock.occurrences(items: [daily], on: date(2026, 10, 13)).first!
        try expect(monday.isCompleted && !tuesday.isCompleted, "recurrence completion isolated by date")
        try expect(monday.id != tuesday.id, "recurrence unique IDs")
        try expect(AgendaClock.occurrences(items: [daily], on: date(2026, 10, 11)).isEmpty, "no recurrence before anchor")
        let weekdays = AgendaItem(title: "工作日", date: date(2026, 10, 9), timeMinutes: 540, repeatRule: .weekdays)
        try expect(AgendaClock.occurrences(items: [weekdays], on: date(2026, 10, 10)).isEmpty, "Saturday omitted")
        try expect(AgendaClock.occurrences(items: [weekdays], on: date(2026, 10, 11)).isEmpty, "Sunday omitted")
        try expect(AgendaClock.next(items: [weekdays], now: date(2026, 10, 9, 10))?.day == date(), "next weekday after weekend")
        var farCompleted = daily
        farCompleted.completedDays = Set((0...20).map { AgendaClock.dayKey(AgendaClock.calendar.date(byAdding: .day, value: $0, to: date())!) })
        try expect(AgendaClock.next(items: [farCompleted], now: date())?.day == date(2026, 11, 2), "next skips many completed future instances")

        let past = AgendaItem(title: "逾期", date: date(), timeMinutes: 480)
        let future = AgendaItem(title: "未来", date: date(), timeMinutes: 720, durationMinutes: 30)
        let undated = AgendaItem(title: "未定时", date: date(), timeMinutes: nil)
        let now = date(2026, 10, 12, 9)
        try expect(AgendaClock.next(items: [past, undated, future], now: now)?.title == "未来", "next strictly future skips overdue")
        try expect(AgendaClock.next(items: [past, undated], now: now) == nil, "no false future when only overdue")
        try expect(AgendaClock.overdue(items: [past, undated, future], now: now).map(\.title) == ["逾期"], "only timed past is overdue")
        try expect(!AgendaClock.occurrences(items: [past], on: date())[0].isCompleted, "time passing never completes")
        try expect(AgendaClock.occurrences(items: [undated], on: date())[0].due == nil, "undated stays untimed")
        try expect(AgendaClock.occurrences(items: [undated], on: date(2026, 10, 13)).isEmpty, "undated stays selected day")
        try expect(AgendaClock.occurrences(items: [future], on: date())[0].end == date(2026, 10, 12, 12, 30), "duration end time")
        let recent = AgendaItem(title: "近期", date: date(2026, 10, 5), timeMinutes: 1)
        let old = AgendaItem(title: "更早", date: date(2026, 10, 4), timeMinutes: 1)
        var recurring = daily; recurring.completedDays = []
        try expect(AgendaClock.overdue(items: [recent, old, recurring], now: date(2026, 10, 12, 11)).map(\.title) == ["更早", "近期", "每天"], "all old one-offs retained repeated today only")
        let twentyDaysOld = AgendaItem(title: "二十天前", date: date(2026, 9, 22), timeMinutes: 540)
        var completedOld = twentyDaysOld; completedOld.id = UUID(); completedOld.completedDays = ["2026-09-22"]
        try expect(AgendaClock.overdue(items: [twentyDaysOld, completedOld], now: now).map(\.id) == [AgendaClock.occurrences(items: [twentyDaysOld], on: twentyDaysOld.date)[0].id], "twenty day old unfinished retained completed excluded")
        let earlierUntimed = AgendaItem(title: "昨日未定时", date: date(2026, 10, 11), timeMinutes: nil)
        let olderUntimed = AgendaItem(title: "更早未定时", date: date(2026, 9, 22), timeMinutes: nil)
        let futureUntimed = AgendaItem(title: "明日未定时", date: date(2026, 10, 13), timeMinutes: nil)
        var completedUntimed = earlierUntimed; completedUntimed.id = UUID(); completedUntimed.completedDays = ["2026-10-11"]
        var repeatedUntimed = earlierUntimed; repeatedUntimed.id = UUID(); repeatedUntimed.repeatRule = .daily
        let earlierVisible = AgendaClock.earlierUnscheduled(items: [earlierUntimed, olderUntimed], now: now)
        try expect(earlierVisible.map(\.title) == ["更早未定时", "昨日未定时"], "earlier untimed carry-over visible oldest first")
        try expect(earlierVisible[1].day == earlierUntimed.date && earlierVisible[1].item.date == earlierUntimed.date && earlierVisible[1].due == nil, "carry-over preserves original date and remains untimed")
        try expect(AgendaClock.earlierUnscheduled(items: [undated, futureUntimed], now: now).isEmpty, "today and future untimed excluded from earlier section")
        try expect(AgendaClock.earlierUnscheduled(items: [completedUntimed], now: now).isEmpty, "completed earlier untimed excluded")
        try expect(AgendaClock.earlierUnscheduled(items: [twentyDaysOld, repeatedUntimed], now: now).isEmpty, "timed and repeating items excluded from earlier untimed")

        let dir = root.appendingPathComponent("persist")
        let store = AgendaStore(directory: dir, seedIfEmpty: false)
        try expect(store.items.isEmpty && !fm.fileExists(atPath: store.fileURL.path), "empty isolated store")
        try expect(store.upsert(daily), "save daily")
        try expect(store.upsert(undated), "save undated")
        var edit = undated; edit.title = "  改名  "; edit.note = "用户自己的备注"
        try expect(store.upsert(edit), "edit persistence")
        try expect(store.items.first(where: { $0.id == undated.id })?.title == "改名", "title trimmed")
        let reloaded = AgendaStore(directory: dir)
        try expect(reloaded.items.count == 2 && reloaded.items.contains(where: { $0.note == "用户自己的备注" }), "reload keeps edits no template replacement")
        let occurrence = store.occurrences(on: date(2026, 10, 13)).first!
        store.toggle(occurrence)
        try expect(store.occurrences(on: date(2026, 10, 13))[0].isCompleted, "toggle instance complete")
        try expect(store.occurrences(on: date())[0].isCompleted, "previous completed date preserved")
        store.undo()
        try expect(!store.occurrences(on: date(2026, 10, 13))[0].isCompleted, "undo complete persisted")
        let beforeSnooze = Date()
        store.snooze(store.occurrences(on: date(2026, 10, 13))[0], minutes: 15)
        let snooze = AgendaStore(directory: dir).items.first(where: { $0.id == daily.id })!.snoozes["2026-10-13"]!
        try expect(snooze >= beforeSnooze.addingTimeInterval(900) && snooze <= Date().addingTimeInterval(901), "snooze persisted from absolute now")
        try expect(store.occurrences(on: date(2026, 10, 13))[0].remindAt == snooze, "snooze determines next reminder")
        var changedTime = store.items.first(where: { $0.id == daily.id })!; changedTime.timeMinutes = 660
        try expect(store.upsert(changedTime) && store.items.first(where: { $0.id == daily.id })!.snoozes.isEmpty, "time edit clears old snooze")
        store.delete(undated.id)
        try expect(store.items.count == 1, "delete persisted")
        store.undo()
        try expect(AgendaStore(directory: dir).items.count == 2, "undo deletion persisted")
        let persisted = try Data(contentsOf: store.fileURL)
        var invalid = future; invalid.title = " \n "
        try expect(!store.upsert(invalid) && store.error != nil, "reject blank title")
        invalid = future; invalid.timeMinutes = 1440
        try expect(!store.upsert(invalid), "reject invalid minute")
        invalid.timeMinutes = -1
        try expect(!store.upsert(invalid), "reject negative minute")
        invalid = future; invalid.durationMinutes = -1
        try expect(!store.upsert(invalid), "reject negative duration")
        invalid = future; invalid.date = Date(timeIntervalSinceReferenceDate: .infinity)
        try expect(!store.upsert(invalid), "reject nonfinite date without calendar conversion")
        invalid = future; invalid.title = String(repeating: "字", count: 201)
        try expect(!store.upsert(invalid), "reject oversized title")
        invalid = future; invalid.note = String(repeating: "字", count: 2001)
        try expect(!store.upsert(invalid), "reject oversized note")
        invalid = future; invalid.snoozes["2026-10-12"] = Date(timeIntervalSinceReferenceDate: .infinity)
        try expect(!store.upsert(invalid), "reject nonfinite snooze")
        invalid = future; invalid.snoozes["2026-10-12"] = Date(timeIntervalSince1970: 253402272000)
        try expect(!store.upsert(invalid), "reject out of range snooze")
        try expect(try Data(contentsOf: store.fileURL) == persisted, "validation leaves persisted bytes intact")
        store.settings.leadMinutes = -1
        try expect(!store.save() && store.settings.leadMinutes == 10, "invalid settings rollback")
        store.settings.compact = true; store.settings.sound = false
        try expect(store.save(), "settings save")
        try expect(AgendaStore(directory: dir).settings.compact && !AgendaStore(directory: dir).settings.sound, "settings reload")

        let corruptDir = root.appendingPathComponent("corrupt")
        try fm.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptFile = corruptDir.appendingPathComponent("agenda.json")
        let corruptBytes = Data("{broken user file".utf8)
        try corruptBytes.write(to: corruptFile)
        let corrupt = AgendaStore(directory: corruptDir)
        try expect(corrupt.items.isEmpty && corrupt.error != nil, "corrupt load reports error no seeds")
        corrupt.resetError()
        try expect(!corrupt.upsert(future) && corrupt.error != nil, "resetError does not unlock corruption")
        try expect(try Data(contentsOf: corruptFile) == corruptBytes, "corrupt file not overwritten")
        try expect(corrupt.isDataLocked, "corrupt store exposes lock")
        try expect(corrupt.recoverCorruptFile() && !corrupt.isDataLocked, "explicit corrupt recovery unlocks only after save")
        try expect(corrupt.items.count == 9 && AgendaStore(directory: corruptDir).items.count == 9, "recovery template persisted")
        try expect(corrupt.recoveryBackupURL != nil && corrupt.recoveryBackupURL != corruptFile, "recovery backup path exposed")
        try expect(try Data(contentsOf: corrupt.recoveryBackupURL!) == corruptBytes, "recovery preserves exact corrupt source bytes")
        let recoveredBytes = try Data(contentsOf: corruptFile)
        try expect(!corrupt.recoverCorruptFile(), "healthy store rejects needless reconstruction")
        try expect(try Data(contentsOf: corruptFile) == recoveredBytes, "healthy recovery rejection preserves live bytes")
        let schemaDir = root.appendingPathComponent("schema")
        try fm.createDirectory(at: schemaDir, withIntermediateDirectories: true)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
        json["version"] = 999
        let schemaBytes = try JSONSerialization.data(withJSONObject: json)
        let schemaFile = schemaDir.appendingPathComponent("agenda.json")
        try schemaBytes.write(to: schemaFile)
        let unsupported = AgendaStore(directory: schemaDir)
        try expect(unsupported.error != nil && !unsupported.save(), "unsupported schema locked")
        try expect(try Data(contentsOf: schemaFile) == schemaBytes, "unsupported schema untouched")
        json["version"] = 1
        var badItems = json["items"] as! [[String: Any]]
        badItems[0]["timeMinutes"] = 1500
        json["items"] = badItems
        let invalidBytes = try JSONSerialization.data(withJSONObject: json)
        try invalidBytes.write(to: schemaFile)
        let invalidSchema = AgendaStore(directory: schemaDir)
        try expect(invalidSchema.error != nil && !invalidSchema.upsert(future), "invalid item schema locked")
        try expect(try Data(contentsOf: schemaFile) == invalidBytes, "invalid schema untouched")

        let restoreFile = root.appendingPathComponent("user-selected-backup.json")
        let restoreBytes = try Data(contentsOf: store.fileURL)
        try restoreBytes.write(to: restoreFile)
        try expect(corrupt.restore(from: restoreFile), "user-selected valid backup restored")
        try expect(corrupt.items == store.items && corrupt.settings == store.settings, "restore adopts exact backed up edits and settings")
        try expect(AgendaStore(directory: corruptDir).items == store.items, "restore persisted")
        try expect(try Data(contentsOf: corrupt.recoveryBackupURL!) == recoveredBytes, "restore first preserves current live bytes")
        let beforeRejectedRestore = try Data(contentsOf: corruptFile)
        let invalidBackup = root.appendingPathComponent("invalid-backup.json")
        try corruptBytes.write(to: invalidBackup)
        try expect(!corrupt.restore(from: invalidBackup), "malformed backup rejected")
        try expect(try Data(contentsOf: corruptFile) == beforeRejectedRestore, "malformed restore leaves live bytes intact")
        try expect(!corrupt.restore(from: schemaFile), "invalid schema backup rejected")
        try expect(try Data(contentsOf: corruptFile) == beforeRejectedRestore, "invalid schema restore leaves live bytes intact")
        try expect(invalidSchema.restore(from: restoreFile) && !invalidSchema.isDataLocked, "valid backup can recover locked store")
        try expect(try Data(contentsOf: invalidSchema.recoveryBackupURL!) == invalidBytes, "restore from lock preserves original invalid bytes")

        let failStore = AgendaStore(directory: root.appendingPathComponent("fail"), seedIfEmpty: false)
        try expect(failStore.upsert(future), "failure fixture saved")
        let saved = failStore.items
        try fm.removeItem(at: failStore.fileURL)
        try fm.createDirectory(at: failStore.fileURL, withIntermediateDirectories: true)
        try expect(!failStore.upsert(past) && failStore.items == saved && failStore.error != nil, "atomic write failure rolls back and reports")
        failStore.items.append(past); failStore.settings.compact = true
        try expect(!failStore.save() && failStore.items == saved && !failStore.settings.compact, "direct published mutations rollback on save failure")
        failStore.delete(future.id)
        try expect(failStore.items == saved, "failed delete never published")
        let seedStore = AgendaStore(directory: root.appendingPathComponent("seed"))
        try expect(seedStore.items.count == 9 && seedStore.error == nil, "seed initializes only empty new store")
        seedStore.delete(seedStore.items[0].id)
        try expect(AgendaStore(directory: seedStore.fileURL.deletingLastPathComponent()).items.count == 8, "deleted template not restored")

        let batchStore = AgendaStore(directory: root.appendingPathComponent("batch"), seedIfEmpty: false)
        try expect(batchStore.upsert(undated), "batch fixture initial item")
        let batchBefore = try Data(contentsOf: batchStore.fileURL)
        var batchInvalid = past; batchInvalid.title = ""
        try expect(!batchStore.upsertBatch([future, batchInvalid]), "invalid batch rejected before partial insertion")
        try expect(batchStore.items == [undated] && (try Data(contentsOf: batchStore.fileURL)) == batchBefore, "invalid batch leaves all state and bytes unchanged")
        try expect(!batchStore.upsertBatch([future, future]), "duplicate incoming IDs rejected")
        try expect((try Data(contentsOf: batchStore.fileURL)) == batchBefore, "duplicate batch preserves original bytes")
        var batchEdit = undated; batchEdit.title = " 批量改名 "; batchEdit.date = date(2026, 10, 12, 16)
        try expect(batchStore.upsertBatch([batchEdit, past, future]), "valid batch update and insert atomic")
        try expect(batchStore.items.count == 3 && batchStore.items.first(where: { $0.id == undated.id })?.title == "批量改名" && batchStore.items.first(where: { $0.id == undated.id })?.date == date(), "batch shares trimming and selected day normalization")
        try expect(AgendaStore(directory: batchStore.fileURL.deletingLastPathComponent()).items == batchStore.items, "batch all items persisted")
        batchStore.undo()
        try expect(batchStore.items == [undated] && AgendaStore(directory: batchStore.fileURL.deletingLastPathComponent()).items == [undated], "one undo reverses full batch and persists")

        let draftStore = AgendaStore(directory: root.appendingPathComponent("draft-state"), seedIfEmpty: false)
        var completionItem = future; completionItem.id = UUID()
        var snoozeItem = past; snoozeItem.id = UUID()
        try expect(draftStore.upsertBatch([completionItem, snoozeItem]), "stale draft fixtures")
        var completionDraft = completionItem
        draftStore.toggle(draftStore.occurrences(on: date()).first(where: { $0.item.id == completionItem.id })!)
        completionDraft.title = "编辑期间已经完成"
        try expect(draftStore.upsert(completionDraft), "save stale editor after live completion")
        try expect(draftStore.items.first(where: { $0.id == completionItem.id })!.completedDays == ["2026-10-12"], "stale editor preserves latest completion")
        var snoozeDraft = snoozeItem
        draftStore.snooze(draftStore.occurrences(on: date()).first(where: { $0.item.id == snoozeItem.id })!, minutes: 15)
        let liveSnooze = draftStore.items.first(where: { $0.id == snoozeItem.id })!.snoozes
        snoozeDraft.note = "编辑期间已经稍后提醒"
        try expect(draftStore.upsert(snoozeDraft), "save stale editor after live snooze")
        try expect(!liveSnooze.isEmpty && draftStore.items.first(where: { $0.id == snoozeItem.id })!.snoozes == liveSnooze, "stale editor preserves latest snooze")
        try expect(AgendaStore(directory: draftStore.fileURL.deletingLastPathComponent()).items == draftStore.items, "merged live states persisted")
        snoozeDraft.timeMinutes = 510
        try expect(draftStore.upsert(snoozeDraft) && draftStore.items.first(where: { $0.id == snoozeItem.id })!.snoozes.isEmpty, "stale time shift clears live old snooze")

        var completionBatchItem = completionItem; completionBatchItem.id = UUID()
        var snoozeBatchItem = snoozeItem; snoozeBatchItem.id = UUID()
        try expect(draftStore.upsertBatch([completionBatchItem, snoozeBatchItem]), "stale planner fixtures")
        var plannerDraft = [completionBatchItem, snoozeBatchItem]
        draftStore.toggle(draftStore.occurrences(on: date()).first(where: { $0.item.id == completionBatchItem.id })!)
        draftStore.snooze(draftStore.occurrences(on: date()).first(where: { $0.item.id == snoozeBatchItem.id })!, minutes: 30)
        let plannerLiveSnooze = draftStore.items.first(where: { $0.id == snoozeBatchItem.id })!.snoozes
        plannerDraft[0].title = "批量修改标题"
        plannerDraft[1].note = "批量修改备注"
        try expect(draftStore.upsertBatch(plannerDraft), "save stale planner after live state changes")
        try expect(draftStore.items.first(where: { $0.id == completionBatchItem.id })!.completedDays == ["2026-10-12"], "stale batch preserves completion")
        try expect(draftStore.items.first(where: { $0.id == snoozeBatchItem.id })!.snoozes == plannerLiveSnooze, "stale batch preserves snooze")
        plannerDraft[1].date = date(2026, 10, 13)
        try expect(draftStore.upsertBatch(plannerDraft) && draftStore.items.first(where: { $0.id == snoozeBatchItem.id })!.snoozes.isEmpty, "stale batch date shift clears old snooze")
        try postponementChecks(root: root)
        try pinnedOccurrenceChecks(root: root)
        try appearanceSettingsChecks(root: root)
        try checklistChecks(root: root)
        try captureChecks(root: root)
    }

    @MainActor static func postponementChecks(root: URL) throws {
        let store = AgendaStore(directory: root.appendingPathComponent("postponement"), seedIfEmpty: false)
        let now = date(2026, 10, 12, 20, 0)
        let original = AgendaItem(title: "结束工作", date: date(), timeMinutes: 18 * 60 + 30, repeatRule: .daily)
        try expect(store.upsert(original), "postponement fixture")
        let o = store.occurrences(on: now)[0]
        try expect(store.pinOccurrence(o), "pin original occurrence")
        store.snooze(o, minutes: 10)
        try expect(AgendaClock.overdue(items: store.items, now: now).count == 1 && store.occurrences(on: now)[0].due == date(2026, 10, 12, 18, 30), "reminder snooze does not move the event or due state")
        try expect(store.postpone(o, minutes: 30, now: now), "postpone an overdue occurrence from current time")
        let delayed = store.occurrences(on: now)[0]
        try expect(delayed.due == date(2026, 10, 12, 20, 30) && delayed.id == o.id && delayed.item.timeMinutes == original.timeMinutes, "postponement changes effective due, keeps original occurrence identity and repeat schedule")
        try expect(delayed.item.snoozes.isEmpty && AgendaClock.overdue(items: store.items, now: now).isEmpty, "postponement clears conflicting snooze and old due state")
        try expect(store.highlightedFocus(now: now)?.due == delayed.due && AgendaClock.next(items: store.items, now: now)?.id == o.id, "pinned hero and next event use effective time")
        try expect(store.occurrences(on: date(2026, 10, 13))[0].due == date(2026, 10, 13, 18, 30), "tomorrow's repeating event is unchanged")
        try expect(AgendaStore(directory: store.fileURL.deletingLastPathComponent()).items == store.items, "postponement persists and reloads")
        var actualEditorDraft = delayed.item; actualEditorDraft.timeMinutes = 21 * 60
        try expect(store.upsert(actualEditorDraft) && store.items[0].postponedTimes == nil, "editor carrying old override can move base time past postponed time")
        store.undo()
        actualEditorDraft = store.items[0]; actualEditorDraft.timeMinutes = nil
        try expect(store.upsert(actualEditorDraft) && store.items[0].postponedTimes == nil && store.items[0].timeMinutes == nil, "editor can turn timing off after postponement")
        store.undo()
        actualEditorDraft = store.items[0]; actualEditorDraft.date = date(2026, 10, 13)
        try expect(store.upsert(actualEditorDraft) && store.items[0].postponedTimes == nil, "editor can change anchor day after postponement")
        store.undo()
        var stale = original; stale.note = "stale editor note"
        try expect(store.upsert(stale) && store.occurrences(on: now)[0].due == delayed.due, "stale editor preserves the latest postponement")
        try expect(store.postpone(o, until: date(2026, 10, 13, 0, 10), now: now), "postpone across midnight")
        try expect(store.occurrences(on: now).isEmpty, "cross-midnight occurrence leaves original day's timeline")
        let tomorrow = store.occurrences(on: date(2026, 10, 13))
        try expect(tomorrow.count == 2 && tomorrow[0].id == o.id && tomorrow[0].day == date() && tomorrow[0].displayDay == date(2026, 10, 13), "moved occurrence coexists with tomorrow's repeat and keeps its completion date")
        let dayDrafts = store.editableDayItems(on: date(2026, 10, 13))
        try expect(dayDrafts.count == 1 && dayDrafts[0].id == original.id, "cross-day repeating occurrences produce one series editing draft")
        try expect(store.upsertBatch(dayDrafts) && store.occurrences(on: date(2026, 10, 13)).count == 2, "day planner can save without duplicating or losing cross-day occurrences")
        try expect(AgendaClock.occurrence(items: store.items, id: o.id)?.due == tomorrow[0].due && store.highlightedFocus(now: now)?.due == tomorrow[0].due, "cross-midnight original ID and pin resolve")
        try expect(AgendaClock.overdue(items: store.items, now: date(2026, 10, 13, 0, 11)).map(\.id) == [o.id], "prior repeat postponement becomes due on its new date")
        store.undo() // Undo the unchanged batch save, preserving the postponed time.
        store.toggle(tomorrow[0])
        try expect(store.occurrences(on: date(2026, 10, 13))[0].isCompleted && !store.occurrences(on: date(2026, 10, 13))[1].isCompleted, "completing moved occurrence does not complete tomorrow's repeat")
        let before = try Data(contentsOf: store.fileURL)
        try expect(!store.postpone(o, minutes: 30, now: now) && (try Data(contentsOf: store.fileURL)) == before, "completed event cannot be postponed")
        store.undo()
        try expect(!store.occurrences(on: date(2026, 10, 13))[0].isCompleted, "completion undo keeps postponement")
        store.undo()
        try expect(store.occurrences(on: now)[0].due == delayed.due, "postponement undo restores preceding time")
        stale.timeMinutes = 19 * 60
        try expect(store.upsert(stale) && store.items[0].postponedTimes == nil, "editing base time removes old overrides")
        let rejectionBytes = try Data(contentsOf: store.fileURL)
        for minutes in [0, -1, 1441] { try expect(!store.postpone(o, minutes: minutes, now: now), "reject invalid postponement interval") }
        try expect(!store.postpone(o, until: now, now: now) && !store.postpone(o, until: Date(timeIntervalSince1970: .nan), now: now), "reject old and nonfinite target times")
        try expect((try Data(contentsOf: store.fileURL)) == rejectionBytes, "failed postponements preserve bytes")
        var invalid = original; invalid.id = UUID(); invalid.postponedTimes = ["2026-10-12": date(2026, 10, 12, 18)]
        try expect(!store.upsert(invalid), "reject persisted postponement before original time")
        invalid.postponedTimes = ["2026-10-11": date(2026, 10, 12, 21)]
        try expect(!store.upsert(invalid), "reject override without a valid original occurrence")
        let checklist = AgendaItem(title: "独立清单", date: date(), reminderEnabled: false, checklistState: .pending)
        try expect(store.upsert(checklist), "checklist denial fixture")
        try expect(!store.postpone(Occurrence(item: checklist, day: date(), due: now), minutes: 10, now: now), "fake checklist occurrence cannot be postponed")
        var tentative = original; tentative.id = UUID(); tentative.repeatRule = .none; tentative.isTentative = true; tentative.reminderEnabled = false
        try expect(store.upsert(tentative), "tentative fixture")
        let tentativeO = store.occurrences(on: now).first { $0.item.id == tentative.id }!
        try expect(store.postpone(tentativeO, minutes: 10, now: now) && store.items.first { $0.id == tentative.id }!.isTentative && !store.items.first { $0.id == tentative.id }!.reminderEnabled, "postponement preserves tentative and silent state")
        let silentBytes = try Data(contentsOf: store.fileURL)
        store.snooze(tentativeO, minutes: 10)
        try expect((try Data(contentsOf: store.fileURL)) == silentBytes, "tentative event cannot create a misleading snooze")
        var longDelay = original; longDelay.id = UUID()
        longDelay.postponedTimes = ["2026-10-12": date(2026, 10, 20, 20)]
        try expect(AgendaClock.next(items: [longDelay], now: now)?.due == date(2026, 10, 13, 18, 30), "a far postponement cannot hide the nearer daily repeat")
    }

    @MainActor static func pinnedOccurrenceChecks(root: URL) throws {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("pinned")
        let store = AgendaStore(directory: dir, seedIfEmpty: false)
        let now = date(2026, 10, 12, 10)
        let next = AgendaItem(title: "午餐", date: date(), timeMinutes: 735)
        let later = AgendaItem(title: "晚餐", date: date(2026, 10, 13), timeMinutes: 1140)
        let overdue = AgendaItem(title: "上班", date: date(), timeMinutes: 540)
        let untimed = AgendaItem(title: "整理待办", date: date(2026, 10, 11), timeMinutes: nil)
        let daily = AgendaItem(title: "睡前回顾", date: date(), timeMinutes: 1380, repeatRule: .daily)
        try expect(store.upsertBatch([next, later, overdue, untimed, daily]), "pin fixtures persisted")
        let laterRow = store.occurrences(on: later.date).first(where: { $0.item.id == later.id })!
        let overdueRow = store.occurrences(on: overdue.date).first(where: { $0.item.id == overdue.id })!
        let untimedRow = store.occurrences(on: untimed.date).first!
        let itemsBefore = store.items
        let settingsBefore = store.settings
        try expect(store.highlightedOccurrence(now: now)?.item.id == next.id, "automatic highlight retains existing next behavior")
        try expect(store.pinOccurrence(laterRow) && store.isPinned(laterRow), "future non-next occurrence can be pinned")
        try expect(store.highlightedOccurrence(now: now)?.id == laterRow.id, "pinned future occurrence wins over earlier next")
        try expect(store.highlightedOccurrence(now: date(2026, 10, 14))?.id == laterRow.id, "time passing does not silently replace an overdue pin")
        try expect(store.items == itemsBefore, "pin changes no item data")
        var settingsWithPin = settingsBefore; settingsWithPin.pinnedOccurrenceID = laterRow.id
        try expect(store.settings == settingsWithPin, "pin preserves all unrelated settings")
        let restarted = AgendaStore(directory: dir, seedIfEmpty: false)
        try expect(restarted.isPinned(laterRow) && restarted.highlightedOccurrence(now: now)?.id == laterRow.id, "pin survives restart")
        let pinBytes = try Data(contentsOf: store.fileURL)
        try expect(store.pinOccurrence(laterRow) && (try Data(contentsOf: store.fileURL)) == pinBytes, "pin replay is idempotent")
        try expect(store.clearPinnedOccurrence() && store.settings == settingsBefore, "return to automatic only clears pin")
        try expect(store.items == itemsBefore && store.highlightedOccurrence(now: now)?.item.id == next.id, "cancel restores automatic and preserves items")
        try expect(AgendaStore(directory: dir).settings.pinnedOccurrenceID == nil, "cancel survives restart")
        store.undo()
        try expect(store.isPinned(laterRow), "undo cancel restores previous pinned snapshot")
        store.undo()
        try expect(store.settings.pinnedOccurrenceID == nil, "undo pin restores automatic without extra replay history")

        try expect(store.pinOccurrence(overdueRow) && store.highlightedOccurrence(now: now)?.id == overdueRow.id, "overdue incomplete occurrence can be pinned")
        try expect(store.pinOccurrence(untimedRow) && store.highlightedOccurrence(now: now)?.due == nil, "earlier untimed occurrence can be pinned without inventing a time")
        try expect(store.highlightedOccurrence(now: now)?.id == untimedRow.id, "untimed pin remains exact instance")
        store.toggle(untimedRow)
        try expect(store.settings.pinnedOccurrenceID == nil && store.highlightedOccurrence(now: now)?.item.id == next.id, "completing pin atomically returns to automatic")
        try expect(AgendaStore(directory: dir).settings.pinnedOccurrenceID == nil, "completion clears pin on disk")
        try expect(!store.pinOccurrence(untimedRow) && store.settings.pinnedOccurrenceID == nil, "stale incomplete snapshot cannot repin now completed occurrence")
        store.undo()
        try expect(store.isPinned(untimedRow) && !store.highlightedOccurrence(now: now)!.isCompleted, "undo completion restores pin and incomplete state together")
        store.delete(untimed.id)
        try expect(store.settings.pinnedOccurrenceID == nil && !store.items.contains(where: { $0.id == untimed.id }), "deleting pinned item clears pin")
        store.undo()
        try expect(store.isPinned(untimedRow) && AgendaStore(directory: dir).isPinned(untimedRow), "undo deletion restores item and pin on disk")

        let todayDaily = store.occurrences(on: date()).first(where: { $0.item.id == daily.id })!
        let tomorrowDaily = store.occurrences(on: date(2026, 10, 13)).first(where: { $0.item.id == daily.id })!
        try expect(store.pinOccurrence(tomorrowDaily) && !store.isPinned(todayDaily), "repeat pin selects only specified date")
        try expect(store.highlightedOccurrence(now: date(2026, 10, 14))?.id == tomorrowDaily.id, "repeat pin never follows next day")
        store.toggle(todayDaily)
        try expect(store.isPinned(tomorrowDaily), "completing another repeated date preserves pin")
        store.toggle(tomorrowDaily)
        try expect(store.settings.pinnedOccurrenceID == nil && !store.isPinned(tomorrowDaily), "completing pinned repeated date clears pin")
        store.undo()
        try expect(store.isPinned(tomorrowDaily), "undo repeated completion restores exact date pin")
        var edit = store.items.first(where: { $0.id == daily.id })!
        edit.timeMinutes = 1320; edit.title = "晚间回顾"
        try expect(store.upsert(edit) && store.isPinned(tomorrowDaily) && store.highlightedOccurrence(now: now)?.title == edit.title, "time and title changes preserve existing pinned date and use current item")
        edit.date = date(2026, 10, 14)
        try expect(store.upsert(edit) && store.settings.pinnedOccurrenceID == nil, "moving repeat anchor after pin clears missing instance")
        try expect(!store.pinOccurrence(tomorrowDaily), "old snapshot cannot pin missing repeated date")
        store.undo()
        try expect(store.isPinned(tomorrowDaily), "undo anchor move restores exact instance pin")
        edit = store.items.first(where: { $0.id == daily.id })!; edit.repeatRule = .none
        try expect(store.upsert(edit) && store.settings.pinnedOccurrenceID == nil, "removing repeat clears a non-anchor pin")
        store.undo()
        let saturday = store.occurrences(on: date(2026, 10, 17)).first(where: { $0.item.id == daily.id })!
        try expect(store.pinOccurrence(saturday), "daily Saturday instance can be pinned")
        edit = store.items.first(where: { $0.id == daily.id })!; edit.repeatRule = .weekdays
        try expect(store.upsert(edit) && store.settings.pinnedOccurrenceID == nil, "changing to weekdays clears pinned weekend instance")
        try expect(store.pinOccurrence(laterRow), "single-day pin fixture before reschedule")
        edit = store.items.first(where: { $0.id == later.id })!; edit.date = date(2026, 10, 14)
        try expect(store.upsert(edit) && store.settings.pinnedOccurrenceID == nil, "rescheduling single-day item clears old-date pin")
        let missing = Occurrence(item: AgendaItem(title: "未保存事项", date: date(), timeMinutes: nil), day: date(), due: nil)
        try expect(!store.pinOccurrence(missing) && !store.isPinned(missing), "unknown occurrence cannot be pinned")

        // This is the exact older document shape: every original settings field, no pin field.
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
        var legacySettings = legacy["settings"] as! [String: Any]
        legacySettings.removeValue(forKey: "pinnedOccurrenceID")
        legacy["settings"] = legacySettings
        let legacyDir = root.appendingPathComponent("legacy-no-pin")
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyFile = legacyDir.appendingPathComponent("agenda.json")
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacy)
        try legacyBytes.write(to: legacyFile)
        let old = AgendaStore(directory: legacyDir, seedIfEmpty: false)
        try expect(!old.isDataLocked && old.error == nil && old.items == store.items, "old document without pin field reads original items")
        try expect(old.settings == store.settings && old.settings.pinnedOccurrenceID == nil, "old document retains all settings and defaults to automatic")
        try expect(try Data(contentsOf: legacyFile) == legacyBytes, "reading compatible old document does not rewrite it")
        try expect(old.highlightedOccurrence(now: now)?.item.id == next.id, "old document uses automatic next")

        let invalidIDs = ["", "invalid", "\(next.id.uuidString):2026-02-30", "\(next.id.uuidString):2026-10-13", "\(UUID().uuidString):2026-10-12", "\(next.id.uuidString):9999999999-10-12", "\(next.id.uuidString):2026-1-12", "\(next.id.uuidString):2026-10-12:extra"]
        for (index, id) in invalidIDs.enumerated() {
            var invalidDocument = legacy
            var invalidSettings = legacySettings; invalidSettings["pinnedOccurrenceID"] = id
            invalidDocument["settings"] = invalidSettings
            let invalidDir = root.appendingPathComponent("stale-pin-\(index)")
            try fm.createDirectory(at: invalidDir, withIntermediateDirectories: true)
            let file = invalidDir.appendingPathComponent("agenda.json")
            try JSONSerialization.data(withJSONObject: invalidDocument).write(to: file)
            let stale = AgendaStore(directory: invalidDir, seedIfEmpty: false)
            try expect(!stale.isDataLocked && stale.error == nil && stale.items == store.items && stale.settings.pinnedOccurrenceID == nil, "invalid or stale pin \(index) clears without corrupting items")
            try expect(stale.highlightedOccurrence(now: now)?.item.id == next.id && AgendaStore(directory: invalidDir).settings.pinnedOccurrenceID == nil, "invalid or stale pin \(index) falls back and cleanup persists")
        }
        var completedDocument = legacy
        var completedSettings = legacySettings; completedSettings["pinnedOccurrenceID"] = todayDaily.id
        completedDocument["settings"] = completedSettings
        try JSONSerialization.data(withJSONObject: completedDocument).write(to: legacyFile)
        let completedPin = AgendaStore(directory: legacyDir, seedIfEmpty: false)
        try expect(completedPin.settings.pinnedOccurrenceID == nil && completedPin.items == store.items, "completed pin from disk is cleaned without changing completion data")
        if geteuid() != 0 {
            let cleanupDir = root.appendingPathComponent("pin-cleanup-write-failure")
            try fm.createDirectory(at: cleanupDir, withIntermediateDirectories: true)
            let cleanupFile = cleanupDir.appendingPathComponent("agenda.json")
            let cleanupBytes = try JSONSerialization.data(withJSONObject: completedDocument)
            try cleanupBytes.write(to: cleanupFile)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cleanupDir.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cleanupDir.path) }
            let cleanupFailed = AgendaStore(directory: cleanupDir, seedIfEmpty: false)
            try expect(!cleanupFailed.isDataLocked && cleanupFailed.error != nil && cleanupFailed.items == store.items, "stale pin cleanup failure retains readable item data and reports write error")
            try expect(!cleanupFailed.isPinned(todayDaily) && cleanupFailed.highlightedOccurrence(now: now)?.item.id == next.id && (try Data(contentsOf: cleanupFile)) == cleanupBytes, "stale pin cleanup failure shows automatic fallback and preserves original file")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cleanupDir.path)
            try expect(cleanupFailed.clearPinnedOccurrence() && AgendaStore(directory: cleanupDir).settings.pinnedOccurrenceID == nil, "stale pin cleanup can be retried after write target recovers")
        }
        var malformedPinDocument = legacy
        var malformedPinSettings = legacySettings; malformedPinSettings["pinnedOccurrenceID"] = true
        malformedPinDocument["settings"] = malformedPinSettings
        let malformedPinBytes = try JSONSerialization.data(withJSONObject: malformedPinDocument)
        try malformedPinBytes.write(to: legacyFile)
        let malformedPin = AgendaStore(directory: legacyDir, seedIfEmpty: false)
        try expect(malformedPin.isDataLocked && !malformedPin.save() && (try Data(contentsOf: legacyFile)) == malformedPinBytes, "wrong-type pin field protects malformed source instead of replacing it")

        let failDir = root.appendingPathComponent("pin-write-failure")
        let failed = AgendaStore(directory: failDir, seedIfEmpty: false)
        try expect(failed.upsertBatch([next, later]), "pin save failure fixtures")
        let liveLater = failed.occurrences(on: later.date).first!
        try fm.removeItem(at: failed.fileURL)
        try fm.createDirectory(at: failed.fileURL, withIntermediateDirectories: true)
        try expect(!failed.pinOccurrence(liveLater) && failed.error != nil && !failed.isPinned(liveLater), "failed pin write does not publish pinned state")
        try expect(failed.highlightedOccurrence(now: now)?.item.id == next.id, "failed pin write preserves automatic highlight")
        failed.settings.pinnedOccurrenceID = liveLater.id
        try expect(!failed.isPinned(liveLater) && failed.highlightedOccurrence(now: now)?.item.id == next.id, "unsaved settings mutation never reports pin success")
        try expect(!failed.save() && failed.settings.pinnedOccurrenceID == nil, "failed direct pin settings write rolls back")
        try fm.removeItem(at: failed.fileURL)
        try expect(failed.pinOccurrence(liveLater), "pin succeeds after write target is usable")
        let successfulBytes = try Data(contentsOf: failed.fileURL)
        let backup = root.appendingPathComponent("pinned-backup.json")
        try successfulBytes.write(to: backup)
        try fm.removeItem(at: failed.fileURL)
        try fm.createDirectory(at: failed.fileURL, withIntermediateDirectories: true)
        try expect(!failed.clearPinnedOccurrence() && failed.error != nil && failed.isPinned(liveLater), "failed cancel keeps last successfully saved pin")
        failed.toggle(liveLater)
        try expect(failed.isPinned(liveLater) && !failed.highlightedOccurrence(now: now)!.isCompleted, "failed completion preserves pin and incomplete state")
        failed.delete(later.id)
        try expect(failed.isPinned(liveLater) && failed.items.count == 2, "failed delete preserves item and pin")
        failed.undo()
        try expect(failed.isPinned(liveLater), "failed undo does not consume pinned snapshot")
        try fm.removeItem(at: failed.fileURL)
        failed.undo()
        try expect(failed.settings.pinnedOccurrenceID == nil && failed.items.count == 2, "retry undo reverses successful pin only")
        try expect(failed.restore(from: backup) && failed.isPinned(liveLater) && AgendaStore(directory: failDir).isPinned(liveLater), "restore retains valid persisted pin")

        let corruptDir = root.appendingPathComponent("pin-corrupt")
        try fm.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptFile = corruptDir.appendingPathComponent("agenda.json")
        let corruptBytes = Data("{broken pin file".utf8)
        try corruptBytes.write(to: corruptFile)
        let locked = AgendaStore(directory: corruptDir, seedIfEmpty: false)
        try expect(!locked.pinOccurrence(laterRow) && !locked.clearPinnedOccurrence() && locked.isDataLocked, "pin actions cannot unlock corrupt document")
        try expect(locked.highlightedOccurrence(now: now) == nil && (try Data(contentsOf: corruptFile)) == corruptBytes, "pin actions preserve corrupt bytes and do not create template")
    }

    @MainActor static func checklistChecks(root: URL) throws {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("checklist")
        let store = AgendaStore(directory: dir, seedIfEmpty: false)
        let legacyItems = AgendaClock.seed() + [AgendaItem(title: "某天未定时", date: date(), timeMinutes: nil)]
        try expect(store.upsertBatch(legacyItems), "checklist legacy fixture saved")
        let legacyBytes = try Data(contentsOf: store.fileURL)
        let old = AgendaStore(directory: dir, seedIfEmpty: false)
        try expect(!old.isDataLocked && old.items == legacyItems && old.checklistItems(includeCompleted: true).isEmpty, "old documents without checklistState remain date arrangements")
        try expect((try Data(contentsOf: store.fileURL)) == legacyBytes && old.items.allSatisfy { !$0.isChecklist && $0.scheduledDay == $0.date }, "legacy checklist read does not migrate dates or rewrite data")
        try expect(store.addChecklistItem(title: "  买滤芯  ", note: "来源备注"), "title-only checklist adds")
        let a = store.checklistItems()[0]
        try expect(a.title == "买滤芯" && a.note == "来源备注" && a.checklistState == .pending && a.scheduledDay == nil, "checklist trims title and has no scheduled date")
        try expect(a.timeMinutes == nil && a.durationMinutes == 0 && a.repeatRule == .none && !a.reminderEnabled && !a.isTentative && a.completedDays.isEmpty && a.snoozes.isEmpty, "new checklist has no timing reminder repeat or date completion state")
        let between = AgendaItem(title: "明日未定时", date: date(2026, 10, 13), timeMinutes: nil)
        try expect(store.upsert(between) && store.addChecklistItem(title: "看合同") && store.addChecklistItem(title: "订车票"), "mixed checklist and agenda fixture saved")
        let b = store.checklistItems()[1], c = store.checklistItems()[2]
        let focusA = AgendaFocus.checklist(a)
        try expect(focusA.id == "checklist:\(a.id.uuidString)" && focusA.item == a && focusA.title == a.title && focusA.day == nil && focusA.due == nil && focusA.occurrence == nil && focusA.isChecklist && !focusA.isCompleted, "checklist focus exposes identity without invented date or countdown")
        let scheduledRow = store.occurrences(on: date())[0]
        let scheduledFocus = AgendaFocus.scheduled(scheduledRow)
        try expect(scheduledFocus.id == scheduledRow.id && scheduledFocus.item == scheduledRow.item && scheduledFocus.day == scheduledRow.day && scheduledFocus.due == scheduledRow.due && scheduledFocus.occurrence?.id == scheduledRow.id && !scheduledFocus.isChecklist, "scheduled focus retains existing occurrence properties")
        let listBeforeDays = store.checklistItems()
        store.selectedDay = date(2026, 10, 14)
        try expect(store.checklistItems() == listBeforeDays && AgendaStore(directory: dir).checklistItems() == listBeforeDays, "day changes and restart preserve undated checklist order and state")
        for day in [date(2026, 10, 11), date(), date(2026, 10, 13), a.date] {
            try expect(!store.occurrences(on: day).contains(where: { $0.item.isChecklist }), "checklist never produces date occurrences")
        }
        try expect(AgendaClock.next(items: listBeforeDays, now: date()) == nil && AgendaClock.overdue(items: listBeforeDays, now: date(2026, 10, 20)).isEmpty && AgendaClock.earlierUnscheduled(items: listBeforeDays, now: date(2026, 10, 20)).isEmpty, "checklist does not produce future overdue or earlier-unscheduled candidates")
        var forgedTimed = a; forgedTimed.timeMinutes = 540; forgedTimed.repeatRule = .daily; forgedTimed.reminderEnabled = true
        try expect(AgendaClock.occurrences(items: [forgedTimed], on: a.date).isEmpty && AgendaClock.next(items: [forgedTimed], now: a.date) == nil && AgendaClock.overdue(items: [forgedTimed], now: a.date.addingTimeInterval(86400)).isEmpty, "Clock excludes checklist even if passed malformed timing state directly")
        let fake = Occurrence(item: forgedTimed, day: a.date, due: a.date.addingTimeInterval(3600))
        try expect(fake.remindAt == nil, "forged checklist occurrence has no notification candidate")
        let beforeFake = try Data(contentsOf: store.fileURL)
        store.toggle(fake); store.snooze(fake, minutes: 10)
        try expect(!store.pinOccurrence(fake) && store.items.first(where: { $0.id == a.id }) == a && (try Data(contentsOf: store.fileURL)) == beforeFake, "fake checklist occurrence cannot complete snooze or pin date state")

        let timedBefore = store.occurrences(on: date()).map(\.id)
        try expect(store.setChecklistCompleted(b.id, completed: true), "checklist completion saves")
        let beforeMove = store.items
        try expect(store.moveChecklistItem(c.id, by: -1) && store.checklistItems().map(\.id) == [c.id, a.id], "move swaps adjacent pending checklist items across completed or agenda rows")
        let swappedIndices = [beforeMove.firstIndex(where: { $0.id == a.id })!, beforeMove.firstIndex(where: { $0.id == c.id })!]
        try expect(beforeMove.indices.filter { !swappedIndices.contains($0) }.allSatisfy { beforeMove[$0] == store.items[$0] } && store.occurrences(on: date()).map(\.id) == timedBefore, "checklist reordering changes only two stored indices and leaves agenda display order unchanged")
        try expect(AgendaStore(directory: dir).checklistItems().map(\.id) == [c.id, a.id], "checklist order survives restart")
        store.undo()
        try expect(store.items == beforeMove && store.checklistItems().map(\.id) == [a.id, c.id], "undo move restores array positions")
        let boundaryBytes = try Data(contentsOf: store.fileURL)
        try expect(!store.moveChecklistItem(a.id, by: -1) && !store.moveChecklistItem(c.id, by: 1) && !store.moveChecklistItem(a.id, by: 0) && !store.moveChecklistItem(a.id, by: Int.max), "move rejects list bounds and unsupported offsets")
        try expect(!store.moveChecklistItem(b.id, by: -1) && !store.moveChecklistItem(between.id, by: 1) && (try Data(contentsOf: store.fileURL)) == boundaryBytes, "move cannot reorder completed checklist or date arrangements")
        let visibleIdentities = store.checklistItems().map(\.id)
        try expect(Array(visibleIdentities.enumerated()).map { $0.offset + 1 } == [1, 2] && visibleIdentities == [a.id, c.id], "display numbering derives from pending order and never rewrites UUIDs")
        try expect(store.checklistItems(includeCompleted: true).map(\.id) == [a.id, b.id, c.id], "completed checklist remains available in stored order")
        try expect(AgendaFocus.checklist(store.checklistItems(includeCompleted: true)[1]).isCompleted, "completed checklist focus reflects global checklist completion")

        var staleDraft = a
        try expect(store.setChecklistCompleted(a.id, completed: true), "checklist completion before stale edit")
        staleDraft.title = "买新的滤芯"; staleDraft.date = date(2026, 10, 20)
        try expect(store.upsert(staleDraft) && store.items.first(where: { $0.id == a.id })!.checklistState == .completed && store.items.first(where: { $0.id == a.id })!.date == a.date, "same-type stale draft preserves live checklist completion and creation anchor")
        var staleBatchA = staleDraft; staleBatchA.note = "批量草稿修改"
        try expect(store.upsertBatch([staleBatchA, b]) && store.items.first(where: { $0.id == a.id })!.checklistState == .completed && store.items.first(where: { $0.id == b.id })!.checklistState == .completed, "batch stale checklist drafts preserve each current completion state")
        let completedBytes = try Data(contentsOf: store.fileURL)
        try expect(store.setChecklistCompleted(a.id, completed: true) && (try Data(contentsOf: store.fileURL)) == completedBytes, "setting existing checklist completion is idempotent")
        store.toggle(AgendaFocus.checklist(staleDraft))
        try expect(store.items.first(where: { $0.id == a.id })!.checklistState == .pending, "focus toggle uses current checklist state instead of stale draft state")
        store.undo()
        try expect(store.items.first(where: { $0.id == a.id })!.checklistState == .completed, "undo checklist restore returns global completed state")
        try expect(store.setChecklistCompleted(a.id, completed: false), "explicit checklist restore saves")
        try expect(store.highlightedFocus(now: date(2026, 10, 12, 6))?.isChecklist == false, "automatic timed next takes priority over pending checklist")
        try expect(store.pinChecklistItem(c.id) && store.isPinned(AgendaFocus.checklist(c)), "pending checklist can be pinned")
        try expect(store.highlightedFocus(now: date(2026, 10, 12, 6))?.id == AgendaFocus.checklist(c).id && store.highlightedFocus(now: date(2026, 10, 30))?.id == AgendaFocus.checklist(c).id, "pinned checklist overrides timed next and survives across days")
        try expect(AgendaStore(directory: dir).isPinned(AgendaFocus.checklist(c)), "checklist pin survives restart without stale cleanup")
        try expect(store.highlightedOccurrence(now: date(2026, 10, 12, 6))?.due != nil, "legacy highlightedOccurrence retains scheduled-only API")
        try expect(store.setChecklistCompleted(c.id, completed: true) && store.settings.pinnedOccurrenceID == nil, "completing pinned checklist clears pin atomically")
        try expect(!store.pinChecklistItem(c.id) && !store.isPinned(AgendaFocus.checklist(c)), "completed checklist cannot be pinned")
        store.undo()
        try expect(store.isPinned(AgendaFocus.checklist(c)) && store.items.first(where: { $0.id == c.id })!.checklistState == .pending, "undo completion restores checklist pin and pending state")
        store.delete(c.id)
        try expect(store.settings.pinnedOccurrenceID == nil && !store.checklistItems().contains(where: { $0.id == c.id }), "deleting pinned checklist clears fixed target")
        store.undo()
        try expect(store.isPinned(AgendaFocus.checklist(c)) && store.checklistItems().map(\.id).last == c.id, "undo deletion restores checklist position and pin")

        var scheduling = c
        scheduling.title = "  订返程车票  "; scheduling.date = date(2026, 10, 13, 15)
        scheduling.timeMinutes = 900; scheduling.durationMinutes = 25; scheduling.category = "出行"
        scheduling.note = "安排备注"; scheduling.isTentative = true; scheduling.reminderEnabled = true; scheduling.repeatRule = .weekdays
        scheduling.completedDays = ["invalid stale state"]; scheduling.snoozes = ["invalid": Date(timeIntervalSince1970: .nan)]
        let beforeSchedule = store.items
        try expect(store.scheduleChecklistItem(scheduling), "pending checklist schedules same UUID atomically")
        let scheduled = store.items.first(where: { $0.id == c.id })!
        try expect(store.items.count == beforeSchedule.count && scheduled.id == c.id && !scheduled.isChecklist && scheduled.date == date(2026, 10, 13), "schedule converts same item without a duplicate and normalizes chosen day")
        try expect(scheduled.title == "订返程车票" && scheduled.timeMinutes == 900 && scheduled.durationMinutes == 25 && scheduled.category == "出行" && scheduled.note == "安排备注" && scheduled.isTentative && scheduled.reminderEnabled && scheduled.repeatRule == .weekdays && scheduled.completedDays.isEmpty && scheduled.snoozes.isEmpty, "schedule retains selected arrangement fields and clears checklist date states")
        try expect(store.settings.pinnedOccurrenceID == nil && !store.checklistItems(includeCompleted: true).contains(where: { $0.id == c.id }) && store.items.filter { $0.id != c.id } == beforeSchedule.filter { $0.id != c.id }, "schedule removes checklist fixed target and changes only this item")
        let afterScheduleBytes = try Data(contentsOf: store.fileURL)
        try expect(!store.upsert(c) && !store.setChecklistCompleted(c.id, completed: true) && !store.pinChecklistItem(c.id), "old checklist drafts and actions cannot convert scheduled item back or complete it globally")
        store.toggle(AgendaFocus.checklist(c))
        try expect((try Data(contentsOf: store.fileURL)) == afterScheduleBytes && store.items.first(where: { $0.id == c.id }) == scheduled, "stale checklist focus cannot toggle a converted date arrangement")
        var dateDraft = scheduled
        let currentOccurrence = store.occurrences(on: scheduled.date).first(where: { $0.item.id == c.id })!
        store.toggle(currentOccurrence); dateDraft.note = "日期草稿修改"
        try expect(store.upsert(dateDraft) && store.items.first(where: { $0.id == c.id })!.completedDays.contains("2026-10-13"), "same-type date draft after conversion preserves live date completion")
        store.undo(); store.undo(); store.undo()
        try expect(store.items == beforeSchedule && store.isPinned(AgendaFocus.checklist(c)), "undo scheduling restores original checklist object order and fixed target")
        try expect(store.setChecklistCompleted(c.id, completed: true) && !store.scheduleChecklistItem(scheduling), "completed checklist cannot be scheduled until explicitly restored")
        try expect(store.setChecklistCompleted(c.id, completed: false), "completed checklist explicitly restored before schedule")
        var dateOnly = c; dateOnly.date = date(2026, 10, 14); dateOnly.reminderEnabled = true
        try expect(store.scheduleChecklistItem(dateOnly) && store.items.first(where: { $0.id == c.id })!.timeMinutes == nil && !store.items.first(where: { $0.id == c.id })!.reminderEnabled, "date-only schedule forcibly disables reminder even if incoming draft enables it")
        let dateOnlyRow = store.occurrences(on: dateOnly.date).first(where: { $0.item.id == c.id })!
        try expect(dateOnlyRow.due == nil && dateOnlyRow.remindAt == nil && !dateOnlyRow.item.isChecklist, "date-only conversion is dated untimed arrangement without reminder candidate")
        store.undo()
        var silentConversion = between; silentConversion.checklistState = .pending; silentConversion.reminderEnabled = false
        var inverseConversion = a; inverseConversion.checklistState = nil
        let beforeConversions = try Data(contentsOf: store.fileURL)
        try expect(!store.upsert(silentConversion) && !store.upsert(inverseConversion) && (try Data(contentsOf: store.fileURL)) == beforeConversions, "ordinary upsert cannot silently convert either existing type")
        var validEditBeforeInvalidConversion = a; validEditBeforeInvalidConversion.title = "不应部分保存"
        try expect(!store.upsertBatch([validEditBeforeInvalidConversion, silentConversion]) && (try Data(contentsOf: store.fileURL)) == beforeConversions, "batch type conversion rejection does not partially publish earlier valid edit")
        var invalidSchedule = c; invalidSchedule.timeMinutes = -1
        try expect(!store.scheduleChecklistItem(invalidSchedule) && store.items.first(where: { $0.id == c.id })!.isChecklist, "invalid schedule preserves original checklist")

        var invalidLists: [AgendaItem] = []
        var invalid = a; invalid.id = UUID(); invalid.timeMinutes = 1; invalidLists.append(invalid)
        invalid = a; invalid.id = UUID(); invalid.durationMinutes = 1; invalidLists.append(invalid)
        invalid = a; invalid.id = UUID(); invalid.repeatRule = .daily; invalidLists.append(invalid)
        invalid = a; invalid.id = UUID(); invalid.reminderEnabled = true; invalidLists.append(invalid)
        invalid = a; invalid.id = UUID(); invalid.isTentative = true; invalidLists.append(invalid)
        invalid = a; invalid.id = UUID(); invalid.completedDays = ["2026-10-12"]; invalidLists.append(invalid)
        invalid = a; invalid.id = UUID(); invalid.snoozes = ["2026-10-12": date()]; invalidLists.append(invalid)
        let beforeInvalid = try Data(contentsOf: store.fileURL)
        for invalidList in invalidLists { try expect(!store.upsert(invalidList), "invalid checklist state combination rejected") }
        try expect(!store.addChecklistItem(title: "  ") && (try Data(contentsOf: store.fileURL)) == beforeInvalid, "invalid checklist input preserves file bytes")

        let onlyDir = root.appendingPathComponent("checklist-only")
        let only = AgendaStore(directory: onlyDir, seedIfEmpty: false)
        try expect(only.addChecklistItem(title: "第一项") && only.addChecklistItem(title: "第二项"), "checklist-only automatic fixtures")
        let onlyFirst = only.checklistItems()[0], onlySecond = only.checklistItems()[1]
        try expect(only.highlightedFocus(now: date())?.id == AgendaFocus.checklist(onlyFirst).id, "automatic focus falls back to first pending checklist")
        try expect(only.setChecklistCompleted(onlyFirst.id, completed: true) && only.highlightedFocus(now: date(2026, 10, 30))?.id == AgendaFocus.checklist(onlySecond).id, "automatic fallback skips globally completed checklist across days")
        try expect(only.setChecklistCompleted(onlySecond.id, completed: true) && only.highlightedFocus(now: date()) == nil, "completed-only checklist yields no unfinished focus")
        try expect(only.setChecklistCompleted(onlyFirst.id, completed: false) && only.pinChecklistItem(onlyFirst.id) && only.clearPinnedOccurrence() && !only.isPinned(AgendaFocus.checklist(onlyFirst)), "manual automatic mode clears checklist pin through existing API")
        try expect(only.upsert(between), "dated untimed and independent checklist coexist")
        let untimedFocus = AgendaFocus.scheduled(only.occurrences(on: between.date)[0])
        try expect(only.pinOccurrence(untimedFocus.occurrence!) && only.isPinned(untimedFocus) && only.highlightedFocus(now: date())?.id == untimedFocus.id, "existing dated untimed pin still outranks checklist fallback")
        try expect(only.clearPinnedOccurrence(), "dated untimed pin can return to automatic")
        let pinPrefixFile = only.fileURL
        var staleDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: pinPrefixFile)) as! [String: Any]
        var staleSettings = staleDocument["settings"] as! [String: Any]
        for id in ["checklist:invalid", "checklist:\(UUID().uuidString)", AgendaFocus.checklist(onlySecond).id, "checklist:\(between.id.uuidString)"] {
            staleSettings["pinnedOccurrenceID"] = id; staleDocument["settings"] = staleSettings
            try JSONSerialization.data(withJSONObject: staleDocument).write(to: pinPrefixFile)
            let stale = AgendaStore(directory: onlyDir)
            try expect(!stale.isDataLocked && stale.settings.pinnedOccurrenceID == nil && stale.items == only.items && stale.highlightedFocus(now: date())?.id == AgendaFocus.checklist(onlyFirst).id, "invalid missing or completed checklist pins clear and fall back without changing items")
        }

        let failDir = root.appendingPathComponent("checklist-failure")
        let failed = AgendaStore(directory: failDir, seedIfEmpty: false)
        try expect(failed.addChecklistItem(title: "失败保留一") && failed.addChecklistItem(title: "失败保留二"), "checklist write failure fixtures")
        let failFirst = failed.checklistItems()[0]
        try expect(failed.pinChecklistItem(failFirst.id), "checklist write failure pin baseline")
        let failedItems = failed.items, failedSettings = failed.settings
        try fm.removeItem(at: failed.fileURL); try fm.createDirectory(at: failed.fileURL, withIntermediateDirectories: true)
        var failSchedule = failFirst; failSchedule.date = date(2026, 10, 13); failSchedule.timeMinutes = 540; failSchedule.reminderEnabled = true
        try expect(!failed.addChecklistItem(title: "不能保存") && !failed.setChecklistCompleted(failFirst.id, completed: true) && !failed.moveChecklistItem(failFirst.id, by: 1) && !failed.scheduleChecklistItem(failSchedule), "write failure rejects add complete reorder and schedule")
        try expect(!failed.pinChecklistItem(failed.checklistItems()[1].id) && !failed.clearPinnedOccurrence() && failed.error != nil && failed.items == failedItems && failed.settings == failedSettings, "write failures retain last successful checklist state and pin")
        failed.delete(failFirst.id); failed.undo()
        try expect(failed.items == failedItems && failed.isPinned(AgendaFocus.checklist(failFirst)), "failed delete or undo does not publish lost checklist data")
        try fm.removeItem(at: failed.fileURL)
        failed.undo()
        try expect(failed.items == failedItems && failed.settings.pinnedOccurrenceID == nil, "undo retries last successful pin instead of consuming failed history")

        let corruptDir = root.appendingPathComponent("checklist-corrupt")
        try fm.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptFile = corruptDir.appendingPathComponent("agenda.json")
        var malformed = try JSONSerialization.jsonObject(with: Data(contentsOf: failed.fileURL)) as! [String: Any]
        var malformedItems = malformed["items"] as! [[String: Any]]
        for state: Any in [true, "unknown-state"] {
            malformedItems[0]["checklistState"] = state; malformed["items"] = malformedItems
            let bytes = try JSONSerialization.data(withJSONObject: malformed)
            try bytes.write(to: corruptFile)
            let corrupt = AgendaStore(directory: corruptDir)
            try expect(corrupt.isDataLocked && !corrupt.addChecklistItem(title: "不得覆盖") && (try Data(contentsOf: corruptFile)) == bytes, "wrong-type or unknown checklist state locks and preserves malformed source")
        }
        malformedItems[0]["checklistState"] = "pending"; malformedItems[0]["timeMinutes"] = 540
        malformed["items"] = malformedItems
        let invalidCombinationBytes = try JSONSerialization.data(withJSONObject: malformed)
        try invalidCombinationBytes.write(to: corruptFile)
        let invalidCombination = AgendaStore(directory: corruptDir)
        try expect(invalidCombination.isDataLocked && !invalidCombination.save() && (try Data(contentsOf: corruptFile)) == invalidCombinationBytes, "invalid checklist timing combination from disk locks and preserves source")
    }

    @MainActor static func captureChecks(root: URL) throws {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("capture")
        let store = AgendaStore(directory: dir, seedIfEmpty: false)
        try expect(store.upsertBatch(AgendaClock.seed()) && store.addChecklistItem(title: "已有清单"), "capture existing agenda and checklist fixtures")
        store.settings.appearanceMode = .dark; store.settings.accentColor = .purple
        try expect(store.save(), "capture existing appearance settings fixture")
        let legacyItems = store.items, legacySettings = store.settings
        let legacyBytes = try Data(contentsOf: store.fileURL)
        let oldBackup = root.appendingPathComponent("capture-old-backup.json")
        try legacyBytes.write(to: oldBackup)
        let old = AgendaStore(directory: dir, seedIfEmpty: false)
        try expect(!old.isDataLocked && old.items == legacyItems && old.settings == legacySettings && (try Data(contentsOf: old.fileURL)) == legacyBytes, "old document without captureReceipts reads unchanged agenda checklist and appearance")
        let now = date(2026, 10, 12, 13)
        let request = AgendaCaptureRequest(requestID: "req-1", title: "  买滤芯  ", source: " HERMES ")
        let normalized = try request.normalized()
        try expect(normalized.title == "买滤芯" && normalized.source == "hermes" && normalized.durationMinutes == 0, "capture request normalizes title source and default duration")
        try expect(normalized.fingerprint == "6b266120850e95a2b421604f646e7db3c70b868281e1038cc667ec7818917dec", "capture fingerprint matches stable sorted JSON SHA256 fixture")
        var explicitNoRepeat = request; explicitNoRepeat.repeatRule = RepeatRule.none
        try expect(explicitNoRepeat.fingerprint == normalized.fingerprint, "explicit repeat none preserves historical capture fingerprint")
        let created = store.capture(request, now: now)
        try expect(created.ok && created.status == "created" && created.requestID == request.requestID && created.itemID != nil && created.itemExists == true && created.error == nil, "capture returns created receipt only after save")
        let captured = store.items.first(where: { $0.id == created.itemID })!
        try expect(captured.title == "买滤芯" && captured.checklistState == .pending && captured.scheduledDay == nil && !captured.reminderEnabled && captured.date == date(), "undated capture is checklist with creation anchor and no reminder")
        try expect(store.items.filter { $0.id != captured.id } == legacyItems && store.settings == legacySettings, "capture preserves existing agenda checklist and appearance settings")
        let firstBytes = try Data(contentsOf: store.fileURL)
        let firstJSON = try JSONSerialization.jsonObject(with: firstBytes) as! [String: Any]
        let firstReceipts = firstJSON["captureReceipts"] as! [String: Any]
        let firstReceipt = firstReceipts[request.requestID] as! [String: Any]
        try expect(firstReceipt["fingerprint"] as? String == normalized.fingerprint && firstReceipt["itemID"] as? String == captured.id.uuidString && firstReceipt["source"] as? String == "hermes", "capture persists fingerprint UUID and source in same document")
        let receipt = try JSONDecoder().decode(AgendaCaptureReceipt.self, from: JSONSerialization.data(withJSONObject: firstReceipt))
        try expect(receipt.createdAt == now, "capture receipt uses supplied creation instant")
        var equivalent = normalized; equivalent.note = ""; equivalent.durationMinutes = nil
        let repeated = store.capture(equivalent, now: date(2026, 10, 30))
        try expect(repeated.ok && repeated.status == "already_processed" && repeated.itemID == captured.id && repeated.itemExists == true && store.items.count == legacyItems.count + 1, "same normalized request returns existing item without duplication")
        try expect((try Data(contentsOf: store.fileURL)) == firstBytes, "equivalent replay performs no write")
        try expect(store.capture(explicitNoRepeat, now: now).status == "already_processed" && (try Data(contentsOf: store.fileURL)) == firstBytes, "upgraded explicit none replays legacy receipt without conflict or write")
        var differentID = normalized; differentID.requestID = "different-id"
        try expect(differentID.fingerprint == normalized.fingerprint, "request ID is excluded from payload fingerprint")
        var conflict = normalized; conflict.title = "买另一个滤芯"
        let rejected = store.capture(conflict, now: now)
        try expect(!rejected.ok && rejected.status == "conflict" && rejected.error != nil && (try Data(contentsOf: store.fileURL)) == firstBytes, "same request ID with different payload conflicts without writing")
        var payloadConflicts: [AgendaCaptureRequest] = []
        conflict = normalized; conflict.note = "不同备注"; payloadConflicts.append(conflict)
        conflict = normalized; conflict.source = "cli"; payloadConflicts.append(conflict)
        conflict = normalized; conflict.date = "2026-10-13"; payloadConflicts.append(conflict)
        conflict = normalized; conflict.date = "2026-10-13"; conflict.time = "09:00"; payloadConflicts.append(conflict)
        conflict.durationMinutes = 30; payloadConflicts.append(conflict)
        for payloadConflict in payloadConflicts {
            try expect(store.capture(payloadConflict, now: now).status == "conflict" && (try Data(contentsOf: store.fileURL)) == firstBytes, "fingerprint includes every normalized content field and rejects changed replay")
        }
        let restart = AgendaStore(directory: dir)
        try expect(restart.capture(request, now: now).status == "already_processed" && restart.items.count == store.items.count, "capture deduplication survives restart")
        store.undo()
        try expect(store.items == legacyItems && store.capture(request, now: now).status == "already_processed" && store.capture(request, now: now).itemExists == false, "undo capture preserves tombstone and replay does not resurrect item")
        try expect(AgendaStore(directory: dir).capture(request).itemExists == false, "undo capture tombstone survives restart")

        let preservedNote = "  原备注\n第二行  "
        let dateRequest = AgendaCaptureRequest(requestID: "date-only", title: "领资料", note: preservedNote, date: " 2026-10-13 ")
        let dateResult = store.capture(dateRequest, now: now)
        let dated = store.items.first(where: { $0.id == dateResult.itemID })!
        try expect(dateResult.ok && !dated.isChecklist && dated.date == date(2026, 10, 13) && dated.timeMinutes == nil && !dated.reminderEnabled && dated.note == preservedNote, "date-only capture creates dated untimed item and preserves note text")
        let timeRequest = AgendaCaptureRequest(requestID: "at-time", title: "面谈", date: "2026-10-13", time: " 09:05 ", durationMinutes: 60, source: "cli")
        let timeResult = store.capture(timeRequest, now: now)
        let timed = store.items.first(where: { $0.id == timeResult.itemID })!
        try expect(timeResult.ok && timed.date == date(2026, 10, 13) && timed.timeMinutes == 545 && timed.durationMinutes == 60 && timed.reminderEnabled && !timed.isTentative && timed.repeatRule == .none && !timed.isChecklist, "dated timed capture creates confirmed schedule with existing reminder behavior")
        let recurringStore = AgendaStore(directory: root.appendingPathComponent("capture-recurring"), seedIfEmpty: false)
        let dailyRequest = AgendaCaptureRequest(requestID: "daily-recite", title: "每日复习", date: "2026-10-13", time: "09:00", durationMinutes: 30, source: "hermes", repeatRule: .daily)
        let dailyResult = recurringStore.capture(dailyRequest, now: now)
        try expect(dailyResult.ok && recurringStore.items.first?.repeatRule == .daily && recurringStore.items.first?.durationMinutes == 30 && recurringStore.items.first?.timeMinutes == 540, "daily capture preserves repetition explicit time and half-hour duration")
        try expect(AgendaClock.occurrences(items: recurringStore.items, on: date(2026, 10, 14)).count == 1 && AgendaClock.occurrences(items: recurringStore.items, on: date(2026, 10, 12)).isEmpty, "captured daily schedule repeats from explicit anchor only")
        let recurringBytes = try Data(contentsOf: recurringStore.fileURL)
        try expect(recurringStore.capture(dailyRequest, now: now).status == "already_processed" && (try Data(contentsOf: recurringStore.fileURL)) == recurringBytes, "daily capture retry is idempotent with no write")
        var weekdaysRequest = dailyRequest; weekdaysRequest.repeatRule = .weekdays
        try expect(weekdaysRequest.fingerprint != dailyRequest.fingerprint && recurringStore.capture(weekdaysRequest, now: now).status == "conflict" && (try Data(contentsOf: recurringStore.fileURL)) == recurringBytes, "repeat rule is included in fingerprint and changed replay conflicts")
        weekdaysRequest.requestID = "weekday-recite"
        let weekdayItem = try weekdaysRequest.makeItem(now: now)
        try expect(weekdayItem.repeatRule == .weekdays && AgendaClock.occurrences(items: [weekdayItem], on: date(2026, 10, 16)).count == 1 && AgendaClock.occurrences(items: [weekdayItem], on: date(2026, 10, 17)).isEmpty, "weekday capture uses existing Monday to Friday recurrence")
        let repeatWire = try JSONDecoder().decode(AgendaCaptureRequest.self, from: Data("{\"request_id\":\"repeat-wire\",\"title\":\"背诵\",\"date\":\"2026-10-13\",\"time\":\"22:30\",\"duration_minutes\":30,\"repeat_rule\":\"daily\"}".utf8))
        try expect((try repeatWire.makeItem(now: now)).repeatRule == .daily, "snake-case repeat rule decodes into actual recurring item")
        do {
            _ = try JSONDecoder().decode(AgendaCaptureRequest.self, from: Data("{\"request_id\":\"bad-repeat\",\"title\":\"任务\",\"repeat_rule\":\"weekly\"}".utf8))
            throw Failure(message: "unknown capture repeat rule must reject")
        } catch is DecodingError { }
        let longNote = AgendaCaptureRequest(requestID: "long-note", title: "完整备注", note: String(repeating: "字", count: 2000), source: "hermes")
        let longNoteResult = store.capture(longNote, now: now)
        try expect(longNoteResult.ok && store.items.first(where: { $0.id == longNoteResult.itemID })?.note == longNote.note, "maximum-length note remains original without appended source text")
        let receiptBackup = root.appendingPathComponent("capture-with-receipts-backup.json")
        try Data(contentsOf: store.fileURL).write(to: receiptBackup)
        store.delete(timed.id)
        let replayDeleted = store.capture(timeRequest, now: now)
        try expect(replayDeleted.ok && replayDeleted.status == "already_processed" && replayDeleted.itemID == timed.id && replayDeleted.itemExists == false && !store.items.contains(where: { $0.id == timed.id }), "delete capture retains receipt and replay does not resurrect deleted item")
        store.undo()
        try expect(store.items.contains(where: { $0.id == timed.id }) && store.capture(timeRequest).itemExists == true, "undo delete restores original captured item without losing receipt")
        var edited = dated; edited.title = "领资料改名"
        try expect(store.upsert(edited), "ordinary edit of captured item saves")
        store.settings.compact.toggle()
        try expect(store.save() && store.capture(dateRequest).status == "already_processed" && AgendaStore(directory: dir).capture(timeRequest).status == "already_processed", "ordinary upsert and settings save preserve capture receipts")
        try expect(store.restore(from: receiptBackup) && store.capture(timeRequest).itemID == timed.id && store.capture(request).itemExists == false, "receipt backup restores exact live item and tombstone receipts")
        try expect(store.restore(from: oldBackup) && store.items == legacyItems && store.settings == legacySettings, "old backup restores pre-capture items and settings")
        let afterOldRestore = store.capture(request, now: now)
        try expect(afterOldRestore.status == "created" && afterOldRestore.itemID != captured.id, "old backup without receipts resets ledger rather than implicitly merging newer receipts")
        try expect(store.restore(from: receiptBackup) && store.capture(request).itemID == captured.id && store.capture(request).itemExists == false, "restoring receipt backup replaces ledger rather than merging later capture UUID")

        let decoded = try JSONDecoder().decode(AgendaCaptureRequest.self, from: Data("{\"request_id\":\"wire-1\",\"title\":\"标题\",\"duration_minutes\":0}".utf8))
        try expect(decoded.requestID == "wire-1" && decoded.durationMinutes == 0 && decoded.source == nil, "capture request snake-case wire decodes optional defaults")
        let encodedResult = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timeResult)) as! [String: Any]
        try expect(encodedResult["request_id"] as? String == "at-time" && encodedResult["item_id"] as? String == timed.id.uuidString && encodedResult["item_exists"] as? Bool == true && encodedResult["requestID"] == nil, "capture result uses documented wire names")
        let bridgeFailure = AgendaCaptureResult(ok: false, status: "invalid", error: "失败")
        try expect(bridgeFailure.requestID == nil && bridgeFailure.itemID == nil && bridgeFailure.itemExists == nil, "bridge result initializer defaults optional fields to nil")
        let defaultRequest = AgendaCaptureRequest(requestID: "defaults", title: "默认来源")
        var defaultEquivalent = defaultRequest; defaultEquivalent.source = "cli"; defaultEquivalent.note = ""; defaultEquivalent.durationMinutes = 0
        try expect(defaultRequest.fingerprint == defaultEquivalent.fingerprint && (try defaultRequest.normalized()).source == "cli", "nil source note and duration normalize equivalently to explicit defaults")
        var allowedID = defaultRequest; allowedID.requestID = String(repeating: "a", count: 123) + "._:-Z"
        try expect((try allowedID.normalized()).requestID == allowedID.requestID, "capture accepts maximum-length ASCII request ID and permitted punctuation")

        var invalidRequests: [AgendaCaptureRequest] = []
        for id in ["", "bad id", "中文", String(repeating: "a", count: 129), "slash/id", "id\n"] {
            var invalid = defaultRequest; invalid.requestID = id; invalidRequests.append(invalid)
        }
        for title in ["   ", String(repeating: "字", count: 201)] {
            var invalid = defaultRequest; invalid.title = title; invalidRequests.append(invalid)
        }
        var invalid = defaultRequest; invalid.note = String(repeating: "字", count: 2001); invalidRequests.append(invalid)
        for day in ["", " ", "2026-02-30", "2026-1-01", "2026-13-01", "0000-01-01", "２０２６-10-12", "tomorrow"] {
            invalid = defaultRequest; invalid.date = day; invalidRequests.append(invalid)
        }
        for time in ["", " ", "24:00", "09:60", "9:00", "０９:00", "09:00:00"] {
            invalid = defaultRequest; invalid.date = "2026-10-13"; invalid.time = time; invalidRequests.append(invalid)
        }
        invalid = defaultRequest; invalid.time = "09:00"; invalidRequests.append(invalid)
        invalid = defaultRequest; invalid.repeatRule = .daily; invalidRequests.append(invalid)
        invalid = defaultRequest; invalid.repeatRule = .weekdays; invalid.date = "2026-10-13"; invalidRequests.append(invalid)
        for duration in [-1, 1441, 1] { invalid = defaultRequest; invalid.durationMinutes = duration; invalidRequests.append(invalid) }
        for source in ["wechat", "", "unknown"] { invalid = defaultRequest; invalid.source = source; invalidRequests.append(invalid) }
        let beforeInvalid = try Data(contentsOf: store.fileURL)
        for invalidRequest in invalidRequests {
            let result = store.capture(invalidRequest, now: now)
            try expect(!result.ok && result.status == "invalid" && result.error != nil, "invalid capture request rejected before writing")
        }
        try expect(store.capture(defaultRequest, now: Date(timeIntervalSince1970: .nan)).status == "invalid" && (try Data(contentsOf: store.fileURL)) == beforeInvalid, "invalid requests and nonfinite creation instant leave document unchanged")
        var durationLimit = timeRequest; durationLimit.requestID = "duration-limit"; durationLimit.durationMinutes = 1440
        try expect((try durationLimit.makeItem(now: now)).durationMinutes == 1440, "capture accepts maximum explicit timed duration")
        var leap = dateRequest; leap.date = "2028-02-29"
        try expect((try leap.makeItem(now: now)).date == date(2028, 2, 29), "capture accepts valid leap day")

        let failDir = root.appendingPathComponent("capture-write-failure")
        let failed = AgendaStore(directory: failDir, seedIfEmpty: false)
        try expect(failed.upsertBatch(legacyItems), "capture write failure baseline saved")
        let failBytes = try Data(contentsOf: failed.fileURL)
        try fm.removeItem(at: failed.fileURL); try fm.createDirectory(at: failed.fileURL, withIntermediateDirectories: true)
        let failResult = failed.capture(defaultRequest, now: now)
        try expect(!failResult.ok && failResult.status == "save_failed" && failResult.itemID == nil && failed.items == legacyItems, "capture write failure does not publish item or success receipt")
        try fm.removeItem(at: failed.fileURL); try failBytes.write(to: failed.fileURL)
        let retry = failed.capture(defaultRequest, now: now)
        try expect(retry.ok && retry.status == "created" && failed.items.count == legacyItems.count + 1 && AgendaStore(directory: failDir).capture(defaultRequest).itemID == retry.itemID, "same request can retry after failed write without phantom receipt")

        let corruptDir = root.appendingPathComponent("capture-corrupt-receipts")
        try fm.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptFile = corruptDir.appendingPathComponent("agenda.json")
        let goodDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptBackup)) as! [String: Any]
        var corruptDocuments: [[String: Any]] = []
        var corruptDocument = goodDocument; corruptDocument["captureReceipts"] = true; corruptDocuments.append(corruptDocument)
        for (field, value) in [("fingerprint", "bad" as Any), ("itemID", "bad-uuid" as Any), ("createdAt", 1e20 as Any), ("source", "unknown" as Any)] {
            var badReceipt = firstReceipt; badReceipt[field] = value
            corruptDocument = goodDocument; corruptDocument["captureReceipts"] = ["req-1": badReceipt]; corruptDocuments.append(corruptDocument)
        }
        corruptDocument = goodDocument; corruptDocument["captureReceipts"] = ["bad id": firstReceipt]; corruptDocuments.append(corruptDocument)
        corruptDocument = goodDocument; corruptDocument["captureReceipts"] = ["one": firstReceipt, "two": firstReceipt]; corruptDocuments.append(corruptDocument)
        corruptDocument = goodDocument; corruptDocument["captureReceipts"] = ["req-1": ["fingerprint": normalized.fingerprint]]; corruptDocuments.append(corruptDocument)
        for bad in corruptDocuments {
            let bytes = try JSONSerialization.data(withJSONObject: bad)
            try bytes.write(to: corruptFile)
            let corrupt = AgendaStore(directory: corruptDir, seedIfEmpty: false)
            try expect(corrupt.isDataLocked && corrupt.capture(request, now: now).status == "save_failed" && !corrupt.save() && (try Data(contentsOf: corruptFile)) == bytes, "corrupt capture receipt protects entire document against capture or save")
        }
        let beforeRejectedRestore = try Data(contentsOf: store.fileURL)
        try expect(!store.restore(from: corruptFile) && (try Data(contentsOf: store.fileURL)) == beforeRejectedRestore, "corrupt receipt backup cannot replace current valid document")
    }

    @MainActor static func appearanceSettingsChecks(root: URL) throws {
        let fm = FileManager.default
        try expect(AgendaSettings().appearanceMode == .light && AgendaSettings().accentColor == .green, "new settings default to light and green")
        try expect(AgendaAppearanceMode.allCases.map(\.label) == ["浅色", "深色", "跟随系统"], "appearance mode labels match user choices")
        try expect(AgendaAccentColor.allCases.map(\.label) == ["松绿", "海蓝", "雾紫", "暖橙", "石墨"], "accent labels match user choices")
        let dir = root.appendingPathComponent("appearance")
        let store = AgendaStore(directory: dir, seedIfEmpty: false)
        let item = AgendaItem(title: "晚间整理", date: date(), timeMinutes: 1200, durationMinutes: 30,
                              note: "保留提醒状态", repeatRule: .daily, completedDays: ["2026-10-12"],
                              snoozes: ["2026-10-13": date(2026, 10, 13, 21)])
        let untimed = AgendaItem(title: "整理资料", date: date(), timeMinutes: nil, reminderEnabled: false)
        try expect(store.upsertBatch([item, untimed]), "appearance fixture items saved")
        store.settings.floating = false; store.settings.compact = true
        store.settings.notifications = false; store.settings.sound = false
        store.settings.leadMinutes = 37; store.settings.showCompleted = false
        try expect(store.save(), "nondefault unrelated settings saved")
        let pinned = store.occurrences(on: date(2026, 10, 13)).first!
        try expect(store.pinOccurrence(pinned), "appearance fixture pin saved")
        let originalItems = store.items
        let originalSettings = store.settings
        for mode in AgendaAppearanceMode.allCases {
            for color in AgendaAccentColor.allCases {
                store.settings.appearanceMode = mode
                store.settings.accentColor = color
                var expected = originalSettings; expected.theme = mode.rawValue; expected.accentName = color.rawValue
                try expect(store.save() && store.settings == expected && store.items == originalItems, "\(mode.rawValue)/\(color.rawValue) saves only selected appearance fields")
                let restarted = AgendaStore(directory: dir, seedIfEmpty: false)
                try expect(!restarted.isDataLocked && restarted.settings.appearanceMode == mode && restarted.settings.accentColor == color && restarted.settings == expected, "\(mode.rawValue)/\(color.rawValue) survives restart")
                try expect(restarted.items == originalItems && restarted.isPinned(pinned), "\(mode.rawValue)/\(color.rawValue) preserves item state and pin after restart")
            }
        }
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
        let persistedSettings = persisted["settings"] as! [String: Any]
        try expect(persistedSettings["theme"] as? String == "system" && persistedSettings["accentName"] as? String == "graphite", "new system choice has explicit stored system value")
        try expect(persistedSettings["appearanceMode"] == nil && persistedSettings["accentColor"] == nil, "computed appearance properties do not add duplicate Codable fields")

        // Old documents contain only the original required settings, without either optional addition.
        var legacy = persisted
        var legacySettings = persistedSettings
        legacySettings.removeValue(forKey: "accentName")
        legacySettings.removeValue(forKey: "pinnedOccurrenceID")
        legacySettings["theme"] = "automatic"
        legacy["settings"] = legacySettings
        let legacyDir = root.appendingPathComponent("appearance-legacy")
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyFile = legacyDir.appendingPathComponent("agenda.json")
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacy)
        try legacyBytes.write(to: legacyFile)
        let old = AgendaStore(directory: legacyDir, seedIfEmpty: false)
        try expect(!old.isDataLocked && old.error == nil && old.items == originalItems, "pre-appearance document without accent or pin decodes original data")
        try expect(old.settings.theme == "automatic" && old.settings.appearanceMode == .light && old.settings.accentName == nil && old.settings.accentColor == .green, "legacy automatic retains light appearance with default green")
        var expectedOldSettings = originalSettings
        expectedOldSettings.theme = "automatic"; expectedOldSettings.accentName = nil; expectedOldSettings.pinnedOccurrenceID = nil
        try expect(old.settings == expectedOldSettings, "legacy appearance read preserves all existing settings")
        try expect(try Data(contentsOf: legacyFile) == legacyBytes, "legacy appearance read does not migrate or rewrite original bytes")
        old.settings.appearanceMode = .dark; old.settings.accentColor = .orange
        try expect(old.save() && AgendaStore(directory: legacyDir).settings.appearanceMode == .dark && AgendaStore(directory: legacyDir).settings.accentColor == .orange, "old document can explicitly adopt and persist new appearance choices")

        var unknownDocument = legacy
        var unknownSettings = legacySettings
        unknownSettings["theme"] = "future-theme"; unknownSettings["accentName"] = "future-color"
        unknownDocument["settings"] = unknownSettings
        let unknownBytes = try JSONSerialization.data(withJSONObject: unknownDocument)
        try unknownBytes.write(to: legacyFile)
        let unknown = AgendaStore(directory: legacyDir, seedIfEmpty: false)
        try expect(!unknown.isDataLocked && unknown.error == nil && unknown.items == originalItems, "unknown nonempty appearance values keep document readable")
        try expect(unknown.settings.appearanceMode == .light && unknown.settings.accentColor == .green && unknown.settings.theme == "future-theme" && unknown.settings.accentName == "future-color", "unknown appearance falls back without replacing stored values")
        try expect(try Data(contentsOf: legacyFile) == unknownBytes, "unknown appearance read preserves original bytes")
        try expect(unknown.save() && AgendaStore(directory: legacyDir).settings.theme == "future-theme" && AgendaStore(directory: legacyDir).settings.accentName == "future-color", "saving readable unknown nonempty values preserves existing validation contract")

        var malformedDocument = legacy
        var malformedSettings = legacySettings; malformedSettings["accentName"] = true
        malformedDocument["settings"] = malformedSettings
        let malformedBytes = try JSONSerialization.data(withJSONObject: malformedDocument)
        try malformedBytes.write(to: legacyFile)
        let malformed = AgendaStore(directory: legacyDir, seedIfEmpty: false)
        try expect(malformed.isDataLocked && malformed.error != nil && !malformed.save() && (try Data(contentsOf: legacyFile)) == malformedBytes, "wrong-type accent field protects malformed source instead of overwriting it")

        let failDir = root.appendingPathComponent("appearance-write-failure")
        let failed = AgendaStore(directory: failDir, seedIfEmpty: false)
        try expect(failed.upsertBatch(originalItems), "appearance write failure items saved")
        failed.settings = store.settings
        try expect(failed.save(), "appearance write failure baseline saved")
        let savedSettings = failed.settings
        let savedBytes = try Data(contentsOf: failed.fileURL)
        let backup = root.appendingPathComponent("appearance-backup.json")
        try savedBytes.write(to: backup)
        try fm.removeItem(at: failed.fileURL)
        try fm.createDirectory(at: failed.fileURL, withIntermediateDirectories: true)
        failed.settings.appearanceMode = .dark; failed.settings.accentColor = .purple
        try expect(!failed.save() && failed.error != nil && failed.settings == savedSettings, "appearance save failure returns false and rolls back all settings")
        try expect(failed.items == originalItems && failed.isPinned(pinned) && failed.settings.appearanceMode == .system && failed.settings.accentColor == .graphite, "appearance save failure preserves last saved items pin and choices")
        try fm.removeItem(at: failed.fileURL)
        failed.settings.appearanceMode = .light; failed.settings.accentColor = .blue
        try expect(failed.save() && AgendaStore(directory: failDir).settings.accentColor == .blue, "appearance changes can save after write target recovers")
        try expect(failed.restore(from: backup) && failed.settings == savedSettings && AgendaStore(directory: failDir).settings == savedSettings, "backup restore retains exact appearance and unrelated settings")
    }
}
