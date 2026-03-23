import SwiftUI

struct AppLogoView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32)
                .fill(.black.opacity(0.3))
                .frame(width: 160, height: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .stroke(LinearGradient(
                            gradient: Gradient(colors: [.white.opacity(0.3), .white.opacity(0.1)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ), lineWidth: 2)
                )

            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.9))

            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundColor(Color(red: 0.8, green: 0.6, blue: 1.0))
                .offset(x: 30, y: -30)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        }
    }
}

// MARK: - 模式选择卡片

private struct ModeCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 36))
                    .foregroundColor(isSelected ? iconColor : .white.opacity(0.6))
                    .frame(height: 44)

                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.7))

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected
                          ? iconColor.opacity(0.18)
                          : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isSelected ? iconColor.opacity(0.7) : Color.white.opacity(0.12),
                                    lineWidth: isSelected ? 1.5 : 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - WelcomeView

struct WelcomeView: View {
    var onScan: (ScanMode) -> Void
    @Binding var sensitivity: ScanSensitivity
    @State private var selectedMode: ScanMode = .exactDeduplication

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            AppLogoView()
                .padding(.bottom, 8)

            VStack(spacing: 6) {
                Text("CleanLivePhotos")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("选择清理模式，开始整理您的照片库")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            // 模式选择卡片
            HStack(spacing: 12) {
                ModeCard(
                    icon: "checkmark.shield.fill",
                    iconColor: Color(red: 0.3, green: 0.8, blue: 0.5),
                    title: "精确去重",
                    subtitle: "移除字节完全相同的 Live Photo\n保留 EXIF 信息最丰富的副本\n安全，可自动执行",
                    isSelected: selectedMode == .exactDeduplication
                ) {
                    selectedMode = .exactDeduplication
                }

                ModeCard(
                    icon: "sparkle.magnifyingglass",
                    iconColor: Color(red: 0.8, green: 0.6, blue: 1.0),
                    title: "相似清理",
                    subtitle: "检测视觉相似的照片（如不同曝光）\n需手动审阅后决定删除\n类似其他照片整理软件",
                    isSelected: selectedMode == .similarPhotos
                ) {
                    selectedMode = .similarPhotos
                }
            }
            .frame(maxWidth: 540)

            // 灵敏度选择器（仅相似清理模式显示）
            if selectedMode == .similarPhotos {
                VStack(spacing: 8) {
                    Text("检测灵敏度")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .textCase(.uppercase)
                        .tracking(1.2)

                    Picker("灵敏度", selection: $sensitivity) {
                        ForEach(ScanSensitivity.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)

                    Text(sensitivity.description)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .frame(width: 280)
                        .animation(.easeInOut(duration: 0.2), value: sensitivity)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer()

            // 开始按钮
            Button {
                onScan(selectedMode)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selectedMode == .exactDeduplication
                          ? "checkmark.shield.fill"
                          : "sparkle.magnifyingglass")
                    Text(selectedMode == .exactDeduplication ? "开始精确去重" : "开始相似清理")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                }
                .padding()
                .frame(width: 220, height: 56)
                .background(
                    ZStack {
                        selectedMode == .exactDeduplication
                            ? Color(red: 0.2, green: 0.6, blue: 0.4)
                            : Color(red: 0.5, green: 0.3, blue: 0.9)
                        RadialGradient(
                            gradient: Gradient(colors: [.white.opacity(0.3), .clear]),
                            center: .center,
                            startRadius: 1,
                            endRadius: 80
                        )
                    }
                )
                .foregroundColor(.white)
                .clipShape(Capsule())
                .shadow(
                    color: (selectedMode == .exactDeduplication
                            ? Color(red: 0.2, green: 0.6, blue: 0.4)
                            : Color(red: 0.5, green: 0.3, blue: 0.9)).opacity(0.5),
                    radius: 20, y: 10
                )
            }
            .buttonStyle(PlainButtonStyle())
            .animation(.easeInOut(duration: 0.2), value: selectedMode)
            .padding(.bottom, 50)
        }
        .animation(.easeInOut(duration: 0.25), value: selectedMode)
    }
}
