import AppKit
import SwiftUI
import Combine
import ServiceManagement
import UserNotifications
import Darwin

final class AgendaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct AgendaCapturePresentation {
    private(set) var restoresCompact = false

    mutating func began(originatedCompact: Bool) {
        restoresCompact = restoresCompact || originatedCompact
    }

    mutating func finished(hasQueuedCapture: Bool) -> Bool {
        guard !hasQueuedCapture else { return false }
        let restore = restoresCompact
        restoresCompact = false
        return restore
    }
}

enum CaptureParser {
    static func parse(_ url: URL, day: Date) -> AgendaItem? {
        guard url.scheme?.lowercased() == "chaoxi", url.host == "add", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let args = c.queryItems ?? []
        guard !args.contains(where: { ($0.name == "date" || $0.name == "time") && $0.value == nil }) else { return nil }
        let title = args.first { $0.name == "title" }?.value ?? ""
        guard title.count <= 200 else { return nil }
        var item = AgendaItem(title: title, date: day)
        if let t = args.first(where: { $0.name == "time" })?.value {
            let bits = t.split(separator: ":"); guard bits.count == 2, let h = Int(bits[0]), let m = Int(bits[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
            item.timeMinutes = h * 60 + m
        }
        if let d = args.first(where: { $0.name == "date" })?.value {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = AgendaClock.calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.isLenient = false
            guard let parsed = f.date(from: d), AgendaClock.dayKey(parsed) == d else { return nil }; item.date = parsed
        }
        item.note = args.first { $0.name == "source" }?.value == "clawd" ? "从 Clawd 添加" : ""
        if !args.contains(where: { $0.name == "date" || $0.name == "time" }) {
            item.checklistState = .pending
            item.reminderEnabled = false
        }
        return item
    }
}

struct AgendaCaptureDraft {
    let item: AgendaItem
    let source: String?
    let restoreCompactOnDismiss: Bool
}

struct AgendaCaptureReception {
    var captureCount = 0
    var shouldReveal = false
    var hasInvalidCapture = false
}

struct AgendaCaptureReceiver {
    private var pendingURLs: [URL] = []
    private var drafts: [AgendaCaptureDraft] = []

    mutating func receiveURLs(_ urls: [URL], isReady: Bool, day: Date, originatedCompact: Bool) -> AgendaCaptureReception {
        guard isReady else {
            pendingURLs.append(contentsOf: urls)
            return AgendaCaptureReception()
        }
        let received = pendingURLs + urls
        pendingURLs.removeAll()
        return consumeURLs(received, day: day, originatedCompact: originatedCompact)
    }

    mutating func becomeReady(day: Date, originatedCompact: Bool) -> AgendaCaptureReception {
        receiveURLs([], isReady: true, day: day, originatedCompact: originatedCompact)
    }

    mutating func enqueue(item: AgendaItem, source: String?, originatedCompact: Bool) {
        drafts.append(AgendaCaptureDraft(item: item, source: source, restoreCompactOnDismiss: originatedCompact))
    }

    mutating func takeDrafts() -> [AgendaCaptureDraft] {
        let pending = drafts
        drafts.removeAll()
        return pending
    }

    private mutating func consumeURLs(_ urls: [URL], day: Date, originatedCompact: Bool) -> AgendaCaptureReception {
        var reception = AgendaCaptureReception()
        for url in urls {
            guard url.scheme?.lowercased() == "chaoxi" else { continue }
            if url.host == "add" {
                guard let item = CaptureParser.parse(url, day: day) else {
                    reception.hasInvalidCapture = true
                    continue
                }
                enqueue(item: item, source: item.note == "从 Clawd 添加" ? "clawd" : nil, originatedCompact: originatedCompact)
                reception.captureCount += 1
            } else if url.host == nil || url.host == "" {
                reception.shouldReveal = true
            }
        }
        return reception
    }
}

@MainActor final class AppController: NSObject, ObservableObject, NSApplicationDelegate, NSWindowDelegate {
    let store: AgendaStore
    let notifications: NotificationService
    let feishuSync: FeishuSyncCoordinator
    @Published var loginEnabled = false
    @Published var loginText = ""
    @Published var captureToken = UUID()
    private var captureReceiver = AgendaCaptureReceiver()
    private var panel: AgendaPanel!
    private var statusItem: NSStatusItem!
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private lazy var captureInbox = CaptureInbox(root: store.fileURL.deletingLastPathComponent())
    private var selectedToday = false
    private var lastDay = AgendaClock.dayKey(Date())
    private var isBuildingMenu = false
    private let qa: Bool
    var isQA: Bool { qa }
    private var panelCompact = false
    private var changingPanelMode = false
    @Published var glassStrength: Double = 0.55
    @Published var glassEnabled: Bool = true
    private var frameKey: String { qa ? "qaPanelFrame" : "panelFrame" }
    private func modeFrameKey(_ compact: Bool) -> String { (qa ? "qaPanel" : "panel") + (compact ? "CompactFrame" : "ExpandedFrame") }
    private var glassKey: String { qa ? "qaGlassStrength" : "glassStrength" }
    private var glassEnabledKey: String { qa ? "qaGlassEnabled" : "glassEnabled" }
    func setGlassStrength(_ value: Double) {
        glassStrength = AgendaBackgroundOpacity.clamp(value, fallback: glassStrength); UserDefaults.standard.set(glassStrength, forKey: glassKey)
        writeRuntimeEvidence()
    }
    func setGlassEnabled(_ value: Bool) {
        glassEnabled = value; UserDefaults.standard.set(value, forKey: glassEnabledKey)
        writeRuntimeEvidence()
    }
    override init() {
        let args = ProcessInfo.processInfo.arguments
        qa = args.contains("--qa")
        var directory: URL?
        if let idx = args.firstIndex(of: "--data-dir"), args.indices.contains(idx + 1) { directory = URL(fileURLWithPath: args[idx + 1]) }
        store = AgendaStore(directory: directory)
        feishuSync = FeishuSyncCoordinator(store: store, qa: qa)
        notifications = NotificationService(simulated: qa)
        notifications.evidenceURL = store.fileURL.deletingLastPathComponent().appendingPathComponent("notification-test.json")
        super.init()
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createMenu()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showRequested), name: Notification.Name("com.djx.chaoxi.show"), object: store.fileURL.deletingLastPathComponent().path)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showRequested), name: AgendaGUILease.revealNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(processCaptures), name: CaptureInbox.notificationName, object: CaptureInbox.notificationObject(for: store.fileURL.deletingLastPathComponent()))
        let launchDay = AgendaClock.startOfDay(Date())
        store.selectedDay = launchDay
        lastDay = AgendaClock.dayKey(launchDay)
        selectedToday = true
        applyAppearance(); createPanel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        notifications.onReady = { [weak self] in self?.syncReminders(force: true); self?.writeRuntimeEvidence() }
        notifications.onAction = { [weak self] oid, action, plannedDue in self?.notificationAction(oid: oid, action: action, plannedDue: plannedDue) }
        notifications.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        feishuSync.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        store.$items.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.syncReminders(); self?.refreshStatus() } }.store(in: &subscriptions)
        store.$settings.dropFirst().removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.applyAppearance(); self?.applyWindowMode(); self?.resizePanel(); self?.syncReminders() } }.store(in: &subscriptions)
        store.$selectedDay.dropFirst().sink { [weak self] day in self?.selectedToday = AgendaClock.dayKey(day) == AgendaClock.dayKey(Date()) }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshTick() } }
        refreshStatus(); syncReminders(); refreshLogin()
        if !qa {
            let hasRegistered = UserDefaults.standard.bool(forKey: "didConfigureLogin")
            if !hasRegistered { setLoginEnabled(true); UserDefaults.standard.set(true, forKey: "didConfigureLogin") }
            notifications.refreshPermission(request: true)
        }
        applyCaptureReception(captureReceiver.becomeReady(day: AgendaClock.startOfDay(Date()), originatedCompact: store.settings.compact))
        processCaptures(); feishuSync.tick(); writeRuntimeEvidence()
    }
    private func createPanel() {
        panelCompact = store.settings.compact
        if UserDefaults.standard.object(forKey: glassKey) != nil { glassStrength = AgendaBackgroundOpacity.clamp(UserDefaults.standard.double(forKey: glassKey), fallback: glassStrength) }
        if UserDefaults.standard.object(forKey: glassEnabledKey) != nil { glassEnabled = UserDefaults.standard.bool(forKey: glassEnabledKey) }
        let size = NSSize(width: 400, height: panelCompact ? 82 : 850)
        panel = AgendaPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.title = qa ? "朝夕 · 隔离验收" : "朝夕 · 日程"; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.delegate = self; panel.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let content = AgendaContentHostingView(rootView: AgendaView(store: store, controller: self))
        // The panel owns its size limits. A direct hosting contentView replaces
        // them with SwiftUI's smaller minimum whenever the layout changes.
        content.sizingOptions = []
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        panel.contentView = container
        if let saved = UserDefaults.standard.string(forKey: modeFrameKey(panelCompact)) ?? UserDefaults.standard.string(forKey: frameKey) {
            panel.setFrame(AgendaPanelGeometry.normalized(NSRectFromString(saved), compact: panelCompact), display: false)
        }
        else if let screen = NSScreen.main { let area = screen.visibleFrame; panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 22, y: area.maxY - size.height - 28)) }
        applyWindowMode(); resizePanel(); ensureVisible(); panel.orderFrontRegardless()
    }
    private func createMenu() {
        let root = NSMenu()
        let appItem = NSMenuItem(); root.addItem(appItem)
        let appMenu = NSMenu(title: "朝夕"); appItem.submenu = appMenu
        let quit = NSMenuItem(title: "退出朝夕", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; appMenu.addItem(quit)
        let fileItem = NSMenuItem(); root.addItem(fileItem)
        let fileMenu = NSMenu(title: "日程"); fileItem.submenu = fileMenu
        for (title, action, key) in [("添加待办", #selector(newItem), "n"), ("展开日程", #selector(expand), ""), ("隐藏浮窗", #selector(hidePanel), "w")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; fileMenu.addItem(item)
        }
        let editItem = NSMenuItem(); root.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        let undo = NSMenuItem(title: "撤销", action: #selector(undoAction), keyEquivalent: "z"); undo.target = self; edit.addItem(undo); edit.addItem(.separator())
        for (title, selector, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key)) }
        NSApp.mainMenu = root
    }
    func minimizeToMenu() { hidePanel() }
    @objc private func hidePanel() { panel.orderOut(nil); NSApp.hide(nil); writeRuntimeEvidence() }
    @objc private func undoAction() { if let text = panel.firstResponder as? NSTextView { text.undoManager?.undo() } else { store.undo() } }
    func resizePanel() {
        guard panel != nil else { return }
        let compact = store.settings.compact
        if compact != panelCompact {
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: modeFrameKey(panelCompact))
            changingPanelMode = true
            panelCompact = compact
            panel.minSize = NSSize(width: 320, height: compact ? 82 : 520)
            panel.maxSize = NSSize(width: 10000, height: compact ? 82 : 10000)
            let old = panel.frame
            let saved = UserDefaults.standard.string(forKey: modeFrameKey(compact)).map(NSRectFromString)
            let target = saved ?? NSRect(x: old.minX, y: old.maxY - (compact ? 82 : 850), width: old.width, height: compact ? 82 : 850)
            panel.setFrame(AgendaPanelGeometry.normalized(target, compact: compact), display: true)
            changingPanelMode = false
        } else {
            panel.minSize = NSSize(width: 320, height: compact ? 82 : 520)
            panel.maxSize = NSSize(width: 10000, height: compact ? 82 : 10000)
        }
        ensureVisible(); savePanelFrame()
    }
    private func applyAppearance() {
        let name: NSAppearance.Name?
        switch store.settings.appearanceMode {
        case .light: name = .aqua
        case .dark: name = .darkAqua
        case .system: name = nil
        }
        // App-scoped appearance also updates native controls in existing sheets.
        // A nil override inherits macOS; no system preference is changed.
        if NSApp.appearance?.name != name { NSApp.appearance = name.flatMap { NSAppearance(named: $0) } }
    }
    func applyWindowMode() { guard panel != nil else { return }; panel.level = store.settings.floating ? .floating : .normal; writeRuntimeEvidence() }
    private func ensureVisible() {
        guard panel != nil, let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) }) ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var frame = panel.frame
        frame.size.width = min(frame.width, bounds.width)
        frame.size.height = min(frame.height, bounds.height)
        frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
    private func savePanelFrame() {
        guard panel != nil, !changingPanelMode else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: modeFrameKey(panelCompact))
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameKey)
        writeRuntimeEvidence()
    }
    func windowDidMove(_ notification: Notification) { savePanelFrame() }
    func windowDidResize(_ notification: Notification) { savePanelFrame() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hidePanel(); return false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
    func showPanel() { NSApp.unhideWithoutActivation(); ensureVisible(); panel.orderFrontRegardless(); writeRuntimeEvidence() }
    func focusTextEntry() { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) }
    @objc private func showRequested() { showPanel() }
    @objc private func processCaptures() {
        captureInbox.processPending { store.capture($0) }
        writeRuntimeEvidence()
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { showPanel() }
    }
    private func showMenu() {
        let menu = NSMenu()
        for (title, selector) in [("展开日程", #selector(expand)), ("收起为小窗", #selector(compactPanel)), ("添加待办", #selector(newItem)), ("显示 / 隐藏浮窗", #selector(toggleVisible))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出朝夕", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
    }
    @objc private func compactPanel() { store.settings.compact = true; _ = store.save(); resizePanel(); showPanel() }
    @objc private func expand() { store.settings.compact = false; _ = store.save(); resizePanel(); showPanel() }
    @objc private func toggleVisible() { if panel.isVisible { hidePanel() } else { showPanel() } }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func newItem() { beginChecklistCapture() }
    func beginChecklistCapture() {
        var draft = AgendaItem(title: "", date: AgendaClock.startOfDay(Date()))
        draft.checklistState = .pending; draft.reminderEnabled = false
        showCapture(item: draft, source: nil)
    }
    func expandForInput() { if store.settings.compact { store.settings.compact = false; _ = store.save(); resizePanel() } }
    func takeCaptureDrafts() -> [AgendaCaptureDraft] { captureReceiver.takeDrafts() }
    private func showCapture(item: AgendaItem, source: String?) {
        captureReceiver.enqueue(item: item, source: source, originatedCompact: store.settings.compact)
        presentCaptureRequests()
    }
    private func presentCaptureRequests() {
        expandForInput(); showPanel(); panel.makeKey(); NSApp.activate(ignoringOtherApps: true); captureToken = UUID()
    }
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        receiveURLs([url])
    }
    func application(_ application: NSApplication, open urls: [URL]) { receiveURLs(urls) }
    private func receiveURLs(_ urls: [URL]) {
        let reception = captureReceiver.receiveURLs(urls, isReady: panel != nil, day: AgendaClock.startOfDay(Date()), originatedCompact: store.settings.compact)
        applyCaptureReception(reception)
    }
    private func applyCaptureReception(_ reception: AgendaCaptureReception) {
        if reception.hasInvalidCapture { store.error = "这条待办链接的时间或内容无效，未创建任何安排。" }
        if reception.captureCount > 0 { presentCaptureRequests() }
        else if reception.shouldReveal || reception.hasInvalidCapture { showPanel() }
    }
    func addTemplate(on day: Date) {
        let existing = Set(store.occurrences(on: day).map(\.title))
        for var item in AgendaClock.seed() where !existing.contains(item.title) { item.id = UUID(); item.date = AgendaClock.startOfDay(day); item.isTentative = true; item.reminderEnabled = false; _ = store.upsert(item) }
    }
    private func syncReminders(force: Bool = false) { notifications.sync(items: store.items, settings: store.settings, force: force) }
    private func refreshTick() {
        processCaptures()
        feishuSync.tick()
        let day = AgendaClock.dayKey(Date())
        if day != lastDay {
            lastDay = day
            let browsingDay = AgendaEditorNavigation.dayAfterMidnight(browsingDay: store.selectedDay, now: Date(), wasViewingToday: selectedToday)
            if store.selectedDay != browsingDay { store.selectedDay = browsingDay }
            syncReminders(force: true)
        }
        refreshStatus(); syncReminders(); writeRuntimeEvidence()
    }
    private func refreshStatus() {
        guard statusItem != nil else { return }
        let next = AgendaClock.next(items: store.items, now: Date())
        let text = next.flatMap { o in o.due.map { "\(String(o.title.prefix(5))) · \(AgendaClock.timeText($0))" } } ?? "朝夕"
        statusItem.button?.title = "朝夕"
        statusItem.button?.font = .systemFont(ofSize: 11, weight: .medium)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.horizon", accessibilityDescription: "朝夕日程"); statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "朝夕 · \(text) · 点击找回日程，右键更多操作"
    }
    @objc private func woke() { notifications.refreshPermission(); syncReminders(force: true); refreshTick(); ensureVisible() }
    @objc private func becameActive() { notifications.refreshPermission(); refreshLogin() }
    @objc private func screenChanged() { resizePanel(); ensureVisible() }
    private func notificationAction(oid: String, action: String, plannedDue: Double?) {
        guard let o = AgendaClock.occurrence(items: store.items, id: oid) else { showPanel(); return }
        guard ReminderPlanner.deliveredIsCurrent(occurrenceID: oid, plannedDue: plannedDue, items: store.items, settings: store.settings) else {
            store.selectedDay = o.displayDay; showPanel(); return
        }
        if action == "done" { if !o.isCompleted { store.toggle(o) } }
        else if action == "snooze" { store.snooze(o, minutes: 10) }
        else { store.selectedDay = o.displayDay; showPanel() }
    }
    func refreshLogin() {
        if qa { loginText = "隔离验证模式，不修改登录项"; return }
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        loginText = status == .requiresApproval ? "登录项等待系统允许，可在系统设置中开启。" : loginEnabled ? "已登记，登录后打开这台 Mac 上的朝夕。" : "当前未设为登录启动。"
    }
    func setLoginEnabled(_ enabled: Bool) {
        guard !qa else { return }
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; refreshLogin() }
        catch { refreshLogin(); loginText = "登录项设置失败：\(error.localizedDescription)" }
    }
    func exportData() {
        let save = NSSavePanel(); save.nameFieldStringValue = "朝夕日程-\(AgendaClock.dayKey(Date())).json"; save.allowedContentTypes = [.json]
        panel.makeKey(); NSApp.activate(ignoringOtherApps: true)
        save.begin { result in
            guard result == .OK, let target = save.url else { return }
            do { try Data(contentsOf: self.store.fileURL).write(to: target, options: .atomic) }
            catch { self.store.error = "导出失败：\(error.localizedDescription)" }
        }
    }
    func restoreData() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.json]; picker.allowsMultipleSelection = false; picker.message = "选择朝夕导出的日程备份。当前日程会先保留副本，再恢复所选备份。"
        panel.makeKey(); NSApp.activate(ignoringOtherApps: true)
        picker.begin { result in
            guard result == .OK, let source = picker.url else { return }
            if self.store.restore(from: source) { self.syncReminders(force: true); self.refreshStatus() }
        }
    }
    private func writeRuntimeEvidence() {
        guard panel != nil else { return }
        let surface = AgendaGlassSurface.first(in: panel.contentView)
        let evidence: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", "pid": ProcessInfo.processInfo.processIdentifier, "bundle": Bundle.main.bundleURL.path, "data": store.fileURL.path, "floating": store.settings.floating, "windowLevel": panel.level.rawValue, "opaque": panel.isOpaque, "visible": panel.isVisible, "applicationHidden": NSApp.isHidden, "frame": NSStringFromRect(panel.frame), "itemCount": store.items.count, "notificationAuthorized": notifications.authorized, "pendingCount": notifications.pendingCount, "loginEnabled": loginEnabled, "qa": qa, "compact": panelCompact, "glassStrength": glassStrength, "transparency": 1 - glassStrength, "glassEnabled": glassEnabled, "appearanceMode": store.settings.appearanceMode.rawValue, "effectiveAppearance": NSApp.effectiveAppearance.name.rawValue, "accentColor": store.settings.accentColor.rawValue, "resizable": panel.styleMask.contains(.resizable)]
        let materialEvidence: [String: Any] = ["glassRenderer": surface?.rendererName ?? "awaiting-layout", "materialAlpha": surface?.effectView.alphaValue ?? 0]
        if let data = try? JSONSerialization.data(withJSONObject: evidence.merging(materialEvidence) { _, native in native }, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: store.fileURL.deletingLastPathComponent().appendingPathComponent("runtime.json"), options: .atomic) }
    }
}

