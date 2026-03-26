import SwiftUI

// MARK: - Helpers

/// LCG 确定性伪随机 [0,1)
private func lcg(_ seed: UInt64) -> Double {
    let s = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(s >> 33) / Double(1 << 31)
}

/// 有机呼吸：返回 [0,1]，基于 sin
private func breathe(_ t: Double, period: Double = 4.0, phase: Double = 0) -> Double {
    (1 + sin((t + phase) * 2 * .pi / period)) * 0.5
}

private func lp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

/// 圆形 CGRect
private func cr(_ cx: Double, _ cy: Double, _ r: Double) -> CGRect {
    CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
}

/// 模拟高斯辉光：三圈叠加渲染软光点
private func glow(_ ctx: GraphicsContext, _ x: Double, _ y: Double,
                  _ color: Color, _ intensity: Double, _ r: Double = 2.0) {
    ctx.fill(Path(ellipseIn: cr(x, y, r)),       with: .color(color.opacity(intensity)))
    ctx.fill(Path(ellipseIn: cr(x, y, r * 3)),   with: .color(color.opacity(intensity * 0.18)))
    ctx.fill(Path(ellipseIn: cr(x, y, r * 7)),   with: .color(color.opacity(intensity * 0.05)))
}

// MARK: - PhaseBackgroundView

struct PhaseBackgroundView: View {
    let phase: String
    let animationRate: Double

    /// 去饱和柔和调——每个阶段独特但不刺眼
    private var accent: Color {
        if phase.hasPrefix("🔍") { return Color(red: 0.58, green: 0.80, blue: 1.00) }  // 雾蓝
        if phase.hasPrefix("🔗") { return Color(red: 0.75, green: 0.65, blue: 1.00) }  // 淡紫
        if phase.hasPrefix("📊") { return Color(red: 0.52, green: 1.00, blue: 0.84) }  // 冰青
        if phase.hasPrefix("🧹") { return Color(red: 1.00, green: 0.75, blue: 0.58) }  // 暖橙
        if phase.hasPrefix("🎵") { return Color(red: 1.00, green: 0.90, blue: 0.60) }  // 暖金
        if phase.hasPrefix("🌐") { return Color(red: 0.60, green: 0.92, blue: 0.70) }  // 嫩绿
        if phase.hasPrefix("✅") { return Color(red: 0.70, green: 1.00, blue: 0.82) }  // 薄荷
        return Color(red: 0.58, green: 0.80, blue: 1.00)
    }

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.09).ignoresSafeArea()

            // 极淡的全局氛围光
            RadialGradient(
                colors: [accent.opacity(0.07), .clear],
                center: .center, startRadius: 0, endRadius: 380
            ).ignoresSafeArea()

            phaseEffect
                .id(phase)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.9), value: phase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var phaseEffect: some View {
        if phase.hasPrefix("🔍")      { SonarView(accent: accent) }
        else if phase.hasPrefix("🔗") { ConstellationView(accent: accent) }
        else if phase.hasPrefix("📊") { ScanlineView(accent: accent) }
        else if phase.hasPrefix("🧹") { DustView(accent: accent) }
        else if phase.hasPrefix("🎵") { WaveformView(accent: accent) }
        else if phase.hasPrefix("🌐") { TraversalView(accent: accent) }
        else if phase.hasPrefix("✅") { BloomView(accent: accent) }
        else                          { SonarView(accent: accent) }
    }
}

// MARK: - 1. 🔍 声呐涟漪
// 隐喻：探测信号从中心向外扩散，触达文件时短暂亮起
// 视觉：极细同心圆缓慢扩散 + 边缘发现点

struct SonarView: View {
    let accent: Color
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let cx = size.width / 2, cy = size.height / 2
                let maxR = max(size.width, size.height) * 0.60
                let period = 3.2

                // 4 圈错相位涟漪
                for i in 0..<4 {
                    let offset = Double(i) * period / 4.0
                    let p = ((t + offset) / period).truncatingRemainder(dividingBy: 1.0)
                    let r = p * maxR
                    let op = pow(1 - p, 1.6) * 0.09
                    guard op > 0.003 else { continue }
                    ctx.stroke(Path(ellipseIn: cr(cx, cy, r)),
                               with: .color(accent.opacity(op)), lineWidth: 0.7)
                    ctx.stroke(Path(ellipseIn: cr(cx, cy, r)),
                               with: .color(accent.opacity(op * 0.25)), lineWidth: 5)
                }

