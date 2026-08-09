import Foundation
import SwiftData

@MainActor
final class VaultBackupService {
    struct BackupSummary: Sendable {
        let url: URL
        let createdAt: Date
        let byteCount: Int64
    }

    enum BackupReason: Sendable {
        case preUpdate(targetVersion: String)
        case manual

        var label: String {
            switch self {
            case .preUpdate(let targetVersion):
                "pre-update-\(targetVersion)"
            case .manual:
                "manual"
            }
        }
    }

    static let shared = VaultBackupService()
    static let retentionCount = 14

    let backupDirectoryURL: URL

    private let fileManager: FileManager
    private let container: ModelContainer

    init(
        container: ModelContainer = VaultContainer.shared.container,
        fileManager: FileManager = .default,
        backupDirectoryURL: URL = VaultContainer.vaultDirectory
            .appendingPathComponent("Backups", isDirectory: true)
    ) {
        self.container = container
        self.fileManager = fileManager
        self.backupDirectoryURL = backupDirectoryURL
    }

    func createBackup(reason: BackupReason) throws -> BackupSummary {
        let context = container.mainContext
        if context.hasChanges {
            try context.save()
        }

        let shards = try context.fetch(FetchDescriptor<Shard>())
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let templates = try context.fetch(FetchDescriptor<PresetTemplate>())
        let collections = try context.fetch(FetchDescriptor<ShardCollection>())
        let attachments = try context.fetch(FetchDescriptor<ShardAttachment>())
        let createdAt = Date()

        let package = ExportPackage(
            shards: shards.map(ShardExport.init),
            tags: tags.map(TagExport.init),
            templates: templates.map(TemplateExport.init),
            collections: collections.map(CollectionExport.init),
            exportedAt: createdAt,
            formatVersion: 2,
            attachments: attachments.map(AttachmentExport.init),
            reason: reason.label,
            appVersion: AppBuildInfo.version,
            appBuild: AppBuildInfo.build
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(package)

        try fileManager.createDirectory(
            at: backupDirectoryURL,
            withIntermediateDirectories: true
        )

        let safeReason = reason.label
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let filename = "Shards-\(Self.filenameDateFormatter.string(from: createdAt))-\(safeReason).shardsbackup"
        let destinationURL = backupDirectoryURL.appendingPathComponent(filename)
        try data.write(to: destinationURL, options: .atomic)
        try pruneOldBackups()

        return BackupSummary(
            url: destinationURL,
            createdAt: createdAt,
            byteCount: Int64(data.count)
        )
    }

    func backupSummaries() -> [BackupSummary] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "shardsbackup" }
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]) else {
                    return nil
                }
                return BackupSummary(
                    url: url,
                    createdAt: values.creationDate ?? .distantPast,
                    byteCount: Int64(values.fileSize ?? 0)
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func pruneOldBackups() throws {
        for backup in backupSummaries().dropFirst(Self.retentionCount) {
            try fileManager.removeItem(at: backup.url)
        }
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}
