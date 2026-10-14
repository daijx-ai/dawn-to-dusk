import Foundation

enum FeishuEventStatus: String, Codable { case active, cancelled, declined }

struct FeishuEvent: Codable, Equatable {
    var calendarID: String
    var eventID: String
    var title: String = ""
    var start: Date? = nil
    var end: Date? = nil
    var isAllDay: Bool = false
    var timezone: String = "Asia/Shanghai"
    var appLink: String? = nil
    var status: FeishuEventStatus = .active

    func metadata() throws -> FeishuMetadata {
        guard status == .active, let start, let end else { throw FeishuModelError.invalid("飞书活动事件缺少准确起止时间") }
        let result = FeishuMetadata(calendarID: calendarID, eventID: eventID, start: start, end: end,
                                    isAllDay: isAllDay, timezone: timezone, appLink: appLink)
        try result.validate()
        return result
    }
}

struct FeishuSnapshot: Equatable {
    var calendarID: String
    var windowStart: Date
    var windowEnd: Date
    var events: [FeishuEvent]
    var fetchedAt: Date = Date()
}

struct FeishuMetadata: Codable, Equatable {
    var calendarID: String
    var eventID: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var timezone: String
    var appLink: String? = nil

    // All-day dates belong to the source calendar, rather than a shifted local 24-hour interval.
    private func allDayDisplayDate(_ instant: Date) -> Date {
        var source = Calendar(identifier: .gregorian)
        source.timeZone = TimeZone(identifier: timezone) ?? AgendaClock.calendar.timeZone
        return AgendaClock.calendar.date(from: source.dateComponents([.year, .month, .day], from: instant))!
    }
    var displayStartDay: Date { isAllDay ? allDayDisplayDate(start) : AgendaClock.startOfDay(start) }
    var displayEndDay: Date { isAllDay ? allDayDisplayDate(end) : AgendaClock.startOfDay(end) }
    var completionKey: String { AgendaClock.dayKey(displayStartDay) }
    var durationMinutes: Int { Int(ceil(end.timeIntervalSince(start) / 60)) }
    var timeMinutes: Int? {
        guard !isAllDay else { return nil }
        let parts = AgendaClock.calendar.dateComponents([.hour, .minute], from: start)
        return parts.hour! * 60 + parts.minute!
    }
    func occurs(on day: Date) -> Bool {
        if isAllDay { return day >= displayStartDay && day < displayEndDay }
        let following = AgendaClock.calendar.date(byAdding: .day, value: 1, to: day)!
        return start < following && (end > day || (start == end && start >= day))
    }
    func validate() throws {
        guard !calendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.validDate(start), Self.validDate(end), end >= start,
              let zone = TimeZone(identifier: timezone) else { throw FeishuModelError.invalid("飞书来源或时间数据无效") }
        if isAllDay {
            var source = Calendar(identifier: .gregorian); source.timeZone = zone
            guard end > start, source.startOfDay(for: start) == start, source.startOfDay(for: end) == end else {
                throw FeishuModelError.invalid("全天事件必须有源时区的起始日期和不含在内的结束日期")
            }
        }
        if let appLink {
            guard let url = URL(string: appLink), url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(), ["applink.feishu.cn", "applink.larkoffice.com"].contains(host),
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443,
                  url.path == "/client/calendar/event/detail" else {
                throw FeishuModelError.invalid("飞书原事件链接无效")
            }
        }
    }
    static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= Date(timeIntervalSince1970: -62135596800) && date <= Date(timeIntervalSince1970: 253402271999)
    }
}

struct FeishuSyncState: Codable, Equatable {
    var lastSuccess: Date
    var calendarID: String
    var status: String = "synced"
}

enum FeishuModelError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}
