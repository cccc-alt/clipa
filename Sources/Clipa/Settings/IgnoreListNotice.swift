import Foundation

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
