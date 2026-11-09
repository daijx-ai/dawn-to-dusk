import Foundation

enum AgendaQueryError: LocalizedError {
    case invalidArguments, invalidRequest, invalidDate, oversized, invalidDocument, unsupportedVersion, unreadableDocument
    var errorDescription: String? {
        switch self {
        case .invalidArguments: return "查询参数无效；使用 --query，隔离查询须同时提供 --qa --data-dir <绝对路径>。"
        case .invalidRequest: return "查询 JSON 仅支持 {}、{\"date\":\"YYYY-MM-DD\"} 或 {\"from\":\"YYYY-MM-DD\",\"to\":\"YYYY-MM-DD\"}（最多 31 天）。"
        case .invalidDate: return "查询日期需为有效的 YYYY-MM-DD。"
        case .oversized: return "查询请求超过 16 KiB。"
        case .invalidDocument: return "日程文件损坏或内容无效，未修改任何数据。"
        case .unsupportedVersion: return "日程数据版本不受支持，未修改任何数据。"
        case .unreadableDocument: return "日程文件不存在或无法读取，未创建任何数据。"
        }
    }
}

struct AgendaQueryRequest: Decodable {
    static let maximumRangeDays = 31
    let date: String?
    let from: String?
    let to: String?
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard container.allKeys.allSatisfy({ ["date", "from", "to"].contains($0.stringValue) }) else { throw AgendaQueryError.invalidRequest }
        func value(_ name: String) throws -> String? {
            let key = Key(stringValue: name)!
            return container.contains(key) ? try container.decode(String.self, forKey: key) : nil
        }
        date = try value("date"); from = try value("from"); to = try value("to")
        guard date == nil || (from == nil && to == nil), (from == nil) == (to == nil) else { throw AgendaQueryError.invalidRequest }
    }
    var isRange: Bool { from != nil }
    /// Requested days in order; a range is inclusive and limited to 31 days.
    func days(now: Date) throws -> [Date] {
        guard let from, let to else { return [try day(now: now)] }
        guard let start = Self.parsedDay(from), let end = Self.parsedDay(to) else { throw AgendaQueryError.invalidDate }
        guard start <= end, let span = AgendaClock.calendar.dateComponents([.day], from: start, to: end).day, span < Self.maximumRangeDays else { throw AgendaQueryError.invalidRequest }
        return (0...span).map { AgendaClock.calendar.date(byAdding: .day, value: $0, to: start)! }
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= AgendaQueryCLI.maximumInputBytes else { throw AgendaQueryError.oversized }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw AgendaQueryError.invalidRequest }
    }
    func day(now: Date) throws -> Date {
        guard FeishuMetadata.validDate(now) else { throw AgendaQueryError.invalidDate }
        guard let date else { return AgendaClock.startOfDay(now) }
        guard let day = Self.parsedDay(date) else { throw AgendaQueryError.invalidDate }
        return day
    }
    static func parsedDay(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }) else { return nil }
        let parts = text.split(separator: "-")
        guard let year = Int(parts[0]), (1...9999).contains(year), let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day),
              let result = AgendaClock.calendar.date(from: DateComponents(year: year, month: month, day: day)),
              FeishuMetadata.validDate(result), AgendaClock.dayKey(result) == text else { return nil }
        return result
    }
}

