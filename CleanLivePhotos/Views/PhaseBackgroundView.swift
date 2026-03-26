import SwiftUI

// MARK: - Helpers

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
/// 三圈叠加模拟高斯辉光
private func glow(_ ctx: GraphicsContext, _ x: Double, _ y: Double,
                  _ color: Color, _ intensity: Double, _ r: Double = 2.0) {
    ctx.fill(Path(ellipseIn: cr(x, y, r)),     with: .color(color.opacity(intensity)))
    ctx.fill(Path(ellipseIn: cr(x, y, r * 3)), with: .color(color.opacity(intensity * 0.18)))
    ctx.fill(Path(ellipseIn: cr(x, y, r * 6)), with: .color(color.opacity(intensity * 0.05)))
}
private func eio(_ t: Double) -> Double {
    let x = max(0, min(1, t))
    return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
}

// MARK: - PhaseBackgroundView
// 方案 A：底层液态光球（高级感）+ 上层算法数据结构可视化（有意义）

struct PhaseBackgroundView: View {
    let phase: String
    let animationRate: Double

    private var palette: (Color, Color, Color) {
        switch true {
        case phase.hasPrefix("📁"):
            return (.init(red:0.55, green:0.65, blue:0.85),
                    .init(red:0.25, green:0.30, blue:0.55),
                    .init(red:0.75, green:0.82, blue:1.00))
        case phase.hasPrefix("📝"):
            return (.init(red:0.88, green:0.78, blue:0.55),
                    .init(red:0.62, green:0.48, blue:0.22),
                    .init(red:1.00, green:0.92, blue:0.72))
        case phase.hasPrefix("🔗"):
            return (.init(red:0.52, green:0.18, blue:0.95),
                    .init(red:0.85, green:0.22, blue:0.60),
                    .init(red:0.68, green:0.45, blue:1.00))
        case phase.hasPrefix("🔍"):
            return (.init(red:0.12, green:0.38, blue:0.98),
                    .init(red:0.04, green:0.12, blue:0.62),
                    .init(red:0.32, green:0.62, blue:1.00))
        case phase.hasPrefix("🔀"):
            return (.init(red:0.04, green:0.62, blue:0.70),
                    .init(red:0.02, green:0.35, blue:0.50),
                    .init(red:0.25, green:0.92, blue:0.90))
        case phase.hasPrefix("🧮"):
            return (.init(red:0.08, green:0.62, blue:0.40),
                    .init(red:0.02, green:0.32, blue:0.45),
                    .init(red:0.28, green:0.95, blue:0.65))
        case phase.hasPrefix("👀"):
            return (.init(red:0.95, green:0.45, blue:0.08),
                    .init(red:0.72, green:0.20, blue:0.12),
                    .init(red:1.00, green:0.72, blue:0.32))
        case phase.hasPrefix("⚖️"):
            return (.init(red:0.10, green:0.78, blue:0.58),
                    .init(red:0.04, green:0.42, blue:0.65),
                    .init(red:0.45, green:1.00, blue:0.78))
        default:
            return (.init(red:0.55, green:0.65, blue:0.85),
                    .init(red:0.25, green:0.30, blue:0.55),
                    .init(red:0.75, green:0.82, blue:1.00))
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
        let (c1, c2, c3) = palette
        let base = min(W, H)

        // 1. 深海基底
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(.init(red: 0.026, green: 0.032, blue: 0.072)))

        // 2. 液态光球（Lissajous 轨道，黄金比例频率）
        let a1 = t / 31.0 * .pi * 2
        let ox1 = cx + (cos(a1) * 0.22 + sin(a1 * 0.618 + 0.5) * 0.07) * W
        let oy1 = cy + (sin(a1 * 0.786) * 0.16 + cos(a1 * 1.272 + 0.3) * 0.05) * H
        let a2 = t / 23.0 * .pi * 2 + 2.094
        let ox2 = cx + (cos(a2 * 1.082) * 0.21 + sin(a2 + 1.1) * 0.08) * W
        let oy2 = cy + (sin(a2 * 0.910) * 0.19 + cos(a2 * 0.618 + 0.9) * 0.06) * H
        let a3 = t / 17.0 * .pi * 2 + 4.189
        let ox3 = cx + (cos(a3 * 0.786 + 0.4) * 0.18 + sin(a3 * 1.175) * 0.06) * W
        let oy3 = cy + (sin(a3 * 1.134) * 0.15 + cos(a3 * 0.720 + 1.3) * 0.07) * H

        var sc = ctx
        sc.blendMode = .screen
        paintOrb(&sc, cx: ox1, cy: oy1, color: c1, r: base * 0.48)
        paintOrb(&sc, cx: ox2, cy: oy2, color: c2, r: base * 0.37)
        paintOrb(&sc, cx: ox3, cy: oy3, color: c3, r: base * 0.24)

        // 3. 呼吸环
        paintRings(ctx, cx: cx, cy: cy, base: base, t: t, color: c1)

        // 4. 算法可视化叠加层（正常混色，透明度克制）
        switch true {
        case phase.hasPrefix("📁"): drawFileTree(ctx, W: W, H: H, t: t, a: c1)
        case phase.hasPrefix("📝"): drawPairing(ctx, W: W, H: H, t: t, ca: c1, cb: c3)
        case phase.hasPrefix("🔗"): drawCrossDir(ctx, W: W, H: H, t: t, a: c1)
        case phase.hasPrefix("🔍"): drawSHA256(ctx, W: W, H: H, t: t, a: c1)
        case phase.hasPrefix("🔀"): drawUnionFind(ctx, W: W, H: H, t: t, a: c1)
        case phase.hasPrefix("🧮"): drawDCT(ctx, cx: cx, cy: cy, base: base, t: t, a: c1)
        case phase.hasPrefix("👀"): drawHashBuckets(ctx, W: W, H: H, t: t, a: c1)
        case phase.hasPrefix("⚖️"): drawDecision(ctx, cx: cx, cy: cy, W: W, H: H, t: t, a: c1)
        default: break
        }
    }

