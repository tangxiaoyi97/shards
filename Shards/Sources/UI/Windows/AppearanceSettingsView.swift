import SwiftUI

struct PersonalizationSettingsView: View {
    @AppStorage(AppSettingKeys.appearance) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage("vault_sidebar_compact") private var vaultSidebarCompact = false
    @AppStorage("custom_accent_hex") private var customAccentHex = ""
    @AppStorage(AppSettingKeys.backgroundStyle) private var backgroundStyle = "system"
    @AppStorage(AppSettingKeys.backgroundColorHex) private var bgColorHex = "#1A1A2E"
    @AppStorage(AppSettingKeys.backgroundGradientFrom) private var gradientFrom = "#0F0C29"
    @AppStorage(AppSettingKeys.backgroundGradientTo) private var gradientTo = "#302B63"
    @AppStorage(AppSettingKeys.backgroundGlassTintHex) private var glassTintHex = "#4F46E5"
    @AppStorage(AppSettingKeys.backgroundOpacity) private var backgroundOpacity = 1.0
    @AppStorage(AppSettingKeys.backgroundColorOpacity) private var backgroundColorOpacity = 1.0
    @AppStorage(AppSettingKeys.editorFontSize) private var editorFontSize = 15.0

    private let bgStyles: [(id: String, label: String, icon: String)] = [
        ("system", "System", "laptopcomputer"),
        ("solid", "Solid Color", "paintpalette.fill"),
        ("gradient", "Gradient", "circle.lefthalf.filled"),
        ("glass", "Glass", "rectangle.on.rectangle"),
        ("tinted_glass", "Tinted Glass", "circle.hexagongrid.fill"),
    ]

    private var styleSupportsColorOpacity: Bool {
        ["solid", "gradient", "tinted_glass"].contains(backgroundStyle)
    }

    private var backgroundOpacityLabel: String {
        switch backgroundStyle {
        case "glass", "tinted_glass": "Surface Strength"
        default: "Opacity"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                "App Appearance",
                icon: "circle.lefthalf.filled",
                summary: "Choose one appearance for every Shards window."
            ) {
                Picker("Appearance", selection: $appearanceRawValue) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(appearance.title, systemImage: appearance.symbol)
                            .tag(appearance.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                SettingsNote(text: "System follows the current macOS appearance. Light and Dark stay fixed until you change them here.")
            }

            SettingsCard(
                "Accent Color",
                icon: "paintbrush.pointed.fill",
                summary: "Used for selection, primary actions, and interactive accents."
            ) {
                HStack(spacing: 12) {
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: customAccentHex) ?? Color(red: 79 / 255, green: 70 / 255, blue: 229 / 255) },
                        set: { customAccentHex = $0.toHex() ?? customAccentHex }
                    ))
                    .labelsHidden()
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Custom Accent")
                            .font(.body)
                        Text("Applied to buttons, icons, and interactive elements")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !customAccentHex.isEmpty {
                        Button("Reset") {
                            withAnimation { customAccentHex = "" }
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
            }

            SettingsCard(
                "Window Background",
                icon: "rectangle.3.group.fill",
                summary: "Preview changes before returning to your vault."
            ) {
                backgroundPreview
                    .frame(height: 96)
                    .compositingGroup()
                    .clipShape(.rect(cornerRadius: 11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    }

                Picker("Style", selection: $backgroundStyle) {
                    ForEach(bgStyles, id: \.id) { style in
                        Label(style.label, systemImage: style.icon)
                            .tag(style.id)
                    }
                }

                switch backgroundStyle {
                case "solid":
                    ColorPicker("Background Color", selection: Binding(
                        get: { Color(hex: bgColorHex) ?? .black },
                        set: { bgColorHex = $0.toHex() ?? bgColorHex }
                    ))
                case "gradient":
                    ColorPicker("From", selection: Binding(
                        get: { Color(hex: gradientFrom) ?? .black },
                        set: { gradientFrom = $0.toHex() ?? gradientFrom }
                    ))
                    ColorPicker("To", selection: Binding(
                        get: { Color(hex: gradientTo) ?? .indigo },
                        set: { gradientTo = $0.toHex() ?? gradientTo }
                    ))
                case "tinted_glass":
                    ColorPicker("Tint Color", selection: Binding(
                        get: { Color(hex: glassTintHex) ?? .indigo },
                        set: { glassTintHex = $0.toHex() ?? glassTintHex }
                    ))
                default:
                    EmptyView()
                }

                opacitySlider(
                    label: backgroundOpacityLabel,
                    value: $backgroundOpacity,
                    range: 0 ... 1
                )

                if styleSupportsColorOpacity {
                    opacitySlider(
                        label: "Color Intensity",
                        value: $backgroundColorOpacity,
                        range: 0 ... 1
                    )
                }

                if backgroundStyle == "system" {
                    SettingsNote(text: "Uses the standard window surface for the selected app appearance.")
                }
            }

            SettingsCard(
                "Typography",
                icon: "textformat.size",
                summary: "Adjust the writing size without changing stored content."
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Editor Font Size")
                        Spacer()
                        Text("\(Int(editorFontSize))pt")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 32, alignment: .trailing)
                    }
                    Slider(value: $editorFontSize, in: 12 ... 24, step: 1)
                }

                HStack {
                    Text("Preview:")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("The quick brown fox")
                        .font(.system(size: editorFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .padding(.vertical, 2)
            }

            SettingsCard("List Layout", icon: "list.bullet.rectangle") {
                Toggle("Compact List", isOn: $vaultSidebarCompact)
                SettingsNote(text: "Compact mode hides previews and dates while keeping icons and tags visible.")
            }
        }
    }

    @ViewBuilder
    private func opacitySlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
            Slider(value: value, in: range, step: 0.05)
        }
    }

    @ViewBuilder
    private var backgroundPreview: some View {
        AppBackgroundView()
    }
}
