import Foundation
import CryptoKit

// External change API (`--change`). Everything here is pure: the Store commits
// the returned state, the CLI dry-run only reads it.

enum AgendaRevision {
    private struct Canonical: Encodable {
        let id: String, title: String, date: Double, timeMinutes: Int?, durationMinutes: Int, category: String, note: String
        let isTentative: Bool, reminderEnabled: Bool, repeatRule: String, weeklyTimes: [String: Int]?
        let completedDays: [String], snoozes: [String: Double], postponedTimes: [String: Double]?
        let checklistState: String?, feishu: FeishuMetadata?, skippedDays: [String]?, pausedRanges: [AgendaDayRange]?
    }
    /// Content hash of one item. Sets are sorted so every process computes the same value.
    static func of(_ item: AgendaItem) -> String {
        let value = Canonical(id: item.id.uuidString, title: item.title, date: item.date.timeIntervalSinceReferenceDate,
                              timeMinutes: item.timeMinutes, durationMinutes: item.durationMinutes, category: item.category, note: item.note,
                              isTentative: item.isTentative, reminderEnabled: item.reminderEnabled, repeatRule: item.repeatRule.rawValue,
                              weeklyTimes: item.weeklyTimes, completedDays: item.completedDays.sorted(),
                              snoozes: item.snoozes.mapValues(\.timeIntervalSinceReferenceDate),
                              postponedTimes: item.postponedTimes?.mapValues(\.timeIntervalSinceReferenceDate),
                              checklistState: item.checklistState?.rawValue, feishu: item.feishu,
                              skippedDays: (item.skippedDays ?? []).isEmpty ? nil : item.skippedDays!.sorted(),
                              pausedRanges: (item.pausedRanges ?? []).isEmpty ? nil : item.pausedRanges)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data(item.id.uuidString.utf8)
        return "r" + SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Where an item came from, derived from persisted capture receipts.
struct AgendaItemOrigin {
    let source: String
    let captureRequestID: String?
    static func index(_ receipts: [String: AgendaCaptureReceipt]) -> [UUID: AgendaItemOrigin] {
        var result: [UUID: AgendaItemOrigin] = [:]
        for (requestID, receipt) in receipts { result[receipt.itemID] = AgendaItemOrigin(source: receipt.source, captureRequestID: requestID) }
        return result
    }
    static func of(_ item: AgendaItem, index: [UUID: AgendaItemOrigin]) -> AgendaItemOrigin {
        if item.feishu != nil { return AgendaItemOrigin(source: "feishu", captureRequestID: nil) }
        return index[item.id] ?? AgendaItemOrigin(source: "ui", captureRequestID: nil)
    }
}

/// Full item snapshot used in change receipts (`before` / `after` / `current`).
struct AgendaItemView: Encodable, Equatable {
    let item: AgendaItem
    let origin: AgendaItemOrigin
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.item == rhs.item }
    enum CodingKeys: String, CodingKey {
        case id, revision, title, note, type, date, time, tentative, source
        case durationMinutes = "duration_minutes", repeatRule = "repeat_rule", weeklyTimes = "weekly_times"
        case reminderEnabled = "reminder_enabled", completedDays = "completed_days", checklistCompleted = "checklist_completed"
        case postponed = "postponed", skippedDays = "skipped_days", pausedRanges = "paused_ranges"
        case captureRequestID = "capture_request_id", feishuReadonly = "feishu_readonly"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(item.id, forKey: .id)
        try c.encode(AgendaRevision.of(item), forKey: .revision)
        try c.encode(item.title, forKey: .title)
        try c.encode(item.note, forKey: .note)
        try c.encode(item.isChecklist ? "checklist" : "scheduled", forKey: .type)
        try c.encode(item.scheduledDay.map(AgendaClock.dayKey), forKey: .date)
        try c.encode(item.timeMinutes.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }, forKey: .time)
        try c.encode(item.durationMinutes, forKey: .durationMinutes)
        try c.encode(item.repeatRule, forKey: .repeatRule)
        try c.encode(item.weeklyTimes?.mapValues { String(format: "%02d:%02d", $0 / 60, $0 % 60) }, forKey: .weeklyTimes)
        try c.encode(item.isTentative, forKey: .tentative)
        try c.encode(item.reminderEnabled, forKey: .reminderEnabled)
        try c.encode(item.completedDays.sorted(), forKey: .completedDays)
        try c.encode(item.isChecklist ? Optional(item.checklistState == .completed) : nil, forKey: .checklistCompleted)
        try c.encode((item.postponedTimes ?? [:]).mapValues { AgendaClock.dayKey($0) + " " + AgendaClock.timeText($0) }, forKey: .postponed)
        try c.encode((item.skippedDays ?? []).sorted(), forKey: .skippedDays)
        try c.encode(item.pausedRanges ?? [], forKey: .pausedRanges)
        try c.encode(origin.source, forKey: .source)
        try c.encode(origin.captureRequestID, forKey: .captureRequestID)
        try c.encode(item.feishu != nil, forKey: .feishuReadonly)
    }
}