    // MARK: - Base Layers

    private func paintOrb(_ ctx: inout GraphicsContext, cx: Double, cy: Double,
                          color: Color, r: Double) {
        for (scale, alpha) in [(1.00, 0.07), (0.60, 0.12), (0.28, 0.17), (0.10, 0.26)] {
            let lr = r * scale
            ctx.fill(Path(ellipseIn: CGRect(x: cx-lr, y: cy-lr, width: lr*2, height: lr*2)),
                     with: .color(color.opacity(alpha)))
        }
    }

    private func paintRings(_ ctx: GraphicsContext, cx: Double, cy: Double,
                             base: Double, t: Double, color: Color) {
        let cfg: [(Double, Double, Double)] = [
            (0.20, 8.5,  0.0), (0.28, 11.2, 1.8),
            (0.36, 14.0, 3.5), (0.43, 17.3, 5.2), (0.50, 21.0, 7.0)
        ]
        for (i, (frac, period, ph)) in cfg.enumerated() {
            let pulse = (1 + sin((t + ph) * 2 * .pi / period)) * 0.5
            let r = base * (frac + pulse * 0.018)
            let op = 0.030 - Double(i) * 0.004
            ctx.stroke(Path(ellipseIn: cr(cx, cy, r)),
                       with: .color(color.opacity(op)), lineWidth: 0.6)
        }
    }

    // MARK: - 算法可视化层

    // 📁 目录树递归生长
    // 算法：URLDirectoryAsyncSequence 深度优先遍历，从根向叶扩展
    private func drawFileTree(_ ctx: GraphicsContext, W: Double, H: Double,
                              t: Double, a: Color) {
        let rootX = W / 2, rootY = H * 0.55
        let cycle = 5.5
        let progress = (t / cycle).truncatingRemainder(dividingBy: 1.0)

        // (parentX, parentY, childX, childY, growStart)
        typealias Branch = (Double, Double, Double, Double, Double)
        var branches: [Branch] = []

        let mainLen = min(W, H) * 0.20
        let mainAngles: [Double] = [-.pi*0.55, -.pi*0.25, -.pi*0.05, .pi*0.20, .pi*0.45]
        for (i, ang) in mainAngles.enumerated() {
            let nx = rootX + cos(ang) * mainLen
            let ny = rootY + sin(ang) * mainLen
            let start = Double(i) * 0.07
            branches.append((rootX, rootY, nx, ny, start))
            // 子分支
            let subAngles = [ang - .pi/5.5, ang + .pi/5.5]
            let subLen = mainLen * 0.58
            for (j, sa) in subAngles.enumerated() {
                let snx = nx + cos(sa) * subLen
                let sny = ny + sin(sa) * subLen
                let sStart = start + 0.10 + Double(j) * 0.04
                branches.append((nx, ny, snx, sny, sStart))
                // 孙分支
                let ssLen = subLen * 0.55
                let ssa = sa + (j == 0 ? -.pi/6 : .pi/6)
                branches.append((snx, sny,
                                  snx + cos(ssa) * ssLen, sny + sin(ssa) * ssLen,
                                  sStart + 0.10))
            }
        }

        glow(ctx, rootX, rootY, a, 0.45, 2.5) // 根节点
        for (px, py, ex_, ey_, start) in branches {
            let p = eio(max(0, min(1, (progress - start) / 0.13)))
            guard p > 0 else { continue }
            let ex = lp(px, ex_, p), ey = lp(py, ey_, p)
            var path = Path()
            path.move(to: CGPoint(x: px, y: py))
            path.addLine(to: CGPoint(x: ex, y: ey))
            ctx.stroke(path, with: .color(a.opacity(0.20)), lineWidth: 0.7)
            if p >= 1 { glow(ctx, ex_, ey_, a, 0.32, 1.8) }
        }
    }

