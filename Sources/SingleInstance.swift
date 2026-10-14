import Foundation
import Darwin

// A GUI lease is shared by every build and data directory. Capture producers
// never take this lease; they communicate with the existing consumer instead.
final class AgendaGUILease {
    static let revealNotification = Notification.Name("com.djx.chaoxi.revealExisting")
    private let descriptor: Int32
    enum Failure: Error { case occupied, unsafe }

    init(fileURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("chaoxi-gui-\(getuid()).lock")) throws {
        let fd = Darwin.open(fileURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.unsafe }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, (info.st_mode & 0o077) == 0 else {
            Darwin.close(fd); throw Failure.unsafe
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            Darwin.close(fd)
            throw reason == EWOULDBLOCK ? Failure.occupied : Failure.unsafe
        }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }
}
