import Foundation
import LocalAuthentication

/// The wording that keeps the "private" feature honest.
///
/// Product decision (2026-09-16): private is a display-level cover, not
/// protection. The only thing standing between that decision and a user
/// believing the opposite is saying so where they actually look — the lock
/// card, the Settings note next to the data directory, and the toast shown at
/// the moment they mark something private. Keeping the sentences in one place
/// is what stops one surface from quietly losing the qualifier.
enum PrivateCoverDisclosure {
    /// Lock card + Settings note. Both surfaces need the full sentence.
    ///
    /// 三句话对应三件用户会踩到的事：加密了什么、代价是什么、搜索行为。
    /// 少任何一句都会让这句话变成"感觉更安全"的营销词。
    /// （2026-10-04：图片字节自 seal 事务化后全部落盘即密——legacy 导入
    /// 亦同，"暂未加密"的旧说明已不再属实，删除。）
    static let note = "已加密存储：正文与备注以密文保存在本机数据库，"
        + "密钥在本机钥匙串、不随备份或同步离开这台机器"
        + "（把数据库恢复到别的机器上读不回来，正是它的代价）。"
        + "私密内容（含图片）不参与搜索。"
    /// Toast shown when an item is marked private.
    static let toast = "已设为私密：正文已加密存储，仅本机可解"
    /// 锁卡片上那行小字。比 `note` 短——卡片里放不下整句，但放进来的这句
    /// 也必须是真话（原先是"仅遮挡，不加密"）。
    static let lockCardDetail = "已加密 · 仅本机可解"
}

/// System authentication (Touch ID / password) used to unlock private clips.
///
/// Unlock state is tracked per clip id: authenticating for one private item
/// must not unlock the other private items, and items set to private later
/// start locked again.
///
/// 2026-09-26（M3）之后它挡的不只是肩窥：私密正文在库里是密文，解锁是"让应用去
/// 解密并显示"的开始，锁着的时候卡片**拿不到正文**，而不是拿到之后盖住。所以
/// 这里不再写成"仅遮挡显示"。
///
/// 仍然挡不住什么（别把它说成保险箱）：应用以你的身份运行时，进程内存里有明文；
/// 图片字节与派生的快捷片段这一版还没加密（见 `StoreCrypto`）。
final class PrivacyGate {
    static let shared = PrivacyGate()

    private let unlockWindow: TimeInterval = 60
    private var unlockDeadlines: [UUID: Date] = [:]

    func isUnlocked(_ id: UUID) -> Bool {
        guard let deadline = unlockDeadlines[id] else { return false }
        return deadline > Date()
    }

    func markLocked(_ id: UUID? = nil) {
        if let id {
            unlockDeadlines[id] = nil
        } else {
            unlockDeadlines.removeAll()
        }
    }

    func requestUnlock(
        for id: UUID,
        reason: String = "解锁 Clipa 私密内容",
        completion: @escaping (Bool) -> Void
    ) {
        if isUnlocked(id) {
            completion(true)
            return
        }
        requestAuthentication(reason: reason) { [weak self] ok in
            guard let self else { return }
            if ok {
                // Drop already-expired entries to keep the map small.
                let now = Date()
                self.unlockDeadlines = self.unlockDeadlines.filter { $0.value > now }
                self.unlockDeadlines[id] = now.addingTimeInterval(self.unlockWindow)
            }
            completion(ok)
        }
    }

    /// Requests a fresh system authentication every time. Used for guarded
    /// actions such as removing private protection, where an earlier unlock
    /// within the 60-second viewing window must not be reused.
    func requestAuthentication(
        reason: String = "验证 Clipa 私密内容",
        completion: @escaping (Bool) -> Void
    ) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async {
                completion(ok)
            }
        }
    }
}
