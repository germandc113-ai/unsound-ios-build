import SwiftUI
import UIKit

enum USTheme {
    static let background = Color.black
    static let panel = Color(red: 0.012, green: 0.010, blue: 0.014)
    static let panel2 = Color(red: 0.040, green: 0.018, blue: 0.026)
    static let accent = Color(red: 0.98, green: 0.055, blue: 0.13)
    static let accentDeep = Color(red: 0.34, green: 0.008, blue: 0.036)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.36)
    static let hairline = Color.white.opacity(0.085)
}

extension Color {
    static func unsoundHex(_ rawValue: String, fallback: Color = USTheme.accent) -> Color {
        let cleaned = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else {
            return fallback
        }

        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    var unsoundHexString: String {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#FA0E21"
        }

        return String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
    }
}

struct USBackdrop: View {
    var body: some View {
        ZStack {
            Color.black

            RadialGradient(
                colors: [USTheme.accentDeep.opacity(0.32), .clear],
                center: UnitPoint(x: 0.92, y: 0.02),
                startRadius: 18,
                endRadius: 390
            )

            RadialGradient(
                colors: [Color.white.opacity(0.035), .clear],
                center: UnitPoint(x: 0.10, y: 0.42),
                startRadius: 10,
                endRadius: 260
            )

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.16), USTheme.accentDeep.opacity(0.06)],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

struct BrandFooter: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("POWERED BY")
                .foregroundStyle(USTheme.tertiary)
            Text("unseen.ug")
                .foregroundStyle(.white.opacity(0.74))
            Text("/")
                .foregroundStyle(USTheme.tertiary)
            Text("Adrian")
                .foregroundStyle(USTheme.accent.opacity(0.92))
        }
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .tracking(1.15)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct USPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.972 : 1)
            .brightness(configuration.isPressed ? 0.035 : 0)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

extension View {
    @ViewBuilder
    func usGlass<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                self
                    .glassEffect(Glass.regular.tint(tint).interactive(), in: shape)
                    .overlay(
                        shape.stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.22),
                                    Color.white.opacity(0.055),
                                    (tint ?? USTheme.accent).opacity(0.14)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.72
                        )
                    )
                    .shadow(color: (tint ?? Color.white).opacity(0.055), radius: 12, y: 5)
            } else {
                self
                    .glassEffect(Glass.regular.tint(tint), in: shape)
                    .overlay(
                        shape.stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18), Color.white.opacity(0.035)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.7
                        )
                    )
            }
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background((tint ?? Color.clear).opacity(0.14), in: shape)
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.045)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                )
                .shadow(color: (tint ?? Color.white).opacity(0.05), radius: 10, y: 5)
        }
    }
}
