import AppKit
import SwiftUI

struct AppBackgroundMetrics {
    let contentOpacity: Double
    let glassSurfaceOpacity: Double
    let glassTintOpacity: Double

    static func resolve(
        backgroundStyle: String,
        backgroundOpacity: Double,
        backgroundColorOpacity: Double
    ) -> AppBackgroundMetrics {
        let clampedBackgroundOpacity = backgroundOpacity.clamped(to: 0...1)
        let clampedColorOpacity = backgroundColorOpacity.clamped(to: 0...1)

        switch backgroundStyle {
        case "solid", "gradient":
            return AppBackgroundMetrics(
                contentOpacity: clampedBackgroundOpacity * clampedColorOpacity,
                glassSurfaceOpacity: 0,
                glassTintOpacity: 0
            )
        case "glass":
            return AppBackgroundMetrics(
                contentOpacity: 1,
                glassSurfaceOpacity: 0.14 + (clampedBackgroundOpacity * 0.18),
                glassTintOpacity: 0
            )
        case "tinted_glass":
            return AppBackgroundMetrics(
                contentOpacity: 1,
                glassSurfaceOpacity: 0.12 + (clampedBackgroundOpacity * 0.16),
                glassTintOpacity: (0.08 + (clampedBackgroundOpacity * 0.16)) * clampedColorOpacity
            )
        default:
            return AppBackgroundMetrics(
                contentOpacity: clampedBackgroundOpacity,
                glassSurfaceOpacity: 0,
                glassTintOpacity: 0
            )
        }
    }
}

struct AppBackgroundView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppSettingKeys.backgroundStyle) private var backgroundStyle = "system"
    @AppStorage(AppSettingKeys.backgroundColorHex) private var bgColorHex = "#1A1A2E"
    @AppStorage(AppSettingKeys.backgroundGradientFrom) private var gradientFrom = "#0F0C29"
    @AppStorage(AppSettingKeys.backgroundGradientTo) private var gradientTo = "#302B63"
    @AppStorage(AppSettingKeys.backgroundGlassTintHex) private var glassTintHex = "#4F46E5"
    @AppStorage(AppSettingKeys.backgroundOpacity) private var backgroundOpacity = 1.0
    @AppStorage(AppSettingKeys.backgroundColorOpacity) private var backgroundColorOpacity = 1.0

    private var metrics: AppBackgroundMetrics {
        AppBackgroundMetrics.resolve(
            backgroundStyle: backgroundStyle,
            backgroundOpacity: backgroundOpacity,
            backgroundColorOpacity: backgroundColorOpacity
        )
    }

    var body: some View {
        if reduceTransparency, backgroundStyle == "glass" || backgroundStyle == "tinted_glass" {
            Color(nsColor: .windowBackgroundColor)
        } else {
            backgroundLayer
        }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        switch backgroundStyle {
        case "solid":
            Rectangle().fill((Color(hex: bgColorHex) ?? .black).opacity(metrics.contentOpacity))
        case "gradient":
            Rectangle().fill(
                LinearGradient(
                    colors: [
                        (Color(hex: gradientFrom) ?? .black).opacity(metrics.contentOpacity),
                        (Color(hex: gradientTo) ?? .indigo).opacity(metrics.contentOpacity)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case "glass":
            glassBackground(tint: nil)
        case "tinted_glass":
            glassBackground(tint: Color(hex: glassTintHex) ?? .indigo)
        default:
            Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(metrics.contentOpacity))
        }
    }

    @ViewBuilder
    private func glassBackground(tint: Color?) -> some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
            Color(nsColor: .windowBackgroundColor)
                .opacity(metrics.glassSurfaceOpacity)

            if let tint, metrics.glassTintOpacity > 0 {
                tint.opacity(metrics.glassTintOpacity)
            }
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
