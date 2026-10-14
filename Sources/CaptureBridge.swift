import Foundation
import Darwin

private enum CaptureTransportError: LocalizedError {
    case unsafePath, oversized, io(String), invalidArguments(String)
    var errorDescription: String? {
        switch self {
        case .unsafePath: return "捕获目录或文件不安全，未操作日程。"
        case .oversized: return "捕获请求超过 16 KiB。"
        case .io(let detail): return "捕获文件操作失败：\(detail)"
        case .invalidArguments(let detail): return detail
        }
    }
}

// All request/reply names are generated attempt UUIDs, never external request IDs.
private final class CaptureDirectory {
    static let maximumBytes = 16 * 1024
    let fd: Int32
    init(root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw CaptureTransportError.unsafePath }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw CaptureTransportError.unsafePath }
        defer { Darwin.close(rootFD) }
        try Self.secureDirectory(rootFD)
        if mkdirat(rootFD, "CaptureInbox", 0o700) != 0 && errno != EEXIST { throw CaptureTransportError.io("无法创建队列") }
        fd = openat(rootFD, "CaptureInbox", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw CaptureTransportError.unsafePath }
        do { try Self.secureDirectory(fd) }
        catch { Darwin.close(fd); throw error }
    }
    deinit { Darwin.close(fd) }

    private static func secureDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), fchmod(fd, 0o700) == 0 else { throw CaptureTransportError.unsafePath }
    }
    func names() throws -> [String] {
        guard let directory = fdopendir(dup(fd)) else { throw CaptureTransportError.io("无法读取队列") }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }
    func read(_ name: String) throws -> Data? {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if file < 0 {
            if errno == ENOENT { return nil }
            throw CaptureTransportError.unsafePath
        }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { throw CaptureTransportError.unsafePath }
        guard info.st_size >= 0 && info.st_size <= Self.maximumBytes else { throw CaptureTransportError.oversized }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw CaptureTransportError.io("无法读取文件") }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= Self.maximumBytes else { throw CaptureTransportError.oversized }
        }
        return data
    }
    func write(_ data: Data, name: String) throws {
        guard data.count <= Self.maximumBytes else { throw CaptureTransportError.oversized }
        var target = stat()
        if fstatat(fd, name, &target, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (target.st_mode & S_IFMT) == S_IFREG, target.st_uid == getuid() else { throw CaptureTransportError.unsafePath }
        } else if errno != ENOENT { throw CaptureTransportError.io("无法核对目标") }
        let temporary = UUID().uuidString + ".tmp"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw CaptureTransportError.io("无法创建文件") }
        defer { Darwin.close(file); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw CaptureTransportError.io("无法写入文件") }
                guard count > 0 else { throw CaptureTransportError.io("文件写入未完成") }
                offset += count
            }
        }
        guard fsync(file) == 0, renameat(fd, temporary, fd, name) == 0, fsync(fd) == 0 else { throw CaptureTransportError.io("无法原子保存文件") }
    }
    func remove(_ name: String) throws {
        if unlinkat(fd, name, 0) == 0 || errno == ENOENT { return }
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFDIR, unlinkat(fd, name, AT_REMOVEDIR) == 0 { return }
        throw CaptureTransportError.io("无法清理已处理请求")
    }
}

final class CaptureInbox {
    static let notificationName = Notification.Name("com.djx.chaoxi.capture")
    private let root: URL
    init(root: URL) { self.root = root }
    static func notificationObject(for root: URL) -> String { root.standardizedFileURL.resolvingSymlinksInPath().path }

    @MainActor func processPending(handler: (AgendaCaptureRequest) -> AgendaCaptureResult) {
        do {
            let directory = try CaptureDirectory(root: root)
            for name in try directory.names() where name.hasSuffix(".request.json") {
                let attempt = String(name.dropLast(".request.json".count))
                guard UUID(uuidString: attempt) != nil else { continue }
                let result: AgendaCaptureResult
                do {
                    guard let data = try directory.read(name) else { continue }
                    let request = try JSONDecoder().decode(AgendaCaptureRequest.self, from: data).normalized()
                    let handled = handler(request)
                    result = handled.requestID == request.requestID ? handled : AgendaCaptureResult(ok: false, requestID: request.requestID, status: "save_failed", error: "保存回执的请求编号不匹配。")
                } catch {
                    result = AgendaCaptureResult(ok: false, status: "invalid", error: error.localizedDescription)
                }
                do {
                    // Store handler has returned before publishing an acknowledgment.
                    try directory.write(JSONEncoder().encode(result), name: attempt + ".reply.json")
                    try directory.remove(name)
                } catch {
                    // Keep the request for a later replay if the acknowledgment cannot be saved.
                    continue
                }
            }
        } catch {
            // A failed or unsafe queue cannot imply that any request was saved.
        }
    }
}