enum AgendaChangeOp: String, CaseIterable {
    case update, delete, restore, complete, reopen, resume
    case rescheduleOnce = "reschedule_once", skipOnce = "skip_once", pauseRange = "pause_range"
    var doneStatus: String {
        switch self {
        case .update: return "updated"
        case .delete: return "deleted"
        case .restore: return "restored"
        case .complete: return "completed"
        case .reopen: return "reopened"
        case .resume: return "resumed"
        case .rescheduleOnce: return "rescheduled"
        case .skipOnce: return "skipped"
        case .pauseRange: return "paused"
        }
    }
    var label: String {
        switch self {
        case .update: return L("修改")
        case .delete: return L("删除")
        case .restore: return L("恢复删除")
        case .complete: return L("标记完成")
        case .reopen: return L("恢复待办")
        case .resume: return L("恢复跳过")
        case .rescheduleOnce: return L("仅改这一次")
        case .skipOnce: return L("跳过一次")
        case .pauseRange: return L("暂停一段时间")
        }
    }
}

enum AgendaTimeField: Equatable { case absent, clear, value(Int) }

struct AgendaChangeFields: Equatable {
    var title: String? = nil
    var note: String? = nil
    var date: String? = nil
    var time: AgendaTimeField = .absent
    var durationMinutes: Int? = nil
    var repeatRule: RepeatRule? = nil
    var tentative: Bool? = nil
    var reminderEnabled: Bool? = nil
    var isEmpty: Bool { self == AgendaChangeFields() }
    var touchesSchedule: Bool { date != nil || time != .absent || durationMinutes != nil || repeatRule != nil || tentative != nil || reminderEnabled != nil }
}

struct AgendaChangeTarget: Equatable {
    var itemID: UUID? = nil
    var occurrenceID: String? = nil
    var captureRequestID: String? = nil
}

struct AgendaChangeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AgendaChangeRequest: Equatable {
    static let maximumPauseDays = 366
    var requestID: String
    var op: AgendaChangeOp
    var target: AgendaChangeTarget
    var ifMatch: String? = nil
    var fields = AgendaChangeFields()
    var occurrenceID: String? = nil
    var newDate: String? = nil
    var newTime: String? = nil
    var from: String? = nil
    var to: String? = nil
    var source = "cli"

