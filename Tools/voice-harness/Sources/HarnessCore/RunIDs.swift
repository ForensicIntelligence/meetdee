import Foundation

/// Calm round 2: every run / replay gets its own report folder, even when two start in
/// the same second (round 1: two replays both wrote `Reports/replay-20261016-…`).
/// The id is claimed by creating `<reports>/<id>`, which is atomic across processes:
/// the first claimant wins and the next tries `<id>-2`, `<id>-3`, …. An id whose folder
/// exists under any of `alsoFree` (the traces root) is skipped too.
public enum RunIDs {
    public static func claim(_ base: String, in reports: URL, alsoFree: [URL] = [], maxTries: Int = 1000) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: reports, withIntermediateDirectories: true)
        for n in 1...maxTries {
            let id = n == 1 ? base : "\(base)-\(n)"
            if alsoFree.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent(id).path) }) { continue }
            let dir = reports.appendingPathComponent(id)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: false)
                return id
            } catch {
                // Someone else holds this id (or it is a file): try the next one.
                if fm.fileExists(atPath: dir.path) { continue }
                throw error
            }
        }
        throw Exhausted(base: base, tries: maxTries)
    }

    public struct Exhausted: Error, CustomStringConvertible {
        public var base: String
        public var tries: Int
        public var description: String { "no free report folder for \(base) after \(tries) tries" }
    }
}