struct AgendaQueryScheduleRow: Encodable {
    let id: UUID
    let occurrenceID: String
    let title: String
    let date: String
    let time: String?
    let baseTime: String?
    let durationMinutes: Int
    let repeatRule: RepeatRule
    let completed: Bool
    let tentative: Bool
    let revision: String
    let note: String
    let source: String
    let captureRequestID: String?
    let feishuReadonly: Bool
    enum CodingKeys: String, CodingKey {
        case id, title, date, time, completed, tentative, revision, note, source
        case occurrenceID = "occurrence_id", baseTime = "base_time", durationMinutes = "duration_minutes", repeatRule = "repeat_rule"
        case captureRequestID = "capture_request_id", feishuReadonly = "feishu_readonly"
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(occurrenceID, forKey: .occurrenceID)
        try container.encode(title, forKey: .title)
        try container.encode(date, forKey: .date)
        try container.encode(time, forKey: .time)
        try container.encode(baseTime, forKey: .baseTime)
        try container.encode(durationMinutes, forKey: .durationMinutes)
        try container.encode(repeatRule, forKey: .repeatRule)
        try container.encode(completed, forKey: .completed)
        try container.encode(tentative, forKey: .tentative)
        try container.encode(revision, forKey: .revision)
        try container.encode(note, forKey: .note)
        try container.encode(source, forKey: .source)
        try container.encode(captureRequestID, forKey: .captureRequestID)
        try container.encode(feishuReadonly, forKey: .feishuReadonly)
    }
}

/// A repeating occurrence hidden by skip_once or pause_range; not deleted, can be resumed.
struct AgendaQuerySkippedRow: Encodable {
    let id: UUID
    let occurrenceID: String
    let title: String
    let date: String
    let baseTime: String?
    let repeatRule: RepeatRule
    let revision: String
    let skippedBy: String
    let pausedUntil: String?
    enum CodingKeys: String, CodingKey {
        case id, title, date, revision
        case occurrenceID = "occurrence_id", baseTime = "base_time", repeatRule = "repeat_rule", skippedBy = "skipped_by", pausedUntil = "paused_until"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(occurrenceID, forKey: .occurrenceID); try c.encode(title, forKey: .title)
        try c.encode(date, forKey: .date); try c.encode(baseTime, forKey: .baseTime); try c.encode(repeatRule, forKey: .repeatRule)
        try c.encode(revision, forKey: .revision); try c.encode(skippedBy, forKey: .skippedBy); try c.encode(pausedUntil, forKey: .pausedUntil)
    }
}

struct AgendaQueryChecklistRow: Encodable {
    let id: UUID
    let title: String
    let completed: Bool
    let revision: String
    let note: String
    let source: String
    let captureRequestID: String?
    enum CodingKeys: String, CodingKey { case id, title, completed, revision, note, source, captureRequestID = "capture_request_id" }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(completed, forKey: .completed)
        try c.encode(revision, forKey: .revision); try c.encode(note, forKey: .note); try c.encode(source, forKey: .source)
        try c.encode(captureRequestID, forKey: .captureRequestID)
    }
}

struct AgendaQueryDay: Encodable {
    let date: String
    let schedule: [AgendaQueryScheduleRow]
    let skipped: [AgendaQuerySkippedRow]
}

struct AgendaQueryRangeResult: Encodable {
    let ok = true
    let status = "queried"
    let readOnly = true
    let timezone = "Asia/Shanghai"
    let from: String
    let to: String
    let generatedAt: String
    let days: [AgendaQueryDay]
    let checklist: [AgendaQueryChecklistRow]
    enum CodingKeys: String, CodingKey {
        case ok, status, timezone, from, to, days, checklist
        case readOnly = "read_only", generatedAt = "generated_at"
    }
}

struct AgendaQueryResult: Encodable {
    let ok = true
    let status = "queried"
    let readOnly = true
    let timezone = "Asia/Shanghai"
    let date: String
    let generatedAt: String
    let schedule: [AgendaQueryScheduleRow]
    let skipped: [AgendaQuerySkippedRow]
    let checklist: [AgendaQueryChecklistRow]
    enum CodingKeys: String, CodingKey {
        case ok, status, timezone, date, schedule, skipped, checklist
        case readOnly = "read_only", generatedAt = "generated_at"
    }
}

