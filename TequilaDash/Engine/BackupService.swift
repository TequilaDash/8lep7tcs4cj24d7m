import Foundation
import CryptoKit

/// Progress callback for backup export.
typealias BackupProgress = (_ filesProcessed: Int, _ totalBytes: Int64, _ currentFile: String) -> Void

/// Result of a completed backup export.
struct BackupResult {
    let archiveURL: URL
    let fileCount: Int
    let totalBytes: Int64
    let manifestSHA256: String
    let metadata: BackupMetadata
    /// v0.3.673: files that were listed but could not be read (locked / removed
    /// between listing and read) and were therefore NOT written into the archive.
    ///
    /// Root cause this field exists: `walk` used to swallow
    /// `ZipWriterError.cannotReadSource` with a bare `continue`, so those files
    /// vanished from the archive AND from the manifest with no counter and no log.
    /// The manifest is the restore contract (RestoreService refuses entries that
    /// are not in it), so a "successful" backup was silently incomplete forever.
    /// Callers must treat a non-empty list as "this archive is partial".
    let skippedFiles: [String]
}

/// Errors specific to backup / restore archives.
enum BackupError: Error, LocalizedError {
    case containerInaccessible(String)
    case writeFailed(String)
    case cancelled
    case invalidArchive(String)
    case restoreBlocked(String)
    case appNotInstalled(String)

    var errorDescription: String? {
        switch self {
        case .containerInaccessible(let m): return "Container inaccessible: \(m)"
        case .writeFailed(let m): return "Failed to write backup: \(m)"
        case .cancelled: return "Backup was cancelled."
        case .invalidArchive(let m): return "Invalid backup archive: \(m)"
        case .restoreBlocked(let m): return m
        case .appNotInstalled(let id): return "App is not installed: \(id)"
        }
    }
}

/// Exports an app's Data container (Documents, Library, tmp) into a zip
/// archive with a manifest of SHA-256 hashes. Read-only with respect to the
/// target app during export.
final class BackupService {

    private let escape = SandboxEscape()
    private let files = FileService()

    /// Subtrees of a Data container we export and restore.
    static let backupRoots = ["Documents", "Library", "tmp"]

    // Safety limits live in `BackupLimits`. The previous hard-coded
    // 5,000 files / 512 MiB gate was removed in v0.3.531: it was not a ZIP
    // limit and it silently rejected valid containers. The byte ceiling is now
    // derived from the volume's free space, and the file ceiling only guards
    // against runaway trees (ZIP64 removed the 65,535-entry format limit).

