@preconcurrency import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var statusMessage = "Ready to check"
    @Published private(set) var lastBackupURL: URL?

    private var updaterController: SPUStandardUpdaterController!
    private var canCheckForUpdatesObserver: AnyCancellable?

    var isConfigured: Bool {
        guard
            let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }

        return URL(string: feed) != nil
            && !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var lastCheckDate: Date? {
        UserDefaults.standard.object(forKey: AppSettingKeys.lastUpdateCheckDate) as? Date
    }

    private override init() {
        super.init()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        canCheckForUpdatesObserver = updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }

        if !isConfigured {
            statusMessage = "Update signing is not configured"
        }
    }

    func checkForUpdates() {
        guard isConfigured else {
            statusMessage = "Update signing is not configured"
            return
        }
        guard canCheckForUpdates else {
            statusMessage = "The updater is still starting; try again in a moment"
            return
        }

        statusMessage = "Checking for updates…"
        UserDefaults.standard.set(Date(), forKey: AppSettingKeys.lastUpdateCheckDate)
        updaterController.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        statusMessage = "Version \(item.displayVersionString) is available"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        statusMessage = "Shards is up to date"
    }

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        do {
            let backup = try VaultBackupService.shared.createBackup(
                reason: .preUpdate(targetVersion: updateItem.displayVersionString)
            )
            lastBackupURL = backup.url
            statusMessage = "Backup created; update is ready"
        } catch {
            statusMessage = "Update stopped because backup failed"
            throw NSError(
                domain: "com.tangxiaoyi.Shards.Update",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Shards could not create a safety backup before updating.",
                    NSUnderlyingErrorKey: error
                ]
            )
        }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        UserDefaults.standard.set(Date(), forKey: AppSettingKeys.lastUpdateCheckDate)
        if let error {
            let nsError = error as NSError
            // Sparkle exposes SUNoUpdateError as code 1001 in its Objective-C header,
            // but the constant is not imported into Swift as a standalone symbol.
            if nsError.domain != SUSparkleErrorDomain || nsError.code != 1001 {
                statusMessage = "Update check failed: \(error.localizedDescription)"
            }
        }
    }
}
