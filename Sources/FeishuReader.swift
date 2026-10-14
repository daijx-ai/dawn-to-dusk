import Foundation
import Darwin
import CoreFoundation

enum FeishuReadError: LocalizedError {
    case invalidWindow, malformed, partial, permission, timeout, processFailed, dependencyUnavailable, tooLarge, accountChanged
    var errorDescription: String? {
        switch self {
        case .invalidWindow: return "飞书同步时间范围无效，原日程未更新。"
        case .malformed: return "飞书日程数据无法完整解析，原日程未更新。"
        case .partial: return "有飞书日程尚未核实，原日程未更新。"
        case .permission: return "飞书日历读取权限或登录态不可用，原日程未更新。"
        case .timeout: return "读取飞书日程超时，原日程未更新。"
        case .processFailed: return "飞书只读工具未完成，原日程未更新。"
        case .dependencyUnavailable: return "飞书同步所需的 Node 或 lark-cli 不可用，请检查本机工具安装；原日程未更新。"
        case .tooLarge: return "飞书返回的数据过大，原日程未更新。"
        case .accountChanged: return "飞书主日历身份不一致，原日程未更新。"
        }
    }
}

struct FeishuCLIOutput {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

struct FeishuReader {
    typealias Runner = @Sendable ([String], TimeInterval) async throws -> FeishuCLIOutput
    private let run: Runner
    init() { run = { arguments, timeout in try await FeishuReadProcess.execute(arguments: arguments, timeout: timeout) } }
    // Tests replace the entire external process boundary before any query executes.
    init(run: @escaping Runner) { self.run = run }

    static func defaultWindow(now: Date = Date()) -> (start: Date, end: Date) {
        let today = AgendaClock.startOfDay(now)
        return (AgendaClock.calendar.date(byAdding: .day, value: -1, to: today)!, AgendaClock.calendar.date(byAdding: .day, value: 8, to: today)!)
    }

    func read(windowStart: Date, windowEnd: Date,
              mirroredEventIDs: @escaping @Sendable (String) async -> [String]) async throws -> FeishuSnapshot {
        try Task.checkCancellation()
        let start = windowStart.timeIntervalSince1970, end = windowEnd.timeIntervalSince1970
        guard start.isFinite, end.isFinite, start.rounded(.towardZero) == start, end.rounded(.towardZero) == end,
              start >= -62135596800, end <= 253402300799, end > start, end - start < 40 * 86400 else { throw FeishuReadError.invalidWindow }
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        let primary: PrimaryData = try await query(["calendar", "calendars", "primary", "--as", "user", "--jq", Self.primaryProjection], deadline: deadline)
        guard primary.calendars.count == 1 else { throw FeishuReadError.accountChanged }
        let calendar = primary.calendars[0].calendar
        guard calendar.type == "primary", ["owner", "writer", "reader"].contains(calendar.role), Self.validID(calendar.calendarID) else { throw FeishuReadError.accountChanged }
        let calendarID = calendar.calendarID
        let previous = await mirroredEventIDs(calendarID)
        try Task.checkCancellation()
        guard previous.count <= 2000, previous.allSatisfy(Self.validID), Set(previous).count == previous.count else { throw FeishuReadError.malformed }
        let view: InstanceData = try await query(["calendar", "events", "instance_view", "--calendar-id", calendarID,
                                                "--start-time", String(Int64(start)), "--end-time", String(Int64(end)),
                                                "--as", "user", "--jq", Self.instanceProjection], deadline: deadline)
        guard view.items.count <= 2000 else { throw FeishuReadError.tooLarge }
        var events: [FeishuEvent] = [], seen = Set<String>()
        for item in view.items {
            guard seen.insert(item.eventID).inserted else { throw FeishuReadError.malformed }
            events.append(try Self.event(item, calendarID: calendarID))
        }
        // Absence is not a cancellation. Every missing mirrored ID must be resolved.
        for eventID in previous where !seen.contains(eventID) {
            try Task.checkCancellation()
            let detail: EventData = try await query(["calendar", "events", "get", "--calendar-id", calendarID,
                                                    "--event-id", eventID, "--as", "user", "--jq", Self.eventProjection], deadline: deadline)
            guard detail.event.eventID == eventID else { throw FeishuReadError.partial }
            events.append(try Self.event(detail.event, calendarID: calendarID))
            seen.insert(eventID)
        }
        try Task.checkCancellation()
        return FeishuSnapshot(calendarID: calendarID, windowStart: windowStart, windowEnd: windowEnd, events: events, fetchedAt: Date())
    }

