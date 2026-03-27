import SwiftUI

// MARK: - Math Helpers

private func lcg(_ s: UInt64) -> Double {
    let r = s &* 6364136223846793005 &+ 1442695040888963407
    return Double(r >> 33) / Double(1 << 31)
}
private func breathe(_ t: Double, period: Double = 4.0, phase: Double = 0) -> Double {
    (1 + sin((t + phase) * 2 * .pi / period)) * 0.5
}
private func lp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
private func cr(_ cx: Double, _ cy: Double, _ r: Double) -> CGRect {
    CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
}
private func eio(_ t: Double) -> Double {
    let x = max(0, min(1, t))
    return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
}
private func midpt(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
}

// MARK: - Liquid Glass Primitives

/// 平滑闭合曲线（二次贝塞尔穿点法）
private func smoothLoop(_ pts: [CGPoint]) -> Path {
    guard pts.count >= 3 else { return Path() }
    var p = Path()
    let n = pts.count
    p.move(to: midpt(pts[n-1], pts[0]))
    for i in 0..<n {
        p.addQuadCurve(to: midpt(pts[i], pts[(i+1) % n]), control: pts[i])
    }
    p.closeSubpath()
    return p
}

/// 有机液态泡泡轮廓：圆 + 双频正弦扰动
private func liquidBlob(cx: Double, cy: Double, r: Double, t: Double,
                        amp: Double = 0.055, seed: Double = 0) -> Path {
    let n = 14
    var pts: [CGPoint] = []
    for i in 0..<n {
        let a  = Double(i) / Double(n) * 2 * .pi
        let w1 = sin(t * 1.10  + a * 3 + seed) * amp
        let w2 = sin(t * 0.67 * 1.618 + a * 5 + seed * 1.4) * amp * 0.45
        let rr = r * (1 + w1 + w2)
        pts.append(CGPoint(x: cx + cos(a) * rr, y: cy + sin(a) * rr))
    }
    return smoothLoop(pts)
}

/// 绘制液态玻璃球体
/// - 磨砂填充 + 轮廓细线 + 焦散亮核 + 主/次高光弧 + 折射内线 + 外围辉光
private func paintGlass(_ ctx: GraphicsContext, cx: Double, cy: Double,
                        r: Double, color: Color, t: Double,
                        amp: Double = 0.055, alpha: Double = 1.0, seed: Double = 0) {
    let body = liquidBlob(cx: cx, cy: cy, r: r, t: t, amp: amp, seed: seed)
    // 磨砂玻璃体
    ctx.fill(body, with: .color(color.opacity(0.11 * alpha)))
    // 玻璃轮廓
    ctx.stroke(body, with: .color(.white.opacity(0.13 * alpha)), lineWidth: 0.7)
    // 内部焦散核（偏左上白亮斑）
    ctx.fill(Path(ellipseIn: cr(cx - r*0.11, cy - r*0.13, r*0.36)),
             with: .color(.white.opacity(0.12 * alpha)))
    // 主高光弧（左上 ~105°）
    var rim = Path()
    rim.addArc(center: CGPoint(x: cx, y: cy), radius: r * 0.87,
               startAngle: .degrees(-150), endAngle: .degrees(-48), clockwise: false)
    ctx.stroke(rim, with: .color(.white.opacity(0.38 * alpha)), lineWidth: 0.85)
    // 次高光弧（右下）
    var rim2 = Path()
    rim2.addArc(center: CGPoint(x: cx, y: cy), radius: r * 0.78,
                startAngle: .degrees(25), endAngle: .degrees(65), clockwise: false)
    ctx.stroke(rim2, with: .color(.white.opacity(0.14 * alpha)), lineWidth: 0.45)
    // 折射内线
    let ra = t * 0.17 + seed
    var refr = Path()
    refr.move(to:    CGPoint(x: cx + cos(ra) * r * 0.50,
                             y: cy + sin(ra) * r * 0.50))
    refr.addLine(to: CGPoint(x: cx + cos(ra + .pi*0.62) * r * 0.38,
                             y: cy + sin(ra + .pi*0.62) * r * 0.38))
    ctx.stroke(refr, with: .color(.white.opacity(0.07 * alpha)), lineWidth: 0.3)
    // 外围辉光
    ctx.fill(Path(ellipseIn: cr(cx, cy, r * 1.55)),
             with: .color(color.opacity(0.04 * alpha)))
}