enum AgendaQueryReader {
    private struct Document: Decodable {
        let version: Int
        let items: [AgendaItem]
        let settings: AgendaSettings
        let captureReceipts: [String: AgendaCaptureReceipt]?
        let feishuSyncState: FeishuSyncState?
        let changeReceipts: [String: AgendaChangeReceipt]?
        let changeLog: [AgendaChangeRecord]?
    }
    private static func load(_ data: Data) throws -> Document {
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw AgendaQueryError.invalidDocument }
        guard document.version == 1 else { throw AgendaQueryError.unsupportedVersion }
        try validate(document)
        return document
    }
    private static func clock(_ minutes: Int?) -> String? { minutes.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } }
    private static func day(_ document: Document, _ selectedDay: Date, origins: [UUID: AgendaItemOrigin]) -> AgendaQueryDay {
        let date = AgendaClock.dayKey(selectedDay)
        let schedule = AgendaClock.occurrences(items: document.items, on: selectedDay).map { occurrence in
            let origin = AgendaItemOrigin.of(occurrence.item, index: origins)
            return AgendaQueryScheduleRow(id: occurrence.item.id, occurrenceID: occurrence.id, title: occurrence.title, date: date,
                                   time: occurrence.due.map(AgendaClock.timeText), baseTime: clock(occurrence.item.timeMinutes(on: occurrence.day)),
                                   durationMinutes: occurrence.item.durationMinutes, repeatRule: occurrence.item.repeatRule,
                                   completed: occurrence.isCompleted, tentative: occurrence.item.isTentative,
                                   revision: AgendaRevision.of(occurrence.item), note: occurrence.item.note, source: origin.source,
                                   captureRequestID: origin.captureRequestID, feishuReadonly: occurrence.item.feishu != nil)
        }
        let skipped = AgendaClock.skippedOccurrences(items: document.items, on: selectedDay).map { occurrence in
            let range = (occurrence.item.pausedRanges ?? []).first { $0.contains(date) }
            return AgendaQuerySkippedRow(id: occurrence.item.id, occurrenceID: occurrence.id, title: occurrence.title, date: date,
                                         baseTime: clock(occurrence.item.timeMinutes(on: occurrence.day)), repeatRule: occurrence.item.repeatRule,
                                         revision: AgendaRevision.of(occurrence.item), skippedBy: range == nil ? "skip_once" : "pause_range", pausedUntil: range?.to)
        }
        return AgendaQueryDay(date: date, schedule: schedule, skipped: skipped)
    }
    private static func checklist(_ document: Document, origins: [UUID: AgendaItemOrigin]) -> [AgendaQueryChecklistRow] {
        document.items.filter(\.isChecklist).map { item in
            let origin = AgendaItemOrigin.of(item, index: origins)
            return AgendaQueryChecklistRow(id: item.id, title: item.title, completed: item.checklistState == .completed, revision: AgendaRevision.of(item),
                                           note: item.note, source: origin.source, captureRequestID: origin.captureRequestID)
        }
    }
    private static func timestamp(_ now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now)
    }
    static func query(data: Data, on day: Date? = nil, now: Date = Date()) throws -> AgendaQueryResult {
        guard FeishuMetadata.validDate(now), FeishuMetadata.validDate(day ?? now) else { throw AgendaQueryError.invalidDate }
        let document = try load(data)
        let origins = AgendaItemOrigin.index(document.captureReceipts ?? [:])
        let value = Self.day(document, AgendaClock.startOfDay(day ?? now), origins: origins)
        return AgendaQueryResult(date: value.date, generatedAt: timestamp(now), schedule: value.schedule, skipped: value.skipped, checklist: checklist(document, origins: origins))
    }
    static func query(data: Data, days: [Date], now: Date = Date()) throws -> AgendaQueryRangeResult {
        guard FeishuMetadata.validDate(now), let first = days.first, let last = days.last, days.count <= AgendaQueryRequest.maximumRangeDays else { throw AgendaQueryError.invalidDate }
        let document = try load(data)
        let origins = AgendaItemOrigin.index(document.captureReceipts ?? [:])
        return AgendaQueryRangeResult(from: AgendaClock.dayKey(first), to: AgendaClock.dayKey(last), generatedAt: timestamp(now),
                                      days: days.map { Self.day(document, AgendaClock.startOfDay($0), origins: origins) }, checklist: checklist(document, origins: origins))
    }
    /// `--change --dry-run`: evaluate against the saved file only. Window drafts are not visible here.
    static func previewChange(_ request: AgendaChangeRequest, data: Data, now: Date = Date()) throws -> AgendaChangeResult {
        let document = try load(data)
        let state = AgendaChangeState(items: document.items, receipts: document.changeReceipts ?? [:], log: document.changeLog ?? [])
        var (result, _) = AgendaChangeEngine.apply(request, state: state, captureReceipts: document.captureReceipts ?? [:], editing: [], now: now)
        result.dryRun = true
        result.saved = false
        if result.ok && result.status != "already_processed" {
            result.expectedStatus = result.status
            result.status = "preview"
            result.recordID = nil
            result.message = L("仅预览，未保存；朝夕窗口若正在编辑该事项，实际提交仍会返回 conflict")
        }
        return result
    }
    private static func validate(_ document: Document) throws {
        guard (0...1440).contains(document.settings.leadMinutes), !document.settings.theme.isEmpty,
              Set(document.items.map(\.id)).count == document.items.count else { throw AgendaQueryError.invalidDocument }
        for item in document.items {
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.title.count <= 200, item.note.count <= 2000,
                  FeishuMetadata.validDate(item.date), item.timeMinutes.map({ (0...1439).contains($0) }) ?? true,
                  item.durationMinutes >= 0, item.feishu != nil || item.durationMinutes <= 1440 else { throw AgendaQueryError.invalidDocument }
            if let times = item.weeklyTimes {
                guard item.repeatRule == .weekly, !item.isChecklist, item.feishu == nil,
                      item.timeMinutes != nil, !times.isEmpty,
                      times.allSatisfy({ key, value in ["1", "2", "3", "4", "5", "6", "7"].contains(key) && (0...1439).contains(value) }) else { throw AgendaQueryError.invalidDocument }
            }
            if let source = item.feishu {
                do { try source.validate() } catch { throw AgendaQueryError.invalidDocument }
                guard !item.isChecklist, item.repeatRule == .none, !item.isTentative, (item.postponedTimes ?? [:]).isEmpty,
                      item.date == source.displayStartDay, item.timeMinutes == source.timeMinutes, item.durationMinutes == source.durationMinutes,
                      !source.isAllDay || !item.reminderEnabled, item.completedDays.isSubset(of: [source.completionKey]),
                      Set(item.snoozes.keys).isSubset(of: [source.completionKey]), !source.isAllDay || item.snoozes.isEmpty else { throw AgendaQueryError.invalidDocument }
            }
            if item.isChecklist {
                guard item.timeMinutes == nil, item.durationMinutes == 0, item.repeatRule == .none, !item.reminderEnabled,
                      !item.isTentative, item.completedDays.isEmpty, item.snoozes.isEmpty, (item.postponedTimes ?? [:]).isEmpty else { throw AgendaQueryError.invalidDocument }
            }
            if item.hasSkips {
                guard item.feishu == nil, !item.isChecklist,
                      (item.skippedDays ?? []).allSatisfy({ AgendaQueryRequest.parsedDay($0) != nil }),
                      (item.pausedRanges ?? []).allSatisfy({ $0.from <= $0.to && AgendaQueryRequest.parsedDay($0.from) != nil && AgendaQueryRequest.parsedDay($0.to) != nil }) else { throw AgendaQueryError.invalidDocument }
            }
            let keys = item.completedDays.union(item.snoozes.keys).union((item.postponedTimes ?? [:]).keys)
            guard keys.allSatisfy({ AgendaQueryRequest.parsedDay($0) != nil }), item.snoozes.values.allSatisfy(FeishuMetadata.validDate) else { throw AgendaQueryError.invalidDocument }
            for (key, target) in item.postponedTimes ?? [:] {
                var original = item
                original.postponedTimes = nil; original.skippedDays = nil; original.pausedRanges = nil
                guard FeishuMetadata.validDate(target), let occurrence = AgendaClock.occurrence(items: [original], id: item.id.uuidString + ":" + key),
                      occurrence.due != nil else { throw AgendaQueryError.invalidDocument }
            }
        }
    }
}

