import AppKit
import SwiftUI

/// Shared native typography, semantic colors and geometry for the clipboard panel.
/// AppKit supplies the glass, menu rendering and window shadow; colors follow
/// system appearance and the user's accent color.
enum ClipaTheme {

    // MARK: - 颜色（灰阶为主 + 一个强调色）

    enum Palette {
        // 字：三级，全部来自系统
        static var textPrimary: Color { Color(nsColor: .labelColor) }
        static var textSecondary: Color { Color(nsColor: .secondaryLabelColor) }
        static var textTertiary: Color { Color(nsColor: .tertiaryLabelColor) }

        // 线与面
        static var separator: Color { Color(nsColor: .separatorColor) }
        static var border: Color { Color(nsColor: .separatorColor) }
        static var borderStrong: Color { Color(nsColor: .tertiaryLabelColor) }
        /// 面板底：盖在系统材质之上的一层**系统窗底色**，不是自调的白。
        static var surface: Color { Color(nsColor: .windowBackgroundColor) }
        /// 卡片/占位面（比面板再深一档）。
        static var surfaceShade: Color { Color(nsColor: .controlBackgroundColor) }
        static var fill: Color { Color(nsColor: .quaternaryLabelColor) }
        static var fillStrong: Color { Color(nsColor: .tertiaryLabelColor) }

        // 一色主张
        static var accent: Color { Color(nsColor: .controlAccentColor) }
        static var accentPressed: Color { Color(nsColor: .controlAccentColor).opacity(0.82) }
        static var onAccent: Color { .white }

        // 语义
        static var destructive: Color { Color(nsColor: .systemRed) }
        static var warning: Color { Color(nsColor: .systemOrange) }

        // 私密遮蔽：全站唯一刻意保留的深色 —— 它不是装饰，是"遮住"这件事本身。
        static var veil: Color { Color(white: 0.11) }
        static var veilDeep: Color { Color(white: 0.05) }

        static var shadow: Color { .black }
    }

    // MARK: - 几何（D5 归一化）

    /// 间距走 4pt 网格。代码里原来 11 个没有名字的内联值（1/2/3/7/8/10/11/14/16/24/36）
    /// 一律就近吸附到这一组。
    enum Metrics {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32

        /// 圆角只留三档。原来有 8 档（4/5/7/8/9/10/13/20）。
        static let radiusControl: CGFloat = 8
        static let radiusRow: CGFloat = 10
        static let radiusPane: CGFloat = 22

        static let headerHeight: CGFloat = 64
        static let rowHeight: CGFloat = 60
        static let footerHeight: CGFloat = 34
        static let paneInset: CGFloat = 12
    }

    // MARK: - 字阶（D5 归一化：六档）

    /// 原来是 16 个不同字号（9 … 24），没有系统。现在固定六档。
    enum TypeScale {
        static let micro: CGFloat = 11
        static let caption: CGFloat = 12
        static let body: CGFloat = 13
        static let title: CGFloat = 15
        static let display: CGFloat = 19
        static let hero: CGFloat = 24
    }

    // MARK: - 图标尺寸（另一条轴：光学尺寸，不套字阶）

    /// 图标不跟随字阶 —— 它按视觉重量调，四档就够。
    /// 原来散落在 9 / 11 / 12 / 13.5 / 14 / 15 / 16 / 18 / 24 / 28 十个值上。
    enum IconSize {
        /// 行内小记号（chip 类型图标、输入框前导、行尾按钮）。
        static let inline: CGFloat = 11
        /// 控件内图标（工具栏按钮、清除、锁、编辑）。
        static let control: CGFloat = 13
        /// 面内元素（头部标记、缩略图字形、占位图）。
        static let tile: CGFloat = 16
        /// 空态 / 状态页的主图标。
        static let hero: CGFloat = 24
    }

    // MARK: - 高度（只有一个浮起层 + 一个聚焦环）

    /// 面板是唯一浮起的东西；行、卡片、按钮不投影。
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
