import Foundation

/// 卡片正文的显示文本：按上限截断（长的补省略号）。
///
/// 这里曾经是 `ClipRowData`：一个按行缓存的结构，除了预览还存着"右键菜单该不该
/// 出现 JSON 美化 / YAML 互转"，配一套后台预热（`rowDataByClip`、
/// `scheduleRowDataPrewarm`、`pruneRowDataCache`）。那套机制的存在理由是 JSON/YAML
/// 解析——1000 行历史上要在主线程花 ~2.85s（见当时的采样记录）。
///
/// 2026-09-26 互转功能（连同 JSON 美化）删除后，这里只剩一个纯字符串函数，于是整块
/// 缓存与预热一并拆掉：**卡片渲染不再有任何解析开销**，也不再需要后台任务。
///
/// 放在这里而不是 View 的私有属性里，是为了让它**可测**：视图调它，自检也调它，
/// 所以"改了但没渲染"这种事不会悄悄通过。
enum ClipPreview {
    /// 入参上限由调用方给（卡片是 600 字符），所以每行的成本有上界。
    static func display(for text: String, limit: Int) -> String {
        // `prefix` only walks the characters it keeps, so this stays cheap even
        // for a 350 KB clip — while `text.count` (a fuller guard) scanned the
        // whole body.
        let bounded = String(text.prefix(limit))
        return bounded.count == limit ? bounded + "…" : bounded
    }
}
