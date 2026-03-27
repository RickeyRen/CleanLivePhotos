import SwiftUI

/// 方块矩阵动画背景。
/// `phase` 决定方块的激活模式与颜色，每个扫描阶段对应其算法的视觉特征。
struct MatrixAnimationView: View {
    let rate: Double
    let phase: String

    private let rows = 30
    private let columns = 50
    private let spacing: CGFloat = 4.0
    private let cornerRadius: CGFloat = 2.0

    @State private var gridOpacities: [[Double]]
    @State private var lastActivationTime: Date = .now
    @State private var lastFrameTime: Date = .now
    @State private var scanCursor: Int = 0   // 🔍 顺序扫描游标
    @State private var blockCursor: Int = 0  // 🧮 DCT 分块游标

    init(rate: Double, phase: String = "") {
        self.rate = min(50.0, max(1.0, rate))
        self.phase = phase
        _gridOpacities = State(initialValue: Array(repeating: Array(repeating: 0.0, count: 50), count: 30))
    }

    // MARK: - Per-Phase Colors

    private var glowColor: Color {
        switch true {
        case phase.hasPrefix("📁"): return .init(red: 0.72, green: 0.88, blue: 1.00) // 冰蓝
        case phase.hasPrefix("📝"): return .init(red: 1.00, green: 0.92, blue: 0.58) // 暖金
        case phase.hasPrefix("🔗"): return .init(red: 0.82, green: 0.55, blue: 1.00) // 紫
        case phase.hasPrefix("🔍"): return .white                                     // 纯白
        case phase.hasPrefix("🔀"): return .init(red: 0.35, green: 0.96, blue: 0.96) // 青
        case phase.hasPrefix("🧮"): return .init(red: 0.45, green: 1.00, blue: 0.68) // 薄荷绿
        case phase.hasPrefix("👀"): return .init(red: 1.00, green: 0.80, blue: 0.38) // 琥珀橙
        case phase.hasPrefix("⚖️"): return .init(red: 0.38, green: 1.00, blue: 0.72) // 翡翠绿
        default: return .init(red: 0.80, green: 0.95, blue: 1.00)
        }
    }

    private var borderColor: Color {
        switch true {
        case phase.hasPrefix("📁"): return .init(red: 0.40, green: 0.75, blue: 1.00)
        case phase.hasPrefix("📝"): return .init(red: 1.00, green: 0.72, blue: 0.18)
        case phase.hasPrefix("🔗"): return .init(red: 0.60, green: 0.18, blue: 1.00)
        case phase.hasPrefix("🔍"): return .init(red: 0.28, green: 0.60, blue: 1.00)
        case phase.hasPrefix("🔀"): return .init(red: 0.00, green: 0.80, blue: 0.90)
        case phase.hasPrefix("🧮"): return .init(red: 0.10, green: 0.88, blue: 0.48)
        case phase.hasPrefix("👀"): return .init(red: 1.00, green: 0.48, blue: 0.08)
        case phase.hasPrefix("⚖️"): return .init(red: 0.05, green: 0.82, blue: 0.55)
        default: return .init(red: 0.00, green: 0.80, blue: 1.00)
        }
    }

    // MARK: - Body

    var body: some View {
        let gc = glowColor
        let bc = borderColor
        let baseCanvas = Canvas { ctx, size in
            drawGrid(in: &ctx, size: size, glowColor: gc, borderColor: bc)
        }
        TimelineView(.animation) { context in
            ZStack {
                baseCanvas.blur(radius: 6).opacity(0.9)
                baseCanvas
            }
            .onChange(of: context.date) {
                updateGridState(for: context.date)
            }
            .onChange(of: phase) {
                for r in 0..<rows { for c in 0..<columns { gridOpacities[r][c] = 0 } }
                scanCursor = 0
                blockCursor = 0
            }
        }
        .background(.clear)
        .allowsHitTesting(false)
    }

    // MARK: - Update Loop

