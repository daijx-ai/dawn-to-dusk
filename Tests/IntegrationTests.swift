import Foundation

@main struct IntegrationTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !value() { fatalError(message) }
        }
        let cal = AgendaClock.calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 8, minute: 0))!
        var settings = AgendaSettings()
        let seed = AgendaClock.seed(now: now)
        let plans = ReminderPlanner.plans(items: seed, settings: settings, now: now)
        check(plans.count == 2, "Only confirmed 09:00 receives lead and due notifications")
        check(plans.allSatisfy { $0.title == "上班" }, "Tentative schedules never notify")
        check(plans.map { AgendaClock.timeText($0.fireAt) } == ["08:50", "09:00"], "Confirmed morning reminders")
        check(ReminderPlanner.deliveredIsCurrent(occurrenceID: plans[1].occurrenceID, plannedDue: plans[1].due.timeIntervalSince1970, items: seed, settings: settings), "Current delivered notification retains identity")
        check(!ReminderPlanner.deliveredIsCurrent(occurrenceID: plans[1].occurrenceID, plannedDue: plans[1].due.addingTimeInterval(60).timeIntervalSince1970, items: seed, settings: settings), "Time-edit stale delivered notification cleared")
        check(!ReminderPlanner.deliveredIsCurrent(occurrenceID: plans[1].occurrenceID, plannedDue: plans[1].due.timeIntervalSince1970, items: [], settings: settings), "Deleted notification no longer current")
        settings.notifications = false
        check(ReminderPlanner.plans(items: seed, settings: settings, now: now).isEmpty, "Master off cancels desired requests")
        settings.notifications = true
        settings.leadMinutes = 0
        check(ReminderPlanner.plans(items: seed, settings: settings, now: now).count == 1, "No lead means due only")
        var work = seed.first { $0.title == "上班" }!
        work.completedDays.insert(AgendaClock.dayKey(now))
        check(ReminderPlanner.plans(items: [work], settings: settings, now: now).isEmpty, "Completed plans canceled")
        work.completedDays = []; work.timeMinutes = 11 * 60
        check(ReminderPlanner.plans(items: [work], settings: settings, now: now).first?.fireAt == cal.date(bySettingHour: 11, minute: 0, second: 0, of: now), "Edit replaces old time")
        let oldDay = cal.date(byAdding: .day, value: -20, to: now)!
        var old = AgendaItem(title: "未处理旧任务", date: oldDay, timeMinutes: 9 * 60)
        old.snoozes[AgendaClock.dayKey(oldDay)] = now.addingTimeInterval(600)
        let snoozed = ReminderPlanner.plans(items: [old], settings: settings, now: now)
        check(snoozed.count == 1 && snoozed[0].isSnooze, "Twenty-day-old snooze schedules")
        check(snoozed[0].fireAt == now.addingTimeInterval(600), "Snooze keeps future reminder")
        check(AgendaClock.dayKey(snoozed[0].due) == AgendaClock.dayKey(oldDay), "Snooze never moves plan")
        let laterDay = cal.date(byAdding: .day, value: 20, to: now)!
        var later = AgendaItem(title: "未来事项提前稍后提醒", date: laterDay, timeMinutes: 9 * 60)
        later.snoozes[AgendaClock.dayKey(laterDay)] = now.addingTimeInterval(600)
        check(ReminderPlanner.plans(items: [later], settings: settings, now: now).count == 1, "Explicit snooze outside calendar horizon still schedules immediately")
        old.snoozes = [:]
        check(ReminderPlanner.plans(items: [old], settings: settings, now: now).isEmpty, "No late replay storm")
        var repeated = work; repeated.repeatRule = .daily
        check(ReminderPlanner.plans(items: [repeated], settings: settings, now: now).count == 8, "Recurring horizon includes next seven days")
        let lots = (0..<100).map { AgendaItem(title: "同日 \($0)", date: now, timeMinutes: 12 * 60) }
        let limited = ReminderPlanner.plans(items: lots, settings: settings, now: now)
        check(limited.count == 60 && Set(limited.map(\.id)).count == 60, "System capacity limits without duplicate identities")
        settings.leadMinutes = 10
        let thirtyOne = Array(lots.prefix(31))
        let priority = ReminderPlanner.plans(items: thirtyOne, settings: settings, now: now)
        check(priority.filter { !$0.isLead }.count == 31, "Capacity never sacrifices due reminders for optional leads")
        check(ReminderPlanner.plans(items: thirtyOne, settings: settings, now: now, limit: Int.max).count - priority.count == 2, "Overflow count visible")
        let repeatedCapacity = (0..<8).map { AgendaItem(title: "容量检查 \($0)", date: now, timeMinutes: 9 * 60 + $0, repeatRule: .daily) }
        let repeatedUnbounded = ReminderPlanner.plans(items: repeatedCapacity, settings: settings, now: now, limit: Int.max)
        let repeatedBounded = ReminderPlanner.plans(items: repeatedCapacity, settings: settings, now: now)
        check(repeatedUnbounded.filter { !$0.isLead }.count == 64 && repeatedUnbounded.filter(\.isLead).count == 64, "Eight daily items create 64 due and 64 lead plans across the inclusive horizon")
        check(repeatedBounded.count == 60 && repeatedBounded.filter { !$0.isLead }.count == 52 && repeatedBounded.filter(\.isLead).count == 8, "Near-day due and all eight corresponding leads survive far repeating capacity pressure")
        check(repeatedBounded.filter { $0.fireAt < cal.date(byAdding: .day, value: 1, to: AgendaClock.startOfDay(now))! }.count == 16, "All eight due and lead pairs for today are selected")
        check(repeatedUnbounded.count - repeatedBounded.count == 68, "Capacity overflow includes omitted leads and due plans; it does not guarantee early reminders")
        let nineRepeated = repeatedCapacity + [AgendaItem(title: "第九条容量检查", date: now, timeMinutes: 9 * 60 + 8, repeatRule: .daily)]
        let nineBounded = ReminderPlanner.plans(items: nineRepeated, settings: settings, now: now)
        check(nineBounded.count == 60 && nineBounded.filter { !$0.isLead }.count == 51 && nineBounded.filter(\.isLead).count == 9, "Nine daily items retain today's nine leads rather than reserving all slots for far due plans")
        check(priority.filter(\.isLead).count == 29, "Thirty-one same-day due reminders retain the remaining 29 lead slots")
        check(ReminderPlanner.plans(items: repeatedCapacity, settings: settings, now: now, limit: 0).isEmpty, "Zero reminder capacity selects nothing")
        check(ReminderPlanner.plans(items: repeatedCapacity, settings: settings, now: now, limit: -1).isEmpty, "Negative reminder capacity is safely empty")
        let oneSlot = ReminderPlanner.plans(items: repeatedCapacity, settings: settings, now: now, limit: 1)
        check(oneSlot.count == 1 && !oneSlot[0].isLead && oneSlot[0].fireAt == now.addingTimeInterval(3600), "One slot keeps the earliest nearby due instead of its optional lead")
        let tomorrowStart = cal.date(byAdding: .day, value: 1, to: AgendaClock.startOfDay(now))!
        let boundaryDue = AgendaItem(title: "正好 24 小时", date: tomorrowStart, timeMinutes: 8 * 60)
        let beyondBoundaryDue = AgendaItem(title: "超过 24 小时", date: tomorrowStart, timeMinutes: 8 * 60 + 1)
        let boundaryPlans = ReminderPlanner.plans(items: [boundaryDue, beyondBoundaryDue], settings: settings, now: now, limit: 2)
        let boundaryID = AgendaClock.occurrences(items: [boundaryDue], on: tomorrowStart)[0].id
        check(boundaryPlans.count == 2 && boundaryPlans.allSatisfy { $0.occurrenceID == boundaryID } && boundaryPlans.contains(where: \.isLead), "Exactly 24-hour due is nearby and its lead outranks the just-beyond due")
        var nearOldSnooze = old; nearOldSnooze.snoozes[AgendaClock.dayKey(oldDay)] = now.addingTimeInterval(300)
        let nearSnoozePlans = ReminderPlanner.plans(items: repeatedCapacity + [nearOldSnooze], settings: settings, now: now, limit: 1)
        check(nearSnoozePlans.count == 1 && nearSnoozePlans[0].isSnooze && nearSnoozePlans[0].fireAt == now.addingTimeInterval(300), "Old occurrence snooze is prioritized by its nearby fireAt")
        var farOldSnooze = old; farOldSnooze.id = UUID(); farOldSnooze.snoozes[AgendaClock.dayKey(oldDay)] = now.addingTimeInterval(25 * 3600)
        let nearbyPairs = ReminderPlanner.plans(items: repeatedCapacity + [farOldSnooze], settings: settings, now: now, limit: 16)
        check(nearbyPairs.count == 16 && nearbyPairs.filter(\.isLead).count == 8 && nearbyPairs.allSatisfy { !$0.isSnooze }, "Far fireAt of an old snooze does not displace nearby due and lead pairs")
        check(Set(nineBounded.map(\.id)).count == nineBounded.count, "Capacity selection never duplicates request IDs")
        check(zip(nineBounded, nineBounded.dropFirst()).allSatisfy { lhs, rhs in lhs.fireAt < rhs.fireAt || (lhs.fireAt == rhs.fireAt && lhs.id < rhs.id) }, "Selected reminders return in fireAt and identity order")
        let draft = CaptureParser.parse(URL(string: "chaoxi://add?title=Clawd%20%E5%BE%85%E5%8A%9E&date=2026-10-13&time=07:30&source=clawd")!, day: now)
        check(draft?.title == "Clawd 待办", "Deep link UTF-8 title")
        check(draft?.timeMinutes == 450 && draft?.note == "从 Clawd 添加", "Deep link time/source")
        check(draft.map { AgendaClock.dayKey($0.date) } == "2026-10-13", "Deep link date")
        check(CaptureParser.parse(URL(string: "chaoxi://add?time=25:00")!, day: now) == nil, "Reject invalid time")
        check(CaptureParser.parse(URL(string: "chaoxi://add?date=2026-02-30")!, day: now) == nil, "Reject impossible date")
        check(CaptureParser.parse(URL(string: "evil://add?title=test")!, day: now) == nil, "Reject wrong scheme")
        check(CaptureParser.parse(URL(string: "chaoxi://add")!, day: now)?.timeMinutes == nil, "Empty pet link is unsaved draft")
        let checklistDraft = CaptureParser.parse(URL(string: "chaoxi://add?title=Buy%20milk&source=clawd")!, day: now)!
        check(checklistDraft.isChecklist && checklistDraft.scheduledDay == nil && !checklistDraft.reminderEnabled, "Undated capture creates a silent independent checklist draft")
        check(checklistDraft.note == "从 Clawd 添加", "Checklist capture preserves Clawd source")
        check(draft?.isChecklist == false, "Explicit dated/timed capture remains a schedule")
        let dateOnly = CaptureParser.parse(URL(string: "chaoxi://add?title=Prepare&date=2026-10-13")!, day: now)!
        check(!dateOnly.isChecklist && dateOnly.timeMinutes == nil, "Explicit date-only capture remains that day's untimed schedule")
        check(CaptureParser.parse(URL(string: "chaoxi://add?date")!, day: now) == nil, "Reject explicit date without a value")
        check(CaptureParser.parse(URL(string: "chaoxi://add?time")!, day: now) == nil, "Reject explicit time without a value")
        check(ReminderPlanner.plans(items: [checklistDraft], settings: settings, now: now).isEmpty, "Independent checklist capture never schedules a reminder")
        var moved = AgendaItem(title: "推迟事项", date: now, timeMinutes: 9 * 60, durationMinutes: 30)
        let originalO = AgendaClock.occurrences(items: [moved], on: now)[0]
        moved.postponedTimes = [AgendaClock.dayKey(now): now.addingTimeInterval(20 * 3600)]
        let movedO = AgendaClock.occurrence(items: [moved], id: originalO.id)!
        settings.leadMinutes = 10
        let movedPlans = ReminderPlanner.plans(items: [moved], settings: settings, now: now)
        check(movedPlans.count == 2 && movedPlans.allSatisfy { $0.due == movedO.due }, "postponed lead and due notifications both use the new time")
        check(movedPlans.first { !$0.isLead }?.fireAt == movedO.due && movedO.end == movedO.due!.addingTimeInterval(1800), "postponement moves notification and duration together")
        check(Set(movedPlans.map(\.id)).count == 2 && movedPlans.allSatisfy { $0.occurrenceID == originalO.id }, "cross-day plans retain unique original occurrence IDs")
        check(!ReminderPlanner.deliveredIsCurrent(occurrenceID: originalO.id, plannedDue: originalO.due!.timeIntervalSince1970, items: [moved], settings: settings), "postponement invalidates an old delivered notification")
        check(ReminderPlanner.deliveredIsCurrent(occurrenceID: originalO.id, plannedDue: movedO.due!.timeIntervalSince1970, items: [moved], settings: settings), "cross-day notification resolves new due through original ID")
        moved.isTentative = true
        check(ReminderPlanner.plans(items: [moved], settings: settings, now: now).isEmpty, "postponed tentative event stays silent even with reminder flag")
        moved.isTentative = false; moved.reminderEnabled = false
        check(ReminderPlanner.plans(items: [moved], settings: settings, now: now).isEmpty, "postponement preserves reminders disabled")
        moved.reminderEnabled = true; moved.snoozes[AgendaClock.dayKey(now)] = now.addingTimeInterval(21 * 3600)
        let movedSnoozes = ReminderPlanner.plans(items: [moved], settings: settings, now: now)
        check(movedSnoozes.count == 1 && movedSnoozes[0].isSnooze && movedSnoozes[0].due == movedO.due, "snooze after cross-day postponement creates one reminder without duplicate lead")
        check(ReminderPlanner.plans(items: [moved], settings: settings, now: now.addingTimeInterval(24 * 3600)).isEmpty, "expired postponed reminder does not replay")
        let fakeNotifications = NotificationService(simulated: true)
        let actualNow = Date()
        let actualOldDay = AgendaClock.calendar.date(byAdding: .day, value: -1, to: AgendaClock.startOfDay(actualNow))!
        var outsideHorizon = AgendaItem(title: "通知窗口外推迟", date: actualOldDay, timeMinutes: 9 * 60)
        let oldO = AgendaClock.occurrences(items: [outsideHorizon], on: actualOldDay)[0]
        check(fakeNotifications.sync(items: [outsideHorizon], settings: settings) && fakeNotifications.pendingCount == 0, "fake service receives an overdue event with no pending plans")
        outsideHorizon.postponedTimes = [AgendaClock.dayKey(actualOldDay): actualNow.addingTimeInterval(8 * 86400)]
        check(ReminderPlanner.plans(items: [outsideHorizon], settings: settings, now: actualNow).isEmpty, "far postponement retains an empty pending plan set")
        check(fakeNotifications.sync(items: [outsideHorizon], settings: settings) && fakeNotifications.pendingCount == 0, "changed postponement triggers delivered cleanup even with the same empty pending plans")
        check(!fakeNotifications.sync(items: [outsideHorizon], settings: settings), "unchanged event does not repeatedly resync")
        check(!ReminderPlanner.deliveredIsCurrent(occurrenceID: oldO.id, plannedDue: oldO.due!.timeIntervalSince1970, items: [outsideHorizon], settings: settings), "old notification action token cannot match a far postponed event")
        check(!ReminderPlanner.deliveredIsCurrent(occurrenceID: oldO.id, plannedDue: nil, items: [outsideHorizon], settings: settings), "notification action without a due token is rejected")
        let browsingToday = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 10, minute: 45))!
        let explicitTomorrow = cal.date(byAdding: .day, value: 1, to: browsingToday)!
        let browsingHistory = cal.date(byAdding: .day, value: -2, to: browsingToday)!
        check(AgendaEditorNavigation.dayAfterSave(browsingDay: browsingToday, editedDay: now, isExisting: true, schedulingChecklist: false) == AgendaClock.startOfDay(browsingToday), "Editing an October 12 repeat anchor while browsing October 13 preserves October 13")
        check(AgendaEditorNavigation.dayAfterSave(browsingDay: browsingHistory, editedDay: now, isExisting: true, schedulingChecklist: false) == AgendaClock.startOfDay(browsingHistory), "Explicit historical browsing remains historical after an existing-item edit")
        check(AgendaEditorNavigation.dayAfterSave(browsingDay: browsingToday, editedDay: explicitTomorrow, isExisting: true, schedulingChecklist: false) == AgendaClock.startOfDay(browsingToday), "Changing an existing anchor does not implicitly change the browsing day")
        check(AgendaEditorNavigation.dayAfterSave(browsingDay: browsingToday, editedDay: explicitTomorrow, isExisting: false, schedulingChecklist: false) == AgendaClock.startOfDay(explicitTomorrow), "A new item opens its explicitly chosen date")
        check(AgendaEditorNavigation.dayAfterSave(browsingDay: browsingToday, editedDay: browsingHistory, isExisting: false, schedulingChecklist: false) == AgendaClock.startOfDay(browsingHistory), "A new item may explicitly choose a historical date")
        check(AgendaEditorNavigation.dayAfterSave(browsingDay: browsingHistory, editedDay: explicitTomorrow, isExisting: true, schedulingChecklist: true) == AgendaClock.startOfDay(explicitTomorrow), "Scheduling an existing checklist opens the chosen date rather than its old creation anchor")
        let navigationRoot = FileManager.default.temporaryDirectory.appendingPathComponent("chaoxi-integration-navigation-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: navigationRoot) }
        let navigationStore = AgendaStore(directory: navigationRoot, seedIfEmpty: false)
        var repeatEdit = AgendaItem(title: "导航隔离作息", date: AgendaClock.startOfDay(now), timeMinutes: 9 * 60, repeatRule: .daily)
        repeatEdit.completedDays = [AgendaClock.dayKey(now)]
        check(navigationStore.upsert(repeatEdit), "Synthetic navigation fixture saves in a fresh temporary directory")
        navigationStore.selectedDay = AgendaClock.startOfDay(browsingToday)
        repeatEdit.timeMinutes = 10 * 60
        let beforeEditBrowsingDay = navigationStore.selectedDay
        if navigationStore.upsert(repeatEdit) {
            navigationStore.selectedDay = AgendaEditorNavigation.dayAfterSave(browsingDay: beforeEditBrowsingDay, editedDay: repeatEdit.date, isExisting: true, schedulingChecklist: false)
        } else { fatalError("Existing navigation fixture edit must save") }
        check(navigationStore.selectedDay == AgendaClock.startOfDay(browsingToday), "Successful repeat edit plus navigation policy retains today's browsing day")
        check(navigationStore.items[0].date == AgendaClock.startOfDay(now) && navigationStore.items[0].completedDays == [AgendaClock.dayKey(now)], "Navigation does not rewrite the repeat anchor or prior completion record")
        let bytesBeforeInvalid = try Data(contentsOf: navigationStore.fileURL)
        var invalidNavigationDraft = repeatEdit; invalidNavigationDraft.title = " "
        check(!navigationStore.upsert(invalidNavigationDraft), "Invalid editor draft fails instead of applying navigation")
        let bytesAfterInvalid = try Data(contentsOf: navigationStore.fileURL)
        check(navigationStore.selectedDay == beforeEditBrowsingDay && bytesAfterInvalid == bytesBeforeInvalid, "Failed save preserves browsing day and committed synthetic data")
        let checklistToSchedule = AgendaItem(title: "导航隔离清单", date: AgendaClock.startOfDay(browsingHistory), timeMinutes: nil, reminderEnabled: false, checklistState: .pending)
        check(navigationStore.upsert(checklistToSchedule), "Synthetic checklist navigation fixture")
        var scheduledChecklist = checklistToSchedule; scheduledChecklist.date = explicitTomorrow; scheduledChecklist.timeMinutes = 11 * 60
        check(navigationStore.scheduleChecklistItem(scheduledChecklist), "Checklist schedules with the same identity")
        navigationStore.selectedDay = AgendaEditorNavigation.dayAfterSave(browsingDay: beforeEditBrowsingDay, editedDay: scheduledChecklist.date, isExisting: true, schedulingChecklist: true)
        check(navigationStore.selectedDay == AgendaClock.startOfDay(explicitTomorrow) && navigationStore.items.first { $0.id == checklistToSchedule.id }?.isChecklist == false, "Checklist scheduling policy opens the chosen day without creating another item")
        var compactCapture = AgendaCapturePresentation()
        compactCapture.began(originatedCompact: true)
        check(compactCapture.finished(hasQueuedCapture: false), "Dismissing a single capture opened from compact restores compact")
        check(!compactCapture.finished(hasQueuedCapture: false), "Repeated capture dismissal cannot restore compact a second time")
        var cancelledCompactCapture = AgendaCapturePresentation()
        cancelledCompactCapture.began(originatedCompact: true)
        check(cancelledCompactCapture.finished(hasQueuedCapture: false), "Cancellation uses the same compact restoration dismissal policy")
        var expandedCapture = AgendaCapturePresentation()
        expandedCapture.began(originatedCompact: false)
        check(!expandedCapture.finished(hasQueuedCapture: false), "Capture opened from expanded view remains expanded")
        var queuedCaptures = AgendaCapturePresentation()
        queuedCaptures.began(originatedCompact: true)
        check(!queuedCaptures.finished(hasQueuedCapture: true) && queuedCaptures.restoresCompact, "Pending capture queue keeps input expanded and retains compact origin")
        queuedCaptures.began(originatedCompact: false)
        check(queuedCaptures.finished(hasQueuedCapture: false) && !queuedCaptures.restoresCompact, "Last queued capture restores compact even when its own origin was expanded")
        check(!queuedCaptures.finished(hasQueuedCapture: false), "Drained capture queue clears restoration state")
        var mixedCaptures = AgendaCapturePresentation()
        mixedCaptures.began(originatedCompact: false)
        check(!mixedCaptures.finished(hasQueuedCapture: true), "Expanded-origin capture with more queued input waits without restoration")
        mixedCaptures.began(originatedCompact: true)
        check(mixedCaptures.finished(hasQueuedCapture: false), "Any compact-origin session in a capture queue requests restoration when drained")
        // Exercise the same URL parser/receiver used by App callbacks without
        // initializing AppController, a real notification center or a GUI.
        let receiverQARoot = FileManager.default.temporaryDirectory.appendingPathComponent("chaoxi-qa-capture-receiver-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: receiverQARoot) }
        let receiverQAStore = AgendaStore(directory: receiverQARoot, seedIfEmpty: false)
        var coldReceiver = AgendaCaptureReceiver()
        let coldFirstURL = URL(string: "chaoxi://add?title=Cold%20first&source=clawd")!
        let coldLastURL = URL(string: "chaoxi://add?title=Cold%20last&date=2026-10-14&time=10:15")!
        let deferredBatch = coldReceiver.receiveURLs([coldFirstURL, coldLastURL], isReady: false, day: now, originatedCompact: true)
        check(deferredBatch.captureCount == 0 && coldReceiver.takeDrafts().isEmpty, "Cold batch defers every URL instead of exposing a last-write-only draft")
        let coldReception = coldReceiver.becomeReady(day: now, originatedCompact: true)
        let coldDrafts = coldReceiver.takeDrafts()
        check(coldReception.captureCount == 2 && !coldReception.hasInvalidCapture, "Becoming ready parses and receives both cold-start URLs")
        check(coldDrafts.map { $0.item.title } == ["Cold first", "Cold last"], "Cold URL queue preserves first, last and arrival order")
        check(coldDrafts[0].source == "clawd" && coldDrafts[0].item.note == "从 Clawd 添加" && coldDrafts[1].source == nil, "Cold reception snapshots each source independently")
        check(coldDrafts[0].item.isChecklist && !coldDrafts[1].item.isChecklist && coldDrafts[1].item.timeMinutes == 615 && AgendaClock.dayKey(coldDrafts[1].item.date) == "2026-10-14", "Cold reception preserves distinct undated and explicit-date payloads")
        check(coldDrafts.allSatisfy(\.restoreCompactOnDismiss), "Every draft in a cold compact-origin batch retains that origin")
        check(coldReceiver.takeDrafts().isEmpty && coldReceiver.becomeReady(day: now, originatedCompact: false).captureCount == 0, "Cold queue and initial draft drain are idempotent")
        for value in coldDrafts { check(receiverQAStore.upsert(value.item), "Cold draft can save once into isolated QA data") }
        check(receiverQAStore.items.map(\.id) == coldDrafts.map { $0.item.id }, "Cold first and last payload retain identity and order through isolated saves")
        var runningReceiver = AgendaCaptureReceiver()
        let runningURLs = [URL(string: "chaoxi://add?title=Running%20first&source=clawd")!, URL(string: "chaoxi://add?title=Running%20last&date=2026-10-15&time=11:20")!]
        let runningReception = runningReceiver.receiveURLs(runningURLs, isReady: true, day: browsingToday, originatedCompact: true)
        check(runningReception.captureCount == 2 && !runningReception.hasInvalidCapture, "One running callback receives all URLs before a coalesced view change")
        let laterReception = runningReceiver.receiveURLs([URL(string: "chaoxi://add?title=Later%20expanded&source=clawd")!], isReady: true, day: browsingToday, originatedCompact: false)
        let runningDrafts = runningReceiver.takeDrafts()
        check(laterReception.captureCount == 1 && runningDrafts.map { $0.item.title } == ["Running first", "Running last", "Later expanded"], "Undrained running callbacks append every payload in arrival order")
        check(runningDrafts.map(\.restoreCompactOnDismiss) == [true, true, false], "Running batch snapshots compact origin before expansion and keeps later expanded origin separate")
        check(runningDrafts.map(\.source) == ["clawd", nil, "clawd"] && runningDrafts[1].item.timeMinutes == 680, "Running draft source and distinct timed payload cannot be overwritten by the next request")
        check(Set(runningDrafts.map { $0.item.id }).count == 3 && runningReceiver.takeDrafts().isEmpty, "Running drain returns unique identities exactly once")
        var receivedPresentation = AgendaCapturePresentation()
        for (index, value) in runningDrafts.enumerated() {
            receivedPresentation.began(originatedCompact: value.restoreCompactOnDismiss)
            check(receiverQAStore.upsert(value.item), "Each received running payload saves into isolated QA data")
            check(receivedPresentation.finished(hasQueuedCapture: index + 1 < runningDrafts.count) == (index + 1 == runningDrafts.count), "Received mixed-origin queue restores compact only after the final payload closes")
        }
        check(receiverQAStore.items.suffix(3).map(\.id) == runningDrafts.map { $0.item.id } && !receivedPresentation.finished(hasQueuedCapture: false), "All running payloads persist in order and restoration clears after queue drain")
        var invalidNeighborReceiver = AgendaCaptureReceiver()
        let mixedReception = invalidNeighborReceiver.receiveURLs([coldFirstURL, URL(string: "chaoxi://add?title=Invalid&time=25:00")!, coldLastURL], isReady: true, day: now, originatedCompact: false)
        check(mixedReception.captureCount == 2 && mixedReception.hasInvalidCapture && invalidNeighborReceiver.takeDrafts().map { $0.item.title } == ["Cold first", "Cold last"], "Invalid URL cannot erase valid neighbors in the same callback")
        var readyTransitionReceiver = AgendaCaptureReceiver()
        _ = readyTransitionReceiver.receiveURLs([coldFirstURL], isReady: false, day: now, originatedCompact: true)
        let transitionReception = readyTransitionReceiver.receiveURLs([coldLastURL], isReady: true, day: now, originatedCompact: true)
        check(transitionReception.captureCount == 2 && readyTransitionReceiver.takeDrafts().map { $0.item.title } == ["Cold first", "Cold last"], "A first ready callback consumes older pending URLs before its own batch")
        check(readyTransitionReceiver.becomeReady(day: now, originatedCompact: false).captureCount == 0 && readyTransitionReceiver.takeDrafts().isEmpty, "Ready transition leaves no deferred URLs or replayable drafts")
        let revealReception = readyTransitionReceiver.receiveURLs([URL(string: "chaoxi://")!], isReady: true, day: now, originatedCompact: false)
        check(revealReception.shouldReveal && revealReception.captureCount == 0 && readyTransitionReceiver.takeDrafts().isEmpty, "Plain app reveal does not manufacture a capture draft")
        check(AgendaEditorNavigation.dayAfterMidnight(browsingDay: browsingToday, now: explicitTomorrow, wasViewingToday: true) == AgendaClock.startOfDay(explicitTomorrow), "Default today browsing follows the new date across a controlled midnight")
        check(AgendaEditorNavigation.dayAfterMidnight(browsingDay: browsingHistory, now: explicitTomorrow, wasViewingToday: false) == AgendaClock.startOfDay(browsingHistory), "Controlled midnight preserves explicitly selected history")
        let manuallySelectedFuture = cal.date(byAdding: .day, value: 2, to: browsingToday)!
        check(AgendaEditorNavigation.dayAfterMidnight(browsingDay: manuallySelectedFuture, now: explicitTomorrow, wasViewingToday: false) == AgendaClock.startOfDay(manuallySelectedFuture), "Controlled midnight preserves explicitly selected future browsing")
        let afterSeveralDays = cal.date(byAdding: .day, value: 3, to: browsingToday)!
        check(AgendaEditorNavigation.dayAfterMidnight(browsingDay: browsingToday, now: afterSeveralDays, wasViewingToday: true) == AgendaClock.startOfDay(afterSeveralDays), "Default date policy follows the actual current day after multiple missed midnights")
        let beforeMidnightPolicyBytes = try Data(contentsOf: navigationStore.fileURL)
        navigationStore.selectedDay = AgendaEditorNavigation.dayAfterMidnight(browsingDay: browsingToday, now: explicitTomorrow, wasViewingToday: true)
        let afterDefaultPolicyBytes = try Data(contentsOf: navigationStore.fileURL)
        check(navigationStore.selectedDay == AgendaClock.startOfDay(explicitTomorrow) && afterDefaultPolicyBytes == beforeMidnightPolicyBytes, "Applying the default midnight policy changes browsing without rewriting stored items")
        navigationStore.selectedDay = AgendaEditorNavigation.dayAfterMidnight(browsingDay: browsingHistory, now: explicitTomorrow, wasViewingToday: false)
        let afterHistoryPolicyBytes = try Data(contentsOf: navigationStore.fileURL)
        check(navigationStore.selectedDay == AgendaClock.startOfDay(browsingHistory) && afterHistoryPolicyBytes == beforeMidnightPolicyBytes, "Applying the historical midnight policy leaves date selection and committed data intact")
        print("PASS \(checks) integration checks; no real notification/login or production-data effects; synthetic temporary data only")
    }
}
