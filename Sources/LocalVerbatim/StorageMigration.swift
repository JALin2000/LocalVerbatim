import Foundation
import CryptoKit

/// A verified copy is staged on the destination volume. The source is retained
/// until the user explicitly removes it; a failed copy cannot alter the library.
enum StorageMigration {
    static func copyVerified(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        guard source != destination else { return }
        guard !destination.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(destination.path + "/") else {
            throw failure("Source and destination folders must not contain one another.")
        }
        guard !fm.fileExists(atPath: destination.path) else { throw failure("The destination already exists. Choose an empty parent folder.") }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".localverbatim-migration-\(UUID().uuidString)")
        do {
            try Task.checkCancellation()
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: stage) }
            else { try fm.createDirectory(at: stage, withIntermediateDirectories: true) }
            let before = fm.fileExists(atPath: source.path) ? try hashes(in: source) : [:]
            let after = try hashes(in: stage)
            guard before == after else { throw failure("File verification failed. The original library is unchanged.") }
            try Task.checkCancellation()
            try fm.moveItem(at: stage, to: destination)
        } catch {
            try? fm.removeItem(at: stage) // Only our incomplete staging copy.
            throw error
        }
    }
    static func hashes(in folder: URL) throws -> [String: String] {
        let fm = FileManager.default
        var result: [String: String] = [:]
        for relative in try fm.subpathsOfDirectory(atPath: folder.path) {
            try Task.checkCancellation()
            let file = folder.appendingPathComponent(relative)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw failure("Symbolic links are not supported in a meeting library.") }
            guard values.isRegularFile == true else { continue }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation(); hash.update(data: data)
            }
            result[relative] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
    static func checkWritable(_ directory: URL, minimumFreeBytes: Int64 = 50_000_000) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = directory.appendingPathComponent(".localverbatim-write-test-\(UUID().uuidString)")
        try Data("test".utf8).write(to: probe, options: .withoutOverwriting)
        try fm.removeItem(at: probe)
        if let attrs = try? fm.attributesOfFileSystem(forPath: directory.path),
           let free = attrs[.systemFreeSize] as? NSNumber, free.int64Value < minimumFreeBytes {
            throw failure("There is not enough free space in the recording location.")
        }
    }
    static func freeSpace(at directory: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: directory.path), let bytes = attrs[.systemFreeSize] as? NSNumber else {
            return tr("目录不可用", "Location unavailable")
        }
        return ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
    }
    private static func failure(_ message: String) -> NSError { NSError(domain: "LocalVerbatim.Storage", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
