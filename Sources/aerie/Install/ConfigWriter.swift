import Foundation

/// Shared config-file write path for the integration installers.
enum ConfigWriter {
    /// Write `data` to `url` atomically, but *through* symlinks: if the
    /// config path is a symlink (dotfiles repos), resolve it and replace the
    /// target file, preserving the link at the original path. A plain
    /// `.atomic` write would rename over the symlink itself, silently
    /// detaching the file from the user's dotfiles.
    static func writeThroughSymlinks(_ data: Data, to url: URL) throws {
        let dest = url.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
    }

    /// Timestamped sibling backup of `url` if it exists (best-effort).
    static func backup(_ url: URL, label: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(label)-backup-\(df.string(from: Date()))")
        try? FileManager.default.copyItem(at: url, to: dest)
    }
}