    private func query<T: Decodable>(_ arguments: [String], deadline: TimeInterval) async throws -> T {
        try Task.checkCancellation()
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw FeishuReadError.timeout }
        let output: FeishuCLIOutput
        do { output = try await run(arguments, min(12, remaining)) }
        catch is CancellationError { throw CancellationError() }
        catch let error as FeishuReadError { throw error }
        catch { throw FeishuReadError.processFailed }
        try Task.checkCancellation()
        guard output.stdout.count <= FeishuReadProcess.maximumOutput else { throw FeishuReadError.tooLarge }
        guard output.exitCode == 0 else {
            if output.exitCode == 127 { throw FeishuReadError.dependencyUnavailable }
            if let object = try? JSONSerialization.jsonObject(with: output.stderr) as? [String: Any],
               let error = object["error"] as? [String: Any], error["type"] as? String == "authorization" { throw FeishuReadError.permission }
            throw FeishuReadError.processFailed
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope<T>.self, from: output.stdout)
            guard envelope.ok, envelope.identity == "user", let data = envelope.data else { throw FeishuReadError.malformed }
            if let object = try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] {
                for section in [object, object["data"] as? [String: Any] ?? [:], object["meta"] as? [String: Any] ?? [:]] {
                    for flag in ["has_more", "truncated", "is_truncated"] where section[flag] != nil && !(section[flag] is NSNull) {
                        guard let value = section[flag] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw FeishuReadError.malformed }
                        if value.boolValue { throw FeishuReadError.partial }
                    }
                    if let token = section["page_token"], !(token is NSNull) {
                        guard let value = token as? String else { throw FeishuReadError.malformed }
                        if !value.isEmpty { throw FeishuReadError.partial }
                    }
                }
            }
            return data
        } catch let error as FeishuReadError { throw error }
        catch { throw FeishuReadError.malformed }
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.hasPrefix("-") && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [46, 95, 64, 45].contains($0) }
    }

    private static func event(_ wire: WireEvent, calendarID: String) throws -> FeishuEvent {
        guard validID(wire.eventID), ["confirmed", "tentative", "cancelled"].contains(wire.status) else { throw FeishuReadError.malformed }
        if let rsvp = wire.selfRSVP, !["needs_action", "accept", "tentative", "decline", "removed"].contains(rsvp) { throw FeishuReadError.malformed }
        if let recurring = wire.recurringEventID, !recurring.isEmpty, !validID(recurring) { throw FeishuReadError.malformed }
        let status: FeishuEventStatus = wire.status == "cancelled" || wire.selfRSVP == "removed" ? .cancelled : (wire.selfRSVP == "decline" ? .declined : .active)
        let title = wire.summary ?? ""
        guard title.count <= 200, status != .active || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FeishuReadError.malformed }
        var start: Date?, end: Date?, allDay = false
        let zone = wire.startTime?.timezone ?? wire.endTime?.timezone ?? "Asia/Shanghai"
        guard let timezone = TimeZone(identifier: zone), zone.utf8.count <= 100 else { throw FeishuReadError.malformed }
        if let endZone = wire.endTime?.timezone, endZone != zone { throw FeishuReadError.malformed }
        if wire.startTime != nil || wire.endTime != nil {
            guard let first = wire.startTime, let last = wire.endTime else { throw FeishuReadError.malformed }
            if let firstDate = first.date, let lastDate = last.date, first.timestamp == nil, last.timestamp == nil {
                start = try day(firstDate, timezone: timezone); end = try day(lastDate, timezone: timezone); allDay = true
            } else if let firstTimestamp = first.timestamp, let lastTimestamp = last.timestamp, first.date == nil, last.date == nil {
                start = try timestamp(firstTimestamp); end = try timestamp(lastTimestamp)
            } else { throw FeishuReadError.malformed }
            guard allDay ? end! > start! : end! >= start! else { throw FeishuReadError.malformed }
        } else if status == .active { throw FeishuReadError.malformed }
        let event = FeishuEvent(calendarID: calendarID, eventID: wire.eventID, title: title, start: start, end: end,
                                isAllDay: allDay, timezone: zone, appLink: safeLink(wire.appLink), status: status)
        if status == .active {
            do { _ = try event.metadata() } catch { throw FeishuReadError.malformed }
        }
        return event
    }

    private static func timestamp(_ value: String) throws -> Date {
        guard value.utf8.count <= 13, let epoch = Int64(value), String(epoch) == value, epoch >= -62135596800, epoch <= 253402300799 else { throw FeishuReadError.malformed }
        return Date(timeIntervalSince1970: Double(epoch))
    }
    private static func day(_ value: String, timezone: TimeZone) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard value.utf8.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else { throw FeishuReadError.malformed }
        return date
    }
    private static func safeLink(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 2048, let link = URLComponents(string: value), link.scheme == "https",
              ["applink.feishu.cn", "applink.larkoffice.com"].contains(link.host?.lowercased() ?? ""), link.user == nil, link.password == nil,
              link.port == nil || link.port == 443, link.path == "/client/calendar/event/detail", link.url != nil else { return nil }
        return value
    }

    private static let primaryProjection = "{ok,identity,data:{calendars:(.data.calendars|map({calendar:{calendar_id:.calendar.calendar_id,type:.calendar.type,role:.calendar.role}})),has_more:.data.has_more,page_token:.data.page_token,truncated:.data.truncated},meta:{truncated:.meta.truncated}}"
    private static let itemProjection = "{event_id,summary,start_time,end_time,status,self_rsvp_status,is_exception,recurring_event_id,app_link}"
    private static let instanceProjection = "{ok,identity,data:{items:(.data.items|map(" + itemProjection + ")),has_more:.data.has_more,page_token:.data.page_token,truncated:.data.truncated},meta:{truncated:.meta.truncated}}"
    private static let eventProjection = "{ok,identity,data:{event:(.data.event|" + itemProjection + "),has_more:.data.has_more,page_token:.data.page_token,truncated:.data.truncated},meta:{truncated:.meta.truncated}}"
    private struct Envelope<T: Decodable>: Decodable { let ok: Bool; let identity: String; let data: T? }
    private struct PrimaryData: Decodable { let calendars: [PrimaryEntry] }
    private struct PrimaryEntry: Decodable { let calendar: PrimaryCalendar }
    private struct PrimaryCalendar: Decodable {
        let calendarID: String; let type: String; let role: String
        enum CodingKeys: String, CodingKey { case calendarID = "calendar_id", type, role }
    }
    private struct InstanceData: Decodable { let items: [WireEvent] }
    private struct EventData: Decodable { let event: WireEvent }
    private struct WireTime: Decodable { let date: String?; let timestamp: String?; let timezone: String? }
    private struct WireEvent: Decodable {
        let eventID: String; let summary: String?; let startTime: WireTime?; let endTime: WireTime?
        let status: String; let selfRSVP: String?; let isException: Bool?; let recurringEventID: String?; let appLink: String?
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", summary, startTime = "start_time", endTime = "end_time", status
            case selfRSVP = "self_rsvp_status", isException = "is_exception", recurringEventID = "recurring_event_id", appLink = "app_link"
        }
    }
}

