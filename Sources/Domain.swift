import Foundation
import CoreGraphics

enum AgendaAppearanceMode: String, CaseIterable {
    case light, dark, system
    var label: String {
        switch self { case .light: return L("浅色"); case .dark: return L("深色"); case .system: return L("跟随系统") }
    }
}

enum AgendaAccentColor: String, CaseIterable {
    case green, blue, purple, orange, graphite
    var label: String {
        switch self {
        case .green: return L("松绿")
        case .blue: return L("海蓝")
        case .purple: return L("雾紫")
        case .orange: return L("暖橙")
        case .graphite: return L("石墨")
        }
    }
}

enum RepeatRule: String, Codable, CaseIterable {
    case none, daily, weekdays, weekly
    var label: String {
        switch self { case .none: return L("不重复"); case .daily: return L("每天"); case .weekdays: return L("工作日"); case .weekly: return L("每周") }
    }
}

enum ChecklistState: String, Codable { case pending, completed }

/// Inclusive Shanghai day-key range (YYYY-MM-DD) used to pause one repeating item.
struct AgendaDayRange: Codable, Equatable, Hashable {
    var from: String
    var to: String
    func contains(_ key: String) -> Bool { from <= key && key <= to }
}

struct AgendaItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var date: Date
    var timeMinutes: Int?
    var durationMinutes: Int = 0
    var category: String = "生活"
    var note: String = ""
    var isTentative: Bool = false
    var reminderEnabled: Bool = true
    var repeatRule: RepeatRule = .none
    // Calendar weekday (1 = Sunday ... 7 = Saturday) -> minute of day.
    // Nil retains the existing single-time repeat behavior.
    var weeklyTimes: [String: Int]? = nil
    var completedDays: Set<String> = []
    var snoozes: [String: Date] = [:]
    var postponedTimes: [String: Date]? = nil
    var checklistState: ChecklistState? = nil
    var feishu: FeishuMetadata? = nil
    // Skipped occurrence keys and paused ranges hide those days without deleting the series.
    var skippedDays: Set<String>? = nil
    var pausedRanges: [AgendaDayRange]? = nil
    var isChecklist: Bool { checklistState != nil }
    func isSkipped(_ key: String) -> Bool {
        guard feishu == nil else { return false }
        return skippedDays?.contains(key) == true || (pausedRanges ?? []).contains { $0.contains(key) }
    }
    var hasSkips: Bool { !(skippedDays ?? []).isEmpty || !(pausedRanges ?? []).isEmpty }
    /// Upper bound of hidden days, used to extend next-occurrence searches.
    var skippedSpanDays: Int {
        (skippedDays?.count ?? 0) + (pausedRanges ?? []).reduce(0) { total, range in
            guard let a = AgendaClock.day(fromKey: range.from), let b = AgendaClock.day(fromKey: range.to) else { return total }
            return total + max(0, (AgendaClock.calendar.dateComponents([.day], from: a, to: b).day ?? 0) + 1)
        }
    }
    var scheduledDay: Date? { isChecklist ? nil : date }
    func timeMinutes(on day: Date) -> Int? {
        if repeatRule == .weekly, let weeklyTimes {
            return weeklyTimes[String(AgendaClock.calendar.component(.weekday, from: day))]
        }
        return timeMinutes
    }
}

struct Occurrence: Identifiable {
    var item: AgendaItem
    var day: Date
    var due: Date?
    var id: String { item.id.uuidString + ":" + AgendaClock.dayKey(day) }
    var title: String { item.title }
    var completionKey: String { item.feishu?.completionKey ?? AgendaClock.dayKey(day) }
    var isCompleted: Bool { item.completedDays.contains(completionKey) }
    var postponedUntil: Date? { item.postponedTimes?[completionKey] }
    var displayDay: Date { postponedUntil.map(AgendaClock.startOfDay) ?? day }
    var remindAt: Date? {
        guard !item.isChecklist, !isCompleted, let due else { return nil }
        if let source = item.feishu {
            guard !source.isAllDay, AgendaClock.startOfDay(day) == source.displayStartDay else { return nil }
        }
        return item.snoozes[completionKey] ?? due
    }
    var end: Date? { item.feishu?.end ?? due.map { $0.addingTimeInterval(Double(item.durationMinutes) * 60) } }
}

enum AgendaFocus: Identifiable {
    case scheduled(Occurrence), checklist(AgendaItem)
    var id: String {
        switch self { case let .scheduled(value): return value.id; case let .checklist(value): return "checklist:" + value.id.uuidString }
    }
    var item: AgendaItem {
        switch self { case let .scheduled(value): return value.item; case let .checklist(value): return value }
    }
    var title: String { item.title }
    var occurrence: Occurrence? { if case let .scheduled(value) = self { return value }; return nil }
    var due: Date? { occurrence?.due }
    var day: Date? { occurrence?.day }
    var isCompleted: Bool {
        switch self { case let .scheduled(value): return value.isCompleted; case let .checklist(value): return value.checklistState == .completed }
    }
    var isChecklist: Bool { if case .checklist = self { return true }; return false }
}