    /// Strict parser: unknown keys, wrong JSON types and op-irrelevant fields are rejected.
    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 else { throw AgendaChangeError("修改请求超过 16 KiB") }
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else { throw AgendaChangeError("stdin 必须是 JSON 对象") }
        let allowed: Set<String> = ["request_id", "op", "target", "if_match", "fields", "occurrence_id", "new_date", "new_time", "from", "to", "source"]
        guard Set(root.keys).isSubset(of: allowed) else { throw AgendaChangeError("存在不支持的字段：" + Set(root.keys).subtracting(allowed).sorted().joined(separator: ", ")) }
        guard let requestID = root["request_id"] as? String, AgendaCaptureRequest.validRequestID(requestID) else { throw AgendaChangeError("request_id 需为 1–128 个英文字母、数字或 . _ : -") }
        guard let opText = root["op"] as? String, let op = AgendaChangeOp(rawValue: opText) else {
            throw AgendaChangeError("op 只能为 " + AgendaChangeOp.allCases.map(\.rawValue).joined(separator: "、"))
        }
        var request = Self(requestID: requestID, op: op, target: AgendaChangeTarget())
        guard let target = root["target"] as? [String: Any], target.count == 1, let key = target.keys.first, let text = target[key] as? String else {
            throw AgendaChangeError("target 需为只含 item_id、occurrence_id 或 capture_request_id 之一的对象")
        }
        switch key {
        case "item_id":
            guard let id = UUID(uuidString: text) else { throw AgendaChangeError("target.item_id 需为 UUID") }
            request.target.itemID = id
        case "occurrence_id": request.target.occurrenceID = try normalizedOccurrence(text)
        case "capture_request_id":
            guard AgendaCaptureRequest.validRequestID(text) else { throw AgendaChangeError("target.capture_request_id 无效") }
            request.target.captureRequestID = text
        default: throw AgendaChangeError("target 只能使用 item_id、occurrence_id 或 capture_request_id")
        }
        func string(_ name: String) throws -> String? {
            guard let value = root[name] else { return nil }
            guard let text = value as? String else { throw AgendaChangeError(name + " 必须是字符串") }
            return text
        }
        if let match = try string("if_match") {
            guard (1...64).contains(match.utf8.count) else { throw AgendaChangeError("if_match 需为查询返回的 revision") }
            request.ifMatch = match
        }
        if let occurrence = try string("occurrence_id") { request.occurrenceID = try normalizedOccurrence(occurrence) }
        if let value = try string("new_date") { request.newDate = try day(value, "new_date") }
        if let value = try string("new_time") { request.newTime = try clock(value, "new_time") }
        if let value = try string("from") { request.from = try day(value, "from") }
        if let value = try string("to") { request.to = try day(value, "to") }
        if let value = try string("source") {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "hermes" || normalized == "cli" else { throw AgendaChangeError("来源只能为 hermes 或 cli") }
            request.source = normalized
        }
        if let raw = root["fields"] {
            guard let fields = raw as? [String: Any] else { throw AgendaChangeError("fields 必须是对象") }
            request.fields = try parseFields(fields)
        }
        try request.validateShape()
        return request
    }

    private static func parseFields(_ fields: [String: Any]) throws -> AgendaChangeFields {
        let allowed: Set<String> = ["title", "note", "date", "time", "duration_minutes", "repeat_rule", "tentative", "reminder_enabled"]
        guard Set(fields.keys).isSubset(of: allowed) else { throw AgendaChangeError("fields 存在不支持的字段：" + Set(fields.keys).subtracting(allowed).sorted().joined(separator: ", ")) }
        var result = AgendaChangeFields()
        if let value = fields["title"] {
            guard let text = value as? String else { throw AgendaChangeError("title 必须是字符串") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 200 else { throw AgendaChangeError("标题需为 1–200 字") }
            result.title = trimmed
        }
        if let value = fields["note"] {
            guard let text = value as? String, text.count <= 2000 else { throw AgendaChangeError("note 需为不超过 2000 字的字符串") }
            result.note = text
        }
        if let value = fields["date"] {
            guard let text = value as? String else { throw AgendaChangeError("date 必须是 YYYY-MM-DD 字符串") }
            result.date = try day(text, "date")
        }
        if let value = fields["time"] {
            if value is NSNull { result.time = .clear }
            else if let text = value as? String {
                let key = try clock(text, "time")
                result.time = .value(Int(key.prefix(2))! * 60 + Int(key.suffix(2))!)
            } else { throw AgendaChangeError("time 必须是 HH:mm 或 null") }
        }
        if let value = fields["duration_minutes"] {
            guard let number = value as? NSNumber, !isBool(number), number.doubleValue == number.doubleValue.rounded(),
                  (0...1440).contains(number.doubleValue) else { throw AgendaChangeError("duration_minutes 需为 0–1440 的整数") }
            result.durationMinutes = number.intValue
        }
        if let value = fields["repeat_rule"] {
            guard let text = value as? String, let rule = RepeatRule(rawValue: text) else { throw AgendaChangeError("repeat_rule 只能为 none、daily、weekdays 或 weekly") }
            result.repeatRule = rule
        }
        for (name, apply) in [("tentative", { (flag: Bool) in result.tentative = flag }), ("reminder_enabled", { (flag: Bool) in result.reminderEnabled = flag })] {
            if let value = fields[name] {
                guard let number = value as? NSNumber, isBool(number) else { throw AgendaChangeError(name + " 必须是 true 或 false") }
                apply(number.boolValue)
            }
        }
        return result
    }

    private func validateShape() throws {
        let occurrence = occurrenceID ?? target.occurrenceID
        if let explicit = occurrenceID, let fromTarget = target.occurrenceID, explicit != fromTarget { throw AgendaChangeError("occurrence_id 与 target.occurrence_id 不一致") }
        if let occurrence, let itemID = target.itemID, !occurrence.hasPrefix(itemID.uuidString + ":") { throw AgendaChangeError("occurrence_id 不属于 target 事项") }
        let usesFields = !fields.isEmpty, usesNew = newDate != nil || newTime != nil, usesRange = from != nil || to != nil
        func forbid(_ condition: Bool, _ names: String) throws { if condition { throw AgendaChangeError("op \(op.rawValue) 不接受 \(names)") } }
        switch op {
        case .update:
            guard usesFields else { throw AgendaChangeError("update 需要非空 fields") }
            try forbid(occurrenceID != nil, "occurrence_id（改单次请用 reschedule_once）"); try forbid(usesNew, "new_date/new_time"); try forbid(usesRange, "from/to")
        case .delete, .restore:
            try forbid(usesFields, "fields"); try forbid(occurrenceID != nil, "occurrence_id"); try forbid(usesNew, "new_date/new_time"); try forbid(usesRange, "from/to")
        case .rescheduleOnce:
            guard occurrence != nil, newTime != nil else { throw AgendaChangeError("reschedule_once 需要 occurrence_id 和 new_time，可选 new_date") }
            try forbid(usesFields, "fields"); try forbid(usesRange, "from/to")
        case .complete, .reopen:
            try forbid(usesFields, "fields"); try forbid(usesNew, "new_date/new_time"); try forbid(usesRange, "from/to")
        case .skipOnce:
            guard occurrence != nil else { throw AgendaChangeError("skip_once 需要 occurrence_id") }
            try forbid(usesFields, "fields"); try forbid(usesNew, "new_date/new_time"); try forbid(usesRange, "from/to")
        case .pauseRange:
            guard let from, let to else { throw AgendaChangeError("pause_range 需要 from 和 to") }
            try forbid(usesFields, "fields"); try forbid(usesNew, "new_date/new_time"); try forbid(occurrenceID != nil, "occurrence_id")
            try Self.validateRange(from, to)
        case .resume:
            try forbid(usesFields, "fields"); try forbid(usesNew, "new_date/new_time")
            guard (from == nil) == (to == nil) else { throw AgendaChangeError("resume 的 from 与 to 需同时提供") }
            if let from, let to {
                try forbid(occurrenceID != nil, "同时提供 occurrence_id 与 from/to")
                try Self.validateRange(from, to)
            }
        }
    }
    static func validateRange(_ from: String, _ to: String) throws {
        guard from <= to, let start = AgendaClock.day(fromKey: from), let end = AgendaClock.day(fromKey: to),
              (AgendaClock.calendar.dateComponents([.day], from: start, to: end).day ?? .max) < maximumPauseDays else {
            throw AgendaChangeError("from 需不晚于 to，且区间不超过 \(maximumPauseDays) 天")
        }
    }
    static func normalizedOccurrence(_ text: String) throws -> String {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), AgendaClock.day(fromKey: String(parts[1])) != nil else {
            throw AgendaChangeError("occurrence_id 需为查询返回的 UUID:YYYY-MM-DD")
        }
        return id.uuidString + ":" + parts[1]
    }
    private static func day(_ text: String, _ name: String) throws -> String {
        guard AgendaClock.day(fromKey: text) != nil, text.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }) else { throw AgendaChangeError(name + " 需为有效的 YYYY-MM-DD") }
        return text
    }
    private static func clock(_ text: String, _ name: String) throws -> String {
        let bytes = Array(text.utf8)
        guard bytes.count == 5, bytes[2] == 58, bytes.enumerated().allSatisfy({ $0.offset == 2 || (48...57).contains($0.element) }),
              let hour = Int(text.prefix(2)), hour < 24, let minute = Int(text.suffix(2)), minute < 60 else { throw AgendaChangeError(name + " 需为 24 小时制 HH:mm") }
        return text
    }
    private static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() }

    /// Content fingerprint excluding request_id; replays with different content are rejected.
    var fingerprint: String {
        var object: [String: Any] = ["op": op.rawValue, "source": source]
        var targetObject: [String: Any] = [:]
        if let id = target.itemID { targetObject["item_id"] = id.uuidString }
        if let id = target.occurrenceID { targetObject["occurrence_id"] = id }
        if let id = target.captureRequestID { targetObject["capture_request_id"] = id }
        object["target"] = targetObject
        if let ifMatch { object["if_match"] = ifMatch }
        if let occurrenceID { object["occurrence_id"] = occurrenceID }
        if let newDate { object["new_date"] = newDate }
        if let newTime { object["new_time"] = newTime }
        if let from { object["from"] = from }
        if let to { object["to"] = to }
        var f: [String: Any] = [:]
        if let v = fields.title { f["title"] = v }
        if let v = fields.note { f["note"] = v }
        if let v = fields.date { f["date"] = v }
        switch fields.time { case .absent: break; case .clear: f["time"] = NSNull(); case .value(let m): f["time"] = m }
        if let v = fields.durationMinutes { f["duration_minutes"] = v }
        if let v = fields.repeatRule { f["repeat_rule"] = v.rawValue }
        if let v = fields.tentative { f["tentative"] = v }
        if let v = fields.reminderEnabled { f["reminder_enabled"] = v }
        object["fields"] = f
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct AgendaChangeReceipt: Codable, Equatable {
    var fingerprint: String
    var itemID: UUID
    var status: String
    var recordID: UUID?
    var createdAt: Date
    var source: String
}

struct AgendaChangeRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var requestID: String
    var op: String
    var source: String
    var at: Date
    var itemID: UUID
    var occurrenceID: String? = nil
    /// Snapshot before and after; nil means the item did not exist.
    var before: AgendaItem?
    var after: AgendaItem?
    /// Position of a deleted item, so restore keeps checklist order.
    var index: Int? = nil
    var undoneAt: Date? = nil
    var title: String { after?.title ?? before?.title ?? "" }
}

