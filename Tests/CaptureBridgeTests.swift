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

        // MARK: --change request parsing
        func parse(_ object: [String: Any]) throws -> AgendaChangeRequest { try AgendaChangeRequest.parse(JSONSerialization.data(withJSONObject: object)) }
        let itemID = UUID()
        let update: [String: Any] = ["request_id": "xlys-chg-1", "op": "update", "target": ["item_id": itemID.uuidString.lowercased()], "fields": ["time": "10:00", "date": "2026-11-10"]]
        let parsed = try parse(update)
        check(parsed.target.itemID == itemID && parsed.fields.time == .value(600) && parsed.fields.date == "2026-11-10" && parsed.source == "cli", "update parses with defaults")
        check(try parse(update).fingerprint == parsed.fingerprint, "fingerprint is stable")
        var otherFields = update; otherFields["fields"] = ["time": "11:00"]
        check(try parse(otherFields).fingerprint != parsed.fingerprint, "fingerprint covers fields")
        var renamed = update; renamed["request_id"] = "xlys-chg-2"
        check(try parse(renamed).fingerprint == parsed.fingerprint, "fingerprint excludes request_id")
        check(try parse(["request_id": "a", "op": "update", "target": ["item_id": itemID.uuidString], "fields": ["time": NSNull()]]).fields.time == .clear, "time null clears")
        let occurrence = itemID.uuidString + ":2026-11-12"
        check(try parse(["request_id": "a", "op": "reschedule_once", "target": ["occurrence_id": occurrence.lowercased()], "new_time": "09:00"]).target.occurrenceID == occurrence, "occurrence id is normalized")
        let rejected: [[String: Any]] = [
            ["op": "update", "target": ["item_id": itemID.uuidString], "fields": ["title": "x"]],
            ["request_id": "../x", "op": "delete", "target": ["item_id": itemID.uuidString]],
            ["request_id": "a", "op": "erase", "target": ["item_id": itemID.uuidString]],
            ["request_id": "a", "op": "delete", "target": ["item_id": itemID.uuidString, "capture_request_id": "b"]],
            ["request_id": "a", "op": "delete", "target": [:]],
            ["request_id": "a", "op": "delete", "target": ["item_id": "not-a-uuid"]],
            ["request_id": "a", "op": "delete", "target": ["item_id": itemID.uuidString], "extra": true],
            ["request_id": "a", "op": "update", "target": ["item_id": itemID.uuidString]],
            ["request_id": "a", "op": "update", "target": ["item_id": itemID.uuidString], "fields": ["color": "red"]],
            ["request_id": "a", "op": "update", "target": ["item_id": itemID.uuidString], "fields": ["duration_minutes": true]],
            ["request_id": "a", "op": "update", "target": ["item_id": itemID.uuidString], "fields": ["duration_minutes": 1441]],
            ["request_id": "a", "op": "update", "target": ["item_id": itemID.uuidString], "fields": ["duration_minutes": 1.5]],
            ["request_id": "a", "op": "update", "target": ["item_id": itemID.uuidString], "fields": ["tentative": 1]],
            ["request_id": "a", "op": "update", "target": ["item_id": itemID.uuidString], "fields": ["time": "24:00"]],
            ["request_id": "a", "op": "update", "target": ["item_id": itemID.uuidString], "fields": ["date": "2026-02-30"]],
            ["request_id": "a", "op": "update", "target": ["item_id": itemID.uuidString], "fields": ["title": "  "]],
            ["request_id": "a", "op": "update", "target": ["item_id": itemID.uuidString], "fields": ["repeat_rule": "monthly"]],
            ["request_id": "a", "op": "update", "target": ["item_id": itemID.uuidString], "fields": ["title": "x"], "occurrence_id": occurrence],
            ["request_id": "a", "op": "delete", "target": ["item_id": itemID.uuidString], "fields": ["title": "x"]],
            ["request_id": "a", "op": "reschedule_once", "target": ["item_id": itemID.uuidString], "occurrence_id": occurrence],
            ["request_id": "a", "op": "reschedule_once", "target": ["item_id": UUID().uuidString], "occurrence_id": occurrence, "new_time": "09:00"],
            ["request_id": "a", "op": "skip_once", "target": ["item_id": itemID.uuidString]],
            ["request_id": "a", "op": "pause_range", "target": ["item_id": itemID.uuidString], "from": "2026-11-10"],
            ["request_id": "a", "op": "pause_range", "target": ["item_id": itemID.uuidString], "from": "2026-11-22", "to": "2026-11-10"],
            ["request_id": "a", "op": "pause_range", "target": ["item_id": itemID.uuidString], "from": "2026-01-01", "to": "2027-01-02"],
            ["request_id": "a", "op": "resume", "target": ["item_id": itemID.uuidString], "from": "2026-11-10"],
            ["request_id": "a", "op": "delete", "target": ["item_id": itemID.uuidString], "source": "feishu"],
            ["request_id": "a", "op": "delete", "target": ["item_id": itemID.uuidString], "if_match": 5],
        ]
        for body in rejected {
            do { _ = try parse(body); preconditionFailure("invalid change accepted: \(body)") } catch { checks += 1 }
        }
        for body in ["[]", "null", "not json"] {
            do { _ = try AgendaChangeRequest.parse(Data(body.utf8)); preconditionFailure("non-object accepted") } catch { checks += 1 }
        }

        // MARK: --change transport
        let changeData = try JSONSerialization.data(withJSONObject: update)
        func invokeChange(_ root: URL, data: Data? = nil, extra: [String] = ["--no-launch"], running: Bool = true,
                          consumer: ((URL) -> Void)? = nil, preview: ((AgendaChangeRequest, URL) throws -> Data)? = nil) -> (Int32, [String: Any], Data) {
            var tick: TimeInterval = 0, output = Data()
            var env = CaptureCLIEnvironment(
                readInput: { inputReads += 1; return data ?? changeData }, output: { output = $0 },
                isRunning: { _ in lockChecks += 1; return running },
                launch: { b, qa, r in launches += 1; launchQA = qa; launchRoot = r; launchBundle = b },
                notify: { r in notices += 1; consumer?(r) }, clock: { tick }, pause: { tick += 0.01 }, timeout: 0.03)
            env.previewChange = preview
            let code = CaptureCLI.runChange(arguments: ["--change", "--qa", "--data-dir", root.path] + extra, bundleURL: bundle, productionRoot: production, environment: env)
            return (code, (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] ?? [:], output)
        }
        func changeHandler(_ status: String, ok: Bool = true, saved: Bool = true, padding: Int = 0) -> (AgendaChangeRequest) -> AgendaChangeResult {
            { body in
                var item = AgendaItem(title: "交材料", date: Date(timeIntervalSince1970: 1_800_000_000), timeMinutes: 600)
                item.id = body.target.itemID ?? UUID()
                item.note = String(repeating: "备", count: padding)
                let view = AgendaItemView(item: item, origin: AgendaItemOrigin(source: "cli", captureRequestID: nil))
                return AgendaChangeResult(ok: ok, status: status, requestID: body.requestID, itemID: item.id, itemExists: true, saved: saved, before: view, after: view)
            }
        }
        func consumeChange(_ root: URL, _ handler: @escaping (AgendaChangeRequest) -> AgendaChangeResult) {
            MainActor.assumeIsolated { CaptureInbox(root: root).processPending(handler: { _ in preconditionFailure("change routed to capture") }, changeHandler: handler) }
        }
        let changed = path("change-ok")
        let ok = invokeChange(changed, consumer: { consumeChange($0, changeHandler("updated")) })
        check(ok.0 == 0 && ok.1["status"] as? String == "updated" && ok.1["saved"] as? Bool == true && ok.1["request_id"] as? String == "xlys-chg-1", "change reply is forwarded")
        check(ok.1["before"] is [String: Any] && ok.1["after"] is [String: Any], "receipt keeps before/after")
        check(names(changed, suffix: ".change.json").isEmpty && names(changed, suffix: ".reply.json").isEmpty, "change request and reply consumed")
        let big = invokeChange(path("change-big"), consumer: { consumeChange($0, changeHandler("updated", padding: 4000)) })
        check(big.0 == 0 && big.2.count > 16 * 1024, "replies with full snapshots above 16 KiB are delivered")
        for status in ["conflict", "not_found", "forbidden", "invalid"] {
            let failed = invokeChange(path("change-" + status), consumer: { consumeChange($0, changeHandler(status, ok: false, saved: false)) })
            check(failed.0 == 1 && failed.1["status"] as? String == status && failed.1["ok"] as? Bool == false, "\(status) is not success")
        }
        let unsaved = invokeChange(path("change-unsaved"), consumer: { consumeChange($0, changeHandler("updated", saved: false)) })
        check(unsaved.0 == 2 && unsaved.1["status"] as? String == "pending", "ok reply without saved is not reliable")
        let legacy = path("change-legacy")
        let waiting = invokeChange(legacy, consumer: { r in MainActor.assumeIsolated { CaptureInbox(root: r).processPending(handler: { _ in preconditionFailure("old consumer misread change") }) } })
        check(waiting.0 == 2 && waiting.1["status"] as? String == "pending" && waiting.1["saved"] as? Bool == false && names(legacy, suffix: ".change.json").count == 1, "a consumer without change support leaves the request pending")
        check(names(legacy, suffix: ".request.json").isEmpty, "change never uses the capture suffix")
        let changeFile = queue(legacy).appendingPathComponent(names(legacy, suffix: ".change.json")[0])
        check((try fm.attributesOfItem(atPath: changeFile.path)[.posixPermissions] as! NSNumber).intValue == 0o600, "queued change file is private")
        let hostileChange = path("change-hostile")
        try fm.createDirectory(at: queue(hostileChange), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let hostileAttempt = UUID().uuidString
        try privateWrite(Data("{\"op\":\"delete\"}".utf8), queue(hostileChange).appendingPathComponent(hostileAttempt + ".change.json"))
        var changeCalls = 0
        consumeChange(hostileChange, { body in changeCalls += 1; return changeHandler("deleted")(body) })
        let hostileReply = try JSONSerialization.jsonObject(with: Data(contentsOf: queue(hostileChange).appendingPathComponent(hostileAttempt + ".reply.json"))) as! [String: Any]
        check(changeCalls == 0 && hostileReply["status"] as? String == "invalid" && hostileReply["ok"] as? Bool == false, "consumer re-validates queued change before the Store")

        let launchesBefore = launches
        let startedChange = invokeChange(path("change-started"), extra: [], running: false, consumer: { consumeChange($0, changeHandler("deleted")) })
        check(startedChange.0 == 0 && launches == launchesBefore + 1 && launchQA == true && launchRoot == path("change-started"), "stopped QA consumer is launched with the isolated root")

        let dryRoot = path("change-dry")
        var previewed: URL?
        let dryChange = invokeChange(dryRoot, extra: ["--dry-run"], preview: { request, root in
            previewed = root
            return try JSONSerialization.data(withJSONObject: ["ok": true, "status": "preview", "expected_status": "updated", "saved": false, "dry_run": true, "request_id": request.requestID])
        })
        check(dryChange.0 == 0 && dryChange.1["status"] as? String == "preview" && previewed == dryRoot && !fm.fileExists(atPath: dryRoot.path), "dry-run reads through the preview only and creates no queue")
        let noticesBefore = notices
        check(invokeChange(production, extra: ["--dry-run"], preview: { _, _ in preconditionFailure("production preview in QA") }).0 == 1 && notices == noticesBefore, "QA change cannot target production")
        check(invokeChange(path("change-bad"), data: Data("{\"request_id\":\"a\",\"op\":\"update\"}".utf8)).0 == 1 && !fm.fileExists(atPath: path("change-bad").path), "invalid change is rejected before the queue")
        for flags in [["--change", "--capture"], ["--change", "--change"], ["--change", "--query"]] {
            do { _ = try CaptureCLIOptions.parse(flags, productionRoot: production, command: "--change"); preconditionFailure("mixed flags accepted") } catch { checks += 1 }
        }
        print("PASS: \(checks) capture bridge checks; fake launch/notification only; isolated temporary files and locks")
    }
}
