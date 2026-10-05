import AppKit
import SwiftUI

enum ClipaTheme {

    enum Palette {

        static var textPrimary: Color { Color(nsColor: .labelColor) }
        static var textSecondary: Color { Color(nsColor: .secondaryLabelColor) }
        static var textTertiary: Color { Color(nsColor: .tertiaryLabelColor) }

        static var separator: Color { Color(nsColor: .separatorColor) }
        static var border: Color { Color(nsColor: .separatorColor) }
        static var borderStrong: Color { Color(nsColor: .tertiaryLabelColor) }

        static var surface: Color { Color(nsColor: .windowBackgroundColor) }

        static var surfaceShade: Color { Color(nsColor: .controlBackgroundColor) }
        static var fill: Color { Color(nsColor: .quaternaryLabelColor) }
        static var fillStrong: Color { Color(nsColor: .tertiaryLabelColor) }

        static var accent: Color { Color(nsColor: .controlAccentColor) }
        static var accentPressed: Color { Color(nsColor: .controlAccentColor).opacity(0.82) }
        static var onAccent: Color { .white }

        static var destructive: Color { Color(nsColor: .systemRed) }
        static var warning: Color { Color(nsColor: .systemOrange) }

        static var veil: Color { Color(white: 0.11) }
        static var veilDeep: Color { Color(white: 0.05) }

        static var shadow: Color { .black }
    }

    enum Metrics {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32

        static let radiusControl: CGFloat = 6
        static let radiusRow: CGFloat = 10
        static let radiusPane: CGFloat = 12

        static let headerHeight: CGFloat = 48
        static let rowHeight: CGFloat = 56
        static let footerHeight: CGFloat = 24
        static let paneInset: CGFloat = 12
    }

    enum TypeScale {
        static let micro: CGFloat = 11
        static let caption: CGFloat = 12
        static let body: CGFloat = 13
        static let title: CGFloat = 15
        static let display: CGFloat = 19
        static let hero: CGFloat = 24
    }

    enum IconSize {

        static let inline: CGFloat = 11

        static let control: CGFloat = 13

        static let tile: CGFloat = 16

        static let hero: CGFloat = 24
    }

    struct PanelShadow: ViewModifier {
        func body(content: Content) -> some View {
            content.shadow(
                color: Palette.shadow.opacity(0.18),
                radius: 24,
                y: 8
            )
        }
    }
}

extension View {
    func clipaPanelShadow() -> some View {
        modifier(ClipaTheme.PanelShadow())
    }
}
