import Foundation
import CryptoKit

struct AgendaCaptureRequest: Codable, Equatable {
    var requestID: String
    var title: String
    var note: String? = nil
    var date: String? = nil
    var time: String? = nil
    var durationMinutes: Int? = nil
    var source: String? = nil
    var repeatRule: RepeatRule? = nil

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id", title, note, date, time, source
        case durationMinutes = "duration_minutes"
        case repeatRule = "repeat_rule"
    }

    func normalized() throws -> Self {
        guard Self.validRequestID(requestID) else { throw CaptureError.invalid("request_id 需为 1–128 个英文字母、数字或 . _ : -") }
        var value = self
        value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.title.isEmpty, value.title.count <= 200 else { throw CaptureError.invalid("标题需为 1–200 字") }
        guard (note?.count ?? 0) <= 2000 else { throw CaptureError.invalid("备注不能超过 2000 字") }
        // Preserve nonempty note text exactly, including whitespace and line breaks.
        if note == "" { value.note = nil }
        value.source = (source ?? "cli").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.source == "hermes" || value.source == "cli" else { throw CaptureError.invalid("来源只能为 hermes 或 cli") }
        if let date {
            let key = date.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.parsedDay(key) != nil else { throw CaptureError.invalid("日期需为有效的 YYYY-MM-DD") }
            value.date = key
        }
        if let time {
            let key = time.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.date != nil, Self.parsedMinutes(key) != nil else { throw CaptureError.invalid("时刻需为 HH:mm，并提供明确日期") }
            value.time = key
        }
        value.durationMinutes = durationMinutes ?? 0
        guard (0...1440).contains(value.durationMinutes!), value.time != nil || value.durationMinutes == 0 else {
            throw CaptureError.invalid("时长需为 0–1440 分钟；无时刻时只能为 0")
        }
        value.repeatRule = repeatRule ?? RepeatRule.none
        guard value.repeatRule == RepeatRule.none || (value.date != nil && value.time != nil) else {
            throw CaptureError.invalid("重复安排需提供明确日期和时刻；无日期事项仍为清单")
        }
        return value
    }

    func makeItem(now: Date) throws -> AgendaItem {
        let value = try normalized()
        guard Self.validDate(now) else { throw CaptureError.invalid("捕获时间无效") }
        let day = value.date.flatMap(Self.parsedDay) ?? AgendaClock.startOfDay(now)
        let minutes = value.time.flatMap(Self.parsedMinutes)
        return AgendaItem(title: value.title, date: day, timeMinutes: minutes,
                          durationMinutes: value.durationMinutes ?? 0, note: value.note ?? "",
                          reminderEnabled: minutes != nil, repeatRule: value.repeatRule ?? .none,
                          checklistState: value.date == nil ? .pending : nil)
    }

    var fingerprint: String {
        let value = (try? normalized()) ?? self
        let payload = FingerprintPayload(title: value.title, note: value.note ?? "", date: value.date,
                                         time: value.time, durationMinutes: value.durationMinutes ?? 0, source: value.source ?? "cli",
                                         repeatRule: value.repeatRule == RepeatRule.none ? nil : value.repeatRule)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // This payload contains only finite integers and strings; encoding cannot fail.
        let data = try! encoder.encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validRequestID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [46, 95, 58, 45].contains($0)
        }
    }
    static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= Date(timeIntervalSince1970: -62135596800) && date <= Date(timeIntervalSince1970: 253402271999)
    }
    private static func parsedDay(_ key: String) -> Date? {
        let bytes = Array(key.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }) else { return nil }
        let parts = key.split(separator: "-")
        guard let year = Int(parts[0]), (1...9999).contains(year),
              let month = Int(parts[1]), (1...12).contains(month), let day = Int(parts[2]), (1...31).contains(day),
              let result = AgendaClock.calendar.date(from: DateComponents(year: year, month: month, day: day)),
              validDate(result), AgendaClock.dayKey(result) == key else { return nil }
        return result
    }
    private static func parsedMinutes(_ key: String) -> Int? {
        let bytes = Array(key.utf8)
        guard bytes.count == 5, bytes[2] == 58,
              bytes.enumerated().allSatisfy({ $0.offset == 2 || (48...57).contains($0.element) }) else { return nil }
        let parts = key.split(separator: ":")
        guard let hour = Int(parts[0]), (0...23).contains(hour), let minute = Int(parts[1]), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
    private struct FingerprintPayload: Encodable {
        let title: String
        let note: String
        let date: String?
        let time: String?
        let durationMinutes: Int
        let source: String
        // Omit none entirely so pre-upgrade receipts keep their exact fingerprint.
        let repeatRule: RepeatRule?
        enum CodingKeys: String, CodingKey {
            case title, note, date, time, source
            case durationMinutes = "duration_minutes"
            case repeatRule = "repeat_rule"
        }
    }
    private enum CaptureError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
    }
}

struct AgendaCaptureReceipt: Codable {
    var fingerprint: String
    var itemID: UUID
    var createdAt: Date
    var source: String
}

struct AgendaCaptureResult: Codable {
    var ok: Bool
    var requestID: String?
    var status: String
    var itemID: UUID?
    var itemExists: Bool?
    var error: String?
    public init(ok: Bool, requestID: String? = nil, status: String, itemID: UUID? = nil, itemExists: Bool? = nil, error: String? = nil) {
        self.ok = ok; self.requestID = requestID; self.status = status
        self.itemID = itemID; self.itemExists = itemExists; self.error = error
    }
    enum CodingKeys: String, CodingKey {
        case ok, status, error
        case requestID = "request_id", itemID = "item_id", itemExists = "item_exists"
    }
}