struct AgendaChangeResult: Encodable {
    var ok: Bool
    var status: String
    var requestID: String?
    var itemID: UUID? = nil
    var occurrenceID: String? = nil
    var itemExists: Bool? = nil
    var saved = false
    var dryRun = false
    var expectedStatus: String? = nil
    var before: AgendaItemView? = nil
    var after: AgendaItemView? = nil
    var current: AgendaItemView? = nil
    var recordID: UUID? = nil
    var message: String? = nil
    var error: String? = nil
    enum CodingKeys: String, CodingKey {
        case ok, status, saved, before, after, current, message, error
        case requestID = "request_id", itemID = "item_id", occurrenceID = "occurrence_id", itemExists = "item_exists"
        case dryRun = "dry_run", expectedStatus = "expected_status", recordID = "change_id"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ok, forKey: .ok); try c.encode(status, forKey: .status); try c.encode(requestID, forKey: .requestID)
        try c.encode(itemID, forKey: .itemID); try c.encode(itemExists, forKey: .itemExists); try c.encode(saved, forKey: .saved)
        try c.encode(before, forKey: .before); try c.encode(after, forKey: .after)
        try c.encodeIfPresent(occurrenceID, forKey: .occurrenceID)
        if dryRun { try c.encode(true, forKey: .dryRun); try c.encodeIfPresent(expectedStatus, forKey: .expectedStatus) }
        try c.encodeIfPresent(current, forKey: .current); try c.encodeIfPresent(recordID, forKey: .recordID)
        try c.encodeIfPresent(message, forKey: .message); try c.encodeIfPresent(error, forKey: .error)
    }
    static let successStatuses: Set<String> = ["updated", "deleted", "restored", "rescheduled", "skipped", "paused", "resumed", "completed", "reopened", "no_change", "already_processed"]
    static func invalid(_ requestID: String?, _ message: String) -> Self { Self(ok: false, status: "invalid", requestID: requestID, error: message) }
}