struct AgendaQueryCLIOptions {
    let root: URL
    static func parse(_ arguments: [String], productionRoot: URL) throws -> Self {
        guard productionRoot.isFileURL, productionRoot.path.hasPrefix("/") else { throw AgendaQueryError.invalidArguments }
        var seen = Set<String>(), index = 0, dataPath: String?
        while index < arguments.count {
            let argument = arguments[index]
            guard ["--query", "--qa", "--data-dir"].contains(argument), seen.insert(argument).inserted else { throw AgendaQueryError.invalidArguments }
            if argument == "--data-dir" {
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else { throw AgendaQueryError.invalidArguments }
                dataPath = arguments[index]
            }
            index += 1
        }
        guard seen.contains("--query"), seen.contains("--qa") == (dataPath != nil) else { throw AgendaQueryError.invalidArguments }
        let root = dataPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? productionRoot
        if seen.contains("--qa") {
            do { try AgendaDataPathSafety.validateQA(root, productionRoot: productionRoot) }
            catch { throw AgendaQueryError.invalidArguments }
        }
        return Self(root: root)
    }
}

struct AgendaQueryCLIEnvironment {
    var readInput: () throws -> Data
    var readDocument: (URL) throws -> Data
    var output: (Data) -> Void
    var now: () -> Date
}

