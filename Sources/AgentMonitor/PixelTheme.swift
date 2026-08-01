import Cocoa

/// Pixel-art theme constants and drawing helpers for the AgentMonitor
/// "Pixel Art AI Control Center" UI.
///
/// All drawing disables anti-aliasing and uses integer-aligned rects so shapes
/// render with crisp, blocky pixel edges. Big titles use a bitmap-upscale
/// technique (render small → draw large with `.none` interpolation) to produce
/// authentic 8-bit chunky letters without bundling a pixel font file.
enum PixelTheme {

    // MARK: - Palette

    static let bg          = NSColor(srgbRed: 0x10/255, green: 0x10/255, blue: 0x18/255, alpha: 1)
    static let bgPanel     = NSColor(srgbRed: 0x11/255, green: 0x11/255, blue: 0x11/255, alpha: 1.0)
    static let bgCard      = NSColor(srgbRed: 0x1e/255, green: 0x1e/255, blue: 0x2a/255, alpha: 1)
    static let bgCardHi    = NSColor(srgbRed: 0x26/255, green: 0x26/255, blue: 0x34/255, alpha: 1)
    static let border      = NSColor(srgbRed: 0x40/255, green: 0x40/255, blue: 0x52/255, alpha: 1)
    static let borderBright = NSColor(srgbRed: 0x64/255, green: 0x64/255, blue: 0x82/255, alpha: 1)
    static let text        = NSColor(srgbRed: 0xe0/255, green: 0xe0/255, blue: 0xe8/255, alpha: 1)
    static let textDim     = NSColor(srgbRed: 0x70/255, green: 0x70/255, blue: 0x80/255, alpha: 1)

    // Status colors (Pixel Island spec)
    static let cRunning    = NSColor(srgbRed: 0x42/255, green: 0xE8/255, blue: 0xFF/255, alpha: 1) // cyan #42E8FF
    static let cDone       = NSColor(srgbRed: 0x55/255, green: 0xFF/255, blue: 0x88/255, alpha: 1) // green #55FF88
    static let cZCode      = NSColor(srgbRed: 0x3D/255, green: 0xE8/255, blue: 0x5F/255, alpha: 1) // zcode 专属绿 #3DE85F
    static let cIdle       = NSColor(srgbRed: 0x1A/255, green: 0x6B/255, blue: 0x7A/255, alpha: 1) // dark cyan #1A6B7A
    static let cAttention  = NSColor(srgbRed: 0xFF/255, green: 0x55/255, blue: 0x66/255, alpha: 1) // red #FF5566
    static let cOffline    = NSColor(white: 0.22, alpha: 1)

    // MARK: - Fonts

    static let bodyFont: NSFont = {
        NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
    }()
    static var boldFont: NSFont {
        NSFont(name: "Menlo-Bold", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .bold)
    }
    static let smallFont: NSFont = {
        NSFont(name: "Menlo", size: 9) ?? .monospacedSystemFont(ofSize: 9, weight: .regular)
    }()
    static var smallBold: NSFont {
        NSFont(name: "Menlo-Bold", size: 9) ?? .monospacedSystemFont(ofSize: 9, weight: .bold)
    }

    // MARK: - Drawing Primitives

    /// Fills a rect with a color, snapping to integer pixels for crisp edges.
    static func fillRect(_ rect: NSRect, color: NSColor) {
        color.setFill()
        var r = rect
        r.origin.x = round(r.origin.x)
        r.origin.y = round(r.origin.y)
        r.size.width = round(r.size.width)
        r.size.height = round(r.size.height)
        r.fill()
    }