                // 中心脉动光点
                let pulse = breathe(t, period: 3.2)
                glow(ctx, cx, cy, accent, 0.28 + pulse * 0.12)

                // 被发现的文件点（涟漪触达时亮起）
                for i in 0..<14 {
                    let seed = UInt64(i) * 137 + 3
                    let angle = lcg(seed) * 2 * .pi
                    let dist = lcg(seed + 1) * maxR * 0.82 + maxR * 0.08
                    let px = cx + cos(angle) * dist
                    let py = cy + sin(angle) * dist
                    var maxOp = 0.0
                    for i in 0..<4 {
                        let offset = Double(i) * period / 4.0
                        let p = ((t + offset) / period).truncatingRemainder(dividingBy: 1.0)
                        let waveR = p * maxR
                        let diff = abs(waveR - dist)
                        if diff < 10 { maxOp = max(maxOp, (1 - diff / 10) * 0.65) }
                    }
                    if maxOp > 0.01 { glow(ctx, px, py, accent, maxOp, 1.5) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }
}

// MARK: - 2. 🔗 星座配对
// 隐喻：HEIC 和 MOV 像两颗星，缓慢靠近、连线、然后分开
// 视觉：5 对星点，余弦缓动靠拢，极细连线

struct ConstellationView: View {
    let accent: Color
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let W = size.width, H = size.height
                let pairs: [(UInt64, UInt64)] = [(11,21),(31,41),(51,61),(71,81),(91,101)]

                for (sa, sb) in pairs {
                    let ax0 = lcg(sa) * W * 0.7 + W * 0.15
                    let ay0 = lcg(sa + 1) * H * 0.7 + H * 0.15
                    let bx0 = lcg(sb) * W * 0.7 + W * 0.15
                    let by0 = lcg(sb + 1) * H * 0.7 + H * 0.15

                    let period = 5.5 + lcg(sa + 2) * 2.5
                    let ph = lcg(sa + 3) * period
                    let raw = ((t + ph) / period).truncatingRemainder(dividingBy: 1.0)

                    // 0→0.35 靠拢，0.35→0.65 保持，0.65→1 分离
                    let closeness: Double
                    if raw < 0.35      { closeness = (1 - cos(raw / 0.35 * .pi)) / 2 }
                    else if raw < 0.65 { closeness = 1.0 }
                    else               { closeness = (1 + cos((raw - 0.65) / 0.35 * .pi)) / 2 }

                    let mx = (ax0 + bx0) / 2, my = (ay0 + by0) / 2
                    let ax = lp(ax0, mx, closeness * 0.28)
                    let ay = lp(ay0, my, closeness * 0.28)
                    let bx = lp(bx0, mx, closeness * 0.28)
                    let by = lp(by0, my, closeness * 0.28)

                    // 连线（靠近时才出现）
                    if closeness > 0.08 {
                        var line = Path()
                        line.move(to: .init(x: ax, y: ay))
                        line.addLine(to: .init(x: bx, y: by))
                        ctx.stroke(line, with: .color(accent.opacity(closeness * 0.13)), lineWidth: 0.5)
                    }

                    let baseGlow = 0.14 + closeness * 0.18
                    glow(ctx, ax, ay, accent, baseGlow, 2.0)
                    glow(ctx, bx, by, .white,  baseGlow * 0.75, 2.0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }
}

// MARK: - 3. 📊 扫描线
// 隐喻：pHash 计算像逐列扫描图像，留下计算痕迹
// 视觉：一条垂直扫描线从左到右，身后留下极淡的点迹

struct ScanlineView: View {
    let accent: Color
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let W = size.width, H = size.height
                let period = 7.0
                let scanX = ((t / period).truncatingRemainder(dividingBy: 1.0)) * (W + 60) - 30

                // 扫描线：主线 + 辉光
                var vline = Path()
                vline.move(to: .init(x: scanX, y: 0))
                vline.addLine(to: .init(x: scanX, y: H))
                ctx.stroke(vline, with: .color(accent.opacity(0.20)), lineWidth: 0.8)
                ctx.stroke(vline, with: .color(accent.opacity(0.04)), lineWidth: 12)