    private func updateGridState(for newDate: Date) {
        let dt = newDate.timeIntervalSince(lastFrameTime)

        // 🔍 快速衰减模拟字节流；其余正常衰减
        let decayRate: Double = phase.hasPrefix("🔍") ? 0.42 : 0.60
        let dm = pow(decayRate, dt)
        for r in 0..<rows {
            for c in 0..<columns {
                gridOpacities[r][c] *= dm
                if gridOpacities[r][c] < 0.01 { gridOpacities[r][c] = 0 }
            }
        }

        // ⚖️ 下半区额外加速衰减，模拟低质量格子下沉消失
        if phase.hasPrefix("⚖️") {
            for r in rows / 2 ..< rows {
                let extra = 1.0 - Double(r - rows / 2) / Double(rows) * 0.09
                for c in 0..<columns { gridOpacities[r][c] *= extra }
            }
        }

        lastFrameTime = newDate

        let interval = 1.0 / rate
        guard newDate.timeIntervalSince(lastActivationTime) >= interval else { return }

        switch true {
        case phase.hasPrefix("📁"): activateDFSWave()
        case phase.hasPrefix("📝"): activatePairs()
        case phase.hasPrefix("🔗"): activateBeams()
        case phase.hasPrefix("🔍"): activateSequential()
        case phase.hasPrefix("🔀"): activateClusters()
        case phase.hasPrefix("🧮"): activateDCTBlock()
        case phase.hasPrefix("👀"): activateHammingPairs()
        case phase.hasPrefix("⚖️"): activateQualitySort()
        default:                    activateRandom(count: Int(max(5, rate)))
        }

        lastActivationTime = newDate
    }

    // MARK: - Phase Activations

    /// 📁 DFS 扩散波：激活已亮格子的邻居，模拟目录树递归展开
    private func activateDFSWave() {
        var lit: [(Int, Int)] = []
        for r in 0..<rows {
            for c in 0..<columns where gridOpacities[r][c] > 0.25 { lit.append((r, c)) }
        }
        if lit.isEmpty {
            gridOpacities[rows / 2][columns / 2] = 1.0
            return
        }
        let dirs = [(-1,0),(1,0),(0,-1),(0,1),(-1,-1),(1,1),(-1,1),(1,-1)]
        let n = Int(max(3, rate * 0.4))
        for _ in 0..<n {
            guard let (pr, pc) = lit.randomElement(), let d = dirs.randomElement() else { continue }
            let nr = pr + d.0, nc = pc + d.1
            if nr >= 0 && nr < rows && nc >= 0 && nc < columns {
                gridOpacities[nr][nc] = Double.random(in: 0.55...1.0)
            }
        }
        // 偶尔从新位置播种，模拟进入新的子目录
        if Int.random(in: 0..<10) == 0 { activateRandom(count: 1) }
    }

    /// 📝 左右镜像配对：同行左列与右列对称同时亮起，模拟 HEIC/MOV 同名配对
    private func activatePairs() {
        let n = Int(max(2, rate * 0.15))
        for _ in 0..<n {
            let r = Int.random(in: 0..<rows)
            let c = Int.random(in: 0..<columns / 2 - 1)
            gridOpacities[r][c] = 1.0
            gridOpacities[r][columns - 1 - c] = Double.random(in: 0.75...0.95)
        }
    }

    /// 🔗 横向光束：整行从左到右全部点亮（左侧稍亮），模拟跨目录 Content ID 连线
    private func activateBeams() {
        let beams = max(1, Int(rate * 0.08))
        for _ in 0..<beams {
            let r = Int.random(in: 0..<rows)
            for c in 0..<columns {
                let b = 1.0 - Double(c) / Double(columns) * 0.35
                gridOpacities[r][c] = max(gridOpacities[r][c], b)
            }
        }
        activateRandom(count: Int(max(2, rate * 0.10)))
    }

    /// 🔍 顺序扫描：按行列顺序逐格点亮，模拟 SHA256 字节流连续读取
    private func activateSequential() {
        let total = rows * columns
        let step = Int(max(3, rate * 0.6))
        for i in 0..<step {
            let idx = (scanCursor + i) % total
            gridOpacities[idx / columns][idx % columns] = 1.0
        }
        scanCursor = (scanCursor + step) % total
    }

