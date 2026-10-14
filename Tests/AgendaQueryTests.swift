import Foundation

@main struct AgendaQueryTests {
    private struct Document: Encodable {
        var version = 1
        var items: [AgendaItem]
        var settings: AgendaSettings
    }
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { fatalError(message) }
        }
        func rejects(_ message: String, _ action: () throws -> Void) {
            do { try action(); fatalError(message) }
            catch { checks += 1 }
        }
        let calendar = AgendaClock.calendar
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let now = today.addingTimeInterval(8 * 3600)
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("chaoxi-query-tests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let production = temporary.appendingPathComponent("fake-production", isDirectory: true)
        let isolated = temporary.appendingPathComponent("qa", isDirectory: true)
        try fm.createDirectory(at: isolated, withIntermediateDirectories: true)
        let agenda = isolated.appendingPathComponent("agenda.json")

        var repeated = AgendaItem(title: "固定安排", date: yesterday, timeMinutes: 540, durationMinutes: 30,
                                  category: "PRIVATE_CATEGORY", note: "PRIVATE_NOTE", repeatRule: .daily)
        repeated.completedDays = [AgendaClock.dayKey(today)]
        let untimed = AgendaItem(title: "未定时", date: today, timeMinutes: nil, isTentative: true, reminderEnabled: false)
        let future = AgendaItem(title: "明天单次", date: tomorrow, timeMinutes: 600)
        let pending = AgendaItem(title: "清单待办", date: yesterday, reminderEnabled: false, checklistState: .pending)
        let completed = AgendaItem(title: "清单完成", date: yesterday, reminderEnabled: false, checklistState: .completed)
        let source = FeishuMetadata(calendarID: "PRIVATE_CALENDAR", eventID: "PRIVATE_EVENT", start: today.addingTimeInterval(14.5 * 3600),
                                    end: today.addingTimeInterval(15.5 * 3600), isAllDay: false, timezone: "Asia/Shanghai")
        let meeting = AgendaItem(title: "来源日程", date: today, timeMinutes: 870, durationMinutes: 60, feishu: source)
        var settings = AgendaSettings()
        settings.showCompleted = false
        settings.pinnedOccurrenceID = "STALE_PIN_MUST_NOT_BE_NORMALIZED"
        let document = Document(items: [repeated, untimed, future, pending, completed, meeting], settings: settings)
        let data = try JSONEncoder().encode(document)
        try data.write(to: agenda)
        let baselineNames = try fm.contentsOfDirectory(atPath: isolated.path).sorted()
        let result = try AgendaQueryReader.query(data: data, now: now)
        check(result.ok && result.status == "queried" && result.readOnly && result.timezone == "Asia/Shanghai", "Query protocol constants")
        check(result.date == "2026-10-13", "Omitted date uses Shanghai today")
        check(result.schedule.count == 3, "Only today's scheduled instances")
        check(!result.schedule.contains { $0.id == future.id }, "Future one-time item excluded today")
        check(result.schedule.first { $0.id == repeated.id }?.completed == true, "Completed schedule included independently of showCompleted")
        check(result.schedule.first { $0.id == untimed.id }?.tentative == true, "Tentative status retained")
        check(result.schedule.first { $0.id == meeting.id }?.time == "14:30", "Feishu source effective time")
        check(result.checklist.map(\.id) == [pending.id, completed.id], "All independent checklist items retain stored order")
        check(result.checklist.map(\.completed) == [false, true], "Checklist completed field reflects separate state")
        check(!result.schedule.contains { [pending.id, completed.id].contains($0.id) }, "Checklist never becomes a date instance")
        let encoded = try JSONEncoder().encode(result)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let expectedTop: Set<String> = ["ok", "status", "read_only", "timezone", "date", "generated_at", "schedule", "checklist"]
        check(Set(object.keys) == expectedTop, "Only agreed result fields exposed")
        let scheduleRows = object["schedule"] as! [[String: Any]]
        let untimedRow = scheduleRows.first { ($0["id"] as? String) == untimed.id.uuidString }!
        check(untimedRow["time"] is NSNull && untimedRow["base_time"] is NSNull, "Untimed keys are explicit JSON null")
        let expectedRow: Set<String> = ["id", "occurrence_id", "title", "date", "time", "base_time", "duration_minutes", "repeat_rule", "completed", "tentative"]
        check(scheduleRows.allSatisfy { Set($0.keys) == expectedRow }, "Only agreed schedule fields exposed")
        check((object["checklist"] as! [[String: Any]]).allSatisfy { Set($0.keys) == ["id", "title", "completed"] }, "Minimal checklist fields")
        check(!String(data: encoded, encoding: .utf8)!.contains("PRIVATE_"), "Notes, categories and source metadata are not exposed")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        check(iso.date(from: result.generatedAt) == now, "Timestamp is ISO8601 with timezone")
        let tomorrowResult = try AgendaQueryReader.query(data: data, on: tomorrow, now: now)
        check(tomorrowResult.date == "2026-10-14" && tomorrowResult.schedule.contains { $0.id == future.id }, "Explicit future date")
        check(tomorrowResult.checklist.map(\.id) == [pending.id, completed.id], "Checklist remains independent of queried day")
        let weekend = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17))!
        let weekdayOnly = AgendaItem(title: "工作日", date: yesterday, timeMinutes: 500, repeatRule: .weekdays)
        let weekdayData = try JSONEncoder().encode(Document(items: [weekdayOnly], settings: settings))
        check(try AgendaQueryReader.query(data: weekdayData, on: weekend, now: now).schedule.isEmpty, "Weekday repeat excludes weekend")

        var postponed = repeated
        postponed.completedDays = [AgendaClock.dayKey(yesterday)]
        postponed.postponedTimes = [AgendaClock.dayKey(yesterday): today.addingTimeInterval(10 * 60)]
        let postponedData = try JSONEncoder().encode(Document(items: [postponed], settings: settings))
        let postponedResult = try AgendaQueryReader.query(data: postponedData, now: now)
        check(postponedResult.schedule.count == 2, "Cross-day postponed and ordinary repeat both visible")
        check(Set(postponedResult.schedule.map(\.id)) == [postponed.id], "Two instances retain item identity")
        check(Set(postponedResult.schedule.map(\.occurrenceID)).count == 2, "Occurrence identity distinguishes cross-day instances")
        check(postponedResult.schedule.map(\.time) == ["00:10", "09:00"], "Effective times include postponement")
        check(postponedResult.schedule.allSatisfy { $0.baseTime == "09:00" && $0.date == "2026-10-13" }, "Base time is series time while date is display day")
        check(postponedResult.schedule.map(\.completed) == [true, false], "Each occurrence uses its original completion date")
        check(postponedResult.schedule[0].occurrenceID.hasSuffix(":2026-10-12"), "Moved occurrence preserves original anchor in identity")
        check(try AgendaQueryReader.query(data: postponedData, on: yesterday, now: now).schedule.isEmpty, "Moved instance leaves original display day")
        check(try AgendaQueryReader.query(data: postponedData, on: tomorrow, now: now).schedule.first?.time == "09:00", "Postponement leaves next day base time unchanged")

        let shanghaiMidnight = today.addingTimeInterval(30 * 60)
        check(try AgendaQueryRequest.decode(Data("{}".utf8)).day(now: shanghaiMidnight) == today, "Default query follows Shanghai date near UTC boundary")
        for body in ["[]", "null", "{\"date\":null}", "{\"date\":5}", "{\"title\":\"misrouted capture\"}", "{\"date\":\"2026-10-13\",\"source\":\"hermes\"}", "broken"] {
            rejects("Invalid query shape rejected") { _ = try AgendaQueryRequest.decode(Data(body.utf8)) }
        }
        for date in ["2026-02-30", "2026-1-13", " 2026-10-13", "2026-10-13 ", "0000-01-01", "2026-13-01", "２０２６-10-13"] {
            rejects("Invalid date rejected") { _ = try AgendaQueryRequest.decode(Data("{\"date\":\"\(date)\"}".utf8)).day(now: now) }
        }
        check(try AgendaQueryRequest.decode(Data("{\"date\":\"2026-10-14\"}".utf8)).day(now: now) == tomorrow, "Strict valid request date")
        rejects("Oversized stdin rejected") { _ = try AgendaQueryRequest.decode(Data(repeating: 32, count: AgendaQueryCLI.maximumInputBytes + 1)) }
        rejects("Corrupt file rejected") { _ = try AgendaQueryReader.query(data: Data("broken".utf8), now: now) }
        rejects("Unsupported version rejected") { _ = try AgendaQueryReader.query(data: JSONEncoder().encode(Document(version: 2, items: [], settings: settings)), now: now) }
        rejects("Duplicate IDs rejected") { _ = try AgendaQueryReader.query(data: JSONEncoder().encode(Document(items: [pending, pending], settings: settings)), now: now) }
        var invalid = repeated
        invalid.timeMinutes = 1440
        rejects("Invalid stored time rejected") { _ = try AgendaQueryReader.query(data: JSONEncoder().encode(Document(items: [invalid], settings: settings)), now: now) }

        var outputs: [Data] = [], reads = 0, inputReads = 0
        let environment = AgendaQueryCLIEnvironment(readInput: { inputReads += 1; return Data("{}".utf8) }, readDocument: { fileURL in
            reads += 1
            check(fileURL == agenda, "Validated query reads only isolated agenda.json")
            return try Data(contentsOf: fileURL)
        }, output: { outputs.append($0) }, now: { now })
        check(AgendaQueryCLI.run(arguments: ["--query", "--qa", "--data-dir", isolated.path], productionRoot: production, environment: environment) == 0, "Actual CLI adapter succeeds with fake input and data")
        check(reads == 1 && inputReads == 1 && outputs.count == 1, "One bounded input read, one file read and one JSON response")
        check((try JSONSerialization.jsonObject(with: outputs[0]) as! [String: Any])["ok"] as? Bool == true, "CLI response is successful JSON")
        var futureEnvironment = environment
        futureEnvironment.readInput = { Data("{\"date\":\"2026-10-14\"}".utf8) }
        check(AgendaQueryCLI.run(arguments: ["--query", "--qa", "--data-dir", isolated.path], productionRoot: production, environment: futureEnvironment) == 0, "Explicit future request uses actual CLI path")
        check((try JSONSerialization.jsonObject(with: outputs.last!) as! [String: Any])["date"] as? String == "2026-10-14", "CLI future response reports requested date")
        var fakeProductionEnvironment = environment
        fakeProductionEnvironment.readDocument = { fileURL in
            check(fileURL == production.appendingPathComponent("agenda.json"), "Production mode uses only declared default file")
            return data
        }
        check(AgendaQueryCLI.run(arguments: ["--query"], productionRoot: production, environment: fakeProductionEnvironment) == 0, "Default query route reads injected production fixture without custom directory")
        check(try Data(contentsOf: agenda) == data, "Query leaves agenda bytes unchanged")
        check(try fm.contentsOfDirectory(atPath: isolated.path).sorted() == baselineNames, "Query creates no locks, Inbox, backups or metadata")
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: agenda)) as! [String: Any]
        check((after["settings"] as! [String: Any])["pinnedOccurrenceID"] as? String == settings.pinnedOccurrenceID, "Read-only query does not normalize stale pin")
        for arguments in [["--query", "--capture"], ["--query", "--unknown"], ["--query", "--query"], ["--query", "--qa"], ["--query", "--data-dir", isolated.path], ["--query", "--qa", "--data-dir", "relative"], ["--query", "--qa", "--data-dir", production.path]] {
            let beforeInput = inputReads, beforeReads = reads
            check(AgendaQueryCLI.run(arguments: arguments, productionRoot: production, environment: environment) == 1, "Invalid arguments fail closed")
            check(inputReads == beforeInput && reads == beforeReads, "Rejected arguments do not read input or data")
            let error = try JSONSerialization.jsonObject(with: outputs.last!) as! [String: Any]
            check(error["ok"] as? Bool == false && error["error"] is String, "Invalid arguments emit structured failure")
        }
        for body in ["{\"date\":\"2026-02-30\"}", "{\"title\":\"capture\"}"] {
            let beforeReads = reads
            var invalidEnvironment = environment
            invalidEnvironment.readInput = { Data(body.utf8) }
            check(AgendaQueryCLI.run(arguments: ["--query", "--qa", "--data-dir", isolated.path], productionRoot: production, environment: invalidEnvironment) == 1, "Invalid stdin fails CLI")
            check(reads == beforeReads, "Invalid stdin is rejected before reading document")
        }
        let missing = temporary.appendingPathComponent("never-created", isDirectory: true)
        var missingEnvironment = environment
        missingEnvironment.readDocument = { try Data(contentsOf: $0) }
        check(AgendaQueryCLI.run(arguments: ["--query", "--qa", "--data-dir", missing.path], productionRoot: production, environment: missingEnvironment) == 1, "Missing agenda fails rather than seeding")
        check(!fm.fileExists(atPath: missing.path), "Missing directory remains absent")
        try Data("broken".utf8).write(to: agenda)
        let corruptNames = try fm.contentsOfDirectory(atPath: isolated.path).sorted()
        check(AgendaQueryCLI.run(arguments: ["--query", "--qa", "--data-dir", isolated.path], productionRoot: production, environment: environment) == 1, "Corrupt file fails CLI")
        check(try Data(contentsOf: agenda) == Data("broken".utf8), "Corrupt file remains untouched")
        check(try fm.contentsOfDirectory(atPath: isolated.path).sorted() == corruptNames, "Corrupt read adds no backup or recovery files")
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.count == 3, arguments[1] == "--fixture-output", arguments[2].hasPrefix("/") {
            let fixtureData = try JSONEncoder().encode(Document(items: [postponed, untimed, pending, completed], settings: settings))
            let fixture = try AgendaQueryReader.query(data: fixtureData, now: now)
            try JSONEncoder().encode(fixture).write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
        }
        print("PASS \(checks) read-only agenda query checks")
    }
}