    // 📝 HEIC/MOV 按文件名配对
    // 算法：[String: LivePhotoSeedGroup] 哈希表，同名文件两两靠拢
    private func drawPairing(_ ctx: GraphicsContext, W: Double, H: Double,
                              t: Double, ca: Color, cb: Color) {
        let count = 7
        let cy = H / 2
        for i in 0..<count {
            let s = UInt64(i) * 37 + 5
            let ax = W * 0.22 + (lcg(s)   - 0.5) * W * 0.16
            let ay = cy       + (lcg(s+1) - 0.5) * H * 0.58
            let bx = W * 0.78 + (lcg(s+2) - 0.5) * W * 0.16
            let by = cy       + (lcg(s+3) - 0.5) * H * 0.58
            let period = 4.5 + lcg(s+4) * 2.0
            let ph     = lcg(s+5) * period
            let raw    = ((t + ph) / period).truncatingRemainder(dividingBy: 1.0)
            // 0→0.40 靠近，0.40→0.65 配对保持，0.65→1.0 分离
            let attract: Double
            if raw < 0.40      { attract = eio(raw / 0.40) }
            else if raw < 0.65 { attract = 1.0 }
            else               { attract = eio(1.0 - (raw - 0.65) / 0.35) }
            let mx = (ax + bx) / 2, my = (ay + by) / 2
            let pax = lp(ax, mx, attract * 0.32), pay = lp(ay, my, attract * 0.32)
            let pbx = lp(bx, mx, attract * 0.32), pby = lp(by, my, attract * 0.32)
            if attract > 0.08 {
                var line = Path()
                line.move(to: CGPoint(x: pax, y: pay))
                line.addLine(to: CGPoint(x: pbx, y: pby))
                ctx.stroke(line, with: .color(ca.opacity(attract * 0.14)), lineWidth: 0.5)
            }
            glow(ctx, pax, pay, ca, 0.22 + attract * 0.18, 2.0)  // HEIC
            glow(ctx, pbx, pby, cb, 0.22 + attract * 0.18, 2.0)  // MOV
        }
    }

    // 🔗 跨目录 Content ID 匹配
    // 算法：读取 HEIC/MOV 的 Content ID 元数据，相同 ID 用线连接
    private func drawCrossDir(_ ctx: GraphicsContext, W: Double, H: Double,
                               t: Double, a: Color) {
        let count = 5
        for i in 0..<count {
            let s = UInt64(i) * 53 + 11
            // 左侧集群（目录A）
            let ax = W * 0.12 + lcg(s)   * W * 0.22
            let ay = H * 0.15 + lcg(s+1) * H * 0.35
            // 右侧集群（目录B）
            let bx = W * 0.65 + lcg(s+2) * W * 0.22
            let by = H * 0.50 + lcg(s+3) * H * 0.35
            // 连线从左向右生长
            let linePeriod = 3.8
            let lineOff    = Double(i) * 0.55
            let rawP = ((t - lineOff) / linePeriod).truncatingRemainder(dividingBy: 1.0)
            let lineP = rawP < 0 ? 0 : eio(min(rawP, 1.0))
            let ex = lp(ax, bx, lineP), ey = lp(ay, by, lineP)
            if lineP > 0 {
                var line = Path()
                line.move(to: CGPoint(x: ax, y: ay))
                line.addLine(to: CGPoint(x: ex, y: ey))
                let fadeOp = lineP > 0.82 ? (1 - (lineP - 0.82) / 0.18) * 0.14 : 0.14
                ctx.stroke(line, with: .color(a.opacity(fadeOp)), lineWidth: 0.5)
            }
            glow(ctx, ax, ay, a, 0.26, 2.0)
            glow(ctx, bx, by, a, lineP > 0.88 ? 0.50 : 0.18, 2.0)
        }
    }

