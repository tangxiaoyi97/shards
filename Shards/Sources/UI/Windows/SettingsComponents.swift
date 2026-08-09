import Foundation
import SwiftUI

struct SettingsSidebar: View {
    @Binding var selection: SettingsView.SettingsTab
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(accentColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Shards")
                        .font(.headline)
                    Text("Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 22)

            VStack(spacing: 5) {
                ForEach(SettingsView.SettingsTab.allCases) { tab in
                    Button {
                        selection = tab
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 18)

                            Text(tab.rawValue)
                                .font(.subheadline.weight(selection == tab ? .semibold : .medium))

                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selection == tab ? accentColor : .primary)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(
                            selection == tab ? accentColor.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            Text("Changes save automatically")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(18)
        }
        .frame(width: 196)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.52))
    }
}

struct SettingsPageHeader: View {
    let title: String
    let summary: String
    let icon: String
    let accentColor: Color

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 42, height: 42)
                .background(accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.bottom, 4)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let summary: String?
    let icon: String
    @ViewBuilder let content: Content

    init(
        _ title: String,
        icon: String,
        summary: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.summary = summary
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.72),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.38), lineWidth: 0.5)
        }
    }
}

struct SettingsNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Color {
    func toHex() -> String? {
        guard let cgColor, let components = cgColor.components, components.count >= 3 else { return nil }
        return String(
            format: "#%02lX%02lX%02lX",
            lroundf(Float(components[0]) * 255),
            lroundf(Float(components[1]) * 255),
            lroundf(Float(components[2]) * 255)
        )
    }
}

struct SymbolPickerButton: View {
    @Binding var symbol: String
    var color: Color = .secondary
    @State private var showPicker = false
    @State private var searchText = ""

    private static let symbols: [(category: String, icons: [String])] = [
        ("General", ["tag.fill", "bookmark.fill", "star.fill", "heart.fill", "flag.fill",
                     "bell.fill", "bolt.fill", "flame.fill", "leaf.fill", "drop.fill"]),
        ("Objects", ["key.fill", "lock.fill", "folder.fill", "doc.fill", "creditcard.fill",
                     "cart.fill", "gift.fill", "house.fill", "building.2.fill", "briefcase.fill"]),
        ("Communication", ["envelope.fill", "phone.fill", "message.fill", "bubble.left.fill",
                          "at", "globe", "link", "antenna.radiowaves.left.and.right", "wifi", "network"]),
        ("People", ["person.fill", "person.2.fill", "person.crop.circle.fill",
                    "figure.stand", "hand.raised.fill", "brain.head.profile"]),
        ("Media", ["camera.fill", "photo.fill", "video.fill", "music.note", "play.fill",
                   "paintbrush.fill", "pencil", "scissors", "wand.and.stars", "sparkles"]),
        ("Shapes", ["circle.fill", "square.fill", "triangle.fill", "diamond.fill",
                    "hexagon.fill", "shield.fill", "seal.fill", "app.fill"]),
    ]

    var body: some View {
        Button {
            showPicker.toggle()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Search or type SF Symbol name…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit {
                            if !searchText.isEmpty {
                                symbol = searchText
                                showPicker = false
                            }
                        }
                }
                .padding(10)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(filteredSymbols, id: \.category) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.category)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 4)

                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 8),
                                    spacing: 4
                                ) {
                                    ForEach(group.icons, id: \.self) { icon in
                                        Button {
                                            symbol = icon
                                            showPicker = false
                                        } label: {
                                            Image(systemName: icon)
                                                .font(.system(size: 14))
                                                .frame(width: 32, height: 32)
                                                .foregroundStyle(symbol == icon ? .white : .primary)
                                                .background(
                                                    symbol == icon ? AnyShapeStyle(color) : AnyShapeStyle(.clear),
                                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(10)
                }
            }
            .frame(width: 300, height: 320)
        }
    }

    private var filteredSymbols: [(category: String, icons: [String])] {
        if searchText.isEmpty { return Self.symbols }
        let query = searchText.lowercased()
        return Self.symbols.compactMap { group in
            let filtered = group.icons.filter { $0.lowercased().contains(query) }
            return filtered.isEmpty ? nil : (group.category, filtered)
        }
    }
}
