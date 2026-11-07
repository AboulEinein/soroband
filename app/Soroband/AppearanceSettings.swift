import AppKit
import SwiftUI

/// Settings › Appearance, in the UI process: the windows' theme, light or dark and their accent
/// color. Every change goes to the core's settings at once (`Usage.setSetting`), as
/// `soroband config set` would, and every window follows it.
struct AppearanceSettings: View {
    let theme: Theme
    let set: (String, String) -> Void

    var body: some View {
        SettingsPage(
            title: "Appearance",
            subtitle: "How Soroband’s windows look. The island at the notch always stays dark."
        ) {
            SettingsSection(title: "Theme") {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Appearance")
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(Appearance.allCases) { appearance in
                                AppearanceCard(
                                    appearance: appearance, isSelected: appearance == theme.appearance,
                                    select: { set(Appearance.settingKey, appearance.rawValue) })
                            }
                        }
                    }
                    .padding(14)
                    Divider().padding(.leading, 14)
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accent color")
                            Text(accentNote).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(alignment: .top, spacing: 4) {
                            ForEach(Accent.allCases) { accent in
                                AccentSwatch(
                                    accent: accent, isSelected: accent == theme.accent,
                                    select: { set(Accent.settingKey, accent.rawValue) })
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private var accentNote: String {
        theme.accent == .system
            ? "macOS’s accent color, as set in System Settings."
            : "\(theme.accent.label), from Soroband’s icons, on what Soroband draws: selections, cards and highlights."
    }
}

/// An appearance to choose, drawn as a small window in it; System is half light, half dark.
private struct AppearanceCard: View {
    let appearance: Appearance
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                    .frame(height: 74)
                    .clipShape(.rect(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    Text(appearance.label).fontWeight(.semibold)
                }
                .padding(.top, 8).padding(.horizontal, 4).padding(.bottom, 2)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsColor.card, in: .rect(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.08)),
                        lineWidth: isSelected ? 2 : 0.5)
            )
            .contentShape(.rect(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(appearance.label) appearance")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var preview: some View {
        switch appearance {
        case .light: WindowSketch().environment(\.colorScheme, .light)
        case .dark: WindowSketch().environment(\.colorScheme, .dark)
        case .system:
            WindowSketch().environment(\.colorScheme, .light)
                .overlay {
                    WindowSketch().environment(\.colorScheme, .dark)
                        .mask { HalfPlane() }
                }
        }
    }
}

/// A window in miniature: a sidebar with a selected row, and a card with a switch, in the
/// accent color of the colorScheme it is drawn in.
private struct WindowSketch: View {
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(.tint).frame(width: 30, height: 6)
                Capsule().fill(line).frame(width: 24, height: 4)
                Capsule().fill(line).frame(width: 28, height: 4)
                Spacer(minLength: 0)
            }
            .padding(8).padding(.top, 6)
            .frame(width: 46, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(dark ? Color(white: 0.16) : Color(white: 0.89))
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(line.opacity(1.6)).frame(width: 40, height: 5)
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(line).frame(width: 34, height: 4)
                        Capsule().fill(line).frame(width: 24, height: 4)
                    }
                    Spacer(minLength: 0)
                    Capsule().fill(.tint).frame(width: 16, height: 9)
                }
                .padding(6)
                .background(dark ? Color(white: 0.2) : .white, in: .rect(cornerRadius: 4))
                Spacer(minLength: 0)
            }
            .padding(8).padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(dark ? Color(white: 0.12) : Color(white: 0.93))
        }
        .accessibilityHidden(true)
    }

    private var line: Color { dark ? Color(white: 1, opacity: 0.22) : Color(white: 0, opacity: 0.16) }
}

/// The right half of a rectangle, cut on a slant, for System's preview.
private struct HalfPlane: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX + rect.height * 0.2, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX - rect.height * 0.2, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// An accent color to choose, labeled by name: some colors are close to each other, so no swatch
/// stands without its label (as `NetworkColorPicker`'s).
private struct AccentSwatch: View {
    let accent: Accent
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 5) {
                Circle()
                    .fill(fill)
                    .frame(width: 22, height: 22)
                    .overlay {
                        if isSelected {
                            Circle().fill(.white).frame(width: 8, height: 8)
                        }
                    }
                    .padding(3)
                    .overlay(
                        Circle().strokeBorder(isSelected ? AnyShapeStyle(fill) : AnyShapeStyle(.clear), lineWidth: 2))
                Text(accent.label)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(accent.label)
        .accessibilityLabel("\(accent.label) accent color")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// System shows macOS's own accent color, whatever the windows are tinted with.
    private var fill: Color { accent.color ?? Color(nsColor: .controlAccentColor) }
}