enum FeishuProcessEnvironment {
    static func make(from inherited: [String: String]) -> [String: String] {
        var environment = inherited
        // Login items inherit launchd's minimal PATH, unlike Terminal. The
        // shared CLI uses /usr/bin/env node, so its runtime must be discoverable.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LARKSUITE_CLI_NO_UPDATE_NOTIFIER"] = "1"
        environment["LARKSUITE_CLI_NO_SKILLS_NOTIFIER"] = "1"
        return environment
    }
}

// The production boundary has a fixed executable, no shell, concurrent bounded
// stdout/stderr drains, a monotonic timeout, and cancellation of its own child.
private final class FeishuReadProcess: @unchecked Sendable {
    static let maximumOutput = 1024 * 1024
    private let lock = NSLock()
    private let process = Process(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    private var continuation: CheckedContinuation<FeishuCLIOutput, Error>?
    private var finished = false, stdoutEnded = false, stderrEnded = false
    private var code: Int32?, stdout = Data(), stderr = Data()

    static func execute(arguments: [String], timeout: TimeInterval) async throws -> FeishuCLIOutput {
        let job = FeishuReadProcess()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                job.lock.lock()
                if job.finished { job.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                job.continuation = continuation; job.lock.unlock()
                DispatchQueue.global(qos: .utility).async { job.start(arguments: arguments, timeout: timeout) }
            }
        }, onCancel: { job.finish(.failure(CancellationError())) })
    }
    private func start(arguments: [String], timeout: TimeInterval) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        process.executableURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("lark-cli")
        process.arguments = arguments
        process.environment = FeishuProcessEnvironment.make(from: ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = stdoutPipe; process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.drain(handle, isError: false) }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.drain(handle, isError: true) }
        process.terminationHandler = { [weak self] process in self?.terminated(process.terminationStatus) }
        do { try process.run(); lock.unlock() }
        catch { lock.unlock(); finish(.failure(FeishuReadError.processFailed)); return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, min(12, timeout))) { [weak self] in self?.finish(.failure(FeishuReadError.timeout)) }
    }
    private func drain(_ handle: FileHandle, isError: Bool) {
        do {
            let data = try handle.read(upToCount: 4096) ?? Data()
            lock.lock()
            guard !finished else { lock.unlock(); return }
            if data.isEmpty { if isError { stderrEnded = true } else { stdoutEnded = true }; handle.readabilityHandler = nil }
            else if isError { if stderr.count < 16 * 1024 { stderr.append(data.prefix(16 * 1024 - stderr.count)) } }
            else { stdout.append(data) }
            let oversized = stdout.count > Self.maximumOutput
            let complete = stdoutEnded && stderrEnded && code != nil
            let output = complete ? FeishuCLIOutput(exitCode: code!, stdout: stdout, stderr: stderr) : nil
            lock.unlock()
            if oversized { finish(.failure(FeishuReadError.tooLarge)) }
            else if let output { finish(.success(output)) }
        } catch { finish(.failure(FeishuReadError.processFailed)) }
    }
    private func terminated(_ code: Int32) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        self.code = code
        let output = stdoutEnded && stderrEnded ? FeishuCLIOutput(exitCode: code, stdout: stdout, stderr: stderr) : nil
        lock.unlock()
        if let output { finish(.success(output)) }
    }
    private func finish(_ result: Result<FeishuCLIOutput, Error>) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        finished = true; let continuation = self.continuation; self.continuation = nil
        let running = process.isRunning; lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil; stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe.fileHandleForReading.close(); try? stderrPipe.fileHandleForReading.close()
        if running {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [process] in
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        continuation?.resume(with: result)
    }
}