    // 🔍 SHA256 指纹汇聚
    // 算法：文件字节流→ SHA256 指纹，相同指纹的文件汇入同一聚合点
    private func drawSHA256(_ ctx: GraphicsContext, W: Double, H: Double,
                             t: Double, a: Color) {
        // 3 个指纹聚合点
        let fps: [(Double, Double)] = [
            (W * 0.34, H * 0.42), (W * 0.64, H * 0.52), (W * 0.50, H * 0.28)
        ]
        // 粒子流向对应指纹点
        for i in 0..<28 {
            let s = UInt64(i) * 41 + 7
            let fi = Int(lcg(s) * 3) % 3
            let fp = fps[fi]
            let sx = lcg(s+1) * W, sy = lcg(s+2) * H
            let period = 2.2 + lcg(s+3) * 1.8
            let ph     = lcg(s+4) * period
            let raw    = ((t + ph) / period).truncatingRemainder(dividingBy: 1.0)
            let p      = eio(raw)
            let px     = lp(sx, fp.0, p), py = lp(sy, fp.1, p)
            let op     = sin(raw * .pi) * 0.18
            if op > 0.01 { glow(ctx, px, py, a, op, 1.5) }
        }
        // 指纹点本体脉动
        for fp in fps {
            let pulse = breathe(t, period: 1.8)
            glow(ctx, fp.0, fp.1, a, 0.42 + pulse * 0.14, 3.2)
        }
    }

    // 🔀 Union-Find 并查集合并
    // 算法：多个不相交集合逐步 union()，最终变成更少的大集合
    private func drawUnionFind(_ ctx: GraphicsContext, W: Double, H: Double,
                                t: Double, a: Color) {
        let clusterN = 4
        let ppC      = 5      // particles per cluster
        let cycle    = 6.2
        let ph       = (t / cycle).truncatingRemainder(dividingBy: 1.0)
        // 0→0.55 合并，0.55→0.75 保持，0.75→1.0 分散
        let mergeRaw: Double
        if ph < 0.55      { mergeRaw = ph / 0.55 }
        else if ph < 0.75 { mergeRaw = 1.0 }
        else              { mergeRaw = 1.0 - (ph - 0.75) / 0.25 }
        let merge = eio(mergeRaw)

        for c in 0..<clusterN {
            let cs = UInt64(c) * 47 + 3
            let sx = W * 0.18 + lcg(cs)   * W * 0.64
            let sy = H * 0.18 + lcg(cs+1) * H * 0.64
            let clx = lp(sx, W / 2, merge * 0.90)
            let cly = lp(sy, H / 2, merge * 0.90)
            // 集合边界圆
            let ringR = 20.0 + merge * 14.0
            ctx.stroke(Path(ellipseIn: cr(clx, cly, ringR)),
                       with: .color(a.opacity(0.06 + merge * 0.07)), lineWidth: 0.6)
            // 集合内粒子
            for p in 0..<ppC {
                let ps     = UInt64(c * 20 + p) * 31 + 7
                let spread = 24.0 * (1 - merge * 0.78)
                let ox     = (lcg(ps)   - 0.5) * spread * 2
                let oy     = (lcg(ps+1) - 0.5) * spread * 2
                glow(ctx, clx + ox, cly + oy, a, 0.22 + merge * 0.12, 1.8)
            }
        }
    }

