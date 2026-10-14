import Foundation
import Combine

@MainActor final class FeishuSyncCoordinator: ObservableObject {
    typealias Fetch = (Date, Date, @escaping @Sendable (String) async -> [String]) async throws -> FeishuSnapshot
    @Published private(set) var busy = false
    @Published private(set) var statusText = "未开启同步"
    private let store: AgendaStore
    private let qa: Bool
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var nextAttempt = Date.distantPast
    private var failures = 0
    private let fetch: Fetch
    private let now: () -> Date

    init(store: AgendaStore, qa: Bool, now: @escaping () -> Date = Date.init, fetch: Fetch? = nil) {
        self.store = store; self.qa = qa; self.now = now
        self.fetch = fetch ?? { start, end, existing in
            try await FeishuReader().read(windowStart: start, windowEnd: end, mirroredEventIDs: existing)
        }
    }

    func setEnabled(_ enabled: Bool) {
        store.settings.feishuSyncEnabled = enabled
        guard store.save() else { return }
        if !enabled { cancel(); statusText = "已暂停，保留已同步日程" }
        else { tick(force: true) }
    }

    func tick(force: Bool = false) {
        guard store.settings.feishuSyncEnabled == true else {
            cancel()
            if !statusText.hasPrefix("已暂停") { statusText = "未开启同步" }
            return
        }
        guard !qa else { statusText = "隔离验收不连接飞书"; return }
        guard !busy else { return }
        if force { failures = 0; nextAttempt = .distantPast }
        guard failures < 3, now() >= nextAttempt else { return }
        busy = true; statusText = "正在读取飞书日程…"
        let ticket = UUID(); generation = ticket
        let window = FeishuReader.defaultWindow(now: now())
        let targetStore = store
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.fetch(window.start, window.end) { calendarID in
                    await MainActor.run { targetStore.feishuMirroredEventIDs(calendarID: calendarID, windowStart: window.start, windowEnd: window.end) }
                }
                guard !Task.isCancelled, self.generation == ticket, self.store.settings.feishuSyncEnabled == true else { return }
                guard self.store.applyFeishuSnapshot(snapshot) else {
                    self.failed("同步未保存，请检查朝夕数据状态")
                    return
                }
                self.failures = 0
                self.nextAttempt = self.now().addingTimeInterval(300)
                self.statusText = "已同步 · " + AgendaClock.timeText(self.now()) + "，每 5 分钟更新"
            } catch {
                guard !Task.isCancelled, self.generation == ticket else { return }
                self.failed((error as? FeishuReadError)?.localizedDescription ?? "读取失败，已保留上次日程；请检查飞书登录与网络")
            }
            if self.generation == ticket { self.busy = false; self.task = nil }
        }
    }

    private func failed(_ message: String) {
        failures += 1; busy = false; task = nil
        nextAttempt = now().addingTimeInterval(300)
        statusText = message + (failures >= 3 ? "。连续失败，点立即同步后重试" : "")
    }
    private func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false }
}
