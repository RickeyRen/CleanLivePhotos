import SwiftUI

struct ScanningView: View {
    let progressState: ScanningProgress
    let animationRate: Double

    var body: some View {
        ZStack {
            MatrixAnimationView(rate: animationRate)
                .ignoresSafeArea()
            
            // 🚀 固定尺寸的扫描卡片，确保所有内容都能完整显示
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
                            LinearGradient(gradient: Gradient(colors: [.white, .white.opacity(0.6)]), startPoint: .top, endPoint: .bottom)
                        )
                        .rotationEffect(Angle(degrees: 270.0))
                        .animation(.linear(duration: 0.2), value: progressState.progress)
                        .shadow(color: .white.opacity(0.4), radius: 10)

                    Text(String(format: "%.0f%%", min(progressState.progress, 1.0) * 100.0))
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .animation(.none, value: progressState.progress)
                }
                .frame(width: 180, height: 180)

                // 🚀 文字内容区域 - 设置固定高度确保布局稳定
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Text(progressState.phase)
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)

                        Text(progressState.detail)
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.7)
                            .frame(minHeight: 60) // 🚀 固定最小高度确保布局稳定

                        if progressState.totalFiles > 0 {
                            Text("\(progressState.processedFiles) / \(progressState.totalFiles)")
                                .font(.body.monospacedDigit())
                                .foregroundColor(.secondary)
                                .padding(.top, 5)
                        }
                    }
                    .frame(minHeight: 120) // 🚀 为主要文字区域设置最小高度

                    // --- 详细统计信息 ---
                    VStack(spacing: 8) {
                        if progressState.estimatedTimeRemaining != nil || progressState.processingSpeedMBps != nil {
                            HStack(spacing: 30) {
                                if let etr = progressState.estimatedTimeRemaining {
                                    VStack(spacing: 4) {
                                        HStack(spacing: 4) {
                                            Text("ETR")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            if let confidence = progressState.confidence {
                                                Text("(\(confidence.description))")
                                                    .font(.caption2)
                                                    .foregroundColor(confidenceColor(confidence))
                                            }
                                        }
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
                        }
                    }
                    .frame(minHeight: 50) // 🚀 为统计信息区域设置最小高度
                }
                .frame(maxWidth: 380) // 🚀 设置文字区域的最大宽度
            }
            .frame(minWidth: 480, minHeight: 420) // 🚀 设置整个卡片的最小尺寸
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

    private func confidenceColor(_ confidence: ETAConfidence) -> Color {
        switch confidence {
        case .low:
            return .orange
        case .medium:
            return .yellow
        case .high:
            return .green
        case .veryHigh:
            return .blue
        }
    }
} 