struct AgendaChangeState: Equatable {
    var items: [AgendaItem]
    var receipts: [String: AgendaChangeReceipt]
    var log: [AgendaChangeRecord]
}

/// Skip/pause bookkeeping shared by the engine and the window's "恢复" buttons.
enum AgendaSkipEditing {
    static func shift(_ key: String, by days: Int) -> String {
        guard let day = AgendaClock.day(fromKey: key), let moved = AgendaClock.calendar.date(byAdding: .day, value: days, to: day) else { return key }
        return AgendaClock.dayKey(moved)
    }
    static func merged(_ ranges: [AgendaDayRange]) -> [AgendaDayRange] {
        var result: [AgendaDayRange] = []
        for range in ranges.sorted(by: { $0.from == $1.from ? $0.to < $1.to : $0.from < $1.from }) {
            if let last = result.last, shift(last.to, by: 1) >= range.from {
                result[result.count - 1].to = max(last.to, range.to)
            } else { result.append(range) }
        }
        return result
    }
    /// Removes skips and pauses overlapping [from, to]; nil range clears everything.
    static func resume(_ item: AgendaItem, from: String?, to: String?) -> AgendaItem {
        var value = item
        guard let from, let to else { value.skippedDays = nil; value.pausedRanges = nil; return value }
        let days = (item.skippedDays ?? []).filter { !($0 >= from && $0 <= to) }
        value.skippedDays = days.isEmpty ? nil : days
        var ranges: [AgendaDayRange] = []
        for range in item.pausedRanges ?? [] {
            guard range.from <= to && range.to >= from else { ranges.append(range); continue }
            if range.from < from { ranges.append(AgendaDayRange(from: range.from, to: shift(from, by: -1))) }
            if range.to > to { ranges.append(AgendaDayRange(from: shift(to, by: 1), to: range.to)) }
        }
        value.pausedRanges = ranges.isEmpty ? nil : ranges
        return value
    }
    static func pause(_ item: AgendaItem, from: String, to: String) -> AgendaItem {
        var value = item
        value.pausedRanges = merged((item.pausedRanges ?? []) + [AgendaDayRange(from: from, to: to)])
        return value
    }
}

enum AgendaChangeEngine {
    static let logLimit = 300

