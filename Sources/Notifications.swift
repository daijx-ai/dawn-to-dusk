import Foundation
import UserNotifications
import AppKit
import Combine

struct ReminderPlan: Equatable {
    var id: String
    var occurrenceID: String
    var title: String
    var fireAt: Date
    var due: Date
    var isLead: Bool
    var isSnooze: Bool
}

enum ReminderPlanner {
    static func deliveredIsCurrent(occurrenceID: String, plannedDue: Double?, items: [AgendaItem], settings: AgendaSettings) -> Bool {
        guard settings.notifications else { return false }
        let bits = occurrenceID.split(separator: ":")
        guard bits.count == 2, let id = UUID(uuidString: String(bits[0])), let item = items.first(where: { $0.id == id }), !item.isTentative, item.reminderEnabled else { return false }
        guard let o = AgendaClock.occurrence(items: [item], id: occurrenceID), !o.isCompleted, o.remindAt != nil, let due = o.due else { return false }
        guard let plannedDue else { return false }
        return abs(due.timeIntervalSince1970 - plannedDue) < 0.5
    }
    static func plans(items: [AgendaItem], settings: AgendaSettings, now: Date, limit: Int = 60) -> [ReminderPlan] {
        guard settings.notifications, limit > 0 else { return [] }
        var result: [ReminderPlan] = []
        for offset in 0...7 {
            let day = AgendaClock.calendar.date(byAdding: .day, value: offset, to: AgendaClock.startOfDay(now))!
            for o in AgendaClock.occurrences(items: items, on: day) {
                guard !o.isCompleted, !o.item.isTentative, o.item.reminderEnabled, let due = o.due, let fire = o.remindAt else { continue }
                let snoozed = o.item.snoozes[o.completionKey] != nil
                if fire > now {
                    result.append(ReminderPlan(id: o.id + ":due", occurrenceID: o.id, title: o.title, fireAt: fire, due: due, isLead: false, isSnooze: snoozed))
                }
                let lead = due.addingTimeInterval(-Double(settings.leadMinutes) * 60)
                if !snoozed && settings.leadMinutes > 0 && lead > now {
                    result.append(ReminderPlan(id: o.id + ":lead", occurrenceID: o.id, title: o.title, fireAt: lead, due: due, isLead: true, isSnooze: false))
                }
            }
        }
        // Postponing a notification never moves the original plan date, even weeks later.
        for item in items where !item.isTentative && item.reminderEnabled {
            for (key, snooze) in item.snoozes where snooze > now {
                let horizonEnd = AgendaClock.calendar.date(byAdding: .day, value: 7, to: AgendaClock.startOfDay(now))!
                guard let o = AgendaClock.occurrence(items: [item], id: item.id.uuidString + ":" + key),
                      (o.displayDay < AgendaClock.startOfDay(now) || o.displayDay > horizonEnd),
                      !o.isCompleted, let due = o.due else { continue }
                result.append(ReminderPlan(id: o.id + ":due", occurrenceID: o.id, title: o.title, fireAt: snooze, due: due, isLead: false, isSnooze: true))
            }
        }
        let sorted = result.sorted { $0.fireAt == $1.fireAt ? $0.id < $1.id : $0.fireAt < $1.fireAt }
        // Reserve near-term due reminders first, then their early warnings, so
        // a full week of recurring due reminders cannot starve today's leads.
        // Snoozes belong to the window in which they actually fire.
        let nearTermEnd = now.addingTimeInterval(24 * 60 * 60)
        let nearDue = sorted.filter { !$0.isLead && $0.fireAt <= nearTermEnd }
        let nearOccurrenceIDs = Set(nearDue.map(\.occurrenceID))
        let nearLead = sorted.filter { $0.isLead && nearOccurrenceIDs.contains($0.occurrenceID) }
        let futureDue = sorted.filter { !$0.isLead && $0.fireAt > nearTermEnd }
        let futureLead = sorted.filter { $0.isLead && !nearOccurrenceIDs.contains($0.occurrenceID) }
        let selected = Array((nearDue + nearLead + futureDue + futureLead).prefix(limit))
        return selected.sorted { $0.fireAt == $1.fireAt ? $0.id < $1.id : $0.fireAt < $1.fireAt }
    }
}