                // 扫描后留下的点（越久远越淡）
                for i in 0..<90 {
                    let seed = UInt64(i) * 83 + 11
                    let px = lcg(seed) * W
                    let py = lcg(seed + 1) * H
                    guard px < scanX - 2 else { continue }
                    let age = (scanX - px) / W
                    let op = max(0, 1 - age * 1.6) * 0.10
                    if op > 0.004 {
                        ctx.fill(Path(ellipseIn: cr(px, py, 0.9)),
                                 with: .color(accent.opacity(op)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }
}

// MARK: - 4. 🧹 尘埃消散
// 隐喻：冗余文件化为尘埃，从四周向中心漂移后消失
// 视觉：稀疏粒子向中心飘落，中心有极轻的消失涟漪

struct DustView: View {
    let accent: Color
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let W = size.width, H = size.height
                let cx = W / 2, cy = H / 2

                for i in 0..<45 {
                    let seed = UInt64(i) * 61 + 17
                    let edge = Int(lcg(seed + 2) * 4)
                    let (sx, sy): (Double, Double)
                    switch edge {
                    case 0:  sx = lcg(seed) * W;  sy = -8
                    case 1:  sx = lcg(seed) * W;  sy = H + 8
                    case 2:  sx = -8;              sy = lcg(seed) * H
                    default: sx = W + 8;           sy = lcg(seed) * H
                    }
                    let period = 7.0 + lcg(seed + 3) * 5.0
                    let ph = lcg(seed + 4) * period
                    let progress = ((t + ph) / period).truncatingRemainder(dividingBy: 1.0)
                    let moveFrac = min(progress / 0.72, 1.0)
                    let fadeFrac = progress > 0.72 ? (progress - 0.72) / 0.28 : 0.0
                    let tx = cx + (lcg(seed + 5) - 0.5) * 60
                    let ty = cy + (lcg(seed + 6) - 0.5) * 60
                    let px = lp(sx, tx, moveFrac * moveFrac)
                    let py = lp(sy, ty, moveFrac * moveFrac)
                    let op = (1 - fadeFrac) * (0.04 + moveFrac * 0.07)
                    let r = (1 - moveFrac) * 1.4 + 0.4
                    if op > 0.004 {
                        ctx.fill(Path(ellipseIn: cr(px, py, r)),
                                 with: .color(accent.opacity(op)))
                    }
                }

                // 消失点：极轻的脉动圆
                for i in 0..<3 {
                    let offset = Double(i) * 1.0
                    let p = (t * 0.4 + offset).truncatingRemainder(dividingBy: 1.0)
                    let r = p * 55
                    let op = (1 - p) * 0.04
                    if op > 0.002 {
                        ctx.stroke(Path(ellipseIn: cr(cx, cy, r)),
                                   with: .color(accent.opacity(op)), lineWidth: 0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }
}

// MARK: - 5. 🎵 单一波形
// 隐喻：音频波形的直观呈现，振幅随时间呼吸
// 视觉：一条干净的正弦波，极浅的倒影

struct WaveformView: View {
    let accent: Color
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let W = size.width, H = size.height
                let cy = H * 0.50

                let amp   = 32.0 + breathe(t, period: 5.5) * 22.0
                let freq  = 2.8  + breathe(t, period: 14.0) * 1.4
                let speed = t * 0.38

                func wave(yOff: Double, ampScale: Double) -> Path {
                    Path { p in
                        var first = true
                        for xi in stride(from: 0.0, through: W, by: 1.5) {
                            let y = cy + yOff + sin(xi / W * freq * .pi * 2 - speed) * amp * ampScale
                            if first { p.move(to: .init(x: xi, y: y)); first = false }
                            else      { p.addLine(to: .init(x: xi, y: y)) }
                        }
                    }
                }

                // 辉光层（宽线低透）
                ctx.stroke(wave(yOff: 0, ampScale: 1.0),
                           with: .color(accent.opacity(0.05)), lineWidth: 8)
                // 主波形
                ctx.stroke(wave(yOff: 0, ampScale: 1.0),
                           with: .color(accent.opacity(0.22)), lineWidth: 1.0)
                // 倒影
                ctx.stroke(wave(yOff: 0, ampScale: -0.28),
                           with: .color(accent.opacity(0.05)), lineWidth: 0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }
}

// MARK: - 6. 🌐 图遍历
// 隐喻：BFS/DFS 在文件关系图中逐步传播，一次只点亮一条边
// 视觉：稀疏节点图，一个光点沿边缓慢滑动

struct TraversalView: View {
    let accent: Color
    private let nodeCount = 13
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let W = size.width, H = size.height

                var nodes: [(Double, Double)] = []
                for i in 0..<nodeCount {
                    let seed = UInt64(i) * 53 + 19
                    nodes.append((lcg(seed) * W * 0.72 + W * 0.14,
                                  lcg(seed + 1) * H * 0.72 + H * 0.14))
                }

                let threshold = min(W, H) * 0.30
                var edges: [(Int, Int)] = []
                for i in 0..<nodeCount {
                    for j in (i + 1)..<nodeCount {
                        let dx = nodes[i].0 - nodes[j].0
                        let dy = nodes[i].1 - nodes[j].1
                        if sqrt(dx*dx + dy*dy) < threshold { edges.append((i, j)) }
                    }
                }

                // 静态边（极淡）
                for (i, j) in edges {
                    var p = Path()
                    p.move(to: .init(x: nodes[i].0, y: nodes[i].1))
                    p.addLine(to: .init(x: nodes[j].0, y: nodes[j].1))
                    ctx.stroke(p, with: .color(.white.opacity(0.045)), lineWidth: 0.5)
                }

                // 遍历光点
                let n = edges.count
                if n > 0 {
                    let cycleLen = Double(n) * 0.38
                    let phase = (t / cycleLen).truncatingRemainder(dividingBy: 1.0)
                    let edgeIdx = Int(phase * Double(n)) % n
                    let edgeT = (phase * Double(n)).truncatingRemainder(dividingBy: 1.0)
                    let (ai, bi) = edges[edgeIdx]

                    // 活跃边高亮
                    var aLine = Path()
                    aLine.move(to: .init(x: nodes[ai].0, y: nodes[ai].1))
                    aLine.addLine(to: .init(x: nodes[bi].0, y: nodes[bi].1))
                    ctx.stroke(aLine, with: .color(accent.opacity(0.16)), lineWidth: 0.8)

                    // 滑动光点
                    let fx = lp(nodes[ai].0, nodes[bi].0, edgeT)
                    let fy = lp(nodes[ai].1, nodes[bi].1, edgeT)
                    glow(ctx, fx, fy, accent, 0.65, 2.0)

                    // 端点亮起
                    glow(ctx, nodes[ai].0, nodes[ai].1, accent,
                         0.28 + (1 - edgeT) * 0.22, 2.2)
                    glow(ctx, nodes[bi].0, nodes[bi].1, accent,
                         0.10 + edgeT * 0.22, 2.2)
                }

                // 所有静态节点
                for i in 0..<nodeCount {
                    glow(ctx, nodes[i].0, nodes[i].1, .white, 0.10, 1.6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }
}

// MARK: - 7. ✅ 径向绽放
// 隐喻：扫描完成，能量从中心向外平静地绽放
// 视觉：柔和光晕层叠呼吸 + 心跳式扩散环

struct BloomView: View {
    let accent: Color
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let cx = size.width / 2, cy = size.height / 2
                let maxR = max(size.width, size.height) * 0.48

                // 叠层呼吸光晕（4层，相位错开）
                for layer in 0..<4 {
                    let ph = Double(layer) * 1.2
                    let r = (breathe(t, period: 4.8, phase: ph) * 0.55 + 0.12) * maxR
                    let lw = Double(4 - layer) * 1.8
                    let op = 0.042 - Double(layer) * 0.008
                    ctx.stroke(Path(ellipseIn: cr(cx, cy, r)),
                               with: .color(accent.opacity(op)), lineWidth: lw)
                }

                // 心跳扩散环
                let beatPeriod = 3.8
                for i in 0..<3 {
                    let off = Double(i) * beatPeriod / 3.0
                    let p = ((t + off) / beatPeriod).truncatingRemainder(dividingBy: 1.0)
                    let r = p * maxR * 0.75
                    let op = pow(1 - p, 2.2) * 0.07
                    if op > 0.003 {
                        ctx.stroke(Path(ellipseIn: cr(cx, cy, r)),
                                   with: .color(accent.opacity(op)), lineWidth: 0.8)
                    }
                }

                // 中心常驻光点
                glow(ctx, cx, cy, accent, 0.35 + breathe(t, period: 2.6) * 0.10, 3.0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }
}
