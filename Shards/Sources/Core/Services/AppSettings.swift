import Foundation

enum AppSettingKeys {
    static let migrationVersion = "settings_migration_version"
    static let bundleIdentifierMigrationVersion = "bundle_identifier_migration_version"

    static let backgroundStyle = "background_style"
    static let backgroundColorHex = "background_color_hex"
    static let backgroundGradientFrom = "background_gradient_from"
    static let backgroundGradientTo = "background_gradient_to"
    static let backgroundGlassTintHex = "background_glass_tint_hex"
    static let backgroundOpacity = "background_opacity"
    static let backgroundColorOpacity = "background_color_opacity"
    static let editorFontSize = "editor_font_size"
    static let appearance = "app_appearance"
    static let lastUpdateCheckDate = "last_update_check_date"
    static let spotlightIndexingEnabled = "spotlight_indexing_enabled"

    static let llmEndpointURL = "llm_endpoint_url"
    static let llmAPIToken = "llm_api_token"
    static let llmRequestFormat = "llm_request_format"
    static let llmModelName = "llm_model_name"

    static let globalProtectionEnabled = "global_protection_enabled"
    static let globalProtectionSalt = "global_protection_salt"
    static let globalProtectionVerifier = "global_protection_verifier"
    static let globalProtectionConfiguration = "global_protection_configuration_v2"

    static let legacyEditorBackgroundStyle = "editor_background_style"
    static let legacyEditorBackgroundColorHex = "editor_bg_color_hex"
    static let legacyEditorBackgroundGradientFrom = "editor_bg_gradient_from"
    static let legacyEditorBackgroundGradientTo = "editor_bg_gradient_to"
    static let legacyEditorBackgroundGlassTintHex = "editor_bg_glass_tint_hex"

    static let legacyOpenAIKey = "openai_api_key"
    static let legacyAnthropicKey = "anthropic_api_key"
}

enum AppSettingsMigration {
    static let legacyBundleIdentifiers = ["com.yourdomain.Shards"]
    private static let currentBundleIdentifierMigrationVersion = 1

    static func migrateLegacySettingsIfNeeded(
        defaults: UserDefaults = .standard,
        legacyDomainNames: [String] = legacyBundleIdentifiers,
        domainStore: UserDefaults = .standard
    ) {
        migrateBundleIdentifierSettingsIfNeeded(
            defaults: defaults,
            legacyDomainNames: legacyDomainNames,
            domainStore: domainStore
        )

        let version = defaults.integer(forKey: AppSettingKeys.migrationVersion)

        // v2 — reset hide_dock_icon to false now that Shards is a full Dock app.
        // The previous default was true (menu-bar-only), so existing users need
        // this migration to see the Dock icon without changing settings manually.
        if version < 2 {
            defaults.set(false, forKey: "hide_dock_icon")
            if version >= 1 {
                defaults.set(2, forKey: AppSettingKeys.migrationVersion)
                return
            }
        }

        guard version < 1 else { return }

        copyStringIfNeeded(
            newKey: AppSettingKeys.backgroundStyle,
            legacyKey: AppSettingKeys.legacyEditorBackgroundStyle,
            defaults: defaults
        )
        copyStringIfNeeded(
            newKey: AppSettingKeys.backgroundColorHex,
            legacyKey: AppSettingKeys.legacyEditorBackgroundColorHex,
            defaults: defaults
        )
        copyStringIfNeeded(
            newKey: AppSettingKeys.backgroundGradientFrom,
            legacyKey: AppSettingKeys.legacyEditorBackgroundGradientFrom,
            defaults: defaults
        )
        copyStringIfNeeded(
            newKey: AppSettingKeys.backgroundGradientTo,
            legacyKey: AppSettingKeys.legacyEditorBackgroundGradientTo,
            defaults: defaults
        )
        copyStringIfNeeded(
            newKey: AppSettingKeys.backgroundGlassTintHex,
            legacyKey: AppSettingKeys.legacyEditorBackgroundGlassTintHex,
            defaults: defaults
        )

        if isEmpty(defaults.string(forKey: AppSettingKeys.llmAPIToken)),
           let legacyToken = defaults.string(forKey: AppSettingKeys.legacyOpenAIKey),
           !legacyToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.set(legacyToken, forKey: AppSettingKeys.llmAPIToken)
            if isEmpty(defaults.string(forKey: AppSettingKeys.llmRequestFormat)) {
                defaults.set("openai", forKey: AppSettingKeys.llmRequestFormat)
            }
        }

        if isEmpty(defaults.string(forKey: AppSettingKeys.llmAPIToken)),
           let legacyToken = defaults.string(forKey: AppSettingKeys.legacyAnthropicKey),
           !legacyToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.set(legacyToken, forKey: AppSettingKeys.llmAPIToken)
            if isEmpty(defaults.string(forKey: AppSettingKeys.llmRequestFormat)) {
                defaults.set("anthropic", forKey: AppSettingKeys.llmRequestFormat)
            }
        }

        defaults.set(2, forKey: AppSettingKeys.migrationVersion)
    }

    static func migrateBundleIdentifierSettingsIfNeeded(
        defaults: UserDefaults = .standard,
        legacyDomainNames: [String] = legacyBundleIdentifiers,
        domainStore: UserDefaults = .standard
    ) {
        guard defaults.integer(forKey: AppSettingKeys.bundleIdentifierMigrationVersion)
                < currentBundleIdentifierMigrationVersion
        else {
            return
        }

        for domainName in legacyDomainNames {
            guard let legacyValues = domainStore.persistentDomain(forName: domainName) else {
                continue
            }

            for (key, value) in legacyValues {
                guard key != AppSettingKeys.bundleIdentifierMigrationVersion,
                      defaults.object(forKey: key) == nil
                else {
                    continue
                }
                defaults.set(value, forKey: key)
            }
        }

        // Keep the legacy domain intact so users can safely roll back to an
        // earlier build while validating the new bundle identifier.
        defaults.set(
            currentBundleIdentifierMigrationVersion,
            forKey: AppSettingKeys.bundleIdentifierMigrationVersion
        )
    }

    private static func copyStringIfNeeded(newKey: String, legacyKey: String, defaults: UserDefaults) {
        guard isEmpty(defaults.string(forKey: newKey)),
              let legacyValue = defaults.string(forKey: legacyKey),
              !legacyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        defaults.set(legacyValue, forKey: newKey)
    }

    private static func isEmpty(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}
