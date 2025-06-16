import SwiftUI

// Data model for a single glowing cell.
// The coordinates are now absolute in a conceptually infinite grid.
struct ActiveCell: Identifiable {
    let id = UUID()
    let row: Int
    let col: Int
    let creationTime: Date = .now
    
    // Opacity is now a computed property based on time, ensuring smooth animation
    // regardless of frame rate.
    func opacity(at time: Date, halfLife: TimeInterval) -> Double {
        let timeSinceCreation = time.timeIntervalSince(creationTime)
        guard timeSinceCreation > 0 else { return 1.0 }
        
        let newOpacity = pow(0.5, timeSinceCreation / halfLife)
        return newOpacity < 0.01 ? 0.0 : newOpacity
    }
}

/// A view that displays a grid of glowing cells that randomly light up and fade out.
/// The animation speed is controlled by the `rate` parameter.
struct MatrixAnimationView: View {
    // Defines how many times per second the grid state should update.
    let rate: Double
    
    // Grid configuration
    private let targetCellSize: CGFloat = 15.0
    private let spacing: CGFloat = 5.0
    private let cornerRadius: CGFloat = 3.0
    private let animationHalfLife: TimeInterval = 1.5 // Time for a cell to fade to 50%
    
    // Upgraded Color Scheme
    private let fillColor = Color.white
    private let sciFiPurple = Color(red: 0.65, green: 0.25, blue: 1.0)
    
    // --- State Refactoring ---
    // Instead of a 2D array, we track only the "on" cells, which is far more performant.
    @State private var activeCells: [ActiveCell] = []
    // We no longer store grid dimensions, as the grid is now conceptually infinite.
    
    @State private var lastActivationTime: Date = .now
    
    init(rate: Double) {
        // Ensure the rate is within a reasonable range to prevent performance issues.
        self.rate = min(50.0, max(1.0, rate)) // Cap rate between 1 and 50.
    }

    var body: some View {
        // Use a GeometryReader to make the animation adaptive to the window size.
        GeometryReader { geometry in
            TimelineView(.animation) { context in
                ZStack {
                    // Background glow layer
                    Canvas { canvasContext, size in
                        drawGrid(in: &canvasContext, size: size, at: context.date)
                    }
                    .blur(radius: 6)
                    .opacity(0.7)
                    .shadow(color: sciFiPurple.opacity(0.5), radius: 10)
                    
                    // Foreground sharp layer
                    Canvas { canvasContext, size in
                        drawGrid(in: &canvasContext, size: size, at: context.date)
                    }
                }
                .ignoresSafeArea() // Apply to the ZStack to ensure the Canvases within fill the entire space.
                .onChange(of: context.date) {
                    // Update the state based on the current time and the full geometry size.
                    updateGridState(at: context.date, size: geometry.size)
                }
            }
        }
        .ignoresSafeArea() // Apply to the GeometryReader to ensure it gets the full window dimensions.
        .background(.black.opacity(0.2))
        .allowsHitTesting(false) // The animation should not interfere with UI interaction.
    }
    
    /// Calculates the visible row and column ranges based on the view size.
    /// The origin (0,0) is the center of the view.
    private func getVisibleBounds(for size: CGSize) -> (rows: Range<Int>, cols: Range<Int>) {
        let cellPitch = targetCellSize + spacing
        
        let halfVisibleCols = Int(ceil((size.width / cellPitch) / 2.0))
        let halfVisibleRows = Int(ceil((size.height / cellPitch) / 2.0))
        
        let colRange = -halfVisibleCols..<halfVisibleCols
        let rowRange = -halfVisibleRows..<halfVisibleRows
        
        return (rowRange, colRange)
    }

    private func updateGridState(at newDate: Date, size: CGSize) {
        // Prune dead cells based on their age.
        activeCells.removeAll { $0.opacity(at: newDate, halfLife: animationHalfLife) == 0.0 }
        
        // Prune cells that are no longer in the visible area after a resize (shrinking).
        let visibleBounds = getVisibleBounds(for: size)
        activeCells.removeAll {
            !visibleBounds.rows.contains($0.row) || !visibleBounds.cols.contains($0.col)
        }

        // Periodically activate new cells within the currently visible bounds.
        let activationInterval = 1.0 / rate
        if newDate.timeIntervalSince(lastActivationTime) >= activationInterval {
            guard !visibleBounds.rows.isEmpty, !visibleBounds.cols.isEmpty else { return }
            
            let cellsToActivate = Int(max(1, rate * 0.25))
            for _ in 0..<cellsToActivate {
                let randomRow = Int.random(in: visibleBounds.rows)
                let randomCol = Int.random(in: visibleBounds.cols)
                
                activeCells.append(ActiveCell(row: randomRow, col: randomCol))
            }
            lastActivationTime = newDate
        }
    }

    /// Draws the active cells onto the canvas based on their absolute coordinates.
    private func drawGrid(in context: inout GraphicsContext, size: CGSize, at time: Date) {
        let viewCenterX = size.width / 2.0
        let viewCenterY = size.height / 2.0
        let cellPitch = targetCellSize + spacing // The distance from the center of one cell to the next.

        for cell in activeCells {
            let opacity = cell.opacity(at: time, halfLife: animationHalfLife)
            guard opacity > 0 else { continue }
            
            // Calculate the cell's center position relative to the view's center (our grid origin).
            let cellCenterX = viewCenterX + (CGFloat(cell.col) * cellPitch)
            let cellCenterY = viewCenterY + (CGFloat(cell.row) * cellPitch)
            
            // From the calculated center, determine the top-left origin for the rectangle.
            let rect = CGRect(
                x: cellCenterX - (targetCellSize / 2.0),
                y: cellCenterY - (targetCellSize / 2.0),
                width: targetCellSize,
                height: targetCellSize
            )
            
            let path = Path(roundedRect: rect, cornerRadius: cornerRadius)
            
            // Fill the cell first with translucent white.
            context.fill(path, with: .color(fillColor.opacity(opacity * 0.5)))
            
            // Then, add a distinct purple stroke for the border.
            context.stroke(path, with: .color(sciFiPurple.opacity(opacity)), lineWidth: 2)
        }
    }
} 