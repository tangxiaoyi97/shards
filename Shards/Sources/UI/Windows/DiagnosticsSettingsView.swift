import AppKit
import SwiftUI

struct SoftwareUpdateSettingsCard: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        SettingsCard(
            "Software Update",
            icon: "arrow.triangle.2.circlepath",
            summary: "Check manually, review the release, then update and relaunch."
        ) {
            LabeledContent("Current Version") {
                Text("\(AppBuildInfo.version) (\(AppBuildInfo.build))")
                    .monospacedDigit()
            }

            LabeledContent("Status") {
                Text(updates.statusMessage)
                    .foregroundStyle(.secondary)
            }

            if let lastCheckDate = updates.lastCheckDate {
                LabeledContent("Last Checked") {
                    Text(lastCheckDate.formatted(date: .abbreviated, time: .shortened))
                }
            }

            HStack {
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!updates.canCheckForUpdates)

                if !updates.isConfigured {
                    Text("The public update feed and signing key must be configured before release.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

struct DiagnosticsSettingsView: View {
    @ObservedObject private var updates = UpdateController.shared
    @State private var backups: [VaultBackupService.BackupSummary] = []
    @State private var backupMessage: String?
    @State private var backupIsError = false

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                "Vault Health",
                icon: "externaldrive.badge.checkmark",
                summary: "See where your data and safety backups are stored."
            ) {
                LabeledContent("Store") {
                    pathText(VaultContainer.storeURL.path)
                }

                Divider()

                LabeledContent("Backups") {
                    Text("\(backups.count) of \(VaultBackupService.retentionCount) retained")
                        .monospacedDigit()
                }

                if let latest = backups.first {
                    LabeledContent("Latest Backup") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(latest.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text(ByteCountFormatter.string(fromByteCount: latest.byteCount, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button("Create Backup") {
                        createBackup()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Show Vault") {
                        reveal(VaultContainer.storeURL)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Show Backups") {
                        revealBackupDirectory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let backupMessage {
                    Text(backupMessage)
                        .font(.caption)
                        .foregroundStyle(backupIsError ? .red : .green)
                }

                SettingsNote(text: "Backups may contain ordinary shards as readable JSON. Protected shard payloads remain encrypted.")
            }

            SettingsCard(
                "Runtime",
                icon: "stethoscope",
                summary: "Useful details when diagnosing a crash or update problem."
            ) {
                diagnosticsRow("Version", "\(AppBuildInfo.version) (\(AppBuildInfo.build))")
                diagnosticsRow("Git Commit", AppBuildInfo.gitCommit + (AppBuildInfo.hasLocalChanges ? " (modified)" : ""))
                diagnosticsRow("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
                diagnosticsRow("Architecture", Self.architecture)
                diagnosticsRow("Update", updates.statusMessage)

                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticsReport, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            SettingsCard(
                "Update Safety",
                icon: "shield.checkered",
                summary: "Shards creates a backup before Sparkle accepts an update."
            ) {
                Text("If backup creation fails, the update is stopped and the current app remains installed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let lastBackupURL = updates.lastBackupURL {
                    LabeledContent("This Session") {
                        pathText(lastBackupURL.lastPathComponent)
                    }
                }
            }
        }
        .onAppear(perform: refreshBackups)
    }

    private var diagnosticsReport: String {
        [
            "Shards \(AppBuildInfo.version) (\(AppBuildInfo.build))",
            "Git: \(AppBuildInfo.gitCommit)\(AppBuildInfo.hasLocalChanges ? " modified" : "")",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(Self.architecture)",
            "Store: \(VaultContainer.storeURL.path)",
            "Backups: \(backups.count)",
            "Update: \(updates.statusMessage)"
        ].joined(separator: "\n")
    }

    private static var architecture: String {
        #if arch(arm64)
        "Apple Silicon"
        #elseif arch(x86_64)
        "Intel"
        #else
        "Unknown"
        #endif
    }

    private func diagnosticsRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.system(.body, design: label == "Git Commit" ? .monospaced : .default))
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    private func pathText(_ path: String) -> some View {
        Text(path)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
    }

    private func createBackup() {
        do {
            let backup = try VaultBackupService.shared.createBackup(reason: .manual)
            backupMessage = "Created \(backup.url.lastPathComponent)"
            backupIsError = false
            refreshBackups()
        } catch {
            backupMessage = "Backup failed: \(error.localizedDescription)"
            backupIsError = true
        }
    }

    private func refreshBackups() {
        backups = VaultBackupService.shared.backupSummaries()
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func revealBackupDirectory() {
        let directory = VaultBackupService.shared.backupDirectoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reveal(directory)
    }
}