    // 🧮 DCT 8×8 网格逐格扫描
    // 算法：图片缩放为 8×8，对每个像素计算 DCT 系数，生成感知哈希
    private func drawDCT(_ ctx: GraphicsContext, cx: Double, cy: Double,
                          base: Double, t: Double, a: Color) {
        let n    = 8
        let cell = base * 0.062
        let gw   = cell * Double(n)
        let sx   = cx - gw / 2, sy = cy - gw / 2

        let cycle   = 4.2
        let ph      = (t / cycle).truncatingRemainder(dividingBy: 1.0)
        let litFrac = min(ph / 0.78, 1.0) // 78% 时间内扫完
        let litN    = Int(litFrac * Double(n * n))

        for row in 0..<n {
            for col in 0..<n {
                let idx = row * n + col
                let px  = sx + (Double(col) + 0.5) * cell
                let py  = sy + (Double(row) + 0.5) * cell
                if idx < litN {
                    let age = Double(litN - idx) / Double(n * n)
                    glow(ctx, px, py, a, max(0.15, 0.32 - age * 0.15), 2.2)
                } else {
                    ctx.fill(Path(ellipseIn: cr(px, py, 1.0)),
                             with: .color(a.opacity(0.08)))
                }
            }
        }
        // 扫描游标（当前正在计算的像素）
        if ph < 0.78 && litN < n * n {
            let px = sx + (Double(litN % n) + 0.5) * cell
            let py = sy + (Double(litN / n) + 0.5) * cell
            glow(ctx, px, py, a, 0.90, 3.2)
        }
    }

    // 👀 哈希桶内汉明引力
    // 算法：pHash >> 16 分桶，桶内两两计算汉明距离，距离 < 10 的合并
    private func drawHashBuckets(_ ctx: GraphicsContext, W: Double, H: Double,
                                  t: Double, a: Color) {
        // 4 个哈希桶，各自独立"呼吸"引力
        let buckets: [(Double, Double)] = [
            (W * 0.27, H * 0.30), (W * 0.70, H * 0.27),
            (W * 0.28, H * 0.70), (W * 0.72, H * 0.68)
        ]
        for (b, bc) in buckets.enumerated() {
            let attract = 0.28 + breathe(t, period: 3.8, phase: Double(b) * 1.1) * 0.28
            for p in 0..<6 {
                let ps  = UInt64(b * 20 + p) * 43 + 9
                let ox0 = (lcg(ps)   - 0.5) * W * 0.22
                let oy0 = (lcg(ps+1) - 0.5) * H * 0.22
                glow(ctx, bc.0 + ox0 * (1 - attract * 0.72),
                          bc.1 + oy0 * (1 - attract * 0.72),
                          a, 0.18 + attract * 0.12, 1.8)
            }
        }
        // 偶发跨桶比对连线
        let lt = (t * 0.22).truncatingRemainder(dividingBy: 1.0)
        let bA = Int(lt * 4) % 4
        let bB = (bA + 2) % 4
        let p  = sin(lt * .pi)
        if p > 0.05 {
            var line = Path()
            line.move(to:    CGPoint(x: buckets[bA].0, y: buckets[bA].1))
            line.addLine(to: CGPoint(x: buckets[bB].0, y: buckets[bB].1))
            ctx.stroke(line, with: .color(a.opacity(p * 0.11)), lineWidth: 0.4)
        }
    }

    // ⚖️ EXIF 质量评分选优
    // 算法：计算 ISO/曝光/对焦质量分，最高分文件移向中心保留，其余淡出删除
    private func drawDecision(_ ctx: GraphicsContext, cx: Double, cy: Double,
                               W: Double, H: Double, t: Double, a: Color) {
        let n     = 7
        let cycle = 5.0
        let ph    = (t / cycle).truncatingRemainder(dividingBy: 1.0)

        for i in 0..<n {
            let s       = UInt64(i) * 59 + 13
            let sx      = W * 0.18 + lcg(s)   * W * 0.64
            let sy      = H * 0.18 + lcg(s+1) * H * 0.64
            let quality = i == 0 ? 1.0 : 0.15 + lcg(s+2) * 0.45 // index 0 = winner

            let px: Double
            let py: Double
            if i == 0 {
                px = lp(sx, cx, eio(ph))
                py = lp(sy, cy, eio(ph))
            } else {
                // 落选者向外漂移并淡出
                px = lp(sx, sx + (sx - cx) * 0.28, eio(ph))
                py = lp(sy, sy + (sy - cy) * 0.28, eio(ph))
            }
            let fade      = i == 0 ? 1.0 : max(0, 1 - ph * 1.25)
            let intensity = quality * 0.35 * fade + (i == 0 ? ph * 0.22 : 0)
            if intensity > 0.01 {
                glow(ctx, px, py, a, intensity, 1.8 + quality * 1.6)
            }
        }
    }
}