enum AgendaDataPathSafety {
    static func validateQA(_ root: URL, productionRoot: URL) throws {
        var rootInfo = stat()
        if lstat(root.path, &rootInfo) == 0 && (rootInfo.st_mode & S_IFMT) == S_IFLNK { throw CaptureTransportError.unsafePath }
        let resolved = CaptureInbox.notificationObject(for: root)
        let production = CaptureInbox.notificationObject(for: productionRoot)
        guard resolved != production, !resolved.hasPrefix(production + "/") else { throw CaptureTransportError.unsafePath }
        for name in ["agenda.json", "app.lock"] {
            var info = stat()
            let path = root.appendingPathComponent(name).path
            if lstat(path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
                    throw CaptureTransportError.unsafePath
                }
            } else if errno != ENOENT { throw CaptureTransportError.unsafePath }
        }
    }
}

struct CaptureCLIOptions {
    let dryRun: Bool
    let noLaunch: Bool
    let qa: Bool
    let root: URL
    static func parse(_ arguments: [String], productionRoot: URL) throws -> Self {
        var seen = Set<String>(), index = 0, dataPath: String?
        while index < arguments.count {
            let argument = arguments[index]
            guard ["--capture", "--dry-run", "--no-launch", "--qa", "--data-dir"].contains(argument), seen.insert(argument).inserted else { throw CaptureTransportError.invalidArguments("未知或重复的捕获参数。") }
            if argument == "--data-dir" {
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else { throw CaptureTransportError.invalidArguments("--data-dir 必须提供绝对目录。") }
                dataPath = arguments[index]
            }
            index += 1
        }
        guard seen.contains("--capture") else { throw CaptureTransportError.invalidArguments("缺少 --capture。") }
        let qa = seen.contains("--qa")
        guard qa == (dataPath != nil) else { throw CaptureTransportError.invalidArguments("隔离捕获须同时指定 --qa 与 --data-dir，正式捕获不能自定义目录。") }
        let root = dataPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? productionRoot
        var rootInfo = stat()
        if lstat(root.path, &rootInfo) == 0 && (rootInfo.st_mode & S_IFMT) == S_IFLNK { throw CaptureTransportError.unsafePath }
        let resolved = notificationPath(root), production = notificationPath(productionRoot)
        guard !qa || (resolved != production && !resolved.hasPrefix(production + "/")) else { throw CaptureTransportError.invalidArguments("隔离捕获不能指向正式日程目录。") }
        if qa { try AgendaDataPathSafety.validateQA(root, productionRoot: productionRoot) }
        return Self(dryRun: seen.contains("--dry-run"), noLaunch: seen.contains("--no-launch"), qa: qa, root: root)
    }
    private static func notificationPath(_ root: URL) -> String { CaptureInbox.notificationObject(for: root) }
}

// These injections are internal test seams. CLI arguments cannot select a launcher or executable.
struct CaptureCLIEnvironment {
    var readInput: () throws -> Data
    var output: (Data) -> Void
    var isRunning: (URL) throws -> Bool
    var launch: (URL, Bool, URL) throws -> Void
    var notify: (URL) -> Void
    var clock: () -> TimeInterval
    var pause: () -> Void
    var timeout: TimeInterval = 30
}

