import Foundation
import LocalAuthentication

enum PrivateCoverDisclosure {

    static let note = "已加密存储：正文与备注以密文保存在本机数据库，"
        + "密钥在本机钥匙串、不随备份或同步离开这台机器"
        + "（把数据库恢复到别的机器上读不回来，正是它的代价）。"
        + "私密内容（含图片）不参与搜索。"

    static let toast = "已设为私密：正文已加密存储，仅本机可解"

    static let lockCardDetail = "已加密 · 仅本机可解"
}

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

                let now = Date()
                self.unlockDeadlines = self.unlockDeadlines.filter { $0.value > now }
                self.unlockDeadlines[id] = now.addingTimeInterval(self.unlockWindow)
            }
            completion(ok)
        }
    }

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
