import Foundation
import CoreGraphics

enum AgendaAppearanceMode: String, CaseIterable {
    case light, dark, system
    var label: String {
        switch self { case .light: return "浅色"; case .dark: return "深色"; case .system: return "跟随系统" }
    }
}

enum AgendaAccentColor: String, CaseIterable {
    case green, blue, purple, orange, graphite
    var label: String {
        switch self {
        case .green: return "松绿"
        case .blue: return "海蓝"
        case .purple: return "雾紫"
        case .orange: return "暖橙"
        case .graphite: return "石墨"
        }
    }
}

enum RepeatRule: String, Codable, CaseIterable {
    case none, daily, weekdays
    var label: String {
        switch self { case .none: return "不重复"; case .daily: return "每天"; case .weekdays: return "工作日" }
    }
}

enum ChecklistState: String, Codable { case pending, completed }

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
    var completedDays: Set<String> = []
    var snoozes: [String: Date] = [:]
    var postponedTimes: [String: Date]? = nil
    var checklistState: ChecklistState? = nil
    var feishu: FeishuMetadata? = nil
    var isChecklist: Bool { checklistState != nil }
    var scheduledDay: Date? { isChecklist ? nil : date }
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
    static func timeText(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }
    static func countdown(to date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        guard abs(delta) > 1 else { return "刚刚" }
        let suffix = delta < 0 ? "前" : ""
        let seconds = Int(ceil(abs(delta)))
        if seconds < 60 { return "\(seconds) 秒" + suffix }
        let minutes = Int(ceil(abs(delta) / 60))
        if minutes < 60 { return "\(minutes) 分钟" + suffix }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 24 { return (rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分钟") + suffix }
        let days = hours / 24, remaining = hours % 24
        return (remaining == 0 ? "\(days) 天" : "\(days) 天 \(remaining) 小时") + suffix
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
            guard day >= anchor else { return nil }
            switch item.repeatRule {
            case .none: guard day == anchor else { return nil }
            case .daily: break
            case .weekdays:
                let weekday = calendar.component(.weekday, from: day)
                guard (2...6).contains(weekday) else { return nil }
            }
            let due = item.timeMinutes.flatMap { minutes -> Date? in
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
            let attempts = item.repeatRule == .none ? 1 : (item.completedDays.count + (item.postponedTimes?.count ?? 0) + 2) * 7
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
    static func normalized(_ frame: CGRect, compact: Bool) -> CGRect {
        let fallback = CGRect(x: 0, y: 0, width: 400, height: compact ? 82 : 850)
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }), frame.width > 0, frame.height > 0 else { return fallback }
        let size = CGSize(width: max(320, frame.width), height: compact ? 82 : max(520, frame.height))
        return CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
    }
}

// A compact event scale: clock fractions move within the gap between adjacent items.
// It deliberately compresses empty hours instead of pretending rows are equal-hour ticks.
struct CompactAgendaTimeline {
    let rows: [Occurrence]
    let day: Date
    let now: Date
    let rowPitch: Double = 56
    let nowGap: Double = 40
    init(rows: [Occurrence], day: Date, now: Date) {
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
