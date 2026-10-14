import Foundation

@main struct FeishuSyncTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgendaStore(directory: root, seedIfEmpty: false)
        var date = Date(timeIntervalSince1970: 1791780000)
        var calls = 0
        let event = FeishuEvent(calendarID: "fake-calendar", eventID: "fake-meeting_0", title: "隔离会议", start: date, end: date.addingTimeInterval(3600))
        let fetch: FeishuSyncCoordinator.Fetch = { start, end, existing in
            calls += 1
            _ = await existing("fake-calendar")
            return FeishuSnapshot(calendarID: "fake-calendar", windowStart: start, windowEnd: end, events: [event])
        }
        let coordinator = FeishuSyncCoordinator(store: store, qa: false, now: { date }, fetch: fetch)
        func settle(_ coordinator: FeishuSyncCoordinator) async throws {
            for _ in 0..<200 { if !coordinator.busy { return }; try await Task.sleep(nanoseconds: 1_000_000) }
            preconditionFailure("fake sync failed to settle")
        }
        coordinator.tick(); assert(calls == 0)
        coordinator.setEnabled(true); try await settle(coordinator)
        assert(calls == 1 && store.items.count == 1 && coordinator.statusText.hasPrefix("已同步"))
        coordinator.tick(); assert(calls == 1)
        date = date.addingTimeInterval(301); coordinator.tick(); try await settle(coordinator)
        assert(calls == 2 && store.items.count == 1)
        coordinator.setEnabled(false); coordinator.tick(force: true); assert(calls == 2 && !coordinator.busy)

        let qa = FeishuSyncCoordinator(store: store, qa: true, fetch: fetch)
        qa.setEnabled(true); assert(calls == 2 && qa.statusText.contains("不连接"))

        var failures = 0
        let failing = FeishuSyncCoordinator(store: store, qa: false, now: { date }, fetch: { _, _, _ in
            failures += 1; throw FeishuReadError.timeout
        })
        for _ in 0..<3 { failing.tick(); try await settle(failing); date = date.addingTimeInterval(301) }
        failing.tick(); assert(failures == 3 && failing.statusText.contains("连续失败") && store.items.count == 1)
        failing.tick(force: true); try await settle(failing); assert(failures == 4)

        let missingRuntime = FeishuSyncCoordinator(store: store, qa: false, fetch: { _, _, _ in
            throw FeishuReadError.dependencyUnavailable
        })
        missingRuntime.tick(); try await settle(missingRuntime)
        assert(missingRuntime.statusText.contains("Node") && store.items.count == 1)

        var resume: CheckedContinuation<FeishuSnapshot, Never>?
        let pending = FeishuSyncCoordinator(store: store, qa: false, fetch: { start, end, _ in
            await withCheckedContinuation { resume = $0 }
        })
        pending.tick()
        for _ in 0..<200 { if resume != nil { break }; await Task.yield() }
        assert(resume != nil && pending.busy)
        pending.setEnabled(false)
        var changed = event; changed.title = "不应保存迟到响应"
        resume?.resume(returning: FeishuSnapshot(calendarID: "fake-calendar", windowStart: date, windowEnd: date.addingTimeInterval(86400), events: [changed]))
        for _ in 0..<20 { await Task.yield() }
        assert(!pending.busy && store.items.first?.title == "隔离会议")
        print("PASS: fake sync cadence, disable, QA no-network, failure pause/retry and late-response cancellation; no external process")
    }
}