enum AgendaQueryCLI {
    static let maximumInputBytes = 16 * 1024
    static func run(arguments: [String], productionRoot: URL) -> Int32 {
        run(arguments: arguments, productionRoot: productionRoot, environment: AgendaQueryCLIEnvironment(
            readInput: {
                var data = Data()
                while let part = try FileHandle.standardInput.read(upToCount: min(4096, maximumInputBytes + 1 - data.count)), !part.isEmpty {
                    data.append(part)
                    guard data.count <= maximumInputBytes else { throw AgendaQueryError.oversized }
                }
                return data
            },
            readDocument: { try Data(contentsOf: $0) },
            output: { FileHandle.standardOutput.write($0); FileHandle.standardOutput.write(Data([10])) },
            now: Date.init
        ))
    }
    static func run(arguments: [String], productionRoot: URL, environment: AgendaQueryCLIEnvironment) -> Int32 {
        do {
            let options = try AgendaQueryCLIOptions.parse(arguments, productionRoot: productionRoot)
            let request = try AgendaQueryRequest.decode(environment.readInput())
            let now = environment.now()
            let days = try request.days(now: now)
            let data: Data
            do { data = try environment.readDocument(options.root.appendingPathComponent("agenda.json")) }
            catch { throw AgendaQueryError.unreadableDocument }
            if request.isRange { environment.output(try JSONEncoder().encode(AgendaQueryReader.query(data: data, days: days, now: now))) }
            else { environment.output(try JSONEncoder().encode(AgendaQueryReader.query(data: data, on: days[0], now: now))) }
            return 0
        } catch {
            let message = (error as? AgendaQueryError)?.localizedDescription ?? AgendaQueryError.invalidRequest.localizedDescription
            let result = ["ok": false, "status": "invalid", "read_only": true, "error": message] as [String: Any]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { environment.output(data) }
            return 1
        }
    }
}

enum AgendaChangePreviewCLI {
    /// Reads `agenda.json` read-only and returns the encoded dry-run receipt.
    static func preview(_ request: AgendaChangeRequest, root: URL, now: Date = Date(), readDocument: (URL) throws -> Data = { try Data(contentsOf: $0) }) throws -> Data {
        let result: AgendaChangeResult
        do {
            let data: Data
            do { data = try readDocument(root.appendingPathComponent("agenda.json")) }
            catch { throw AgendaQueryError.unreadableDocument }
            result = try AgendaQueryReader.previewChange(request, data: data, now: now)
        } catch let error as AgendaQueryError {
            var failed = AgendaChangeResult(ok: false, status: "invalid", requestID: request.requestID, error: error.localizedDescription)
            failed.dryRun = true
            result = failed
        }
        return try JSONEncoder().encode(result)
    }
}
