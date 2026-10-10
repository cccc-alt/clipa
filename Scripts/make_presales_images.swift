import AppKit

let canvasWidth: CGFloat = 1600
let canvasHeight: CGFloat = 1000

struct Feature {
    let index: String
    let eyebrow: String
    let title: String
    let subtitle: String
    let bullets: [String]
    let screenshotPath: String
    let outputPath: String
    let accent: NSColor
}

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

func drawText(
    _ text: String,
    in rect: NSRect,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    textColor: NSColor,
    alignment: NSTextAlignment = .left
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineSpacing = 4
    let font = NSFont(name: "PingFangSC-Semibold", size: size)
        ?? NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor,
        .paragraphStyle: paragraph
    ]
    (text as NSString).draw(in: rect, withAttributes: attrs)
}

func makeCard(_ feature: Feature) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasWidth),
        pixelsHigh: Int(canvasHeight),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        print("无法创建画布")
        exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        exit(1)
    }
    NSGraphicsContext.current = context

    let background = NSGradient(
        starting: color(0xFAFBFF),
        ending: color(0xEDF1FA)
    )!
    background.draw(
        in: NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight),
        angle: -75
    )

    // Decorative circles
    let accentSoft = feature.accent.withAlphaComponent(0.10)
    accentSoft.setFill()
    NSBezierPath(
        ovalIn: NSRect(x: -180, y: 750, width: 480, height: 480)
    ).fill()
    feature.accent.withAlphaComponent(0.07).setFill()
    NSBezierPath(
        ovalIn: NSRect(x: 1260, y: -240, width: 520, height: 520)
    ).fill()

    let leftX: CGFloat = 72
    let textWidth: CGFloat = 470

    // Brand + index
    let brand = NSMutableAttributedString(
        string: "Clipa",
        attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: color(0x334155)
        ]
    )
    brand.draw(at: NSPoint(x: leftX, y: canvasHeight - 74))

    let indexText = NSMutableAttributedString(
        string: feature.index + " / 05",
        attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: color(0x94A3B8)
        ]
    )
    let indexWidth = indexText.size().width
    indexText.draw(
        at: NSPoint(
            x: canvasWidth - 74 - indexWidth,
            y: canvasHeight - 66
        )
    )

    // Eyebrow pill
    let pillRect = NSRect(
        x: leftX,
        y: canvasHeight - 220,
        width: 118,
        height: 30
    )
    feature.accent.withAlphaComponent(0.12).setFill()
    NSBezierPath(
        roundedRect: pillRect,
        xRadius: 15,
        yRadius: 15
    ).fill()
    drawText(
        feature.eyebrow,
        in: NSRect(
            x: pillRect.minX + 16,
            y: canvasHeight - 218,
            width: pillRect.width - 32,
            height: 24
        ),
        size: 12,
        weight: .semibold,
        textColor: feature.accent,
        alignment: .center
    )

    // Title + subtitle
    drawText(
        feature.title,
        in: NSRect(
            x: leftX,
            y: canvasHeight - 330,
            width: textWidth,
            height: 110
        ),
        size: 37,
        weight: .bold,
        textColor: color(0x1E293B)
    )
    drawText(
        feature.subtitle,
        in: NSRect(
            x: leftX,
            y: canvasHeight - 440,
            width: textWidth - 12,
            height: 60
        ),
        size: 17,
        weight: .regular,
        textColor: color(0x64748B)
    )

    // Bullets
    var bulletY = canvasHeight - 570
    for bullet in feature.bullets {
        feature.accent.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: leftX + 2, y: bulletY - 8, width: 8, height: 8)
        ).fill()
        drawText(
            bullet,
            in: NSRect(
                x: leftX + 24,
                y: bulletY - 30,
                width: textWidth - 24,
                height: 26
            ),
            size: 15,
            weight: .regular,
            textColor: color(0x475569)
        )
        bulletY -= 54
    }

    // Footer
    drawText(
        "本地优先 · 数据不出本机 · 纯本地检索",
        in: NSRect(
            x: leftX,
            y: 46,
            width: textWidth,
            height: 20
        ),
        size: 12,
        weight: .regular,
        textColor: color(0x94A3B8)
    )

    // Screenshot
    if let screenshot = NSImage(contentsOfFile: feature.screenshotPath) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()

        let imageRect = NSRect(
            x: 618,
            y: 162,
            width: 900,
            height: 620
        )
        let path = NSBezierPath(
            roundedRect: imageRect,
            xRadius: 22,
            yRadius: 22
        )
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        screenshot.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    // Accent frame around screenshot
    feature.accent.withAlphaComponent(0.14).setStroke()
    let framePath = NSBezierPath(
        roundedRect: NSRect(
            x: 616,
            y: 160,
            width: 904,
            height: 624
        ),
        xRadius: 24,
        yRadius: 24
    )
    framePath.lineWidth = 1
    framePath.stroke()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("PNG 编码失败: \(feature.outputPath)")
        exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: feature.outputPath))
    print("已生成 \(feature.outputPath)")
}

let blue = color(0x4F7CFF)
let purple = color(0x8B5CF6)
let green = color(0x10B981)
let cyan = color(0x06B6D4)
let red = color(0xEF4444)

let features: [Feature] = [
    Feature(
        index: "01",
        eyebrow: "智能历史",
        title: "每一次复制，\n都成为可检索资产",
        subtitle: "自动记录与去重，正文、备注与来源统一管理",
        bullets: [
            "正文 + 备注全文检索，秒级找回",
            "类型、置顶、暂停、删除，操作一目了然",
            "纯本地 SQLite 存储，数据不出本机"
        ],
        screenshotPath: "docs/presales/raw/history.png",
        outputPath: "docs/presales/clipa-01-smart-history.png",
        accent: blue
    ),
    Feature(
        index: "02",
        eyebrow: "全文检索",
        title: "像聊天一样描述，\n精准找回内容",
        subtitle: "正文与备注一起搜，中文子串、代码、URL 都按字面命中",
        bullets: [
            "SQLite FTS5 索引，十万条历史也是秒回",
            "不联网：全部检索都在本机完成",
            "无需账号、无需 Key，开箱即用"
        ],
        screenshotPath: "docs/presales/raw/ai-search.png",
        outputPath: "docs/presales/clipa-02-ai-search.png",
        accent: purple
    ),
    Feature(
        index: "03",
        eyebrow: "智能识别",
        title: "内容一进来，\n就被正确分类",
        subtitle: "文本 / JSON / YAML / Markdown / 图片 / 文件六类",
        bullets: [
            "JSON / YAML / Markdown 结构化格式自动识别",
            "链接、代码、日志、命令等归入文本，不误判",
            "smartTag 过滤让搜索更精准"
        ],
        screenshotPath: "docs/presales/raw/classification.png",
        outputPath: "docs/presales/clipa-03-smart-classification.png",
        accent: green
    ),
    Feature(
        index: "05",
        eyebrow: "隐私保护",
        title: "敏感内容，\n只留在本地",
        subtitle: "密码、Token、私密内容自动识别与锁定",
        bullets: [
            "Touch ID / Mac 密码验证解锁",
            "60 秒自动重新上锁",
            "API Key、私钥、Token 可自动跳过记录"
        ],
        screenshotPath: "docs/presales/raw/privacy.png",
        outputPath: "docs/presales/clipa-05-privacy.png",
        accent: red
    )
]

for feature in features {
    makeCard(feature)
}
