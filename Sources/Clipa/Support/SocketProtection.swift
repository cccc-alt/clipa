import Foundation

/// P0 修复（2026-10-02）：往已断开对端的 socket 上 `send`/`write` 会触发
/// SIGPIPE，默认处置是**终止整个进程**——本地接口的服务端被一个超时就断开的
/// 客户端（Agent 很常见）杀死，剪贴板记录、在途请求全部陪葬。
///
/// 设 `SO_NOSIGPIPE` 后写失败改为返回 EPIPE，调用方按普通读写失败处理。
/// main.swift 另有 `signal(SIGPIPE, SIG_IGN)` 兜底非 socket 的管道写；
/// 两道闸互为保险，自检把两个分支都钉住。
enum SocketProtection {
    /// 给 fd 关掉 SIGPIPE。返回是否设置成功。
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