    static func apply(_ request: AgendaChangeRequest, state: AgendaChangeState, captureReceipts: [String: AgendaCaptureReceipt],
                      editing: Set<UUID> = [], now: Date) -> (result: AgendaChangeResult, state: AgendaChangeState?) {
        let origins = AgendaItemOrigin.index(captureReceipts)
        func view(_ item: AgendaItem?) -> AgendaItemView? { item.map { AgendaItemView(item: $0, origin: AgendaItemOrigin.of($0, index: origins)) } }
        func fail(_ status: String, _ message: String, itemID: UUID? = nil, current: AgendaItem? = nil) -> (AgendaChangeResult, AgendaChangeState?) {
            let exists = itemID.map { id in state.items.contains { $0.id == id } }
            return (AgendaChangeResult(ok: false, status: status, requestID: request.requestID, itemID: itemID, itemExists: exists,
                                       before: view(current), current: view(current), error: message), nil)
        }
        let fingerprint = request.fingerprint
        if let receipt = state.receipts[request.requestID] {
            guard receipt.fingerprint == fingerprint else { return fail("conflict", L("该 request_id 已用于不同内容"), itemID: receipt.itemID) }
            let record = state.log.first { $0.id == receipt.recordID }
            return (AgendaChangeResult(ok: true, status: "already_processed", requestID: request.requestID, itemID: receipt.itemID,
                                       itemExists: state.items.contains { $0.id == receipt.itemID }, saved: true,
                                       before: view(record?.before), after: view(record?.after), recordID: receipt.recordID,
                                       message: L("该请求已处理（原状态 \(receipt.status)），未重复执行")), nil)
        }
        // Resolve the single target item.
        let itemID: UUID
        if let id = request.target.itemID { itemID = id }
        else if let occurrence = request.target.occurrenceID { itemID = UUID(uuidString: String(occurrence.split(separator: ":")[0]))! }
        else if let capture = request.target.captureRequestID {
            guard let receipt = captureReceipts[capture] else { return fail("not_found", L("没有找到该 capture_request_id 写入的事项")) }
            itemID = receipt.itemID
        } else { return fail("invalid", L("缺少 target")) }
        for occurrence in [request.occurrenceID, request.target.occurrenceID].compactMap({ $0 }) where !occurrence.hasPrefix(itemID.uuidString + ":") {
            return fail("invalid", L("occurrence_id 不属于 target 事项"), itemID: itemID)
        }
        var items = state.items
        let index = items.firstIndex { $0.id == itemID }

        if request.op == .restore {
            if let index {
                var receipts = state.receipts
                receipts[request.requestID] = AgendaChangeReceipt(fingerprint: fingerprint, itemID: itemID, status: "no_change", recordID: nil, createdAt: now, source: request.source)
                return (AgendaChangeResult(ok: true, status: "no_change", requestID: request.requestID, itemID: itemID, itemExists: true, saved: true,
                                           before: view(items[index]), after: view(items[index]), message: L("事项仍然存在，无需恢复")),
                        AgendaChangeState(items: state.items, receipts: receipts, log: state.log))
            }
            guard let deletion = state.log.last(where: { $0.itemID == itemID && $0.before != nil && $0.after == nil && $0.undoneAt == nil }), let snapshot = deletion.before else {
                return fail("not_found", L("没有可恢复的外部删除记录"), itemID: itemID)
            }
            if snapshot.feishu != nil { return fail("forbidden", L("飞书同步来的事项只读"), itemID: itemID) }
            if let ifMatch = request.ifMatch, ifMatch != AgendaRevision.of(snapshot) { return fail("conflict", L("if_match 与删除前的 revision 不一致"), itemID: itemID) }
            items.insert(snapshot, at: min(deletion.index ?? items.count, items.count))
            var log = state.log
            if let position = log.firstIndex(where: { $0.id == deletion.id }) { log[position].undoneAt = now }
            return finish(request, fingerprint: fingerprint, status: AgendaChangeOp.restore.doneStatus, itemID: itemID, occurrenceID: nil,
                          before: nil, after: snapshot, index: nil, items: items, log: log, state: state, view: view, now: now)
        }
        guard let index else { return fail("not_found", L("事项不存在或已删除"), itemID: itemID) }
        let current = items[index]
        guard current.feishu == nil else { return fail("forbidden", L("飞书同步来的事项只读，请在飞书中修改"), itemID: itemID, current: current) }
        guard !editing.contains(itemID) else { return fail("conflict", L("朝夕窗口正在编辑这条事项，有未保存草稿；请等用户保存或取消后重新查询再试"), itemID: itemID, current: current) }
        if let ifMatch = request.ifMatch, ifMatch != AgendaRevision.of(current) {
            return fail("conflict", L("if_match 已过期，事项已被修改；请按 current 重新确认"), itemID: itemID, current: current)
        }
        let occurrenceID = request.occurrenceID ?? request.target.occurrenceID
        let changed: AgendaItem?
        do { changed = try transform(current, request: request, occurrenceID: occurrenceID) }
        catch let error as AgendaChangeError { return fail(error.message.hasPrefix("not_found:") ? "not_found" : "invalid", error.message.replacingOccurrences(of: "not_found:", with: ""), itemID: itemID, current: current) }
        catch { return fail("invalid", error.localizedDescription, itemID: itemID, current: current) }
        if let changed, changed == current {
            var receipts = state.receipts
            receipts[request.requestID] = AgendaChangeReceipt(fingerprint: fingerprint, itemID: itemID, status: "no_change", recordID: nil, createdAt: now, source: request.source)
            return (AgendaChangeResult(ok: true, status: "no_change", requestID: request.requestID, itemID: itemID, occurrenceID: occurrenceID,
                                       itemExists: true, saved: true, before: view(current), after: view(current), message: L("内容与当前一致，未修改")),
                    AgendaChangeState(items: state.items, receipts: receipts, log: state.log))
        }
        if let changed { items[index] = changed } else { items.remove(at: index) }
        return finish(request, fingerprint: fingerprint, status: request.op.doneStatus, itemID: itemID, occurrenceID: occurrenceID,
                      before: current, after: changed, index: changed == nil ? index : nil, items: items, log: state.log, state: state, view: view, now: now)
    }

