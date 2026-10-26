import Foundation

struct ScheduleDraft: Identifiable {
    let original: AgendaItem
    var item: AgendaItem
    var timeInput: String
    var durationInput: String
    var hasTime: Bool
    var weeklyInputs: [String: String]?
    private var weeklyStartDay: Date
    var id: UUID { item.id }

    init(_ item: AgendaItem) {
        original = item
        self.item = item
        weeklyStartDay = AgendaClock.startOfDay(item.date)
        hasTime = item.timeMinutes != nil
        timeInput = item.timeMinutes.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } ?? "09:00"
        durationInput = String(item.durationMinutes)
        weeklyInputs = item.weeklyTimes?.mapValues { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
    }
    mutating func selectWeekday(_ weekday: Int) {
        guard (1...7).contains(weekday) else { return }
        let startWeekday = AgendaClock.calendar.component(.weekday, from: weeklyStartDay)
        item.date = AgendaClock.calendar.date(byAdding: .day, value: (weekday - startWeekday + 7) % 7, to: weeklyStartDay)!
    }
    mutating func setStartDay(_ day: Date) {
        item.date = AgendaClock.startOfDay(day)
        weeklyStartDay = item.date
    }
    var prepared: AgendaItem? {
        var value = item
        if hasTime {
            guard let duration = DurationInputValue.minutes(durationInput) else { return nil }
            value.durationMinutes = duration
            if item.repeatRule == .weekly, let weeklyInputs {
                let times = weeklyInputs.compactMapValues { TimeInputValue($0).minutes }
                guard !times.isEmpty, times.count == weeklyInputs.count else { return nil }
                value.weeklyTimes = times
                value.timeMinutes = times.values.min()
            } else {
                guard let minutes = TimeInputValue(timeInput).minutes else { return nil }
                value.timeMinutes = minutes; value.weeklyTimes = nil
            }
        } else {
            value.timeMinutes = nil
            value.weeklyTimes = nil
            if original.timeMinutes != nil { value.reminderEnabled = false; value.durationMinutes = 0 }
        }
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.title.isEmpty else { return nil }
        if value.date != original.date || value.timeMinutes != original.timeMinutes || value.repeatRule != original.repeatRule || value.weeklyTimes != original.weeklyTimes {
            value.postponedTimes = nil
            value.snoozes = [:]
        }
        return value
    }
}

enum ScheduleEditing {
    static func visible(_ item: AgendaItem) -> Bool {
        guard !item.isChecklist, item.feishu == nil else { return false }
        return item.repeatRule != .none || !item.completedDays.contains(AgendaClock.dayKey(item.date))
    }
    static func applicable(_ edits: [String: ScheduleOccurrenceDraft], to items: [AgendaItem]) -> [String: ScheduleOccurrenceDraft] {
        edits.filter { AgendaClock.occurrence(items: items, id: $0.key)?.due != nil }
    }
}

struct ScheduleOccurrenceDraft {
    let original: Occurrence
    var timeInput: String
    init(_ occurrence: Occurrence) {
        original = occurrence
        timeInput = occurrence.due.map(AgendaClock.timeText) ?? "00:00"
    }
    var target: Date? {
        guard let minutes = TimeInputValue(timeInput).minutes else { return nil }
        return AgendaClock.calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: original.displayDay)
    }
}

struct ScheduleInterval {
    let current: Occurrence
    let next: Occurrence
    var crossesMidnight: Bool { AgendaClock.dayKey(current.displayDay) != AgendaClock.dayKey(next.displayDay) }
    var minutes: Int { Int(((next.due ?? .distantPast).timeIntervalSince(current.due ?? .distantPast) / 60).rounded()) }
    var remainingMinutes: Int { Int(((next.due ?? .distantPast).timeIntervalSince(current.end ?? current.due ?? .distantPast) / 60).rounded()) }
    var text: String {
        let destination = (crossesMidnight ? L("次日 ") : "") + (next.due.map(AgendaClock.timeText) ?? "") + " " + next.title
        if remainingMinutes < 0 { return L("与 ") + destination + L(" 重叠 ") + Self.duration(-remainingMinutes) }
        let prefix = current.item.durationMinutes > 0 || current.item.feishu != nil ? L("结束后距 ") : L("距 ")
        return prefix + destination + " · " + Self.duration(remainingMinutes)
    }
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return L("\(m) 分钟") }
        return m == 0 ? L("\(h) 小时") : L("\(h) 小时 \(m) 分钟")
    }
    static func following(_ current: Occurrence, items: [AgendaItem], on day: Date) -> ScheduleInterval? {
        let rows = AgendaClock.occurrences(items: items, on: day).filter { $0.due != nil }
        guard let index = rows.firstIndex(where: { $0.id == current.id }) else { return nil }
        if index + 1 < rows.count { return ScheduleInterval(current: current, next: rows[index + 1]) }
        guard let tomorrow = AgendaClock.calendar.date(byAdding: .day, value: 1, to: AgendaClock.startOfDay(day)),
              let next = AgendaClock.occurrences(items: items, on: tomorrow).first(where: { $0.due != nil }) else { return nil }
        return ScheduleInterval(current: current, next: next)
    }
}
