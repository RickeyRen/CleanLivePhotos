import SwiftUI

// MARK: - Helpers

/// LCG 伪随机，给定种子返回 [0,1)
private func lcg(_ seed: UInt64) -> Double {
    let s = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(s >> 33) / Double(1 << 31)
}
private func eio(_ t: Double) -> Double {
    let x = max(0, min(1, t)); return x < 0.5 ? 4*x*x*x : 1 - pow(-2*x+2, 3)/2
}
private func eo(_ t: Double) -> Double { let x = max(0, min(1, t)); return 1 - pow(1-x, 3) }
private func lp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b-a)*t }
private func er(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> CGRect {
    CGRect(x: cx-rx, y: cy-ry, width: rx*2, height: ry*2)
}

// MARK: - PhaseBackgroundView

struct PhaseBackgroundView: View {
    let phase: String
    let animationRate: Double

    private var accentColor: Color {
        if phase.hasPrefix("🔍") { return Color(red: 0.2, green: 0.8, blue: 1.0) }
        if phase.hasPrefix("🔗") { return Color(red: 0.6, green: 0.4, blue: 1.0) }
        if phase.hasPrefix("📊") { return Color(red: 0.0, green: 1.0, blue: 0.6) }
        if phase.hasPrefix("🧹") { return Color(red: 1.0, green: 0.5, blue: 0.2) }
        if phase.hasPrefix("🎵") { return Color(red: 1.0, green: 0.8, blue: 0.2) }
        if phase.hasPrefix("🌐") { return Color(red: 0.4, green: 0.8, blue: 0.4) }
        if phase.hasPrefix("✅") { return Color(red: 0.2, green: 1.0, blue: 0.5) }
        return Color(red: 0.2, green: 0.8, blue: 1.0)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.06, blue: 0.12),
                         Color(red: 0.06, green: 0.08, blue: 0.18)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            RadialGradient(
                colors: [accentColor.opacity(0.12), .clear],
                center: .center, startRadius: 0, endRadius: 500
            ).ignoresSafeArea()

            phaseEffect
                .id(phase)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.6), value: phase)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var phaseEffect: some View {
        if phase.hasPrefix("🔍")      { RadarScanView(accent: accentColor) }
        else if phase.hasPrefix("🔗") { MagneticPairView(accent: accentColor) }
        else if phase.hasPrefix("📊") { HexStreamView(accent: accentColor) }
        else if phase.hasPrefix("🧹") { ParticleMergeView(accent: accentColor) }
        else if phase.hasPrefix("🎵") { SpectrumView(accent: accentColor) }
        else if phase.hasPrefix("🌐") { NetworkGraphView(accent: accentColor) }
        else if phase.hasPrefix("✅") { SortingBarsView(accent: accentColor) }
        else                          { MatrixAnimationView(rate: animationRate) }
    }
}

// MARK: - 1. 🔍 雷达扫描（文件发现阶段）

struct RadarScanView: View {
    let accent: Color
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let cx = size.width/2, cy = size.height/2
                let maxR = max(size.width, size.height) * 0.55
                let sweep = (t * 0.4).truncatingRemainder(dividingBy: 1.0)
                let sweepAngle = sweep * .pi * 2 - .pi / 2

                // 同心圆
                for i in 1...5 {
                    let r = maxR * Double(i) / 5.0
                    ctx.stroke(Path(ellipseIn: er(cx, cy, r, r)),
                               with: .color(accent.opacity(0.06 + 0.04*Double(i))), lineWidth: 1)
                }
                // 十字准线
                for (a, b) in [(CGPoint(x:cx, y:cy-maxR), CGPoint(x:cx, y:cy+maxR)),
                               (CGPoint(x:cx-maxR, y:cy), CGPoint(x:cx+maxR, y:cy))] {
                    var p = Path(); p.move(to: a); p.addLine(to: b)
                    ctx.stroke(p, with: .color(accent.opacity(0.1)), lineWidth: 1)
                }
                // 扫描扇形渐变
                for s in 0..<40 {
                    let frac = Double(s) / 40.0
                    let ang = sweepAngle - frac * .pi / 2
                    var p = Path()
                    p.move(to: .init(x: cx, y: cy))
                    p.addLine(to: .init(x: cx + cos(ang)*maxR, y: cy + sin(ang)*maxR))
                    ctx.stroke(p, with: .color(accent.opacity((1-frac)*0.18)), lineWidth: 2)
                }
                // 主射线
                var beam = Path()
                beam.move(to: .init(x: cx, y: cy))
                beam.addLine(to: .init(x: cx + cos(sweepAngle)*maxR, y: cy + sin(sweepAngle)*maxR))
                ctx.stroke(beam, with: .color(accent.opacity(0.7)), lineWidth: 2.5)

