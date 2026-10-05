import Foundation

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
