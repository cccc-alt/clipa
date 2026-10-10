import Foundation

/// The wording used when a manually ignored app is taken off the list.
///
/// It used to live in the settings window. The status bar menu removes entries
/// now, and the subtlety it encodes still matters: an app can be listed both by
/// hand and by the password-manager rule, and dropping the manual entry does not
/// stop it being ignored. Claiming "已移除" in that case is a lie the user only
/// discovers the next time a password fails to appear in the history.
enum IgnoreListNotice {
    struct Notice: Equatable {
        var text: String
        var isWarning = false
    }

    static func removal(
        name: String,
        stillAutoIgnored: Bool
    ) -> Notice {
        guard stillAutoIgnored else { return Notice(text: "已移除 \(name)") }
        return Notice(
            text: "已从自定义列表移除 \(name)，"
                + "但它仍由“跳过密码管理器复制的内容”覆盖",
            isWarning: true
        )
    }
}