    /// Export the given app's container to a zip inside Documents/Backups.
    func exportBackup(
        for app: InstalledApp,
        isContainerApp: Bool = false,
        iconData: Data? = nil,
        progress: BackupProgress? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> BackupResult {
        let backupsDir = try BackupPaths.ensureBackupsDirectory()
        let stamp = BackupPaths.fileTimestamp()
        // Preserve Unicode letters/numbers (including CJK) plus `_` and `-`;
        // replace filesystem-unsafe characters with `_`. Falls back to the
        // bundle identifier if the app name sanitizes to nothing.
        var safeName = app.name.replacingOccurrences(
            of: "[^\\p{L}\\p{N}_\\-]",
            with: "_",
            options: .regularExpression
        )
        if safeName.isEmpty {
            safeName = app.bundleIdentifier.replacingOccurrences(
                of: "[^\\p{L}\\p{N}_\\-]",
                with: "_",
                options: .regularExpression
            )
        }
        if safeName.isEmpty {
            safeName = "App"
        }
        let outURL = backupsDir.appendingPathComponent("\(safeName)_backup_\(stamp).zip")

        // Resolve the limits once per export. The byte ceiling depends on the
        // free space of the volume we are about to write the archive to.
        let maxFiles = BackupLimits.maxFiles
        let maxTotalBytes = BackupLimits.maxTotalBytes(for: backupsDir)

        var manifest: [BackupManifestEntry] = []
        var totalBytes: Int64 = 0
        // v0.3.673: files that could not be read and were dropped from the archive.
        var skipped: [String] = []

        let zip = ZipWriter()
        do {
            try zip.begin(at: outURL)
        } catch {
            throw BackupError.writeFailed(error.localizedDescription)
        }

        do {
            try escape.withHandle(for: app.containerPath) { _ in
                var foundRoot = false
                for root in Self.backupRoots {
                    if isCancelled() { throw BackupError.cancelled }
                    let rootPath = (app.containerPath as NSString).appendingPathComponent(root)
                    guard files.isDirectory(at: rootPath) else {
                        // v0.3.673: a root that exists but cannot be entered
                        // (permission / broken symlink) is NOT the same as an
                        // absent root. Continuing silently made the archive look
                        // complete while a whole subtree was missing, so record
                        // it in the same skip list the walk uses.
                        if files.exists(at: rootPath) {
                            skipped.append("\(root)/")
                            LoginLogger.shared.log(
                                "[备份] 根目录不可进入已跳过（该目录下的文件不会进恢复）：\(rootPath)"
                            )
                        }
                        continue
                    }
                    foundRoot = true
                    try walk(
                        path: rootPath,
                        relativePrefix: root,
                        zip: zip,
                        manifest: &manifest,
                        totalBytes: &totalBytes,
                        skipped: &skipped,
                        maxFiles: maxFiles,
                        maxTotalBytes: maxTotalBytes,
                        progress: progress,
                        isCancelled: isCancelled
                    )
                }
                if !foundRoot {
                    throw BackupError.containerInaccessible(
                        "Documents, Library, and tmp were not visible after opening \(app.containerPath)"
                    )
                }
            }
        } catch let error as BackupError {
            try? FileManager.default.removeItem(at: outURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw BackupError.containerInaccessible(error.localizedDescription)
        }

        // v0.3.673: manifest / metadata / finish used to sit OUTSIDE any cleanup
        // guard. A throw from JSONEncoder or zip.addFile (disk full, handle gone)
        // left a headerless partial zip in Documents/Backups, which the Backups
        // list scans as if it were a real archive. Everything from here on is
        // covered by the same "on failure, delete the product" rule.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadata: BackupMetadata
        let manifestHash: String
        do {
            let manifestData = try encoder.encode(manifest)
            manifestHash = SHA256.hash(data: manifestData)
                .map { String(format: "%02x", $0) }
                .joined()
            try zip.addFile(name: BackupPaths.manifestFileName, data: manifestData)

            metadata = BackupMetadata(
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                containerPath: app.containerPath,
                createdAt: BackupPaths.isoTimestamp(),
                fileCount: manifest.count,
                totalBytes: totalBytes,
                manifestSHA256: manifestHash,
                tequilaDashVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
                isContainerApp: isContainerApp,
                iconData: iconData
            )
            let metadataData = try encoder.encode(metadata)
            try zip.addFile(name: BackupPaths.metadataFileName, data: metadataData)
            try zip.finish()
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw BackupError.writeFailed(error.localizedDescription)
        }

        if !skipped.isEmpty {
            // v0.3.673: make the partial nature of this archive visible instead
            // of reporting a clean success.
            LoginLogger.shared.log(
                "[备份] \(app.name) 备份完成但不完整：清单 \(manifest.count) 个文件，"
                + "另有 \(skipped.count) 个文件读不出被跳过（这些文件不会进恢复）"
            )
        }

        return BackupResult(
            archiveURL: outURL,
            fileCount: manifest.count,
            totalBytes: totalBytes,
            manifestSHA256: manifestHash,
            metadata: metadata,
            skippedFiles: skipped
        )
    }

    private func walk(
        path: String,
        relativePrefix: String,
        zip: ZipWriter,
        manifest: inout [BackupManifestEntry],
        totalBytes: inout Int64,
        skipped: inout [String],
        maxFiles: Int,
        maxTotalBytes: Int64,
        progress: BackupProgress?,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw BackupError.cancelled }

        let entries: [FileItem]
        do {
            entries = try files.list(directory: path)
        } catch {
            throw BackupError.containerInaccessible(error.localizedDescription)
        }

        for entry in entries {
            if isCancelled() { throw BackupError.cancelled }
            let rel = "\(relativePrefix)/\(entry.name)"

            if entry.isDirectory {
                try walk(
                    path: entry.path,
                    relativePrefix: rel,
                    zip: zip,
                    manifest: &manifest,
                    totalBytes: &totalBytes,
                    skipped: &skipped,
                    maxFiles: maxFiles,
                    maxTotalBytes: maxTotalBytes,
                    progress: progress,
                    isCancelled: isCancelled
                )
            } else if entry.kind == .regular {
                let added: ZipAddedFile
                do {
                    // Stream from disk: the file is never held in memory, so a
                    // multi-gigabyte file no longer risks a jetsam kill. The
                    // SHA-256 the manifest needs is computed in the same pass.
                    added = try zip.addFile(name: rel, path: entry.path, expectedSize: entry.size)
                } catch ZipWriterError.cannotReadSource {
                    // v0.3.673: locked or removed between listing and read.
                    // Skipping still keeps the archive structurally consistent,
                    // but it MUST be recorded: the manifest is the restore
                    // contract, so an unrecorded skip is a file the user will
                    // never get back while the UI still says "backup succeeded".
                    skipped.append(rel)
                    LoginLogger.shared.log(
                        "[备份] 文件读取失败已跳过（不进清单，恢复时不会有它）：\(entry.path)"
                    )
                    continue
                } catch {
                    // The local header is already on disk with a partial
                    // payload, so the archive must be discarded by the caller.
                    throw BackupError.writeFailed(error.localizedDescription)
                }

                manifest.append(BackupManifestEntry(path: rel, size: Int(added.size), sha256: added.sha256))
                totalBytes += added.size
                progress?(manifest.count, totalBytes, rel)

                // Guard after every file rather than once per directory. The
                // old entry-level check could be skipped entirely when the
                // overflow happened inside the last existing root.
                if manifest.count > maxFiles || totalBytes > maxTotalBytes {
                    throw BackupError.writeFailed(
                        "Safety limit exceeded (over \(maxFiles) files or over "
                            + ByteCountFormatter.string(fromByteCount: maxTotalBytes, countStyle: .file)
                            + " of data)."
                    )
                }
            }
        }
    }
}