#if !INTEGRATION_TESTS
@main struct ChaoxiLauncher {
    @MainActor static func main() {
        let args = ProcessInfo.processInfo.arguments
        let productionRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chaoxi")
        if args.contains("--query") {
            exit(AgendaQueryCLI.run(arguments: Array(args.dropFirst()), productionRoot: productionRoot))
        }
        if args.contains("--help") {
            print("朝夕 · Mac 常驻日程\n正常使用请打开 朝夕.app。隔离验收：--qa --data-dir <绝对路径>。\n本机捕获：--capture [--dry-run] [--no-launch] [--qa --data-dir <绝对路径>]。\n通过 stdin 传 JSON：request_id、title；可选 note、date（YYYY-MM-DD）、time（HH:mm）、duration_minutes、source（hermes/cli）、repeat_rule（none/daily/weekdays）。无日期进入独立清单，含时刻必须给日期，重复安排须有日期和时刻。\n只读查询：--query [--qa --data-dir <绝对路径>]；stdin JSON 为 {} 或 {\"date\":\"YYYY-MM-DD\"}。默认查询北京时间今天，返回当天日程和全部清单，不启动窗口或修改数据。")
            return
        }
        if args.contains("--capture") {
            exit(CaptureCLI.run(arguments: Array(args.dropFirst()), bundleURL: Bundle.main.bundleURL, productionRoot: productionRoot))
        }
        let qa = args.contains("--qa")
        let dataIndex = args.firstIndex(of: "--data-dir")
        if qa && (dataIndex == nil || !args.indices.contains(dataIndex! + 1) || !args[dataIndex! + 1].hasPrefix("/")) {
            fputs("隔离验收必须指定 --qa --data-dir <绝对路径>，未启动应用。\n", stderr); exit(64)
        }
        if dataIndex != nil && !qa { fputs("自定义数据目录仅用于 --qa 隔离验收，未启动应用。\n", stderr); exit(64) }
        for (i, argument) in args.enumerated().dropFirst() {
            if argument != "--qa" && argument != "--data-dir" && i != (dataIndex ?? -2) + 1 { fputs("未知参数，使用 --help 查看支持的入口。未启动应用。\n", stderr); exit(64) }
        }
        var root = productionRoot
        if let i = args.firstIndex(of: "--data-dir"), args.indices.contains(i + 1) { root = URL(fileURLWithPath: args[i + 1]) }
        if qa && root.resolvingSymlinksInPath().standardizedFileURL == productionRoot.resolvingSymlinksInPath().standardizedFileURL { fputs("隔离验收不能使用正式数据目录，未启动应用。\n", stderr); exit(64) }
        if qa {
            do { try AgendaDataPathSafety.validateQA(root, productionRoot: productionRoot) }
            catch { fputs("隔离数据文件不能使用链接或不安全文件，未启动应用。\n", stderr); exit(64) }
        }
        let guiLease: AgendaGUILease
        do { guiLease = try AgendaGUILease() }
        catch AgendaGUILease.Failure.occupied {
            if !qa { DistributedNotificationCenter.default().postNotificationName(AgendaGUILease.revealNotification, object: nil, userInfo: nil, deliverImmediately: true) }
            fputs("朝夕已经在运行，未打开第二个窗口。\n", stderr)
            return
        } catch { fputs("无法取得朝夕窗口锁，未启动第二个窗口。\n", stderr); exit(74) }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { fputs("无法打开朝夕数据目录：\(error.localizedDescription)\n", stderr); return }
        let lock = Darwin.open(root.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { fputs("无法保护本机日程文件\n", stderr); return }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock)
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.djx.chaoxi.show"), object: root.path, userInfo: nil, deliverImmediately: true)
            return
        }
        defer { Darwin.close(lock) }
        let app = NSApplication.shared
        let delegate = AppController()
        app.delegate = delegate
        withExtendedLifetime((delegate, guiLease)) { app.run() }
    }
}
#endif