    /// 🔀 集群脉冲：4个固定区域交替点亮并向中心扩散，模拟 Union-Find 集合合并
    private func activateClusters() {
        let centers = [
            (rows / 4,     columns / 4),
            (rows / 4,     columns * 3 / 4),
            (rows * 3 / 4, columns / 4),
            (rows * 3 / 4, columns * 3 / 4)
        ]
        let radius = 4
        for center in centers {
            guard Double.random(in: 0...1) < 0.55 else { continue }
            let n = Int(max(2, rate * 0.18))
            for _ in 0..<n {
                let nr = max(0, min(rows - 1,    center.0 + Int.random(in: -radius...radius)))
                let nc = max(0, min(columns - 1, center.1 + Int.random(in: -radius...radius)))
                gridOpacities[nr][nc] = Double.random(in: 0.6...1.0)
            }
        }
    }

    /// 🧮 DCT 分块：按 8×8 块逐块全亮，模拟 DCT 系数分块计算
    private func activateDCTBlock() {
        let bRows = max(1, rows / 8)
        let bCols = max(1, columns / 8)
        let total = bRows * bCols
        let bRow = (blockCursor / bCols) % bRows
        let bCol = blockCursor % bCols
        let sr = bRow * 8, sc = bCol * 8
        for dr in 0..<min(8, rows - sr) {
            for dc in 0..<min(8, columns - sc) {
                gridOpacities[sr + dr][sc + dc] = Double.random(in: 0.45...1.0)
            }
        }
        blockCursor = (blockCursor + 1) % total
    }

    /// 👀 汉明列对：同行内相邻两列同时亮起（列距 = 汉明距离），偶尔高亮整列（哈希桶）
    private func activateHammingPairs() {
        let n = Int(max(2, rate * 0.20))
        for _ in 0..<n {
            let r  = Int.random(in: 0..<rows)
            let c1 = Int.random(in: 0..<columns - 8)
            let c2 = c1 + Int.random(in: 1...8)
            gridOpacities[r][c1] = 1.0
            gridOpacities[r][c2] = 0.85
        }
        if Int.random(in: 0..<7) == 0 {
            let col = Int.random(in: 0..<columns)
            for r in 0..<rows where Double.random(in: 0...1) < 0.45 {
                gridOpacities[r][col] = Double.random(in: 0.30...0.65)
            }
        }
    }

    /// ⚖️ 质量浮选：上方高概率激活且亮度高，结合下半加速衰减，优胜者留在顶部
    private func activateQualitySort() {
        let n = Int(max(3, rate * 0.30))
        for _ in 0..<n {
            let r: Int = Double.random(in: 0...1) < 0.72
                ? Int.random(in: 0..<rows / 2)
                : Int.random(in: rows / 2..<rows)
            let brightness = 1.0 - Double(r) / Double(rows) * 0.55
            gridOpacities[r][Int.random(in: 0..<columns)] = brightness
        }
    }

    private func activateRandom(count: Int) {
        for _ in 0..<count {
            gridOpacities[Int.random(in: 0..<rows)][Int.random(in: 0..<columns)] = 1.0
        }
    }

    // MARK: - Drawing

    private func drawGrid(in context: inout GraphicsContext, size: CGSize,
                          glowColor: Color, borderColor: Color) {
        let cellW = (size.width  - spacing * CGFloat(columns + 1)) / CGFloat(columns)
        let cellH = (size.height - spacing * CGFloat(rows + 1))    / CGFloat(rows)
        let cell  = min(cellW, cellH)
        guard cell > 0 else { return }

        let xOff = (size.width  - CGFloat(columns) * (cell + spacing)) / 2.0
        let yOff = (size.height - CGFloat(rows)    * (cell + spacing)) / 2.0

        for r in 0..<rows {
            for c in 0..<columns {
                let op = gridOpacities[r][c]
                guard op > 0 else { continue }
                let rect = CGRect(
                    x: xOff + CGFloat(c) * (cell + spacing) + spacing,
                    y: yOff + CGFloat(r) * (cell + spacing) + spacing,
                    width: cell, height: cell
                )
                let path = Path(roundedRect: rect, cornerRadius: cornerRadius)
                context.fill(path,   with: .color(glowColor.opacity(op * 0.6)))
                context.stroke(path, with: .color(borderColor.opacity(op)), lineWidth: 1)
            }
        }
    }
}
