// Abstract:
// One look for the whole app (docs/design-ui-2026-10.md): a warm light-grey
// ground with solid white cards, one accent (amber, the overlay's colour),
// tinted tags instead of black pills, SF Pro Rounded. Every window, page and
// row is built from the pieces here, so sizes, colours and wording of
// sections stay the same everywhere.

import AppKit
import SwiftUI

enum Theme {
    // MARK: Colours (light / dark)

    static let ground = dynamic(light: 0xF4F3F1, dark: 0x1E1E1F)
    static let sidebar = dynamic(light: 0xECEBE8, dark: 0x262627)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x2B2B2D)
    static let card2 = dynamic(light: 0xF8F7F5, dark: 0x323234)
    static let line = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.07)
    })
    static let line2 = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.12)
    })
    static let hover = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.04)
    })
    static let selection = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.065)
    })

    /// The one accent — the overlay's amber. Used for the selected page,
    /// primary buttons, the option in use and progress; nothing else.
    static let accent = Color(red: 0.961, green: 0.627, blue: 0.039)
    static let accentNS = NSColor(srgbRed: 0.961, green: 0.627, blue: 0.039, alpha: 1)
    /// Amber dark enough to read as text on a light card.
    static let accentText = dynamic(light: 0xA86A00, dark: 0xFFBE4D)

    static let green = Color(red: 0.184, green: 0.659, blue: 0.310)
    static let red = Color(red: 0.898, green: 0.282, blue: 0.302)
    static let blue = Color(red: 0.184, green: 0.486, blue: 0.965)
    static let violet = Color(red: 0.541, green: 0.388, blue: 0.824)

    // MARK: Type

    static let pageTitle = Font.system(size: 26, weight: .bold, design: .rounded)
    static let bigNumber = Font.system(size: 24, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 13.5, design: .rounded)
    static let bodyEmphasis = Font.system(size: 13.5, weight: .semibold, design: .rounded)
    static let caption = Font.system(size: 12, design: .rounded)
    static let small = Font.system(size: 11, design: .rounded)
    static let sectionTitle = Font.system(size: 12.5, weight: .semibold, design: .rounded)

    static let cardRadius: CGFloat = 14
    static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.isDark ? dark : light)
        })
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Card

struct CardBackground: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 0.5)
            )
    }
}

extension View {
    /// A solid white (dark: graphite) card with a hairline edge.
    func card(radius: CGFloat = Theme.cardRadius) -> some View {
        modifier(CardBackground(radius: radius))
    }
}

// MARK: - Page header

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.pageTitle)
                if let subtitle {
                    Text(subtitle).font(Theme.body).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Grey section title above a card.
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.sectionTitle)
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

// MARK: - Tag

/// A small tinted label: the colour at ~14 % behind text in that colour.
struct Tag: View {
    enum Tint { case neutral, accent, green, red, blue, violet }
    let text: String
    var tint: Tint = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(background, in: .rect(cornerRadius: 5, style: .continuous))
    }

    private var foreground: Color {
        switch tint {
        case .neutral: .secondary
        case .accent: Theme.accentText
        case .green: Theme.green
        case .red: Theme.red
        case .blue: Theme.blue
        case .violet: Theme.violet
        }
    }

    private var background: Color {
        switch tint {
        case .neutral: Theme.hover
        case .accent: Theme.accent.opacity(0.15)
        case .green: Theme.green.opacity(0.14)
        case .red: Theme.red.opacity(0.13)
        case .blue: Theme.blue.opacity(0.13)
        case .violet: Theme.violet.opacity(0.14)
        }
    }
}

// MARK: - Key cap

struct KeyCap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .frame(minWidth: 21, minHeight: 21)
            .background(Theme.card, in: .rect(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.line2, lineWidth: 0.5))
            .shadow(color: Theme.line2, radius: 0, y: 1)
    }
}

// MARK: - Buttons

/// Square icon button with a card background, for detail headers.
struct IconButton: View {
    let systemImage: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(role == .destructive && hovering ? Theme.red : .secondary)
                .frame(width: 30, height: 28)
                .background(hovering ? Theme.hover : Theme.card, in: .rect(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line2, lineWidth: 0.5))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

/// The accent-filled primary button (one per page at most).
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: 7, style: .continuous))
    }
}

/// A plain card-coloured button.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? Theme.hover : Theme.card, in: .rect(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line2, lineWidth: 0.5))
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

// MARK: - Pills (segmented filter)

struct Pills<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Text(label)
                    .font(.system(size: 12, weight: on ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(on ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3.5)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.card)
                                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line2, lineWidth: 0.5))
                        }
                    }
                    .contentShape(.rect)
                    .onTapGesture { withAnimation(Theme.ease) { selection = value } }
            }
        }
        .padding(2)
        .background(Theme.hover, in: .rect(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Settings rows

/// A rounded group of settings rows with hairline dividers between them.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionTitle(text: title) }
            VStack(spacing: 0) {
                Group(subviews: content()) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                        if index > 0 { Divider().overlay(Theme.line).padding(.leading, 16) }
                        subview
                    }
                }
            }
            .card(radius: 12)
        }
    }
}

/// "Name + one line of explanation + control".
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium, design: .rounded))
                if let detail {
                    Text(detail)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 54)
    }
}

/// Empty or not-found state inside a page.
struct EmptyState: View {
    let systemImage: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(Theme.bodyEmphasis)
            if let message {
                Text(message).font(Theme.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 280)
        .padding(30)
    }
}