    private static func finish(_ request: AgendaChangeRequest, fingerprint: String, status: String, itemID: UUID, occurrenceID: String?,
                               before: AgendaItem?, after: AgendaItem?, index: Int?, items: [AgendaItem], log: [AgendaChangeRecord],
                               state: AgendaChangeState, view: (AgendaItem?) -> AgendaItemView?, now: Date) -> (AgendaChangeResult, AgendaChangeState?) {
        let record = AgendaChangeRecord(requestID: request.requestID, op: request.op.rawValue, source: request.source, at: now, itemID: itemID,
                                        occurrenceID: occurrenceID, before: before, after: after, index: index)
        var log = log + [record]
        // Trim old history, but keep deletions that can still be restored.
        while log.count > logLimit, let oldest = log.firstIndex(where: { record in !(record.after == nil && record.before != nil && record.undoneAt == nil && !items.contains(where: { $0.id == record.itemID })) }) {
            log.remove(at: oldest)
        }
        var receipts = state.receipts
        receipts[request.requestID] = AgendaChangeReceipt(fingerprint: fingerprint, itemID: itemID, status: status, recordID: record.id, createdAt: now, source: request.source)
        let message: String? = request.op == .delete ? L("已删除，可用 op:restore 与同一 item_id 原样恢复") : nil
        return (AgendaChangeResult(ok: true, status: status, requestID: request.requestID, itemID: itemID, occurrenceID: occurrenceID,
                                   itemExists: after != nil, saved: true, before: view(before), after: view(after), recordID: record.id, message: message),
                AgendaChangeState(items: items, receipts: receipts, log: log))
    }

