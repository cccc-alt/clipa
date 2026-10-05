import Foundation

enum SocketProtection {

    @discardableResult
    static func disableSigPipe(_ fd: Int32) -> Bool {
        var one: Int32 = 1
        return setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &one,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0
    }
}