enum AgendaClock {
    static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }()
    static func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }
    static func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func day(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard key.utf8.count == 10, parts.count == 3, let year = Int(parts[0]), (1...9999).contains(year),
              let month = Int(parts[1]), (1...12).contains(month), let day = Int(parts[2]), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)), dayKey(date) == key else { return nil }
        return date
    }
    static func timeText(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }
    static func countdown(to date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        guard abs(delta) > 1 else { return L("刚刚") }
        let suffix = delta < 0 ? L("前") : ""
        let seconds = Int(ceil(abs(delta)))
        if seconds < 60 { return L("\(seconds) 秒") + suffix }
        let minutes = Int(ceil(abs(delta) / 60))
        if minutes < 60 { return L("\(minutes) 分钟") + suffix }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 24 { return (rest == 0 ? L("\(hours) 小时") : L("\(hours) 小时 \(rest) 分钟")) + suffix }
        let days = hours / 24, remaining = hours % 24
        return (remaining == 0 ? L("\(days) 天") : L("\(days) 天 \(remaining) 小时")) + suffix
    }
    private static func baseOccurrences(items: [AgendaItem], on date: Date) -> [Occurrence] {
        let day = startOfDay(date)
        return items.compactMap { item in
            guard !item.isChecklist else { return nil }
            if let source = item.feishu {
                guard source.occurs(on: day) else { return nil }
                return Occurrence(item: item, day: day, due: source.isAllDay ? nil : source.start)
            }
            let anchor = startOfDay(item.date)
            guard day >= anchor, !item.isSkipped(dayKey(day)) else { return nil }
            switch item.repeatRule {
            case .none: guard day == anchor else { return nil }
            case .daily: break
            case .weekly:
                if let times = item.weeklyTimes { guard times[String(calendar.component(.weekday, from: day))] != nil else { return nil } }
                else { guard calendar.component(.weekday, from: day) == calendar.component(.weekday, from: anchor) else { return nil } }
            case .weekdays:
                let weekday = calendar.component(.weekday, from: day)
                guard (2...6).contains(weekday) else { return nil }
            }
            let due = item.timeMinutes(on: day).flatMap { minutes -> Date? in
                guard (0...1439).contains(minutes) else { return nil }
                return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
            }
            return Occurrence(item: item, day: day, due: due)
        }.sorted {
            if $0.due != $1.due { return ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }
    static func occurrences(items: [AgendaItem], on date: Date) -> [Occurrence] {
        let day = startOfDay(date)
        var rows = baseOccurrences(items: items, on: day).map { value -> Occurrence in
            var value = value
            if let postponed = value.postponedUntil { value.due = postponed }
            return value
        }.filter { $0.displayDay == day }
        for item in items {
            for key in (item.postponedTimes ?? [:]).keys where key != dayKey(day) {
                if let value = occurrence(items: [item], id: item.id.uuidString + ":" + key), value.displayDay == day {
                    rows.append(value)
                }
            }
        }
        return rows.sorted {
            if $0.due != $1.due { return ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }
    static func next(items: [AgendaItem], now: Date) -> Occurrence? {
        var candidates: [Occurrence] = []
        for item in items where !item.isChecklist && item.timeMinutes != nil {
            for key in (item.postponedTimes ?? [:]).keys {
                if let value = occurrence(items: [item], id: item.id.uuidString + ":" + key), !value.isCompleted, let due = value.due, due > now {
                    candidates.append(value)
                }
            }
            var day = max(startOfDay(now), startOfDay(item.date))
            let attempts = item.repeatRule == .none ? 1 : (item.completedDays.count + (item.postponedTimes?.count ?? 0) + 2) * 7 + item.skippedSpanDays
            for _ in 0..<attempts {
                if let occurrence = baseOccurrences(items: [item], on: day).first, occurrence.postponedUntil == nil,
                   !occurrence.isCompleted, let due = occurrence.due, due > now {
                    candidates.append(occurrence)
                    break
                }
                guard item.repeatRule != .none, let following = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = following
            }
        }
        return candidates.min {
            if $0.due != $1.due { return $0.due! < $1.due! }
            return $0.id < $1.id
        }
    }
    static func occurrence(items: [AgendaItem], id: String) -> Occurrence? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let itemID = UUID(uuidString: String(parts[0])),
              let item = items.first(where: { $0.id == itemID }) else { return nil }
        let key = String(parts[1])
        let dateParts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard key.count == 10, dateParts.count == 3,
              let year = Int(dateParts[0]), (1...9999).contains(year),
              let month = Int(dateParts[1]), (1...12).contains(month),
              let day = Int(dateParts[2]), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              dayKey(date) == key,
              var occurrence = baseOccurrences(items: [item], on: date).first,
              occurrence.id == id else { return nil }
        if let postponed = occurrence.postponedUntil { occurrence.due = postponed }
        return occurrence
    }
    /// Occurrences hidden by skip/pause on the given display day, for an explicit "已跳过" row.
    static func skippedOccurrences(items: [AgendaItem], on date: Date) -> [Occurrence] {
        let key = dayKey(startOfDay(date))
        return items.filter { $0.hasSkips && $0.isSkipped(key) }.compactMap { item in
            var visible = item
            visible.skippedDays = nil; visible.pausedRanges = nil; visible.postponedTimes = nil
            return baseOccurrences(items: [visible], on: date).first.map { occurrence in
                var value = occurrence; value.item = item; return value
            }
        }
    }
    static func overdue(items: [AgendaItem], now: Date) -> [Occurrence] {
        let today = startOfDay(now)
        var result: [Occurrence] = []
        for item in items where !item.isChecklist {
            let day = item.repeatRule == .none ? startOfDay(item.date) : today
            let keys = Set((item.postponedTimes ?? [:]).keys).union([dayKey(day)])
            for key in keys {
                if let value = occurrence(items: [item], id: item.id.uuidString + ":" + key), !value.isCompleted, let due = value.due, due < now {
                    result.append(value)
                }
            }
        }
        return result.sorted { $0.due! < $1.due! }
    }
    static func earlierUnscheduled(items: [AgendaItem], now: Date) -> [Occurrence] {
        let today = startOfDay(now)
        return items.compactMap { item -> Occurrence? in
            guard !item.isChecklist, item.feishu == nil, item.repeatRule == .none, item.timeMinutes == nil,
                  startOfDay(item.date) < today,
                  let occurrence = occurrences(items: [item], on: item.date).first,
                  !occurrence.isCompleted else { return nil }
            return occurrence
        }.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            return $0.id < $1.id
        }
    }
    static func seed(now: Date = Date()) -> [AgendaItem] {
        // Only the first work start was confirmed; every other entry is an editable suggestion.
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        let template: [(String, Int)] = [("起床", 440), ("早餐", 465), ("出门", 495), ("上班", 540), ("午餐", 735), ("下班", 1080), ("晚餐", 1140), ("整理", 1290), ("睡觉", 1380)]
        return template.map { title, minute in
            AgendaItem(title: title, date: day, timeMinutes: minute,
                       category: title == "上班" || title == "下班" ? "工作" : "生活",
                       isTentative: title != "上班", reminderEnabled: title == "上班")
        }
    }
}

// The rail always uses elapsed absolute minutes; readable cards may move independently.
struct AgendaTimeline {
    struct Placement: Identifiable {
        let occurrence: Occurrence
        let startY: Double
        let endY: Double
        let cardY: Double
        let lane: Int
        var id: String { occurrence.id }
    }
    let day: Date
    let pointsPerMinute: Double
    var dayDuration: TimeInterval { AgendaClock.calendar.date(byAdding: .day, value: 1, to: day)!.timeIntervalSince(day) }
    var height: Double { dayDuration / 60 * pointsPerMinute }
    init(day: Date, pointsPerMinute: Double) {
        self.day = AgendaClock.startOfDay(day)
        self.pointsPerMinute = max(0.1, pointsPerMinute.isFinite ? pointsPerMinute : 1.5)
    }
    func y(_ date: Date) -> Double { min(height, max(0, date.timeIntervalSince(day) / 60 * pointsPerMinute)) }
    func y(hour: Int, minute: Int = 0) -> Double { y(day.addingTimeInterval(Double(hour * 60 + minute) * 60)) }
    func progress(at now: Date) -> Double { y(now) / height }
    func placements(_ rows: [Occurrence], cardHeight: Double = 78, gap: Double = 8) -> [Placement] {
        let timed = rows.filter { $0.due != nil }.sorted {
            if $0.due != $1.due { return $0.due! < $1.due! }
            return $0.id < $1.id
        }
        var laneEnds: [Double] = []
        var cardBottom = -Double.infinity
        return timed.map { o in
            let start = y(o.due!)
            let end = y(o.end ?? o.due!)
            // Point events also get their own lane when they share the same instant.
            let occupiedEnd = max(start + 1, end)
            let lane = laneEnds.firstIndex(where: { $0 <= start }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(occupiedEnd) } else { laneEnds[lane] = occupiedEnd }
            let card = max(start, cardBottom + max(0, gap))
            cardBottom = card + max(1, cardHeight)
            return Placement(occurrence: o, startY: start, endY: end, cardY: card, lane: lane)
        }
    }
}

enum AgendaPanelGeometry {
    static func minimumSize(compact: Bool) -> CGSize { compact ? CGSize(width: 220, height: 64) : CGSize(width: 280, height: 360) }
    static func defaultSize(compact: Bool) -> CGSize { compact ? CGSize(width: 280, height: 64) : CGSize(width: 360, height: 600) }
    static func normalized(_ frame: CGRect, compact: Bool) -> CGRect {
        let minimum = minimumSize(compact: compact)
        let fallback = CGRect(origin: .zero, size: defaultSize(compact: compact))
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }), frame.width > 0, frame.height > 0 else { return fallback }
        let size = CGSize(width: max(minimum.width, frame.width), height: compact ? minimum.height : max(minimum.height, frame.height))
        return CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
    }
}

