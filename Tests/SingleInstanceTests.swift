import Foundation
import Darwin

@main struct SingleInstanceTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("gui.lock")
        var lease: AgendaGUILease? = try AgendaGUILease(fileURL: path)
        do { _ = try AgendaGUILease(fileURL: path); fatalError("duplicate accepted") }
        catch AgendaGUILease.Failure.occupied { }
        withExtendedLifetime(lease) {}
        lease = nil
        let replacement = try AgendaGUILease(fileURL: path)
        withExtendedLifetime(replacement) {}
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        do { _ = try AgendaGUILease(fileURL: link); fatalError("symlink accepted") }
        catch AgendaGUILease.Failure.unsafe { }
        do { _ = try AgendaGUILease(fileURL: directory); fatalError("directory accepted") }
        catch AgendaGUILease.Failure.unsafe { }
        let publicFile = directory.appendingPathComponent("public")
        FileManager.default.createFile(atPath: publicFile.path, contents: Data())
        chmod(publicFile.path, 0o644)
        do { _ = try AgendaGUILease(fileURL: publicFile); fatalError("public file accepted") }
        catch AgendaGUILease.Failure.unsafe { }
        print("PASS: GUI lease contention, release, symlink, directory and permissions; isolated files only")
    }
}
