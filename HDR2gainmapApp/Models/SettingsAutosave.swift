import Foundation
import CryptoKit

/// Per-folder autosave of the tone-mapping parameters (`SettingsProfile` format), kept in the app's
/// own container — `Library/Application Support/Autosave/<hash of the folder path>.json` — so it
/// never writes into the user's image folders. `MainViewModel` writes it shortly after every change
/// (and immediately on window close / quit / folder switch) and restores it when the same folder is
/// opened again. Keyed by the folder's path: a moved or renamed folder starts fresh (a profile saved
/// with Save Tone-Mapping Parameters still restores it).
enum SettingsAutosave {

    /// The autosave directory inside the app container.
    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Autosave", isDirectory: true)
    }

    /// The autosave file of `folder` (whether or not it exists yet).
    static func fileURL(forFolder folder: URL) -> URL? {
        let path = folder.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent("\(digest.prefix(32)).json")
    }

    /// The saved state of `folder`, if any. A file that can't be read or decoded (or comes from a
    /// newer schema) is ignored — the folder simply opens at defaults.
    static func load(forFolder folder: URL) -> SettingsProfile? {
        guard let url = fileURL(forFolder: folder),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let profile = try? decoder.decode(SettingsProfile.self, from: data),
              profile.schemaVersion <= SettingsProfile.currentSchemaVersion else { return nil }
        return profile
    }

    /// Writes `profile` as the saved state of `folder` (atomically: the container is ours).
    static func save(_ profile: SettingsProfile, forFolder folder: URL) throws {
        guard let dir = directory, let url = fileURL(forFolder: folder) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profile).write(to: url, options: .atomic)
    }

    /// Drops the saved state of `folder` (nothing left to remember: every image is at defaults).
    static func remove(forFolder folder: URL) {
        guard let url = fileURL(forFolder: folder) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Identity of a source file for the autosave: its size and modification time. If either differs
/// from what was recorded with an entry, the file was replaced (e.g. re-exported) since.
struct SourceFingerprint {
    let size: Int64
    let modifiedAt: Double   // seconds since 1970

    init?(url: URL) {
        // A fresh URL: resource values are cached per URL instance, so re-reading through the image's
        // long-lived URL would return what was first read, missing a file replaced mid-session.
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let date = values.contentModificationDate else { return nil }
        self.size = Int64(size)
        self.modifiedAt = date.timeIntervalSince1970
    }

    /// Whether the recorded `size` / `modifiedAt` still describe this file. An entry without a
    /// recorded fingerprint (older profile) is trusted.
    func matches(size recordedSize: Int64?, modifiedAt recordedTime: Double?) -> Bool {
        guard let recordedSize, let recordedTime else { return true }
        return recordedSize == size && abs(recordedTime - modifiedAt) < 0.001
    }
}