/// 玻璃纤维连线（两点间，可指定进度与透明度）
private func paintGlassThread(_ ctx: GraphicsContext,
                               x1: Double, y1: Double, x2: Double, y2: Double,
                               color: Color, progress: Double = 1.0, alpha: Double = 0.5) {
    guard progress > 0 else { return }
    let tx = lp(x1, x2, progress), ty = lp(y1, y2, progress)
    var path = Path()
    path.move(to:    CGPoint(x: x1, y: y1))
    path.addLine(to: CGPoint(x: tx, y: ty))
    ctx.stroke(path, with: .color(color.opacity(0.16 * alpha)), lineWidth: 0.8)
    // 玻璃折射中心亮线
    ctx.stroke(path, with: .color(.white.opacity(0.08 * alpha)), lineWidth: 0.3)
}

// MARK: - PhaseBackgroundView
// 液态玻璃风格：点阵网格基底 + 氛围光晕 + 算法对应玻璃体动画

struct PhaseBackgroundView: View {
    let phase: String
    let animationRate: Double

    private var palette: (Color, Color, Color) {
        switch true {
        case phase.hasPrefix("📁"):
            return (.init(red:0.50, green:0.65, blue:0.92),
                    .init(red:0.28, green:0.38, blue:0.72),
                    .init(red:0.78, green:0.88, blue:1.00))
        case phase.hasPrefix("📝"):
            return (.init(red:0.95, green:0.82, blue:0.52),
                    .init(red:0.70, green:0.52, blue:0.20),
                    .init(red:1.00, green:0.94, blue:0.72))
        case phase.hasPrefix("🔗"):
            return (.init(red:0.58, green:0.20, blue:0.98),
                    .init(red:0.88, green:0.24, blue:0.62),
                    .init(red:0.72, green:0.50, blue:1.00))
        case phase.hasPrefix("🔍"):
            return (.init(red:0.15, green:0.42, blue:1.00),
                    .init(red:0.05, green:0.18, blue:0.72),
                    .init(red:0.38, green:0.68, blue:1.00))
        case phase.hasPrefix("🔀"):
            return (.init(red:0.05, green:0.68, blue:0.78),
                    .init(red:0.02, green:0.38, blue:0.58),
                    .init(red:0.28, green:0.95, blue:0.92))
        case phase.hasPrefix("🧮"):
            return (.init(red:0.10, green:0.70, blue:0.45),
                    .init(red:0.03, green:0.38, blue:0.50),
                    .init(red:0.32, green:0.98, blue:0.68))
        case phase.hasPrefix("👀"):
            return (.init(red:0.98, green:0.48, blue:0.10),
                    .init(red:0.75, green:0.22, blue:0.14),
                    .init(red:1.00, green:0.76, blue:0.35))
        case phase.hasPrefix("⚖️"):
            return (.init(red:0.12, green:0.82, blue:0.62),
                    .init(red:0.05, green:0.48, blue:0.70),
                    .init(red:0.48, green:1.00, blue:0.80))
        default:
            return (.init(red:0.50, green:0.65, blue:0.92),
                    .init(red:0.28, green:0.38, blue:0.72),
                    .init(red:0.78, green:0.88, blue:1.00))
        }
    }

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                render(ctx, size: size, t: tl.date.timeIntervalSinceReferenceDate)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }

    // MARK: - Main Render

    private func render(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let W = size.width, H = size.height
        let cx = W / 2, cy = H / 2
        let base = min(W, H)
        let (c1, c2, _) = palette

        // 1. 深色基底
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(.init(red: 0.030, green: 0.034, blue: 0.075)))

        // 2. 点阵网格（液态玻璃空间感）
        drawDotGrid(ctx, W: W, H: H, color: c1)

        // 3. 背景氛围光晕（2个缓慢漂移的大球，只用辉光）
        let a1 = t / 28.0 * .pi * 2
        let hx1 = cx + cos(a1 * 0.618) * W * 0.20
        let hy1 = cy + sin(a1 * 0.786) * H * 0.15
        let a2 = t / 19.0 * .pi * 2 + 2.1
        let hx2 = cx + cos(a2 * 0.910) * W * 0.18
        let hy2 = cy + sin(a2 * 0.618) * H * 0.18
        ctx.fill(Path(ellipseIn: cr(hx1, hy1, base * 0.40)),
                 with: .color(c1.opacity(0.055)))
        ctx.fill(Path(ellipseIn: cr(hx2, hy2, base * 0.30)),
                 with: .color(c2.opacity(0.045)))

        // 4. 算法可视化：液态玻璃主体
        switch true {
        case phase.hasPrefix("📁"): drawBubbleForest(ctx, W: W, H: H, t: t)
        case phase.hasPrefix("📝"): drawPairedDrops(ctx, W: W, H: H, t: t)
        case phase.hasPrefix("🔗"): drawGlassFilaments(ctx, W: W, H: H, t: t)
        case phase.hasPrefix("🔍"): drawGlassLens(ctx, cx: cx, cy: cy, W: W, H: H, t: t)
        case phase.hasPrefix("🔀"): drawBubbleMerge(ctx, cx: cx, cy: cy, W: W, H: H, t: t)
        case phase.hasPrefix("🧮"): drawGlassPrism(ctx, cx: cx, cy: cy, base: base, t: t)
        case phase.hasPrefix("👀"): drawSimilarBubbles(ctx, W: W, H: H, t: t)
        case phase.hasPrefix("⚖️"): drawQualityFloat(ctx, cx: cx, cy: cy, W: W, H: H, t: t)
        default: break
        }
    }

    // MARK: - Background

    private func drawDotGrid(_ ctx: GraphicsContext, W: Double, H: Double, color: Color) {
        let spacing = 32.0
        let cols = Int(W / spacing) + 2
        let rows = Int(H / spacing) + 2
        for r in 0..<rows {
            for c in 0..<cols {
                ctx.fill(Path(ellipseIn: cr(Double(c) * spacing, Double(r) * spacing, 0.75)),
                         with: .color(color.opacity(0.055)))
            }
        }
    }

    // MARK: - Phase Implementations

    // 📁 Glass Bubble Forest — 目录树深度优先遍历
    // 泡泡依次生长冒出：大=目录，小=文件，带轻微上浮
    private func drawBubbleForest(_ ctx: GraphicsContext, W: Double, H: Double, t: Double) {
        let (c1, c2, _) = palette
        let cycle = 7.0
        let prog  = (t / cycle).truncatingRemainder(dividingBy: 1.0)
        let total = 14
        for i in 0..<total {
            let s      = UInt64(i) * 43 + 7
            let bx     = W * 0.12 + lcg(s)   * W * 0.76
            let by     = H * 0.20 + lcg(s+1) * H * 0.60
            let isDir  = lcg(s+2) > 0.42
            let baseR  = isDir ? 16.0 + lcg(s+3) * 14.0 : 8.0 + lcg(s+4) * 8.0
            let spawnAt = Double(i) / Double(total) * 0.88
            let age    = max(0, prog - spawnAt)
            let appear = eio(min(age / 0.08, 1.0))
            guard appear > 0.01 else { continue }
            let floatY = by - age * cycle * 3.5 * (0.6 + lcg(s+5) * 0.8)
            let sway   = sin(t * (0.8 + lcg(s+6) * 0.6) + Double(i)) * 4.0
            paintGlass(ctx, cx: bx + sway, cy: floatY,
                       r: baseR * appear,
                       color: isDir ? c1 : c2, t: t,
                       amp: 0.06, alpha: appear * 0.9, seed: Double(i) * 1.7)
        }
    }

    // 📝 Paired Drops — [String: LivePhotoSeedGroup] 同名配对
    // 大液滴(HEIC) + 小液滴(MOV)，靠近时形成玻璃纤维，配对后短暂停留再分离
    private func drawPairedDrops(_ ctx: GraphicsContext, W: Double, H: Double, t: Double) {
        let (c1, _, c3) = palette
        for i in 0..<7 {
            let s      = UInt64(i) * 37 + 5
            let ax     = W * 0.14 + lcg(s)   * W * 0.28
            let ay     = H * 0.15 + lcg(s+1) * H * 0.70
            let bx     = W * 0.58 + lcg(s+2) * W * 0.28
            let by_    = H * 0.15 + lcg(s+3) * H * 0.70
            let period = 5.0 + lcg(s+4) * 2.0
            let raw    = ((t + lcg(s+5) * period) / period).truncatingRemainder(dividingBy: 1.0)
            let attract: Double
            if raw < 0.38      { attract = eio(raw / 0.38) }
            else if raw < 0.65 { attract = 1.0 }
            else               { attract = eio(1.0 - (raw - 0.65) / 0.35) }
            let mx  = (ax + bx) / 2, my = (ay + by_) / 2
            let pax = lp(ax, mx, attract * 0.34), pay = lp(ay, my, attract * 0.34)
            let pbx = lp(bx, mx, attract * 0.34), pby = lp(by_, my, attract * 0.34)
            if attract > 0.12 {
                paintGlassThread(ctx, x1: pax, y1: pay, x2: pbx, y2: pby,
                                 color: c1, progress: 1.0, alpha: attract * 0.7)
            }
            paintGlass(ctx, cx: pax, cy: pay, r: 14.0 + attract * 3,
                       color: c1, t: t, amp: 0.06, alpha: 0.90, seed: Double(i))
            paintGlass(ctx, cx: pbx, cy: pby, r: 9.0 + attract * 2,
                       color: c3, t: t, amp: 0.07, alpha: 0.90, seed: Double(i) + 5.5)
        }
    }

    // 🔗 Glass Filaments — Content ID 跨目录匹配
    // 两侧玻璃节点，匹配时生长玻璃纤维，纤维上有行进亮点
    private func drawGlassFilaments(_ ctx: GraphicsContext, W: Double, H: Double, t: Double) {
        let (c1, _, _) = palette
        for i in 0..<5 {
            let s       = UInt64(i) * 53 + 11
            let ax      = W * 0.08 + lcg(s)   * W * 0.18
            let ay      = H * 0.15 + lcg(s+1) * H * 0.70
            let bx      = W * 0.74 + lcg(s+2) * W * 0.18
            let by_     = H * 0.15 + lcg(s+3) * H * 0.70
            let period  = 4.2 + Double(i) * 0.5
            let rawP    = ((t - Double(i) * 0.7) / period).truncatingRemainder(dividingBy: 1.0)
            let lineP   = rawP < 0 ? 0 : eio(min(rawP, 1.0))
            let matched = lineP > 0.88
            paintGlass(ctx, cx: ax, cy: ay, r: 11.0, color: c1, t: t,
                       amp: 0.05, alpha: 0.85, seed: Double(i))
            paintGlass(ctx, cx: bx, cy: by_, r: 11.0, color: c1, t: t,
                       amp: 0.05, alpha: matched ? 1.0 : 0.50, seed: Double(i) + 3.3)
            paintGlassThread(ctx, x1: ax, y1: ay, x2: bx, y2: by_,
                             color: c1, progress: lineP, alpha: 1.0)
            if lineP > 0.02 && lineP < 0.97 {
                let tx = lp(ax, bx, lineP), ty = lp(ay, by_, lineP)
                ctx.fill(Path(ellipseIn: cr(tx, ty, 2.5)),
                         with: .color(.white.opacity(0.55)))
            }
        }
    }

    // 🔍 Glass Lens Scan — SHA256 文件内容指纹
    // 玻璃透镜左右扫描，粒子流向3个哈希锚点
    private func drawGlassLens(_ ctx: GraphicsContext, cx: Double, cy: Double,
                                W: Double, H: Double, t: Double) {
        let (c1, _, c3) = palette
        let sp    = (t / 9.0).truncatingRemainder(dividingBy: 1.0)
        let lensX = W * 0.15 + eio(sp < 0.5 ? sp * 2 : (1 - sp) * 2) * W * 0.70
        let lensY = cy + sin(t * 0.4) * H * 0.08
        let lrx   = min(W * 0.16, 110.0), lry = lrx * 0.58
        // 透镜体（扁椭圆）
        let lensRect = CGRect(x: lensX - lrx, y: lensY - lry, width: lrx*2, height: lry*2)
        ctx.fill(Path(ellipseIn: lensRect), with: .color(c1.opacity(0.10)))
        ctx.stroke(Path(ellipseIn: lensRect), with: .color(.white.opacity(0.16)), lineWidth: 0.8)
        // 高光弧
        var lRim = Path()
        lRim.addArc(center: CGPoint(x: lensX, y: lensY), radius: lrx * 0.88,
                    startAngle: .degrees(-145), endAngle: .degrees(-45), clockwise: false)
        ctx.stroke(lRim, with: .color(.white.opacity(0.42)), lineWidth: 1.0)
        // 焦散
        ctx.fill(Path(ellipseIn: cr(lensX - lrx*0.30, lensY - lry*0.35, lrx * 0.28)),
                 with: .color(.white.opacity(0.13)))
        // 3 个 SHA256 锚点
        let fps: [(Double, Double)] = [
            (W*0.32, H*0.38), (W*0.65, H*0.55), (W*0.50, H*0.22)
        ]
        for fp in fps {
            let pulse = breathe(t, period: 1.8)
            paintGlass(ctx, cx: fp.0, cy: fp.1, r: 10.0 + pulse * 3,
                       color: c3, t: t, amp: 0.08, alpha: 0.82)
        }
        // 粒子流向锚点
        for i in 0..<20 {
            let s   = UInt64(i) * 41 + 7
            let fi  = Int(lcg(s) * 3) % 3
            let fp  = fps[fi]
            let sx  = lcg(s+1) * W, sy = lcg(s+2) * H
            let per = 2.5 + lcg(s+3) * 1.5
            let raw = ((t + lcg(s+4) * per) / per).truncatingRemainder(dividingBy: 1.0)
            let pp  = eio(raw)
            let op  = sin(raw * .pi) * 0.42
            if op > 0.05 {
                ctx.fill(Path(ellipseIn: cr(lp(sx, fp.0, pp), lp(sy, fp.1, pp), 2.0)),
                         with: .color(c3.opacity(op)))
                ctx.fill(Path(ellipseIn: cr(lp(sx, fp.0, pp), lp(sy, fp.1, pp), 0.9)),
                         with: .color(.white.opacity(op * 0.5)))
            }
        }
    }

    // 🔀 Bubble Merge — Union-Find 并查集 union()
    // 玻璃泡泡碰撞形成表面张力桥，最终合并为一个大球
    private func drawBubbleMerge(_ ctx: GraphicsContext, cx: Double, cy: Double,
                                  W: Double, H: Double, t: Double) {
        let (c1, c2, _) = palette
        let ph = (t / 7.0).truncatingRemainder(dividingBy: 1.0)
        let mergeRaw: Double
        if ph < 0.50      { mergeRaw = ph / 0.50 }
        else if ph < 0.72 { mergeRaw = 1.0 }
        else              { mergeRaw = 1.0 - (ph - 0.72) / 0.28 }
        let merge = eio(mergeRaw)
        for c in 0..<4 {
            let cs  = UInt64(c) * 47 + 3
            let sx  = W * 0.18 + lcg(cs)   * W * 0.64
            let sy  = H * 0.18 + lcg(cs+1) * H * 0.64
            let clx = lp(sx, cx, merge * 0.88)
            let cly = lp(sy, cy, merge * 0.88)
            let rr  = 14.0 + merge * 8.0
            paintGlass(ctx, cx: clx, cy: cly, r: rr,
                       color: c % 2 == 0 ? c1 : c2, t: t,
                       amp: 0.06 + merge * 0.04, alpha: 0.90, seed: Double(c) * 2.5)
            if merge > 0.35 {
                let dist = sqrt((clx-cx)*(clx-cx) + (cly-cy)*(cly-cy))
                if dist < rr * 4.5 {
                    let ba = eio((merge - 0.35) / 0.65) * 0.55
                    paintGlassThread(ctx, x1: clx, y1: cly, x2: cx, y2: cy,
                                     color: c1, progress: 1.0, alpha: ba)
                }
            }
        }
        if merge > 0.28 {
            paintGlass(ctx, cx: cx, cy: cy, r: merge * 22.0,
                       color: c1, t: t, amp: 0.04, alpha: merge * 0.95, seed: 77.0)
        }
    }

    // 🧮 Glass Prism — DCT 8×8 感知哈希
    // 三角玻璃棱镜（左）+ 8×8 玻璃光栅逐格扫亮（右）
    private func drawGlassPrism(_ ctx: GraphicsContext, cx: Double, cy: Double,
                                 base: Double, t: Double) {
        let (c1, _, c3) = palette
        let n    = 8
        let cell = base * 0.058
        let gw   = cell * Double(n)
        let gx   = cx + base * 0.06, gy = cy - gw / 2
        let ph   = (t / 4.5).truncatingRemainder(dividingBy: 1.0)
        let litN = Int(min(ph / 0.80, 1.0) * Double(n * n))
        // 8×8 玻璃光栅
        for row in 0..<n {
            for col in 0..<n {
                let idx = row * n + col
                let px  = gx + (Double(col) + 0.5) * cell
                let py  = gy + (Double(row) + 0.5) * cell
                let tr  = cell * 0.42
                if idx < litN {
                    let age = Double(litN - idx) / Double(n * n)
                    ctx.fill(Path(ellipseIn: cr(px, py, tr)),
                             with: .color(c1.opacity(max(0.12, 0.30 - age * 0.15))))
                    ctx.stroke(Path(ellipseIn: cr(px, py, tr)),
                               with: .color(.white.opacity(0.10)), lineWidth: 0.4)
                    ctx.fill(Path(ellipseIn: cr(px - tr*0.22, py - tr*0.25, tr*0.30)),
                             with: .color(.white.opacity(0.18)))
                } else {
                    ctx.fill(Path(ellipseIn: cr(px, py, cell * 0.35)),
                             with: .color(c1.opacity(0.06)))
                }
            }
        }
        if ph < 0.80 && litN < n * n {
            let px = gx + (Double(litN % n) + 0.5) * cell
            let py = gy + (Double(litN / n) + 0.5) * cell
            paintGlass(ctx, cx: px, cy: py, r: cell * 0.55,
                       color: c3, t: t, amp: 0.08, alpha: 1.0, seed: 12.0)
        }
        // 三角玻璃棱镜
        let prx = cx - base * 0.22, pry = cy, pr = base * 0.12
        let ang: [Double] = [-.pi/2, .pi/6, .pi*5/6]
        var tri = Path()
        tri.move(to: CGPoint(x: prx + cos(ang[0]) * pr, y: pry + sin(ang[0]) * pr))
        for i in 1..<3 {
            tri.addLine(to: CGPoint(x: prx + cos(ang[i]) * pr, y: pry + sin(ang[i]) * pr))
        }
        tri.closeSubpath()
        ctx.fill(tri, with: .color(c1.opacity(0.10)))
        ctx.stroke(tri, with: .color(.white.opacity(0.22)), lineWidth: 0.9)
        // 棱镜顶部主高光
        var tRim = Path()
        tRim.move(to: CGPoint(x: prx + cos(ang[0]) * pr, y: pry + sin(ang[0]) * pr))
        tRim.addLine(to: CGPoint(x: prx + (cos(ang[1]) + cos(ang[0])) * pr * 0.5,
                                  y: pry + (sin(ang[1]) + sin(ang[0])) * pr * 0.5))
        ctx.stroke(tRim, with: .color(.white.opacity(0.40)), lineWidth: 1.0)
        ctx.fill(Path(ellipseIn: cr(prx - pr*0.10, pry - pr*0.25, pr * 0.28)),
                 with: .color(.white.opacity(0.13)))
        // 入射光线
        var lightIn = Path()
        lightIn.move(to:    CGPoint(x: prx - pr * 1.8, y: pry))
        lightIn.addLine(to: CGPoint(x: prx + cos(ang[2]) * pr * 0.7,
                                    y: pry + sin(ang[2]) * pr * 0.7))
        ctx.stroke(lightIn, with: .color(c1.opacity(0.14)), lineWidth: 0.6)
        ctx.stroke(lightIn, with: .color(.white.opacity(0.07)), lineWidth: 0.25)
    }

    // 👀 Similar Bubbles — pHash 分桶 + 汉明距离相似匹配
    // 4个哈希桶吸附卫星泡泡，相似泡跨桶形成玻璃纤维
    private func drawSimilarBubbles(_ ctx: GraphicsContext, W: Double, H: Double, t: Double) {
        let (c1, _, c3) = palette
        let buckets: [(Double, Double)] = [
            (W*0.26, H*0.30), (W*0.72, H*0.27),
            (W*0.24, H*0.72), (W*0.74, H*0.70)
        ]
        for (bi, bc) in buckets.enumerated() {
            let pulse = breathe(t, period: 3.5, phase: Double(bi) * 0.9)
            paintGlass(ctx, cx: bc.0, cy: bc.1, r: 16.0 + pulse * 4,
                       color: c1, t: t, amp: 0.05, alpha: 0.90, seed: Double(bi) * 3.3)
            for p in 0..<5 {
                let ps      = UInt64(bi * 20 + p) * 43 + 9
                let attract = 0.30 + breathe(t, period: 3.8, phase: Double(bi)*1.1 + Double(p)) * 0.30
                let ox0     = (lcg(ps)   - 0.5) * W * 0.18
                let oy0     = (lcg(ps+1) - 0.5) * H * 0.18
                paintGlass(ctx, cx: bc.0 + ox0 * (1 - attract * 0.65),
                           cy: bc.1 + oy0 * (1 - attract * 0.65),
                           r: 5.0 + lcg(ps+2) * 5.0,
                           color: c3, t: t, amp: 0.07, alpha: 0.70, seed: Double(ps))
            }
        }
        // 跨桶相似性纤维
        let lt = (t * 0.20).truncatingRemainder(dividingBy: 1.0)
        let bA = Int(lt * 4) % 4, bB = (bA + 2) % 4
        let pp = sin(lt * .pi)
        if pp > 0.06 {
            paintGlassThread(ctx, x1: buckets[bA].0, y1: buckets[bA].1,
                             x2: buckets[bB].0, y2: buckets[bB].1,
                             color: c1, progress: 1.0, alpha: pp * 0.85)
            let tp = (lt * 3.0).truncatingRemainder(dividingBy: 1.0)
            let tx = lp(buckets[bA].0, buckets[bB].0, tp)
            let ty = lp(buckets[bA].1, buckets[bB].1, tp)
            ctx.fill(Path(ellipseIn: cr(tx, ty, 2.0)), with: .color(.white.opacity(pp * 0.55)))
        }
    }

    // ⚖️ Quality Float — EXIF 质量评分选优
    // 泡泡大小=质量分；高分者向中心上浮变大变亮，低分者下沉淡出
    private func drawQualityFloat(_ ctx: GraphicsContext, cx: Double, cy: Double,
                                   W: Double, H: Double, t: Double) {
        let (c1, c2, _) = palette
        let ph = (t / 5.5).truncatingRemainder(dividingBy: 1.0)
        for i in 0..<7 {
            let s       = UInt64(i) * 59 + 13
            let sx      = W * 0.18 + lcg(s)   * W * 0.64
            let sy      = H * 0.18 + lcg(s+1) * H * 0.64
            let quality = i == 0 ? 1.0 : 0.15 + lcg(s+2) * 0.50
            let sortedY = cy - (quality - 0.5) * H * 0.46
            let px: Double, py: Double, alpha: Double, rr: Double
            if i == 0 {
                px = lp(sx, cx,      eio(ph)); py = lp(sy, cy - H*0.12, eio(ph))
                alpha = 1.0;                   rr = 12.0 + eio(ph) * 8.0
            } else {
                px = lp(sx, cx + (sx - cx) * 0.12, eio(ph))
                py = lp(sy, sortedY, eio(ph))
                alpha = max(0, 1.0 - ph * 1.15) * 0.80
                rr = 6.0 + quality * 8.0
            }
            if alpha > 0.02 {
                paintGlass(ctx, cx: px, cy: py, r: rr,
                           color: i == 0 ? c1 : c2, t: t,
                           amp: 0.055, alpha: alpha, seed: Double(i) * 2.2)
            }
        }
    }
}
