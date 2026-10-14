import Foundation
import Darwin

@main struct CaptureBridgeTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("chaoxi-capture-bridge-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: base) }
        let production = base.appendingPathComponent("production", isDirectory: true)
        let bundle = base.appendingPathComponent("Current.app", isDirectory: true)
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func path(_ name: String) -> URL { base.appendingPathComponent(name, isDirectory: true) }
        func queue(_ root: URL) -> URL { root.appendingPathComponent("CaptureInbox", isDirectory: true) }
        func names(_ root: URL, suffix: String) -> [String] { (try? fm.contentsOfDirectory(atPath: queue(root).path))?.filter { $0.hasSuffix(suffix) } ?? [] }
        func privateWrite(_ data: Data, _ url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let request = AgendaCaptureRequest(requestID: "wx-test:1", title: "检查本机捕获", source: "hermes")
        let requestData = try JSONEncoder().encode(request)
        var notices = 0, launches = 0, lockChecks = 0, inputReads = 0
        var launchQA: Bool?, launchRoot: URL?, launchBundle: URL?
        // Every CLI invocation below supplies these fake effects before executing.
        // No test invokes the production open/DistributedNotificationCenter implementation.
        func invoke(_ root: URL, data: Data = requestData, extra: [String] = ["--no-launch"], running: Bool = true,
                    consumer: ((URL) -> Void)? = nil, launchFails: Bool = false) -> (Int32, [String: Any]) {
            var tick: TimeInterval = 0, output = Data()
            let env = CaptureCLIEnvironment(
                readInput: { inputReads += 1; return data }, output: { output = $0 },
                isRunning: { _ in lockChecks += 1; return running },
                launch: { b, qa, r in
                    launches += 1; launchQA = qa; launchRoot = r; launchBundle = b
                    if launchFails { throw CocoaError(.fileWriteUnknown) }
                },
                notify: { r in notices += 1; consumer?(r) }, clock: { tick }, pause: { tick += 0.01 }, timeout: 0.03
            )
            let code = CaptureCLI.run(arguments: ["--capture", "--qa", "--data-dir", root.path] + extra, bundleURL: bundle, productionRoot: production, environment: env)
            return (code, (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] ?? [:])
        }
        func handler(_ body: AgendaCaptureRequest) -> AgendaCaptureResult {
            AgendaCaptureResult(ok: true, requestID: body.requestID, status: "created", itemID: UUID(), itemExists: true)
        }
        func consume(_ root: URL, using handler: @escaping (AgendaCaptureRequest) -> AgendaCaptureResult) {
            MainActor.assumeIsolated { CaptureInbox(root: root).processPending(handler: handler) }
        }

        let dry = path("dry")
        for unsafe in [production, production.appendingPathComponent("child")] {
            do { try AgendaDataPathSafety.validateQA(unsafe, productionRoot: production); preconditionFailure("GUI QA production subtree accepted") }
            catch { check(!fm.fileExists(atPath: unsafe.path), "shared GUI/CLI preflight rejects production subtree before writes") }
        }
        let dryResult = invoke(dry, extra: ["--dry-run"])
        check(dryResult.0 == 0 && dryResult.1["status"] as? String == "preview", "dry-run previews")
        check(dryResult.1["request_id"] as? String == request.requestID && dryResult.1["type"] as? String == "checklist", "preview has normalized request ID and readable type")
        check(!fm.fileExists(atPath: dry.path) && notices == 0 && launches == 0 && lockChecks == 0, "dry-run has no filesystem, notification, launch or lock effects")
        let timed = try JSONEncoder().encode(AgendaCaptureRequest(requestID: "timed", title: "开会", date: "2026-10-12", time: "14:30"))
        let timedResult = invoke(dry, data: timed, extra: ["--dry-run"])
        check(timedResult.1["type"] as? String == "scheduled" && timedResult.1["time"] as? String == "14:30", "scheduled preview retains explicit time")

        let success = path("success")
        let successResult = invoke(success, consumer: { consume($0, using: handler) })
        check(successResult.0 == 0 && successResult.1["status"] as? String == "created", "file delivery receives committed reply")
        check(successResult.1["request_id"] as? String == request.requestID && successResult.1["item_id"] != nil, "reply retains Store identity")
        check(names(success, suffix: ".request.json").isEmpty && names(success, suffix: ".reply.json").isEmpty, "processed request and acknowledged reply are consumed")
        let mode = (try fm.attributesOfItem(atPath: queue(success).path)[.posixPermissions] as! NSNumber).intValue
        check(mode == 0o700, "queue directory is private")

        for status in ["invalid", "conflict", "save_failed"] {
            let failed = invoke(path(status), consumer: { r in consume(r, using: { body in AgendaCaptureResult(ok: false, requestID: body.requestID, status: status, error: "测试拒绝") }) })
            check(failed.0 != 0 && failed.1["status"] as? String == status, "\(status) never reports success")
        }
        let idempotent = invoke(path("already"), consumer: { r in consume(r, using: { body in AgendaCaptureResult(ok: true, requestID: body.requestID, status: "already_processed", itemID: UUID(), itemExists: false) }) })
        check(idempotent.0 == 0 && idempotent.1["item_exists"] as? Bool == false, "reliable deleted-item receipt remains idempotent without resurrecting")
        let falseSuccess = invoke(path("false-success"), consumer: { r in consume(r, using: { body in AgendaCaptureResult(ok: true, requestID: body.requestID, status: "created") }) })
        check(falseSuccess.0 != 0 && falseSuccess.1["status"] as? String == "pending", "missing persisted item identity is not a reliable success")

        let pending = path("pending")
        let first = invoke(pending, running: false)
        check(first.0 == 2 && first.1["status"] as? String == "pending" && first.1["request_id"] as? String == request.requestID, "no consumer returns pending with reusable request ID")
        let firstName = names(pending, suffix: ".request.json").first!
        check(UUID(uuidString: String(firstName.dropLast(".request.json".count))) != nil && !firstName.contains(request.requestID), "filename uses attempt UUID, never message ID")
        check((try fm.attributesOfItem(atPath: queue(pending).appendingPathComponent(firstName).path)[.posixPermissions] as! NSNumber).intValue == 0o600, "submitted request file is private")
        let firstReply = queue(pending).appendingPathComponent(String(firstName.dropLast(".request.json".count)) + ".reply.json")
        try privateWrite(JSONEncoder().encode(handler(request)), firstReply)
        let second = invoke(pending)
        check(second.0 == 2 && names(pending, suffix: ".request.json").count == 2, "same request ID uses a new attempt and cannot read a stale acknowledgment")
        check(fm.fileExists(atPath: firstReply.path), "second attempt leaves unrelated reply untouched")
        check(launches == 0, "--no-launch never starts an application, even if stopped")

        let started = invoke(path("started"), extra: [], running: false, consumer: { consume($0, using: handler) })
        check(started.0 == 0 && launches == 1 && launchQA == true && launchRoot == path("started") && launchBundle == bundle, "QA launcher receives only the current bundle and exact isolated root")
        let existing = invoke(path("existing"), extra: [], running: true, consumer: { consume($0, using: handler) })
        check(existing.0 == 0 && launches == 1, "running app is signaled without launching or stealing focus")
        let launchFailure = invoke(path("launch-failure"), extra: [], running: false, launchFails: true)
        check(launchFailure.0 == 2 && names(path("launch-failure"), suffix: ".request.json").count == 1, "launcher failure leaves queued request pending")

        let beforeReads = inputReads
        let forbidden = invoke(production, extra: ["--dry-run"])
        check(forbidden.0 != 0 && inputReads == beforeReads && !fm.fileExists(atPath: production.path), "QA production root is rejected before reading or writing")
        let productionLink = path("production-link")
        try fm.createSymbolicLink(at: productionLink, withDestinationURL: production)
        check(invoke(productionLink, extra: ["--dry-run"]).0 != 0, "QA symlink to production is rejected")
        let invalidFlags: [[String]] = [[], ["--capture", "--capture"], ["--capture", "--unknown"], ["--capture", "--data-dir"], ["--capture", "--data-dir", "/tmp/x"], ["--capture", "--qa"], ["--capture", "--qa", "--data-dir", "relative"], ["--capture", "--dry-run", "--dry-run"], ["--capture", "--qa", "--data-dir", production.appendingPathComponent("child").path]]
        for flags in invalidFlags {
            do { _ = try CaptureCLIOptions.parse(flags, productionRoot: production); check(false, "invalid flags accepted") }
            catch { checks += 1 }
        }
        let prodOptions = try CaptureCLIOptions.parse(["--capture", "--no-launch"], productionRoot: production)
        check(prodOptions.root == production && !prodOptions.qa, "production root is fixed by the launcher")

        let hostile = try JSONEncoder().encode(AgendaCaptureRequest(requestID: "../escape", title: "无效路径"))
        check(invoke(path("hostile-id"), data: hostile).0 != 0 && !fm.fileExists(atPath: path("hostile-id").path), "external path-like ID is rejected before queue creation")
        check(invoke(path("oversized"), data: Data(repeating: 32, count: 16 * 1024 + 1)).0 != 0 && !fm.fileExists(atPath: path("oversized").path), "oversized input has no queue effects")
        var atLimit = requestData; atLimit.append(Data(repeating: 32, count: 16 * 1024 - requestData.count))
        check(invoke(path("limit"), data: atLimit, extra: ["--dry-run"]).0 == 0, "exact 16 KiB input is accepted")
        check(invoke(path("bad-json"), data: Data("not json".utf8)).0 != 0, "malformed JSON is rejected")

        let outside = path("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sentinel = outside.appendingPathComponent("sentinel")
        try privateWrite(Data("unchanged".utf8), sentinel)
        let unsafe = path("unsafe")
        try fm.createDirectory(at: unsafe, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createSymbolicLink(at: queue(unsafe), withDestinationURL: outside)
        let unsafeResult = invoke(unsafe)
        let sentinelAfterUnsafe = try Data(contentsOf: sentinel)
        check(unsafeResult.0 != 0 && sentinelAfterUnsafe == Data("unchanged".utf8), "queue symlink is rejected without touching its target")
        let rootLink = path("root-link")
        try fm.createSymbolicLink(at: rootLink, withDestinationURL: outside)
        check(invoke(rootLink).0 != 0, "root symlink is rejected")

        let badFile = path("bad-file")
        let badAttempt = UUID().uuidString
        try fm.createDirectory(at: queue(badFile), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createSymbolicLink(at: queue(badFile).appendingPathComponent(badAttempt + ".request.json"), withDestinationURL: sentinel)
        var consumed = 0
        consume(badFile, using: { body in consumed += 1; return handler(body) })
        let invalidReply = try JSONDecoder().decode(AgendaCaptureResult.self, from: Data(contentsOf: queue(badFile).appendingPathComponent(badAttempt + ".reply.json")))
        check(consumed == 0 && !invalidReply.ok && invalidReply.status == "invalid", "symlink request is refused before the Store handler")
        check(try Data(contentsOf: sentinel) == Data("unchanged".utf8), "request symlink target is untouched")
        let largeAttempt = UUID().uuidString
        try privateWrite(Data(repeating: 32, count: 16 * 1024 + 1), queue(badFile).appendingPathComponent(largeAttempt + ".request.json"))
        consume(badFile, using: { body in consumed += 1; return handler(body) })
        check(consumed == 0 && !names(badFile, suffix: ".request.json").contains(largeAttempt + ".request.json"), "oversized queued file is rejected and consumed after an error reply")
        let directoryAttempt = UUID().uuidString
        try fm.createDirectory(at: queue(badFile).appendingPathComponent(directoryAttempt + ".request.json"), withIntermediateDirectories: false)
        consume(badFile, using: { body in consumed += 1; return handler(body) })
        check(consumed == 0 && !names(badFile, suffix: ".request.json").contains(directoryAttempt + ".request.json"), "nonregular request is rejected and an empty request directory is safely consumed")

        let ackFailure = path("ack-failure")
        let ackAttempt = UUID().uuidString
        let queuedRequest = queue(ackFailure).appendingPathComponent(ackAttempt + ".request.json")
        let queuedReply = queue(ackFailure).appendingPathComponent(ackAttempt + ".reply.json")
        try privateWrite(requestData, queuedRequest)
        try fm.createSymbolicLink(at: queuedReply, withDestinationURL: sentinel)
        var committed = false, replayed = false
        let retainedID = UUID()
        consume(ackFailure, using: { body in
            committed = true
            return AgendaCaptureResult(ok: true, requestID: body.requestID, status: "created", itemID: retainedID, itemExists: true)
        })
        check(committed && fm.fileExists(atPath: queuedRequest.path), "commit happens before failed acknowledgment and request is retained")
        check(try Data(contentsOf: sentinel) == Data("unchanged".utf8), "reply symlink target remains untouched")
        try fm.removeItem(at: queuedReply)
        consume(ackFailure, using: { body in
            replayed = true
            return AgendaCaptureResult(ok: true, requestID: body.requestID, status: "already_processed", itemID: retainedID, itemExists: true)
        })
        let replayReply = try JSONDecoder().decode(AgendaCaptureResult.self, from: Data(contentsOf: queuedReply))
        check(replayed && replayReply.itemID == retainedID && !fm.fileExists(atPath: queuedRequest.path), "replay publishes the idempotent Store receipt and consumes the request")
        check((try fm.attributesOfItem(atPath: queuedReply.path)[.posixPermissions] as! NSNumber).intValue == 0o600, "persisted reply file is private")

        for file in ["agenda.json", "app.lock"] {
            let linkedRoot = path("linked-" + file)
            try fm.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: linkedRoot.appendingPathComponent(file), withDestinationURL: sentinel)
            let counts = (notices, launches, inputReads)
            check(invoke(linkedRoot).0 != 0, "QA child symlink rejected: \(file)")
            check(counts.0 == notices && counts.1 == launches && counts.2 == inputReads && !fm.fileExists(atPath: queue(linkedRoot).path), "QA child link rejected before any effect")
            check(try Data(contentsOf: sentinel) == Data("unchanged".utf8), "QA linked target preserved")
        }
        let hardRoot = path("hard-linked-agenda")
        try fm.createDirectory(at: hardRoot, withIntermediateDirectories: true)
        try fm.linkItem(at: sentinel, to: hardRoot.appendingPathComponent("agenda.json"))
        check(invoke(hardRoot).0 != 0, "QA hard-linked agenda rejected")

        let lockRoot = path("lock")
        try privateWrite(Data(), lockRoot.appendingPathComponent("app.lock"))
        check(try !CaptureCLI.applicationIsRunning(root: lockRoot), "unheld app lock means stopped")
        let lockFD = Darwin.open(lockRoot.appendingPathComponent("app.lock").path, O_RDWR)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { preconditionFailure("test cannot hold isolated lock") }
        check(try CaptureCLI.applicationIsRunning(root: lockRoot), "held app lock means running")
        flock(lockFD, LOCK_UN); Darwin.close(lockFD)
        check(CaptureInbox.notificationObject(for: base.appendingPathComponent("dry/../success")) == success.resolvingSymlinksInPath().path, "notification object normalizes the directory")
        print("PASS: \(checks) capture bridge checks; fake launch/notification only; isolated temporary files and locks")
    }
}
