import SwiftUI

struct ScanningView: View {
    let progressState: ScanningProgress
    let animationRate: Double

    private var phaseColor: Color {
        // Assign a unique, high-tech color to each scanning phase.
        switch progressState.phase {
        case "Phase 1: Discovering":
            return Color(red: 0.2, green: 0.8, blue: 1.0) // Data Blue
        case "Phase 2: Analyzing Content":
            return Color(red: 0.9, green: 0.3, blue: 0.8) // Processing Purple
        case "Phase 3: Building Plan":
            return Color(red: 1.0, green: 0.8, blue: 0.3) // Wisdom Gold
        case "Scan Complete":
            return Color(red: 0.4, green: 1.0, blue: 0.7) // Success Green
        default:
            return .white // Fallback color
        }
    }

    var body: some View {
        ZStack {
            MatrixAnimationView(rate: animationRate)
                .ignoresSafeArea()
            
            // This VStack is now the single, unified panel for all content.
            VStack(spacing: 25) {
                ZStack {
                    Circle()
                        .stroke(lineWidth: 20)
                        .opacity(0.1)
                        .foregroundColor(.primary.opacity(0.3))

                    Circle()
                        .trim(from: 0.0, to: CGFloat(min(progressState.progress, 1.0)))
                        .stroke(style: StrokeStyle(lineWidth: 20, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(
                            LinearGradient(gradient: Gradient(colors: [phaseColor, phaseColor.opacity(0.7)]), startPoint: .top, endPoint: .bottom)
                        )
                        .rotationEffect(Angle(degrees: 270.0))
                        .animation(.linear(duration: 0.2), value: progressState.progress)
                        .shadow(color: phaseColor.opacity(0.5), radius: 10)
                        .animation(.easeInOut(duration: 0.5), value: phaseColor)
                    
                    Text(String(format: "%.0f%%", min(progressState.progress, 1.0) * 100.0))
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .animation(.none, value: progressState.progress)
                }
                .frame(width: 180, height: 180)

                // The textual content is now directly inside the main panel VStack.
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Text(progressState.phase)
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)

                        Text(progressState.detail)
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if progressState.totalFiles > 0 {
                            Text("\(progressState.processedFiles) / \(progressState.totalFiles)")
                                .font(.body.monospacedDigit())
                                .foregroundColor(.secondary)
                                .padding(.top, 5)
                        }
                    }

                    // --- Detailed Stats ---
                    if progressState.estimatedTimeRemaining != nil || progressState.processingSpeedMBps != nil {
                        HStack(spacing: 30) {
                            if let etr = progressState.estimatedTimeRemaining {
                                VStack(spacing: 4) {
                                    Text("ETR")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(formatTimeInterval(etr))
                                        .font(.system(.headline, design: .monospaced))
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                        .contentTransition(.numericText(countsDown: true))
                                        .animation(.easeInOut, value: Int(etr))
                                }
                            }

                            if let speed = progressState.processingSpeedMBps {
                                VStack(spacing: 4) {
                                    Text("SPEED")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.1f MB/s", speed))
                                        .font(.system(.headline, design: .monospaced))
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
                }
            }
            // All styling is now applied to the unified container VStack.
            .padding(.vertical, 40)
            .padding(.horizontal, 50)
            .background(
                RoundedRectangle(cornerRadius: 35, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 35, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.4), .white.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: .black.opacity(0.2), radius: 25, y: 10)
        }
    }

    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "--:--" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        if interval >= 3600 {
            formatter.allowedUnits = [.hour, .minute, .second]
        }
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: interval) ?? "--:--"
    }
} 