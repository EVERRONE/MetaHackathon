import Foundation

/// The test record kept on this iPhone for judging how Pip did afterwards: the logs (session,
/// map, tracking, EdgeTAM, relocalising), every look (its frame, the answer, the outlines),
/// EdgeTAM's kept frames and what the user saw while a cue was drawn. Only on the device: pulled
/// with `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer
/// --domain-identifier be.unveil.pip.dev --source Documents/<name> --destination <dir>`. Never
/// in a backup, deleted with "forget everything" and when it is switched off in the settings.
enum Diagnostics {
    static let key = "pip.diagnostics"
    /// On while Pip is being tested.
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        if !on { removeAll() }
    }

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// What it writes, in Documents: a folder of runs each, and logs.
    static let folders = ["looks", "edgetam", "overlay", "clips"]
    static let logs = ["session.log", "map.log", "tracking.log", "edgetam.log", "relocalise.log"]

    /// Every file it writes goes through this queue, so lines keep their order and a deletion
    /// comes after everything queued before it.
    static let queue = DispatchQueue(label: "pip.diagnostics", qos: .utility)

    /// A time-stamped line in a log.
    static func log(_ line: String, to name: String) {
        append(ISO8601DateFormatter().string(from: Date()) + "\t" + line + "\n", to: name)
    }

    /// Appends `text` to a log. Past `limit` bytes the log moves aside to `<name>.old.log` (the
    /// one before goes), so it never grows without end. `header` starts a new log.
    static func append(_ text: String, to name: String, limit: Int = 2_000_000, header: String? = nil) {
        guard enabled else { return }
        queue.async {
            let url = documents.appendingPathComponent(name)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit {
                let old = oldLog(url)
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? Data(((header ?? "") + text).utf8).write(to: url)
                excludeFromBackup(url)
            }
        }
    }

    private static func oldLog(_ url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("old.log") }

    /// A new folder for one run (a look, an object EdgeTAM follows, a stretch of overlay shots),
    /// named `name` so runs sort by time; only the newest `keep` runs stay. nil when switched off.
    static func newRun(in folder: String, named name: String, keep: Int) -> URL? {
        guard enabled else { return nil }
        let base = documents.appendingPathComponent(folder)
        let dir = base.appendingPathComponent(name)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        excludeFromBackup(base)
        queue.async {
            let runs = ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
                .filter(\.hasDirectoryPath).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in runs.dropLast(keep) { try? FileManager.default.removeItem(at: old) }
        }
        return dir
    }

    /// Writes a file of a run, off the main thread (`make` runs on the queue: encode there).
    static func write(to url: URL, _ make: @escaping () -> Data?) {
        guard enabled else { return }
        queue.async {
            guard enabled, FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), let data = make() else { return }
            try? data.write(to: url)
        }
    }

    static func removeAll() {
        queue.async {
            for name in folders + logs + logs.map({ oldLog(documents.appendingPathComponent($0)).lastPathComponent }) {
                try? FileManager.default.removeItem(at: documents.appendingPathComponent(name))
            }
        }
    }

    /// Nothing Pip keeps goes into an iCloud or computer backup: it stays on this iPhone, as the
    /// memory question says. For what is already there at start (the memory included); new logs
    /// and run folders are excluded when they are made.
    static func excludeAllFromBackup() {
        let docs = documents
        excludeFromBackup(docs)
        for url in (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? [] { excludeFromBackup(url) }
    }

    static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}