                // 发现点
                for i in 0..<18 {
                    let seed = UInt64(i) * 131 + 7
                    let angle = lcg(seed) * 2 * Double.pi
                    let dist = lcg(seed+1) * maxR * 0.9
                    let px = cx + cos(angle)*dist, py = cy + sin(angle)*dist
                    var diff = (sweepAngle - angle).truncatingRemainder(dividingBy: .pi*2)
                    if diff < 0 { diff += .pi*2 }
                    let age = diff / (.pi*2)
                    let op = eo(max(0, 1 - age*1.5)) * 0.85
                    if op > 0.01 {
                        ctx.fill(Path(ellipseIn: er(px, py, 3, 3)), with: .color(accent.opacity(op)))
                    }
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - 2. 🔗 磁性配对（HEIC/MOV 匹配阶段）

struct MagneticPairView: View {
    let accent: Color
    private let pairCount = 8
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let W = size.width, H = size.height
                for i in 0..<pairCount {
                    let seed = UInt64(i) * 97 + 13
                    let ax0 = lcg(seed)   * W*0.8 + W*0.1
                    let ay0 = lcg(seed+1) * H*0.8 + H*0.1
                    let bx0 = lcg(seed+2) * W*0.8 + W*0.1
                    let by0 = lcg(seed+3) * H*0.8 + H*0.1
                    let period = 3.0 + lcg(seed+4) * 2.0
                    let ph = lcg(seed+5) * period
                    let raw = ((t + ph) / period).truncatingRemainder(dividingBy: 1.0)
                    let pull: Double = raw < 0.5 ? eio(raw*2) : 1 - eio((raw-0.5)*2)
                    let mx = (ax0+bx0)/2, my = (ay0+by0)/2
                    let ax = lp(ax0, mx, pull), ay = lp(ay0, my, pull)
                    let bx = lp(bx0, mx, pull), by = lp(by0, my, pull)
                    var line = Path(); line.move(to: .init(x:ax, y:ay)); line.addLine(to: .init(x:bx, y:by))
                    ctx.stroke(line, with: .color(accent.opacity(0.15 + pull*0.35)), lineWidth: 1.2)
                    let r = 4.0 + pull * 3.0
                    ctx.fill(Path(ellipseIn: er(ax, ay, r, r)), with: .color(accent.opacity(0.5 + pull*0.4)))
                    ctx.fill(Path(ellipseIn: er(bx, by, r, r)), with: .color(.white.opacity(0.5 + pull*0.4)))
                }
                // 背景漂浮粒子
                for i in 0..<40 {
                    let seed = UInt64(i) * 53 + 200
                    let bx = lcg(seed) * W
                    let by0 = lcg(seed+1) * H
                    let speed = 20.0 + lcg(seed+2) * 40.0
                    var by = by0 - (t * speed).truncatingRemainder(dividingBy: H+20) + 10
                    if by < 0 { by += H }
                    ctx.fill(Path(ellipseIn: er(bx, by, 1.5, 1.5)), with: .color(accent.opacity(0.12)))
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - 3. 📊 十六进制字节流（哈希/重复检测阶段）

struct HexStreamView: View {
    let accent: Color
    private let colCount = 16
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let W = size.width, H = size.height
                let colW = W / Double(colCount)
                let rowH = 22.0
                let rowCount = Int(H/rowH) + 2
                let hexChars = ["0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F"]
                for col in 0..<colCount {
                    let speed = 40.0 + lcg(UInt64(col)*7+1) * 60.0
                    let offset = lcg(UInt64(col)*7+2) * H
                    let cx = Double(col) * colW + colW/2
                    for row in 0..<rowCount {
                        let ry = Double(row)*rowH - (t*speed + offset).truncatingRemainder(dividingBy: H+rowH)
                        let seed = UInt64(col*1000+row) * 41 + 3
                        let ch = hexChars[Int(lcg(seed)*16)]
                        let distFromCenter = abs(ry - H/2) / (H/2)
                        let op = (1 - distFromCenter) * 0.4
                        if op > 0.02 {
                            ctx.draw(Text(ch).font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(accent.opacity(op)),
                                     at: .init(x: cx, y: ry))
                        }
                    }
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - 4. 🧹 粒子聚合消除（清理阶段）

struct ParticleMergeView: View {
    let accent: Color
    private let particleCount = 60
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let W = size.width, H = size.height
                let cx = W/2, cy = H/2
                for i in 0..<particleCount {
                    let seed = UInt64(i) * 73 + 5
                    let startX = lcg(seed) * W, startY = lcg(seed+1) * H
                    let period = 2.5 + lcg(seed+2) * 2.0
                    let ph = lcg(seed+3) * period
                    let raw = ((t + ph) / period).truncatingRemainder(dividingBy: 1.0)
                    let flyFrac = min(raw / 0.7, 1.0)
                    let fadeFrac = raw > 0.7 ? (raw-0.7) / 0.3 : 0.0
                    let px = lp(startX, cx, eio(flyFrac))
                    let py = lp(startY, cy, eio(flyFrac))
                    let r = (1-flyFrac) * 4.0 + 1.0
                    let op = (1-fadeFrac) * 0.6
                    if op > 0.01 {
                        ctx.fill(Path(ellipseIn: er(px, py, r, r)), with: .color(accent.opacity(op)))
                    }
                }
                // 中心消除脉冲
                let pulse = (t * 1.5).truncatingRemainder(dividingBy: 1.0)
                ctx.stroke(Path(ellipseIn: er(cx, cy, pulse*120, pulse*120)),
                           with: .color(accent.opacity((1-pulse)*0.3)), lineWidth: 2)
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - 5. 🎵 音频频谱（音乐/媒体处理阶段）

struct SpectrumView: View {
    let accent: Color
    private let barCount = 48
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let W = size.width, H = size.height
                let barW = W / Double(barCount) * 0.65
                let baseY = H * 0.7
                for i in 0..<barCount {
                    let seed = UInt64(i) * 31 + 11
                    let f1 = 0.3 + lcg(seed) * 0.7
                    let f2 = 0.2 + lcg(seed+1) * 0.5
                    let ph1 = lcg(seed+2) * 2 * Double.pi
                    let ph2 = lcg(seed+3) * 2 * Double.pi
                    let amp  = 0.5 + 0.5 * sin(t * f1 * 2 * Double.pi + ph1)
                    let amp2 = 0.3 + 0.3 * sin(t * f2 * 2 * Double.pi + ph2)
                    let height = (amp + amp2) * H * 0.25 + 10
                    let x = (Double(i) + 0.5) * (W / Double(barCount))
                    let rect = CGRect(x: x-barW/2, y: baseY-height, width: barW, height: height)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barW/2),
                             with: .color(accent.opacity(0.4 + amp*0.45)))
                    let dot = CGRect(x: x-barW/2, y: baseY-height-4, width: barW, height: 4)
                    ctx.fill(Path(roundedRect: dot, cornerRadius: 2),
                             with: .color(.white.opacity((0.4 + amp*0.45)*0.6)))
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - 6. 🌐 神经网络图（内容分析阶段）

struct NetworkGraphView: View {
    let accent: Color
    private let nodeCount = 20
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let W = size.width, H = size.height
                var nodes: [(Double, Double)] = []
                for i in 0..<nodeCount {
                    let seed = UInt64(i) * 43 + 7
                    nodes.append((lcg(seed)*W*0.85 + W*0.075, lcg(seed+1)*H*0.85 + H*0.075))
                }
                let threshold = min(W, H) * 0.3
                for i in 0..<nodeCount {
                    for j in (i+1)..<nodeCount {
                        let dx = nodes[i].0 - nodes[j].0
                        let dy = nodes[i].1 - nodes[j].1
                        let dist = sqrt(dx*dx + dy*dy)
                        if dist < threshold {
                            let flow = (t*0.5 + lcg(UInt64(i*nodeCount+j)*17)).truncatingRemainder(dividingBy: 1.0)
                            let fx = lp(nodes[i].0, nodes[j].0, flow)
                            let fy = lp(nodes[i].1, nodes[j].1, flow)
                            let lineOp = (1 - dist/threshold) * 0.15
                            var line = Path()
                            line.move(to: .init(x: nodes[i].0, y: nodes[i].1))
                            line.addLine(to: .init(x: nodes[j].0, y: nodes[j].1))
                            ctx.stroke(line, with: .color(accent.opacity(lineOp)), lineWidth: 0.8)
                            ctx.fill(Path(ellipseIn: er(fx, fy, 2.5, 2.5)),
                                     with: .color(accent.opacity(lineOp*3)))
                        }
                    }
                }
                for i in 0..<nodeCount {
                    let seed = UInt64(i) * 43 + 7
                    let pulse = sin(t*1.2 + lcg(seed+5)*2*Double.pi) * 0.3 + 0.7
                    ctx.fill(Path(ellipseIn: er(nodes[i].0, nodes[i].1, 5*pulse, 5*pulse)),
                             with: .color(accent.opacity(0.6*pulse)))
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - 7. ✅ 排序条形图（完成/整理阶段）

struct SortingBarsView: View {
    let accent: Color
    private let barCount = 32
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let W = size.width, H = size.height
                let barW = W / Double(barCount) * 0.7
                let baseY = H * 0.72
                let sortProgress = (t * 0.12).truncatingRemainder(dividingBy: 1.0)
                for i in 0..<barCount {
                    let seed = UInt64(i) * 59 + 3
                    let randomH = lcg(seed) * H*0.45 + H*0.05
                    let sortedH = (Double(i)+1) / Double(barCount) * H*0.45 + H*0.05
                    let h = lp(randomH, sortedH, eio(sortProgress))
                    let x = (Double(i) + 0.5) * (W / Double(barCount))
                    let rect = CGRect(x: x-barW/2, y: baseY-h, width: barW, height: h)
                    let ordered = sortProgress > 0.9 ? 1.0 : Double(i)/Double(barCount)*sortProgress
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 3),
                             with: .color(accent.opacity(0.3 + ordered*0.5)))
                }
            }
            .ignoresSafeArea()
        }
    }
}
