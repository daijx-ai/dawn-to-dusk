import Foundation

enum AgendaQueryError: LocalizedError {
    case invalidArguments, invalidRequest, invalidDate, oversized, invalidDocument, unsupportedVersion, unreadableDocument
    var errorDescription: String? {
        switch self {
        case .invalidArguments: return "查询参数无效；使用 --query，隔离查询须同时提供 --qa --data-dir <绝对路径>。"
        case .invalidRequest: return "查询 JSON 仅支持可选的 date 字符串。"
        case .invalidDate: return "查询日期需为有效的 YYYY-MM-DD。"
        case .oversized: return "查询请求超过 16 KiB。"
        case .invalidDocument: return "日程文件损坏或内容无效，未修改任何数据。"
        case .unsupportedVersion: return "日程数据版本不受支持，未修改任何数据。"
        case .unreadableDocument: return "日程文件不存在或无法读取，未创建任何数据。"
        }
    }
}

struct AgendaQueryRequest: Decodable {
    let date: String?
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard container.allKeys.allSatisfy({ $0.stringValue == "date" }) else { throw AgendaQueryError.invalidRequest }
        let key = Key(stringValue: "date")!
        date = container.contains(key) ? try container.decode(String.self, forKey: key) : nil
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
    enum CodingKeys: String, CodingKey {
        case id, title, date, time, completed, tentative
        case occurrenceID = "occurrence_id", baseTime = "base_time", durationMinutes = "duration_minutes", repeatRule = "repeat_rule"
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
    }
}

struct AgendaQueryChecklistRow: Encodable {
    let id: UUID
    let title: String
    let completed: Bool
}

struct AgendaQueryResult: Encodable {
    let ok = true
    let status = "queried"
    let readOnly = true
    let timezone = "Asia/Shanghai"
    let date: String
    let generatedAt: String
    let schedule: [AgendaQueryScheduleRow]
    let checklist: [AgendaQueryChecklistRow]
    enum CodingKeys: String, CodingKey {
        case ok, status, timezone, date, schedule, checklist
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
    }
    static func query(data: Data, on day: Date? = nil, now: Date = Date()) throws -> AgendaQueryResult {
        guard FeishuMetadata.validDate(now), FeishuMetadata.validDate(day ?? now) else { throw AgendaQueryError.invalidDate }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw AgendaQueryError.invalidDocument }
        guard document.version == 1 else { throw AgendaQueryError.unsupportedVersion }
        try validate(document)
        let selectedDay = AgendaClock.startOfDay(day ?? now)
        let date = AgendaClock.dayKey(selectedDay)
        let schedule = AgendaClock.occurrences(items: document.items, on: selectedDay).map { occurrence in
            AgendaQueryScheduleRow(id: occurrence.item.id, occurrenceID: occurrence.id, title: occurrence.title, date: date,
                                   time: occurrence.due.map(AgendaClock.timeText), baseTime: occurrence.item.timeMinutes.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) },
                                   durationMinutes: occurrence.item.durationMinutes, repeatRule: occurrence.item.repeatRule,
                                   completed: occurrence.isCompleted, tentative: occurrence.item.isTentative)
        }
        let checklist = document.items.filter(\.isChecklist).map { AgendaQueryChecklistRow(id: $0.id, title: $0.title, completed: $0.checklistState == .completed) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return AgendaQueryResult(date: date, generatedAt: formatter.string(from: now), schedule: schedule, checklist: checklist)
    }
    private static func validate(_ document: Document) throws {
        guard (0...1440).contains(document.settings.leadMinutes), !document.settings.theme.isEmpty,
              Set(document.items.map(\.id)).count == document.items.count else { throw AgendaQueryError.invalidDocument }
        for item in document.items {
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.title.count <= 200, item.note.count <= 2000,
                  FeishuMetadata.validDate(item.date), item.timeMinutes.map({ (0...1439).contains($0) }) ?? true,
                  item.durationMinutes >= 0, item.feishu != nil || item.durationMinutes <= 1440 else { throw AgendaQueryError.invalidDocument }
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
            let keys = item.completedDays.union(item.snoozes.keys).union((item.postponedTimes ?? [:]).keys)
            guard keys.allSatisfy({ AgendaQueryRequest.parsedDay($0) != nil }), item.snoozes.values.allSatisfy(FeishuMetadata.validDate) else { throw AgendaQueryError.invalidDocument }
            for (key, target) in item.postponedTimes ?? [:] {
                var original = item
                original.postponedTimes = nil
                guard FeishuMetadata.validDate(target), let occurrence = AgendaClock.occurrence(items: [original], id: item.id.uuidString + ":" + key),
                      let due = occurrence.due, target > due else { throw AgendaQueryError.invalidDocument }
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
            let day = try request.day(now: now)
            let data: Data
            do { data = try environment.readDocument(options.root.appendingPathComponent("agenda.json")) }
            catch { throw AgendaQueryError.unreadableDocument }
            let result = try AgendaQueryReader.query(data: data, on: day, now: now)
            environment.output(try JSONEncoder().encode(result))
            return 0
        } catch {
            let message = (error as? AgendaQueryError)?.localizedDescription ?? AgendaQueryError.invalidRequest.localizedDescription
            let result = ["ok": false, "status": "invalid", "read_only": true, "error": message] as [String: Any]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { environment.output(data) }
            return 1
        }
    }
}
