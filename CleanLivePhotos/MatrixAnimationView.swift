import SwiftUI

/// A view that displays a grid of glowing cells that randomly light up and fade out.
/// The animation speed is controlled by the `rate` parameter.
struct MatrixAnimationView: View {
    // Defines how many times per second the grid state should update.
    let rate: Double
    
    // Grid configuration
    private let rows = 30
    private let columns = 50
    private let spacing: CGFloat = 4.0
    private let cornerRadius: CGFloat = 2.0
    private let glowColor = Color.white
    
    // Animation state
    @State private var gridOpacities: [[Double]]
    @State private var lastActivationTime: Date = .now
    @State private var lastFrameTime: Date = .now
    
    init(rate: Double) {
        // Ensure the rate is within a reasonable range to prevent performance issues.
        self.rate = min(50.0, max(1.0, rate)) // Cap rate between 1 and 50.
        _gridOpacities = State(initialValue: Array(repeating: Array(repeating: 0.0, count: 50), count: 30))
        _lastActivationTime = State(initialValue: .now)
        _lastFrameTime = State(initialValue: .now)
    }

    var body: some View {
        let baseCanvas = Canvas { canvasContext, size in
            drawGrid(in: &canvasContext, size: size)
        }
        
        // Use a high-frequency timeline to drive smooth animations.
        TimelineView(.animation) { context in
            ZStack {
                // Background glow layer: A blurred version of the canvas provides a high-performance glow effect.
                baseCanvas
                    .blur(radius: 6)
                    .opacity(0.9)
                
                // Foreground sharp layer: The crisp cells.
                baseCanvas
            }
            .onChange(of: context.date) {
                updateGridState(for: context.date)
            }
        }
        .background(.clear) // Ensure the view itself has a transparent background.
        .allowsHitTesting(false) // The animation should not interfere with UI interaction.
    }
    
    private func updateGridState(for newDate: Date) {
        let timeSinceLastFrame = newDate.timeIntervalSince(lastFrameTime)

        // 1. Smooth, Time-Based Decay (Every Frame)
        // This ensures the fade-out animation is always fluid, regardless of the activation rate.
        // A decay factor of 0.6 means opacity reduces to 60% over 1 second, for maximum density.
        let decayMultiplier = pow(0.6, timeSinceLastFrame)
        for r in 0..<rows {
            for c in 0..<columns {
                gridOpacities[r][c] *= decayMultiplier
                if gridOpacities[r][c] < 0.01 {
                    gridOpacities[r][c] = 0.0
                }
            }
        }

        // 2. Periodic Activation of New Cells
        // This happens at the specified `rate`, creating the discrete "pop-in" effect.
        let activationInterval = 1.0 / rate
        if newDate.timeIntervalSince(lastActivationTime) >= activationInterval {
            // Maximum intensity activation: Directly scale with the rate for a very busy effect.
            let cellsToActivate = Int(max(5, rate))
            for _ in 0..<cellsToActivate {
                let randomRow = Int.random(in: 0..<rows)
                let randomCol = Int.random(in: 0..<columns)
                // Set to a high value to make the pop-in noticeable.
                gridOpacities[randomRow][randomCol] = 1.0
            }
            lastActivationTime = newDate
        }

        // 3. Update the timestamp for the next frame calculation.
        lastFrameTime = newDate
    }

    /// Draws the entire grid of cells onto the canvas.
    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        // Calculate cell size to be a square, based on the available space.
        let cellWidth = (size.width - (spacing * CGFloat(columns + 1))) / CGFloat(columns)
        let cellHeight = (size.height - (spacing * CGFloat(rows + 1))) / CGFloat(rows)
        let cellSize = min(cellWidth, cellHeight)
        
        guard cellSize > 0 else { return }

        // Center the grid of squares within the view.
        let totalGridWidth = CGFloat(columns) * (cellSize + spacing)
        let totalGridHeight = CGFloat(rows) * (cellSize + spacing)
        let xOffset = (size.width - totalGridWidth) / 2.0
        let yOffset = (size.height - totalGridHeight) / 2.0

        // A premium, high-tech border color.
        let borderColor = Color(red: 0.6, green: 0.9, blue: 1.0)

        for r in 0..<rows {
            for c in 0..<columns {
                let opacity = gridOpacities[r][c]
                guard opacity > 0 else { continue } // Skip drawing cells that are off.
                
                let rect = CGRect(
                    x: xOffset + (CGFloat(c) * (cellSize + spacing)) + spacing,
                    y: yOffset + (CGFloat(r) * (cellSize + spacing)) + spacing,
                    width: cellSize,
                    height: cellSize
                )
                
                let path = Path(roundedRect: rect, cornerRadius: cornerRadius)
                
                // Fill the cell first. The fill provides the main body for the glow.
                context.fill(path, with: .color(glowColor.opacity(opacity * 0.6)))
                
                // Then, add a distinct stroke for the border.
                // The stroke uses a different, more vibrant color for a high-tech feel.
                context.stroke(path, with: .color(borderColor.opacity(opacity)), lineWidth: 1)
            }
        }
    }
} 