<p align="center">
  <img src="Shards/Resources/Assets.xcassets/AppIcon.appiconset/icon_128.png" width="96" height="96" alt="Shards app icon">
</p>

<h1 align="center">Shards</h1>

<p align="center">A local macOS vault for quick notes</p>

<p align="center">
  <img alt="Version 1.0" src="https://img.shields.io/badge/version-1.0-5B4CF0">
  <img alt="macOS 15 or later" src="https://img.shields.io/badge/platform-macOS_15%2B-111111">
  <img alt="Swift 6" src="https://img.shields.io/badge/language-Swift_6-F05138">
  <img alt="MIT License" src="https://img.shields.io/badge/license-MIT-2563EB">
</p>

![The Shards vault](docs/images/shards-vault.jpeg)

Shards turns quick notes, clipboard text, and reusable templates into searchable pieces of information—without an account or cloud service.

## highlights

- Spotlight-style Quick Entry with `Command–Shift–S`; press `Escape` to close it.
- Local clipboard capture from the menu bar.
- Search, tags, categories, pinning, Trash, and restore.
- Reusable templates for structured information.
- Optional Smart mode with an editable preview; it does not read historical Vault content.
- Global or per-Shard password protection, JSON/CSV import and export.

![Shards settings](docs/images/shards-settings.jpeg)

## privacy

- Data stays in `~/Library/Application Support/Shards/Shards.store`.
- Ordinary Shards are plain text or JSON unless protection is enabled.
- Protected payloads use CryptoKit AES-GCM; titles and metadata may remain unencrypted.
- Smart mode sends only the current draft and template schema to your configured endpoint.
- The optional LLM token is stored in local preferences, not Keychain.

Shards is a personal capture tool, not a dedicated password manager. Exported files should be handled according to the sensitivity of their contents.

## build

Requires macOS 15+, Xcode 16+, and Swift 6. Open `Shards.xcodeproj`, select the `Shards` scheme, and run.

```bash
xcodebuild -project Shards.xcodeproj -scheme Shards \
  -destination 'platform=macOS,arch=arm64' \
  SWIFT_STRICT_CONCURRENCY=complete test
```

Create a local release package with `zsh scripts/package-release.sh`. Public distribution requires Developer ID signing and notarization; see [docs/release.md](docs/release.md).

The bundle identifier is `com.tangxiaoyi.Shards`. Version 1.0 migrates known preferences from the former `com.yourdomain.Shards` domain.

## credits

唐晓翼 tangxiaoyi97<br>
gpt5.6 sol

[MIT](LICENSE) © 2026 唐晓翼 (Tangxiaoyi97). See [Third-Party Notices](THIRD_PARTY_NOTICES.md) for bundled dependencies.