    /// Returns the item after the change, or nil for deletion.
    static func transform(_ current: AgendaItem, request: AgendaChangeRequest, occurrenceID: String?) throws -> AgendaItem? {
        let occurrenceKey = occurrenceID.map { String($0.split(separator: ":")[1]) }
        func requireRepeating() throws {
            guard !current.isChecklist, current.repeatRule != .none else { throw AgendaChangeError(L("只有重复事项可以跳过或暂停；一次性事项请用 delete 或 update")) }
        }
        switch request.op {
        case .delete: return nil
        case .restore: return current
        case .update: return try update(current, request.fields)
        case .rescheduleOnce:
            guard !current.isChecklist, let occurrenceID, let key = occurrenceKey else { throw AgendaChangeError(L("清单事项没有单次安排")) }
            guard let occurrence = AgendaClock.occurrence(items: [current], id: occurrenceID) else { throw AgendaChangeError("not_found:" + L("这一次安排不存在或已跳过")) }
            guard occurrence.due != nil else { throw AgendaChangeError(L("未定时的安排不能单次改时间")) }
            let dayKey = request.newDate ?? AgendaClock.dayKey(occurrence.displayDay)
            guard let day = AgendaClock.day(fromKey: dayKey), let minutes = request.newTime.map({ Int($0.prefix(2))! * 60 + Int($0.suffix(2))! }),
                  let target = AgendaClock.calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) else { throw AgendaChangeError(L("新的日期或时刻无效")) }
            var base = current; base.postponedTimes = nil
            guard let original = AgendaClock.occurrence(items: [base], id: occurrenceID)?.due else { throw AgendaChangeError(L("这一次安排无法调整")) }
            var value = current
            var times = value.postponedTimes ?? [:]
            if target == original { times.removeValue(forKey: key) } else { times[key] = target }
            value.postponedTimes = times.isEmpty ? nil : times
            value.snoozes.removeValue(forKey: key)
            return value
        case .complete, .reopen:
            var value = current
            if current.isChecklist {
                guard occurrenceID == nil else { throw AgendaChangeError(L("清单事项不使用 occurrence_id")) }
                value.checklistState = request.op == .complete ? .completed : .pending
                return value
            }
            let id: String
            if let occurrenceID { id = occurrenceID }
            else if current.repeatRule == .none { id = current.id.uuidString + ":" + AgendaClock.dayKey(current.date) }
            else { throw AgendaChangeError(L("重复事项需提供 occurrence_id")) }
            guard let occurrence = AgendaClock.occurrence(items: [current], id: id) else { throw AgendaChangeError("not_found:" + L("这一次安排不存在或已跳过")) }
            if request.op == .complete { value.completedDays.insert(occurrence.completionKey) } else { value.completedDays.remove(occurrence.completionKey) }
            value.snoozes.removeValue(forKey: occurrence.completionKey)
            return value
        case .skipOnce:
            try requireRepeating()
            guard let occurrenceID, let key = occurrenceKey else { throw AgendaChangeError(L("skip_once 需要 occurrence_id")) }
            if current.isSkipped(key) { return current }
            guard AgendaClock.occurrence(items: [current], id: occurrenceID) != nil else { throw AgendaChangeError("not_found:" + L("这一天没有这项安排")) }
            var value = current
            value.skippedDays = (current.skippedDays ?? []).union([key])
            value.snoozes.removeValue(forKey: key)
            return value
        case .pauseRange:
            try requireRepeating()
            let value = AgendaSkipEditing.pause(current, from: request.from!, to: request.to!)
            return value.pausedRanges == AgendaSkipEditing.merged(current.pausedRanges ?? []) ? current : value
        case .resume:
            if let key = occurrenceKey { return AgendaSkipEditing.resume(current, from: key, to: key) }
            return AgendaSkipEditing.resume(current, from: request.from, to: request.to)
        }
    }

    private static func update(_ current: AgendaItem, _ fields: AgendaChangeFields) throws -> AgendaItem {
        var value = current
        if let title = fields.title { value.title = title }
        if let note = fields.note { value.note = note }
        guard fields.touchesSchedule else { return value }
        if current.isChecklist {
            guard current.checklistState == .pending, let date = fields.date else {
                throw AgendaChangeError(L("清单事项只能改标题和备注；安排日期需提供 date，且事项未完成"))
            }
            value.checklistState = nil
            value.completedDays = []; value.snoozes = [:]; value.postponedTimes = nil
            value.date = AgendaClock.day(fromKey: date)!
        } else if let date = fields.date { value.date = AgendaClock.day(fromKey: date)! }
        if current.weeklyTimes != nil, fields.time != .absent, (fields.repeatRule ?? current.repeatRule) == .weekly {
            throw AgendaChangeError(L("该事项按星期分别设置时间，请在朝夕窗口修改时间"))
        }
        let hadTime = value.timeMinutes != nil
        switch fields.time {
        case .absent: break
        case .clear: value.timeMinutes = nil
        case .value(let minutes): value.timeMinutes = minutes
        }
        if let rule = fields.repeatRule {
            value.repeatRule = rule
            if rule != .weekly { value.weeklyTimes = nil }
            // Skips only apply to repeating items; a one-time item must never be hidden by an old pause.
            if rule == .none { value.skippedDays = nil; value.pausedRanges = nil }
        }
        if let duration = fields.durationMinutes { value.durationMinutes = duration }
        if let tentative = fields.tentative { value.isTentative = tentative }
        if let reminder = fields.reminderEnabled { value.reminderEnabled = reminder }
        else if !hadTime && value.timeMinutes != nil { value.reminderEnabled = true }
        if value.timeMinutes == nil {
            guard fields.reminderEnabled != true else { throw AgendaChangeError(L("没有时刻时不能开启提醒")) }
            guard (fields.durationMinutes ?? 0) == 0 else { throw AgendaChangeError(L("时长需为 0–1440 分钟；无时刻时只能为 0")) }
            value.reminderEnabled = false; value.durationMinutes = 0
        }
        guard value.repeatRule == .none || value.timeMinutes != nil else { throw AgendaChangeError(L("重复安排需提供明确日期和时刻")) }
        if value.date != current.date || value.timeMinutes != current.timeMinutes || value.repeatRule != current.repeatRule || value.weeklyTimes != current.weeklyTimes || current.isChecklist {
            value.snoozes = [:]; value.postponedTimes = nil
        }
        return value
    }
}
