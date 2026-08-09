import Foundation

enum AppBuildInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    static let gitCommit: String = buildMetadata.commit
    static let hasLocalChanges: Bool = buildMetadata.hasLocalChanges

    private static let buildMetadata: (commit: String, hasLocalChanges: Bool) = {
        guard
            let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let values = propertyList as? [String: Any]
        else {
            return ("Unavailable", false)
        }

        return (
            values["GitCommit"] as? String ?? "Unavailable",
            values["GitDirty"] as? Bool ?? false
        )
    }()
}