// A compact event scale: clock fractions move within the gap between adjacent items.
// It deliberately compresses empty hours instead of pretending rows are equal-hour ticks.
struct CompactAgendaTimeline {
    let rows: [Occurrence]
    let day: Date
    let now: Date
    let rowPitch: Double
    let nowGap: Double = 40
    init(rows: [Occurrence], day: Date, now: Date, rowPitch: Double = 56) {
        self.rowPitch = rowPitch
        self.rows = rows.filter { $0.due != nil }.sorted {
            if $0.due != $1.due { return $0.due! < $1.due! }
            return $0.id < $1.id
        }
        self.day = AgendaClock.startOfDay(day); self.now = now
    }
    var showsNow: Bool { AgendaClock.dayKey(day) == AgendaClock.dayKey(now) }
    var insertionIndex: Int { rows.firstIndex { $0.due! > now } ?? rows.count }
    var gapFraction: Double {
        let lower = insertionIndex > 0 ? rows[insertionIndex - 1].due! : day
        let upper = insertionIndex < rows.count ? rows[insertionIndex].due! : AgendaClock.calendar.date(byAdding: .day, value: 1, to: day)!
        guard upper > lower else { return 0 }
        return min(1, max(0, now.timeIntervalSince(lower) / upper.timeIntervalSince(lower)))
    }
    var gapOffset: Double { 8 + 24 * gapFraction }
    var nowY: Double? { showsNow ? Double(insertionIndex) * rowPitch + gapOffset : nil }
    var height: Double { Double(rows.count) * rowPitch + (showsNow ? nowGap : 0) }
    func rowY(at index: Int) -> Double { Double(index) * rowPitch + (showsNow && index >= insertionIndex ? nowGap : 0) }
    var elapsedHeight: Double {
        if let nowY { return nowY }
        return now < day ? 0 : height
    }
}

