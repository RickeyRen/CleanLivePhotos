import SwiftUI

// MARK: - PhaseBackgroundView
// 方案 A：液态光晕 Orbs（Apple Intelligence 风格）
// 3 个超大软光球沿 Lissajous 轨迹缓慢漂移，screen 混色如真实光源叠加

struct PhaseBackgroundView: View {
    let phase: String
    let animationRate: Double

    // MARK: Per-phase color palette
    // 每阶段三色：主光球、次光球、高光点缀
    private var palette: (Color, Color, Color) {
        switch true {
        case phase.hasPrefix("🔍"):  // 文件发现 — 电蓝·深靛·冰蓝
            return (.init(red:0.12, green:0.38, blue:0.98),
                    .init(red:0.04, green:0.12, blue:0.62),
                    .init(red:0.32, green:0.62, blue:1.00))
        case phase.hasPrefix("🔗"):  // 配对匹配 — 深紫·玫瑰·紫罗兰
            return (.init(red:0.52, green:0.18, blue:0.95),
                    .init(red:0.85, green:0.22, blue:0.60),
                    .init(red:0.68, green:0.45, blue:1.00))
        case phase.hasPrefix("📊"):  // 哈希检测 — 深青·墨青·冰青
            return (.init(red:0.04, green:0.62, blue:0.70),
                    .init(red:0.02, green:0.35, blue:0.50),
                    .init(red:0.25, green:0.92, blue:0.90))
        case phase.hasPrefix("🧹"):  // 清理删除 — 琥珀橙·朱红·暖金
            return (.init(red:0.95, green:0.35, blue:0.05),
                    .init(red:0.75, green:0.15, blue:0.10),
                    .init(red:1.00, green:0.68, blue:0.28))
        case phase.hasPrefix("🎵"):  // 音频处理 — 深金·琥珀·亮金
            return (.init(red:0.90, green:0.62, blue:0.04),
                    .init(red:0.75, green:0.35, blue:0.05),
                    .init(red:1.00, green:0.90, blue:0.38))
        case phase.hasPrefix("🌐"):  // 内容分析 — 翠绿·深蓝绿·薄荷
            return (.init(red:0.08, green:0.62, blue:0.40),
                    .init(red:0.02, green:0.32, blue:0.45),
                    .init(red:0.28, green:0.95, blue:0.65))
        case phase.hasPrefix("✅"):  // 完成整理 — 翡翠·深青绿·明绿
            return (.init(red:0.10, green:0.78, blue:0.58),
                    .init(red:0.04, green:0.42, blue:0.65),
                    .init(red:0.45, green:1.00, blue:0.78))
        default:
            return (.init(red:0.12, green:0.38, blue:0.98),
                    .init(red:0.04, green:0.12, blue:0.62),
                    .init(red:0.32, green:0.62, blue:1.00))
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

        // 2. 计算三颗光球的 Lissajous 位置
        //    使用黄金比例（0.618）作为频率系数，保证轨迹永不重复
        let a1 = t / 31.0 * .pi * 2
        let ox1 = cx + (cos(a1) * 0.22 + sin(a1 * 0.618 + 0.5) * 0.07) * W
        let oy1 = cy + (sin(a1 * 0.786) * 0.16 + cos(a1 * 1.272 + 0.3) * 0.05) * H

        let a2 = t / 23.0 * .pi * 2 + 2.094   // 相位偏移 2π/3
        let ox2 = cx + (cos(a2 * 1.082) * 0.21 + sin(a2 + 1.1) * 0.08) * W
        let oy2 = cy + (sin(a2 * 0.910) * 0.19 + cos(a2 * 0.618 + 0.9) * 0.06) * H

        let a3 = t / 17.0 * .pi * 2 + 4.189   // 相位偏移 4π/3
        let ox3 = cx + (cos(a3 * 0.786 + 0.4) * 0.18 + sin(a3 * 1.175) * 0.06) * W
        let oy3 = cy + (sin(a3 * 1.134) * 0.15 + cos(a3 * 0.720 + 1.3) * 0.07) * H

        // 3. Screen 混色绘制光球
        //    screen 模式：result = 1-(1-a)(1-b)，像真实光源叠加，不会过曝
        var sc = ctx
        sc.blendMode = .screen
        paintOrb(&sc, cx: ox1, cy: oy1, color: c1, r: base * 0.48)   // 主球·最大
        paintOrb(&sc, cx: ox2, cy: oy2, color: c2, r: base * 0.37)   // 次球·中
        paintOrb(&sc, cx: ox3, cy: oy3, color: c3, r: base * 0.24)   // 高光球·小

        // 4. 极淡呼吸环（加结构感，不抢主体）
        paintRings(ctx, cx: cx, cy: cy, base: base, t: t, color: c1)
    }

    // MARK: - Soft Orb
    // 用 4 圈同心椭圆模拟高斯衰减：外圈大而透，内核小而亮
    private func paintOrb(_ ctx: inout GraphicsContext,
                          cx: Double, cy: Double, color: Color, r: Double) {
        let layers: [(scale: Double, alpha: Double)] = [
            (1.00, 0.07),   // 外晕
            (0.60, 0.12),   // 中层
            (0.28, 0.17),   // 内层
            (0.10, 0.26),   // 核心高光
        ]
        for layer in layers {
            let lr = r * layer.scale
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx-lr, y: cy-lr, width: lr*2, height: lr*2)),
                with: .color(color.opacity(layer.alpha))
            )
        }
    }

    // MARK: - Breathing Rings
    // 5 条极细同心线，各自独立呼吸频率，透明度 1-3%
    private func paintRings(_ ctx: GraphicsContext,
                             cx: Double, cy: Double, base: Double,
                             t: Double, color: Color) {
        let rings: [(rFrac: Double, period: Double, phase: Double, opacity: Double)] = [
            (0.20, 8.5,  0.0, 0.028),
            (0.28, 11.2, 1.8, 0.022),
            (0.36, 14.0, 3.5, 0.016),
            (0.43, 17.3, 5.2, 0.012),
            (0.50, 21.0, 7.0, 0.008),
        ]
        for ring in rings {
            let pulse = (1 + sin((t + ring.phase) * 2 * .pi / ring.period)) * 0.5
            let r = base * (ring.rFrac + pulse * 0.018)
            ctx.stroke(
                Path(ellipseIn: CGRect(x: cx-r, y: cy-r, width: r*2, height: r*2)),
                with: .color(color.opacity(ring.opacity)),
                lineWidth: 0.6
            )
        }
    }
}