@MainActor final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var authorized = false
    @Published var permissionText = "正在检查通知权限…"
    @Published var pendingCount = 0
    @Published var deferredCount = 0
    @Published var testStatus = ""
    var evidenceURL: URL?
    var onAction: ((String, String, Double?) -> Void)?
    var onReady: (() -> Void)?
    private lazy var center = UNUserNotificationCenter.current()
    private var generation = 0
    private var lastPlans: [ReminderPlan] = []
    private var syncing = false
    private var desiredItems: [AgendaItem] = []
    private var desiredSettings = AgendaSettings()
    private let simulated: Bool
    init(simulated: Bool = false) {
        self.simulated = simulated
        super.init()
        if simulated { permissionText = "隔离验证模式 · 不发送真实通知"; return }
        center.delegate = self
        let done = UNNotificationAction(identifier: "done", title: "已完成", options: [])
        let later = UNNotificationAction(identifier: "snooze", title: "10 分钟后提醒", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: "agenda", actions: [done, later], intentIdentifiers: [], options: [])])
        refreshPermission()
    }
    func refreshPermission(request: Bool = false) {
        guard !simulated else { return }
        Task {
            if request { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
            let settings = await center.notificationSettings()
            authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            switch settings.authorizationStatus {
            case .authorized: permissionText = settings.soundSetting == .enabled ? "系统通知已允许" : "系统通知已允许 · 系统声音关闭"
            case .provisional: permissionText = "通知以安静方式投递"
            case .denied: permissionText = "系统通知未允许 · 日程面板仍可提醒"
            case .notDetermined: permissionText = "待允许系统通知"
            default: permissionText = "系统通知权限未知"
            }
            onReady?()
        }
    }
    @discardableResult func sync(items: [AgendaItem], settings: AgendaSettings, force: Bool = false) -> Bool {
        let plans = ReminderPlanner.plans(items: items, settings: settings, now: Date())
        deferredCount = max(0, ReminderPlanner.plans(items: items, settings: settings, now: Date(), limit: Int.max).count - plans.count)
        guard force || plans != lastPlans || items != desiredItems || settings != desiredSettings else { return false }
        lastPlans = plans; desiredItems = items; desiredSettings = settings; generation += 1
        guard !simulated else { pendingCount = plans.count; return true }
        guard !syncing else { return true }
        syncing = true
        Task {
          while true {
            let version = generation, plans = lastPlans, settings = desiredSettings, items = desiredItems
            let existing = await center.pendingNotificationRequests()
            if generation != version { continue }
            // Removal is asynchronous. Deleting and immediately re-adding the
            // same ID can erase the new request; replace retained IDs in place.
            let desiredIDs = Set(plans.map(\.id))
            let existingByID = Dictionary(existing.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            center.removePendingNotificationRequests(withIdentifiers: existing.filter {
                $0.identifier != "chaoxi-test" && !desiredIDs.contains($0.identifier)
            }.map(\.identifier))
            let delivered = await center.deliveredNotifications()
            if generation != version { continue }
            center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
                guard let oid = $0.request.content.userInfo["occurrenceID"] as? String else { return false }
                return !ReminderPlanner.deliveredIsCurrent(occurrenceID: oid, plannedDue: $0.request.content.userInfo["plannedDue"] as? Double, items: items, settings: settings)
            }.map { $0.request.identifier })
            if authorized { for plan in plans {
                if generation != version { break }
                let content = UNMutableNotificationContent()
                content.title = plan.isLead ? "快到时间了 · \(plan.title)" : "现在 · \(plan.title)"
                content.body = plan.isSnooze ? "稍后提醒到了。原安排 \(AgendaClock.timeText(plan.due))，处理后在朝夕标记完成。" : "\(AgendaClock.timeText(plan.due)) 开始。\(plan.isLead ? "还有一会儿，可以准备了。" : "不着急，一件一件来。")"
                content.categoryIdentifier = "agenda"
                content.userInfo = ["occurrenceID": plan.occurrenceID, "plannedDue": plan.due.timeIntervalSince1970]
                if settings.sound { content.sound = UNNotificationSound(named: UNNotificationSoundName("soft.wav")) }
                let components = AgendaClock.calendar.dateComponents([.timeZone, .year, .month, .day, .hour, .minute, .second], from: plan.fireAt)
                let request = UNNotificationRequest(identifier: plan.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
                if let old = existingByID[plan.id],
                   let trigger = old.trigger as? UNCalendarNotificationTrigger,
                   !trigger.repeats, trigger.dateComponents == components,
                   old.content.title == content.title, old.content.body == content.body,
                   old.content.categoryIdentifier == content.categoryIdentifier,
                   (old.content.sound != nil) == settings.sound,
                   old.content.userInfo["occurrenceID"] as? String == plan.occurrenceID,
                   old.content.userInfo["plannedDue"] as? Double == plan.due.timeIntervalSince1970 { continue }
                do { try await center.add(request) }
                catch { permissionText = "提醒排程失败：\(error.localizedDescription)" }
            } }
            if generation != version { continue }
            // The macOS scheduler can acknowledge an add before its pending
            // inventory has settled. Audit after that asynchronous propagation.
            try? await Task.sleep(for: .seconds(1))
            if generation != version { continue }
            let scheduled = await center.pendingNotificationRequests()
            pendingCount = scheduled.count
            if let evidenceURL, generation == version {
                // Read back what macOS actually accepted, rather than treating
                // a computed plan or center.add() call as proof of scheduling.
                let evidence: [String: Any] = [
                    "checkedAt": Date().timeIntervalSince1970,
                    "bundle": Bundle.main.bundleURL.path,
                    "authorized": authorized,
                    "pending": scheduled.map { request -> [String: Any] in
                        let fireAt = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                            ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                        return ["id": request.identifier,
                         "fireAt": fireAt?.timeIntervalSince1970 ?? 0,
                         "sound": request.content.sound != nil]
                    }
                ]
                if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) {
                    try? data.write(to: evidenceURL.deletingLastPathComponent().appendingPathComponent("notification-schedule.json"), options: .atomic)
                }
            }
            if generation == version { break }
          }
          syncing = false
        }
        return true
    }
    func testReminder(sound: Bool) {
        guard !simulated else { return }
        Task {
            let started = Date()
            if !authorized {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                let settings = await center.notificationSettings()
                authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                permissionText = authorized ? "系统通知已允许" : "系统通知未允许 · 日程面板仍可提醒"
                onReady?()
                guard authorized else { return }
            }
            let content = UNMutableNotificationContent(); content.title = "朝夕 · 提醒已就位"; content.body = "这是一次测试提醒。到了时间，就这样轻轻提醒你。"
            if sound { content.sound = UNNotificationSound(named: UNNotificationSoundName("soft.wav")) }
            do {
                try await center.add(UNNotificationRequest(identifier: "chaoxi-test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
                testStatus = "测试已安排，3 秒后轻轻提醒。"
                try? await Task.sleep(for: .seconds(4))
                let delivered = await center.deliveredNotifications()
                let record = delivered.first { $0.request.identifier == "chaoxi-test" && $0.date >= started }
                let pending = await center.pendingNotificationRequests()
                testStatus = record != nil ? "系统已记录投递；没看到横幅时，可检查勿扰与通知设置。" : pending.contains { $0.identifier == "chaoxi-test" } ? "系统仍在等待投递，可检查勿扰与通知设置。" : "系统没有返回投递记录，请检查通知设置。"
                if let evidenceURL {
                    let evidence: [String: Any] = ["startedAt": started.timeIntervalSince1970, "deliveredAt": record?.date.timeIntervalSince1970 ?? 0, "delivered": record != nil, "soundInRequest": record?.request.content.sound != nil, "authorized": authorized, "bundle": Bundle.main.bundleURL.path]
                    if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: evidenceURL, options: .atomic) }
                }
            }
            catch { permissionText = "测试提醒失败：\(error.localizedDescription)" }
        }
    }
    func openSettings() {
        guard !simulated else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["occurrenceID"] as? String ?? ""
        let action = response.actionIdentifier
        let plannedDue = response.notification.request.content.userInfo["plannedDue"] as? Double
        Task { @MainActor in self.onAction?(id, action, plannedDue) }
        completionHandler()
    }
}