enum CaptureCLI {
    static func run(arguments: [String], bundleURL: URL, productionRoot: URL) -> Int32 {
        run(arguments: arguments, bundleURL: bundleURL, productionRoot: productionRoot, environment: CaptureCLIEnvironment(
            readInput: {
                var data = Data()
                while let part = try FileHandle.standardInput.read(upToCount: min(4096, CaptureDirectory.maximumBytes + 1 - data.count)), !part.isEmpty {
                    data.append(part)
                    guard data.count <= CaptureDirectory.maximumBytes else { throw CaptureTransportError.oversized }
                }
                return data
            },
            output: { FileHandle.standardOutput.write($0); FileHandle.standardOutput.write(Data([10])) },
            isRunning: applicationIsRunning,
            launch: launchCurrentApplication,
            notify: { DistributedNotificationCenter.default().postNotificationName(CaptureInbox.notificationName, object: CaptureInbox.notificationObject(for: $0), userInfo: nil, deliverImmediately: true) },
            clock: { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
            pause: { Thread.sleep(forTimeInterval: 0.05) }
        ))
    }

    static func run(arguments: [String], bundleURL: URL, productionRoot: URL, environment: CaptureCLIEnvironment) -> Int32 {
        var requestID: String?
        var submitted = false
        func emit(_ result: AgendaCaptureResult) { if let data = try? JSONEncoder().encode(result) { environment.output(data) } }
        do {
            let options = try CaptureCLIOptions.parse(arguments, productionRoot: productionRoot)
            let input = try environment.readInput()
            guard input.count <= CaptureDirectory.maximumBytes else { throw CaptureTransportError.oversized }
            let request = try JSONDecoder().decode(AgendaCaptureRequest.self, from: input).normalized()
            requestID = request.requestID
            if options.dryRun {
                var preview: [String: Any] = ["ok": true, "status": "preview", "request_id": request.requestID, "type": request.date == nil && request.time == nil ? "checklist" : "scheduled", "title": request.title]
                if let date = request.date { preview["date"] = date }
                if let time = request.time { preview["time"] = time }
                environment.output(try JSONSerialization.data(withJSONObject: preview, options: [.sortedKeys]))
                return 0
            }
            let directory = try CaptureDirectory(root: options.root)
            let attempt = UUID().uuidString
            try directory.write(JSONEncoder().encode(request), name: attempt + ".request.json")
            submitted = true
            var launchError: String?
            do {
                if !options.noLaunch {
                    let running = try environment.isRunning(options.root)
                    if !running { try environment.launch(bundleURL, options.qa, options.root) }
                }
            } catch { launchError = error.localizedDescription }
            environment.notify(options.root)
            let deadline = environment.clock() + min(30, max(0, environment.timeout))
            repeat {
                if let data = try directory.read(attempt + ".reply.json") {
                    let reply = try JSONDecoder().decode(AgendaCaptureResult.self, from: data)
                    guard reply.requestID == request.requestID || (!reply.ok && reply.requestID == nil) else { throw CaptureTransportError.io("回执编号不匹配") }
                    let reliable = reply.ok && ["created", "already_processed"].contains(reply.status) && reply.itemID != nil && reply.itemExists != nil && (reply.status != "created" || reply.itemExists == true)
                    guard !reply.ok || reliable else { throw CaptureTransportError.io("没有可靠的保存回执") }
                    emit(reply)
                    try? directory.remove(attempt + ".reply.json")
                    return reliable ? 0 : 1
                }
                if environment.clock() >= deadline { break }
                environment.pause()
            } while true
            emit(AgendaCaptureResult(ok: false, requestID: request.requestID, status: "pending", error: launchError ?? "请求已排队，30 秒内未收到保存回执；请用原 request_id 核对或重试，当前不能确认已保存。"))
            return 2
        } catch {
            emit(AgendaCaptureResult(ok: false, requestID: requestID, status: submitted ? "pending" : "invalid", error: error.localizedDescription))
            return submitted ? 2 : 1
        }
    }

    static func applicationIsRunning(root: URL) throws -> Bool {
        let file = Darwin.open(root.appendingPathComponent("app.lock").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if file < 0 { if errno == ENOENT { return false }; throw CaptureTransportError.unsafePath }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { throw CaptureTransportError.unsafePath }
        if flock(file, LOCK_EX | LOCK_NB) == 0 { flock(file, LOCK_UN); return false }
        guard errno == EWOULDBLOCK || errno == EAGAIN else { throw CaptureTransportError.io("无法核对应用锁") }
        return true
    }

    private static func launchCurrentApplication(bundleURL: URL, qa: Bool, root: URL) throws {
        guard bundleURL.isFileURL, bundleURL.pathExtension == "app", FileManager.default.fileExists(atPath: bundleURL.path) else { throw CaptureTransportError.io("捕获需从当前朝夕 .app 运行") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-n", bundleURL.path] + (qa ? ["--args", "--qa", "--data-dir", root.path] : [])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Do not wait on open: only the application's persisted acknowledgment counts,
        // and the CLI's bounded reply wait must not depend on a launcher completing.
    }
}
