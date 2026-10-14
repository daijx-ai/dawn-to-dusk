import Foundation

private actor FakeFeishuCLI {
    enum Response { case output(FeishuCLIOutput), timeout, waitForCancellation }
    private var responses: [Response]
    private(set) var commands: [[String]] = []
    private(set) var timeouts: [TimeInterval] = []
    init(_ responses: [Response]) { self.responses = responses }
    func invoke(_ arguments: [String], _ timeout: TimeInterval) async throws -> FeishuCLIOutput {
        commands.append(arguments); timeouts.append(timeout)
        guard !responses.isEmpty else { throw FeishuReadError.processFailed }
        switch responses.removeFirst() {
        case .output(let value): return value
        case .timeout: throw FeishuReadError.timeout
        case .waitForCancellation:
            while true { try await Task.sleep(nanoseconds: 1_000_000) }
        }
    }
}

@main struct FeishuReaderTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        // Real subprocess regression, without the live CLI, account or network.
        // This is the environment supplied to login items by launchd.
        let loginEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        func nodeProbe(_ environment: [String: String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", "-e", "process.exit(0)"]
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        check(try nodeProbe(loginEnvironment) == 127, "minimal login PATH reproduces the missing Node failure")
        let fixedEnvironment = FeishuProcessEnvironment.make(from: loginEnvironment)
        check(try nodeProbe(fixedEnvironment) == 0, "login subprocess resolves Node with the application environment")
        check(fixedEnvironment["HOME"] == loginEnvironment["HOME"], "shared account home is preserved")
        check(fixedEnvironment == FeishuProcessEnvironment.make(from: fixedEnvironment), "environment normalization is idempotent")
        let calendarID = "feishu.cn_test@group.calendar.feishu.cn"
        let start = Date(timeIntervalSince1970: 1791648000), end = Date(timeIntervalSince1970: 1792425600)
        func data(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        func output(_ payload: [String: Any], identity: String = "user") -> FakeFeishuCLI.Response {
            .output(FeishuCLIOutput(exitCode: 0, stdout: data(["ok": true, "identity": identity, "data": payload]), stderr: Data()))
        }
        func primary(id: String = calendarID, role: String = "owner", type: String = "primary") -> FakeFeishuCLI.Response {
            output(["calendars": [["calendar": ["calendar_id": id, "role": role, "type": type]]]])
        }
        func event(_ id: String = "meeting_1791786600", status: String = "confirmed", rsvp: String = "accept", link: String? = nil) -> [String: Any] {
            var value: [String: Any] = ["event_id": id, "summary": "团队会议", "status": status, "self_rsvp_status": rsvp,
                                     "start_time": ["timestamp": "1791786601", "timezone": "Asia/Shanghai"],
                                     "end_time": ["timestamp": "1791790207", "timezone": "Asia/Shanghai"], "is_exception": false]
            if let link { value["app_link"] = link }
            return value
        }
        func reader(_ fake: FakeFeishuCLI) -> FeishuReader { FeishuReader(run: { arguments, timeout in try await fake.invoke(arguments, timeout) }) }
        func snapshot(_ responses: [FakeFeishuCLI.Response], ids: [String] = []) async throws -> (FeishuSnapshot, FakeFeishuCLI) {
            let fake = FakeFeishuCLI(responses)
            let result = try await reader(fake).read(windowStart: start, windowEnd: end, mirroredEventIDs: { _ in ids })
            return (result, fake)
        }
        func rejected(_ responses: [FakeFeishuCLI.Response], ids: [String] = []) async -> String {
            do { _ = try await snapshot(responses, ids: ids); check(false, "malformed/partial snapshot was accepted"); return "" }
            catch { checks += 1; return error.localizedDescription }
        }

        let official = "https://applink.feishu.cn/client/calendar/event/detail?calendarId=1&key=meeting"
        let normal = try await snapshot([primary(), output(["items": [event(link: official)]])])
        check(normal.0.calendarID == calendarID && normal.0.events.count == 1, "snapshot binds to the returned primary calendar")
        check(normal.0.events[0].start == Date(timeIntervalSince1970: 1791786601) && normal.0.events[0].end == Date(timeIntervalSince1970: 1791790207), "timed event keeps exact second timestamps without minute rounding")
        check(normal.0.events[0].timezone == "Asia/Shanghai" && normal.0.events[0].appLink == official, "native timezone and allowed official link survive")
        let commands = await normal.1.commands
        check(commands.count == 2 && commands[0].prefix(3) == ["calendar", "calendars", "primary"] && commands[1].prefix(3) == ["calendar", "events", "instance_view"], "only whitelisted primary/instance reads execute")
        check(commands.allSatisfy { $0.contains("--as") && $0.contains("user") && $0.contains("--jq") && !$0.contains("--need-attendee") }, "all commands force user identity and minimal projection")
        check(commands.allSatisfy { !$0.last!.contains("description") && !$0.last!.contains("attendees") }, "projection excludes unnecessary private details")
        check((await normal.1.timeouts).allSatisfy { $0 > 0 && $0 <= 12 }, "each process has a finite bounded timeout")

        let empty = try await snapshot([primary(), output(["items": []])])
        check(empty.0.events.isEmpty, "successful empty source view is valid")
        let cancelled: [String: Any] = ["event_id": "cancelled_0", "status": "cancelled"]
        let removed: [String: Any] = ["event_id": "removed_0", "status": "confirmed", "self_rsvp_status": "removed"]
        let declined: [String: Any] = ["event_id": "declined_0", "status": "confirmed", "self_rsvp_status": "decline"]
        let tombstones = try await snapshot([primary(), output(["items": [cancelled, removed, declined]])])
        check(tombstones.0.events.map(\.status) == [.cancelled, .cancelled, .declined], "explicit cancellation/removal/decline produce typed tombstones")
        check(tombstones.0.events.allSatisfy { $0.start == nil && $0.end == nil }, "tombstones do not fabricate times")
        let moved = try await snapshot([primary(), output(["items": []]), output(["event": event("old_0")])], ids: ["old_0"])
        check(moved.0.events[0].eventID == "old_0" && moved.0.events[0].status == .active, "missing old event is resolved through get, never inferred cancelled")
        check((await moved.1.commands)[2].contains("old_0"), "missing ID get uses the exact mirrored ID")
        let missingCancelled = try await snapshot([primary(), output(["items": []]), output(["event": cancelled])], ids: ["cancelled_0"])
        check(missingCancelled.0.events[0].status == .cancelled, "get can confirm a previously missing cancellation")
        var recurring = event("series_1791786600")
        recurring["is_exception"] = true; recurring["recurring_event_id"] = "series_0"
        let instances = try await snapshot([primary(), output(["items": [recurring, event("series_1792391400")]])])
        check(instances.0.events.map(\.eventID) == ["series_1791786600", "series_1792391400"], "expanded recurring and exception instance IDs remain distinct")

        let allDay: [String: Any] = ["event_id": "all_day_0", "summary": "多日安排", "status": "confirmed", "self_rsvp_status": "accept",
                                    "start_time": ["date": "2026-03-07", "timezone": "America/New_York"],
                                    "end_time": ["date": "2026-03-10", "timezone": "America/New_York"]]
        let daySnapshot = try await snapshot([primary(), output(["items": [allDay]])])
        let dayEvent = daySnapshot.0.events[0]
        check(dayEvent.isAllDay && dayEvent.timezone == "America/New_York", "all-day event retains its source calendar timezone")
        check(dayEvent.end!.timeIntervalSince(dayEvent.start!) == 71 * 3600, "multi-day exclusive end handles DST without assuming 24-hour days")
        var zero = event("zero_0"); zero["end_time"] = zero["start_time"]
        check(try await snapshot([primary(), output(["items": [zero]])]).0.events[0].start == Date(timeIntervalSince1970: 1791786601), "zero-duration timed event remains representable")
        let globalLink = "https://applink.larkoffice.com/client/calendar/event/detail?key=1"
        check(try await snapshot([primary(), output(["items": [event(link: globalLink)]])]).0.events[0].appLink == globalLink, "official global app link is accepted")
        for unsafe in ["file:///etc/passwd", "javascript:alert(1)", "https://applink.feishu.cn.evil.example/client/calendar/event/detail", "https://user:password@applink.feishu.cn/client/calendar/event/detail", "https://applink.feishu.cn/client/explorer/open?url=evil", "https://applink.feishu.cn:8443/client/calendar/event/detail", "lark://client/calendar/event/detail"] {
            let result = try await snapshot([primary(), output(["items": [event(link: unsafe)]])])
            check(result.0.events[0].appLink == nil, "unsafe/unsupported link is never exposed")
        }

        _ = await rejected([primary(), output(["items": [event(), event()]])])
        _ = await rejected([primary(), output(["items": [event()], "has_more": true])])
        _ = await rejected([primary(), output(["items": [event()], "has_more": 0])])
        _ = await rejected([primary(), output(["items": [event()], "page_token": "next"])])
        _ = await rejected([primary(), output(["items": [event()], "truncated": true])])
        _ = await rejected([primary(), output([:])])
        _ = await rejected([primary(), output(["items": []]), output(["event": event("wrong_0")])], ids: ["missing_0"])
        _ = await rejected([primary(role: "free_busy_reader")])
        _ = await rejected([primary(type: "shared")])
        _ = await rejected([output(["calendars": []])])
        _ = await rejected([output(["calendars": [["calendar": ["calendar_id": calendarID, "role": "owner", "type": "primary"]]]], identity: "bot")])
        _ = await rejected([primary(), output(["items": []])], ids: ["--malicious"])
        _ = await rejected([primary(), output(["items": []])], ids: ["duplicate", "duplicate"])
        var malformedEvents: [[String: Any]] = []
        var bad = event(); bad.removeValue(forKey: "event_id"); malformedEvents.append(bad)
        bad = event(); bad["status"] = "unknown"; malformedEvents.append(bad)
        bad = event(); bad["self_rsvp_status"] = "mystery"; malformedEvents.append(bad)
        bad = event(); bad["summary"] = "   "; malformedEvents.append(bad)
        bad = event(); bad["summary"] = String(repeating: "x", count: 201); malformedEvents.append(bad)
        bad = event(); bad["start_time"] = ["timestamp": "NaN", "timezone": "Asia/Shanghai"]; malformedEvents.append(bad)
        bad = event(); bad["start_time"] = ["timestamp": "1791786601.5", "timezone": "Asia/Shanghai"]; malformedEvents.append(bad)
        bad = event(); bad["start_time"] = ["timestamp": 1791786601, "timezone": "Asia/Shanghai"]; malformedEvents.append(bad)
        bad = event(); bad["start_time"] = ["timestamp": "1791786601", "timezone": "invalid/timezone"]; malformedEvents.append(bad)
        bad = event(); bad["end_time"] = ["timestamp": "1791786600", "timezone": "Asia/Shanghai"]; malformedEvents.append(bad)
        bad = event(); bad.removeValue(forKey: "end_time"); malformedEvents.append(bad)
        bad = event(); bad["end_time"] = ["date": "2026-10-12", "timezone": "Asia/Shanghai"]; malformedEvents.append(bad)
        bad = event(); bad["start_time"] = ["timestamp": "1791786601", "date": "2026-10-12", "timezone": "Asia/Shanghai"]; malformedEvents.append(bad)
        bad = event(); bad["end_time"] = ["timestamp": "1791790207", "timezone": "America/New_York"]; malformedEvents.append(bad)
        bad = allDay; bad["start_time"] = ["date": "2026-02-30", "timezone": "America/New_York"]; malformedEvents.append(bad)
        bad = allDay; bad["end_time"] = bad["start_time"]; malformedEvents.append(bad)
        bad = event(); bad["is_exception"] = "true"; malformedEvents.append(bad)
        for item in malformedEvents { _ = await rejected([primary(), output(["items": [event("good_0"), item]])]) }
        let truncated = FeishuCLIOutput(exitCode: 0, stdout: Data("{\"ok\":true".utf8), stderr: Data())
        _ = await rejected([primary(), .output(truncated)])
        let huge = FeishuCLIOutput(exitCode: 0, stdout: Data(repeating: 32, count: 1024 * 1024 + 1), stderr: Data())
        _ = await rejected([primary(), .output(huge)])
        let privateMarker = "PRIVATE_TEST_ONLY_DO_NOT_ECHO"
        let unauthorized = FeishuCLIOutput(exitCode: 3, stdout: Data(), stderr: data(["ok": false, "error": ["type": "authorization", "message": privateMarker]]))
        let authError = await rejected([.output(unauthorized)])
        check(authError.contains("权限") && !authError.contains(privateMarker), "authorization errors expose no raw stderr")
        let ordinaryFailure = FeishuCLIOutput(exitCode: 1, stdout: Data(), stderr: Data(privateMarker.utf8))
        let dependencyFailure = FeishuCLIOutput(exitCode: 127, stdout: Data(), stderr: Data(privateMarker.utf8))
        let dependencyError = await rejected([.output(dependencyFailure)])
        check(dependencyError.contains("Node") && !dependencyError.contains(privateMarker), "missing runtime reports an actionable sanitized dependency error")
        check(!(await rejected([primary(), output(["items": []]), .output(ordinaryFailure)], ids: ["old_0"])).contains(privateMarker), "missing-event get failure refuses the entire snapshot without raw text")
        _ = await rejected([primary(), .timeout])

        let cancelledFake = FakeFeishuCLI([primary(), .waitForCancellation])
        let cancelledTask = Task { try await reader(cancelledFake).read(windowStart: start, windowEnd: end, mirroredEventIDs: { _ in ["old_0"] }) }
        while await cancelledFake.commands.count < 2 { await Task.yield() }
        cancelledTask.cancel()
        do { _ = try await cancelledTask.value; check(false, "cancelled sync returned a snapshot") }
        catch is CancellationError { checks += 1 }
        check(await cancelledFake.commands.count == 2, "cancelled sync does not proceed to missing-event reads")
        let invalidWindowFake = FakeFeishuCLI([])
        for pair in [(end, start), (start, start), (start, start.addingTimeInterval(40 * 86400)), (Date(timeIntervalSince1970: .nan), end), (start.addingTimeInterval(0.5), end)] {
            do { _ = try await reader(invalidWindowFake).read(windowStart: pair.0, windowEnd: pair.1, mirroredEventIDs: { _ in [] }); check(false, "invalid window accepted") }
            catch { checks += 1 }
        }
        check(await invalidWindowFake.commands.isEmpty, "invalid windows launch no subprocess")
        let window = FeishuReader.defaultWindow(now: Date(timeIntervalSince1970: 1791786600))
        check(AgendaClock.dayKey(window.start) == "2026-10-11" && AgendaClock.dayKey(window.end) == "2026-10-20", "default window covers yesterday through seven future days")
        print("PASS: \(checks) Feishu reader checks; CLI boundaries injected; local Node startup probe only, no live CLI, app, account or network")
    }
}