    /// Draws a solid pixel-style rectangular border (frame) inside `rect`.
    static func drawFrame(in rect: NSRect, color: NSColor, thickness: CGFloat = 2) {
        let t = thickness
        fillRect(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: t), color: color)         // bottom
        fillRect(NSRect(x: rect.minX, y: rect.maxY - t, width: rect.width, height: t), color: color)     // top
        fillRect(NSRect(x: rect.minX, y: rect.minY, width: t, height: rect.height), color: color)        // left
        fillRect(NSRect(x: rect.maxX - t, y: rect.minY, width: t, height: rect.height), color: color)    // right
    }

    /// Draws a double-line retro console border.
    static func drawConsoleBorder(in rect: NSRect) {
        drawFrame(in: rect, color: borderBright, thickness: 2)
        let inner = rect.insetBy(dx: 4, dy: 4)
        drawFrame(in: inner, color: border, thickness: 1)
    }

    /// 半透明渐变玻璃背景(像素友好实现,不用 NSVisualEffectView/blur)。
    ///
    /// 组成:
    /// - 底色填充:传入的 `baseColor`,alpha 由调用方控制(0.6-0.85)
    /// - 顶部高光:上半部分用略亮色(~+15% lightness)的渐变,模拟玻璃反光
    /// - 内描边:1px 内描边,深色细线,强化"玻璃边缘"
    ///
    /// 调用方应在已有 `bgPanel` 实色填充之后调用,作为第二层叠加(产生层次感)。
    /// `alpha` 是基础半透明度(0=完全透明,1=完全不透明)。
    static func drawGlassBackground(in rect: NSRect, baseColor: NSColor, alpha: CGFloat) {
        let clamped = max(0.0, min(1.0, alpha))
        guard clamped > 0.001 else { return }

        // 1) 半透明底色(覆盖已有实色,产生 glass 色调)
        let baseFill = baseColor.withAlphaComponent(clamped * 0.55)
        fillRect(rect, color: baseFill)

        // 2) 顶部高光:上半部分用稍亮版本渐变(纯 NSGradient,无 blur)
        //    从顶部 alpha 较高的亮色,渐变到底部 alpha 0。
        let topStop = baseColor.blended(withFraction: 0.35, of: NSColor.white)?
            .withAlphaComponent(clamped * 0.55) ?? baseColor
        let clearStop = NSColor.clear
        let gradient = NSGradient(colors: [topStop, clearStop])
        // 上半部分 50% 高度作为高光区
        let highlightHeight = rect.height * 0.5
        let highlightRect = NSRect(x: rect.minX,
                                   y: rect.maxY - highlightHeight,
                                   width: rect.width,
                                   height: highlightHeight)
        gradient?.draw(in: highlightRect, angle: 270)  // 270° = 顶部到底部

        // 3) 内描边:1px 暗色细线(玻璃边缘)
        let innerEdge = NSColor.black.withAlphaComponent(0.35 * clamped)
        drawFrame(in: rect.insetBy(dx: 0.5, dy: 0.5), color: innerEdge, thickness: 1)
    }

    /// 像素友好内发光(无 blur/CIFilter)。用 1px 描边的多层叠加 + alpha
    /// 调制模拟"内发光":颜色由调用方传入(intensity 调制 alpha)。
    ///
    /// 实现:在 inset 1/2/3 像素处各画一圈 `color` 描边,alpha 按 1.0/
    /// 0.5/0.25 衰减,产生从内到外的"光晕"。
    ///
    /// `intensity` ∈ [0, 1] 控制整体强度;调用方根据状态传入(working
    /// 0.4、attention 0.8、completed 0.6、idle 0.15 等)。
    static func drawInnerGlow(in rect: NSRect, color: NSColor, intensity: CGFloat) {
        let clamped = max(0.0, min(1.0, intensity))
        guard clamped > 0.01 else { return }

        // 三层叠加,产生"由内向外渐弱"的视觉
        let layers: [(inset: CGFloat, alpha: CGFloat)] = [
            (1.0, 1.00),
            (2.0, 0.55),
            (3.0, 0.30)
        ]
        for (i, layer) in layers.enumerated() {
            let alpha = layer.alpha * clamped
            guard alpha > 0.01 else { continue }
            let glowColor = color.withAlphaComponent(alpha)
            drawFrame(in: rect.insetBy(dx: layer.inset, dy: layer.inset),
                      color: glowColor,
                      thickness: 1)
            // 中间额外填充一环(i == 0 时),增强中央的光感
            if i == 0 {
                let centerFill = color.withAlphaComponent(alpha * 0.35)
                fillRect(rect.insetBy(dx: layer.inset, dy: layer.inset), color: centerFill)
            }
        }
    }

    /// 8-bit cut-corner capsule — the Pixel Island container shape.
    /// Compact mode uses a large cut (≈pill), expanded mode uses a slight cut.
    static func islandPath(in rect: NSRect, cut: CGFloat = 6) -> NSBezierPath {
        let r = rect
        let c = cut
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX + c, y: r.minY))
        path.line(to: NSPoint(x: r.maxX - c, y: r.minY))
        path.line(to: NSPoint(x: r.maxX, y: r.minY + c))
        path.line(to: NSPoint(x: r.maxX, y: r.maxY - c))
        path.line(to: NSPoint(x: r.maxX - c, y: r.maxY))
        path.line(to: NSPoint(x: r.minX + c, y: r.maxY))
        path.line(to: NSPoint(x: r.minX, y: r.maxY - c))
        path.line(to: NSPoint(x: r.minX, y: r.minY + c))
        path.close()
        return path
    }

    // MARK: - Text

    /// Draws text with anti-aliasing disabled for a crisp terminal/pixel look.
    static func drawText(_ string: String,
                         in rect: NSRect,
                         font: NSFont,
                         color: NSColor,
                         alignment: NSTextAlignment = .left) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let astr = NSAttributedString(string: string, attributes: attrs)
        let size = astr.size()
        var x: CGFloat
        switch alignment {
        case .center: x = rect.midX - size.width / 2
        case .right:  x = rect.maxX - size.width
        default:      x = rect.minX
        }
        let y = rect.midY - size.height / 2
        let prevAA = NSGraphicsContext.current?.shouldAntialias
        NSGraphicsContext.current?.shouldAntialias = false
        astr.draw(at: NSPoint(x: round(x), y: round(y)))
        NSGraphicsContext.current?.shouldAntialias = prevAA ?? true
    }

    /// Draws large pixelated (8-bit) text by rendering at a small size into a
    /// low-resolution bitmap, then scaling up with nearest-neighbor interpolation.
    static func drawPixelTitle(_ string: String,
                               in rect: NSRect,
                               color: NSColor,
                               scale: CGFloat = 3) {
        let boldBase = NSFont(name: "Menlo-Bold", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: boldBase, .foregroundColor: color]
        let astr = NSAttributedString(string: string, attributes: attrs)
        let measured = astr.size()
        let tw = max(1, Int(ceil(measured.width)))
        let th = max(1, Int(ceil(measured.height)))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: tw, pixelsHigh: th,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = NSSize(width: tw, height: th)

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.shouldAntialias = false
            astr.draw(at: NSPoint(x: 0, y: 0))
        }
        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: tw, height: th))
        img.addRepresentation(rep)

        let drawH = min(rect.height, CGFloat(th) * scale)
        let drawW = CGFloat(tw) * (drawH / CGFloat(th))
        let x = rect.midX - drawW / 2
        let y = rect.midY - drawH / 2

        let prevInterp = NSGraphicsContext.current?.imageInterpolation
        NSGraphicsContext.current?.imageInterpolation = .none
        img.draw(in: NSRect(x: x, y: y, width: drawW, height: drawH),
                 from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.current?.imageInterpolation = prevInterp ?? .default
    }

    // MARK: - Progress Bar

    /// Draws a pixel-style progress bar. `fraction` 0...1.
    static func drawProgressBar(in rect: NSRect, fraction: CGFloat, color: NSColor, bgColor: NSColor) {
        let f = max(0, min(1, fraction))
        // Background
        fillRect(rect, color: bgColor)
        // Fill blocks
        let blocks = 10
        let gap: CGFloat = 1
        let blockW = (rect.width - CGFloat(blocks - 1) * gap) / CGFloat(blocks)
        let filled = Int(round(f * CGFloat(blocks)))
        for i in 0..<blocks {
            let bx = rect.minX + CGFloat(i) * (blockW + gap)
            let c = i < filled ? color : bgColor
            fillRect(NSRect(x: bx, y: rect.minY, width: blockW, height: rect.height), color: c)
        }
        // Border
        drawFrame(in: rect, color: border, thickness: 1)
    }

    // MARK: - Pixel Robot

    /// Draws a pixel robot head (avatar) in `rect`. `blink` toggles eye height.
    static func drawRobotHead(in rect: NSRect, color: NSColor, blink: Bool) {
        let s = min(rect.width, rect.height) / 10
        guard s > 1 else { return }
        let ox = rect.midX - s * 4
        let oy = rect.midY - s * 4

        // Antenna
        fillRect(NSRect(x: ox + 3.5*s, y: oy + 7.5*s, width: s, height: s*1.5), color: color)
        fillRect(NSRect(x: ox + 3*s, y: oy + 8.5*s, width: 2*s, height: s*0.6), color: cAttention)

        // Head outline (8x6 block)
        fillRect(NSRect(x: ox, y: oy + 2*s, width: 8*s, height: 5*s), color: color)

        // Screen (dark inner)
        fillRect(NSRect(x: ox + s, y: oy + 3*s, width: 6*s, height: 3*s), color: bg)

        // Eyes
        let eyeH = blink ? s * 0.3 : s * 0.9
        let eyeY = oy + 4*s + (s - eyeH) / 2
        fillRect(NSRect(x: ox + 1.8*s, y: eyeY, width: s, height: eyeH), color: color)
        fillRect(NSRect(x: ox + 5.2*s, y: eyeY, width: s, height: eyeH), color: color)

        // Mouth
        fillRect(NSRect(x: ox + 2.5*s, y: oy + 3.3*s, width: 3*s, height: s*0.35), color: color)

        // Body (shoulders)
        fillRect(NSRect(x: ox + 1*s, y: oy + 0.5*s, width: 6*s, height: 1.8*s), color: color)
        fillRect(NSRect(x: ox + 0.5*s, y: oy + 0.2*s, width: s, height: s), color: color)
        fillRect(NSRect(x: ox + 6.5*s, y: oy + 0.2*s, width: s, height: s), color: color)
    }

    /// Draws a small walking robot (full body) for animation. `frame` 0/1 alternates legs.
    static func drawWalkingRobot(in rect: NSRect, color: NSColor, frame: Int) {
        let s = min(rect.width, rect.height) / 8
        guard s > 1 else { return }
        let ox = rect.midX - s * 2.5
        let oy = rect.minY

        // Head
        fillRect(NSRect(x: ox + s, y: oy + 5*s, width: 3*s, height: 2*s), color: color)
        // Eye
        fillRect(NSRect(x: ox + (frame == 0 ? 1.3 : 1.8)*s, y: oy + 5.5*s, width: s*0.6, height: s*0.6), color: bg)
        // Body
        fillRect(NSRect(x: ox + 0.5*s, y: oy + 3*s, width: 4*s, height: 2*s), color: color)
        // Arms
        fillRect(NSRect(x: ox, y: oy + 3*s, width: s*0.7, height: 1.5*s), color: color)
        fillRect(NSRect(x: ox + 4.3*s, y: oy + 3*s, width: s*0.7, height: 1.5*s), color: color)
        // Legs (alternate)
        if frame % 2 == 0 {
            fillRect(NSRect(x: ox + 1*s, y: oy + 1*s, width: s*0.8, height: 2*s), color: color)
            fillRect(NSRect(x: ox + 3.2*s, y: oy + 1.5*s, width: s*0.8, height: 1.5*s), color: color)
        } else {
            fillRect(NSRect(x: ox + 1*s, y: oy + 1.5*s, width: s*0.8, height: 1.5*s), color: color)
            fillRect(NSRect(x: ox + 3.2*s, y: oy + 1*s, width: s*0.8, height: 2*s), color: color)
        }
    }

    /// Draws a pixel star.
    static func drawStar(in rect: NSRect, color: NSColor) {
        let s = min(rect.width, rect.height) / 5
        guard s > 1 else { return }
        let cx = rect.midX
        let cy = rect.midY
        // Cross
        fillRect(NSRect(x: cx - s*2, y: cy - s*0.3, width: s*4, height: s*0.6), color: color)
        fillRect(NSRect(x: cx - s*0.3, y: cy - s*2, width: s*0.6, height: s*4), color: color)
        // Diagonals (approx)
        fillRect(NSRect(x: cx - s*1.2, y: cy - s*1.2, width: s*0.5, height: s*0.5), color: color)
        fillRect(NSRect(x: cx + s*0.7, y: cy - s*1.2, width: s*0.5, height: s*0.5), color: color)
        fillRect(NSRect(x: cx - s*1.2, y: cy + s*0.7, width: s*0.5, height: s*0.5), color: color)
        fillRect(NSRect(x: cx + s*0.7, y: cy + s*0.7, width: s*0.5, height: s*0.5), color: color)
    }
}
