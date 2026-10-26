import Foundation
import Combine

@MainActor final class FeishuSyncCoordinator: ObservableObject {
    typealias Fetch = (Date, Date, @escaping @Sendable (String) async -> [String]) async throws -> FeishuSnapshot
    @Published private(set) var busy = false
    private enum Status { case off, paused, testing, loading, synced(Date), saveFailed, failed(FeishuReadError?) }
    @Published private var status = Status.off
    var statusText: String {
        switch status {
        case .off: return L("未开启同步")
        case .paused: return L("已暂停，保留已同步日程")
        case .testing: return L("隔离验收不连接飞书")
        case .loading: return L("正在读取飞书日程…")
        case .synced(let date): return L("已同步 · ") + AgendaClock.timeText(date) + L("，每 5 分钟更新")
        case .saveFailed: return L("同步未保存，请检查朝夕数据状态") + failureSuffix
        case .failed(let reason): return (reason?.localizedDescription ?? L("读取失败，已保留上次日程；请检查飞书登录与网络")) + failureSuffix
        }
    }
    private var failureSuffix: String { failures >= 3 ? L("。连续失败，点立即同步后重试") : "" }
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
        if !enabled { cancel(); status = .paused }
        else { tick(force: true) }
    }

    func tick(force: Bool = false) {
        guard store.settings.feishuSyncEnabled == true else {
            cancel()
            if case .paused = status { } else { status = .off }
            return
        }
        guard !qa else { status = .testing; return }
        guard !busy else { return }
        if force { failures = 0; nextAttempt = .distantPast }
        guard failures < 3, now() >= nextAttempt else { return }
        busy = true; status = .loading
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
                    self.failed(nil, saveFailed: true)
                    return
                }
                self.failures = 0
                self.nextAttempt = self.now().addingTimeInterval(300)
                self.status = .synced(self.now())
            } catch {
                guard !Task.isCancelled, self.generation == ticket else { return }
                self.failed(error as? FeishuReadError)
            }
            if self.generation == ticket { self.busy = false; self.task = nil }
        }
    }

    private func failed(_ reason: FeishuReadError?, saveFailed: Bool = false) {
        failures += 1; busy = false; task = nil
        nextAttempt = now().addingTimeInterval(300)
        status = saveFailed ? .saveFailed : .failed(reason)
    }
    private func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false }
}