/// A clock string stays invalid until the user corrects it; no date is involved.
struct TimeInputValue {
    enum Part: Hashable { case hour, minute }
    let hour: String
    let minute: String
    private let hasSeparator: Bool

    init(_ text: String) {
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        hasSeparator = pieces.count == 2
        if pieces.count == 2 { hour = String(pieces[0]); minute = String(pieces[1]) }
        else { hour = text; minute = "" }
    }
    func text(for part: Part) -> String { part == .hour ? hour : minute }
    static func range(for part: Part) -> ClosedRange<Int> { part == .hour ? 0...23 : 0...59 }
    static func number(_ text: String, for part: Part) -> Int? {
        guard let number = Int(text.isEmpty ? "0" : text), range(for: part).contains(number) else { return nil }
        return number
    }
    var minutes: Int? {
        guard hasSeparator, let h = Self.number(hour, for: .hour), let m = Self.number(minute, for: .minute) else { return nil }
        return h * 60 + m
    }
    static func normalizedNumberInput(_ text: String) -> String {
        guard text.count > 2, text.first == "0", text.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return text }
        let digits = text.drop(while: { $0 == "0" })
        return digits.isEmpty ? "00" : String(digits)
    }
    func replacing(_ part: Part, with text: String) -> String {
        part == .hour ? text + ":" + minute : hour + ":" + text
    }
    func adjusting(_ part: Part, by step: Int) -> String? {
        guard step != 0 else { return nil }
        let text = self.text(for: part)
        let range = Self.range(for: part)
        let next: Int
        if text.isEmpty { next = 0 }
        else {
            guard let number = Self.number(text, for: part) else { return nil }
            let boundedStep = min(range.upperBound, max(-range.upperBound, step))
            next = min(range.upperBound, max(range.lowerBound, number + boundedStep))
        }
        return replacing(part, with: String(format: "%02d", next))
    }
}

enum DurationInputValue {
    static func minutes(_ text: String) -> Int? {
        guard text.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let value = Int(text.isEmpty ? "0" : text), (0...1440).contains(value) else { return nil }
        return value
    }
}
