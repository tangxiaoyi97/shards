import Foundation

extension Notification.Name {
    static let recentCaptureDidChange = Notification.Name("recentCaptureDidChange")
    static let openShardRequested = Notification.Name("openShardRequested")
}

@MainActor
final class RecentCaptureStore {
    static let shared = RecentCaptureStore()

    private static let shardIDKey = "recent_capture_shard_id"
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    var shardID: String? {
        defaults.string(forKey: Self.shardIDKey)
    }

    func record(shardID: String) {
        defaults.set(shardID, forKey: Self.shardIDKey)
        notificationCenter.post(name: .recentCaptureDidChange, object: shardID)
    }

    func clear(ifMatching shardID: String? = nil) {
        if let shardID, self.shardID != shardID { return }
        defaults.removeObject(forKey: Self.shardIDKey)
        notificationCenter.post(name: .recentCaptureDidChange, object: nil)
    }
}
