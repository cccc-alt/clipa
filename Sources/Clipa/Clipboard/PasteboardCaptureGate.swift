import Foundation

/// Generation gate that keeps captures started before a history clear from
/// being inserted afterwards.
///
/// - `epoch` tags work that begins while a pasteboard event is inspected.
/// - `barrierChangeCount` is the pasteboard change count at the moment the
///   user starts clearing; older change counts are ignored.
struct PasteboardCaptureGate: Equatable {
    private(set) var epoch: UInt64 = 0
    private(set) var barrierChangeCount: Int?

    mutating func beginClear(at changeCount: Int) {
        epoch &+= 1
        barrierChangeCount = changeCount
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == epoch
    }

    func shouldCapture(changeCount: Int) -> Bool {
        guard let barrierChangeCount else { return true }
        return changeCount > barrierChangeCount
    }
}
