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

struct WelcomeView: View {
    var onScan: () -> Void
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            AppLogoView()
                .padding(.bottom, 20)
            
            VStack(spacing: 8) {
                Text("欢迎使用 CleanLivePhotos")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("开始一次快速而全面的扫描来整理您的照片库。")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            Button(action: onScan) {
                Text("开始扫描")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .padding()
                    .frame(width: 180, height: 60)
                    .background(
                        ZStack {
                            Color(red: 0.5, green: 0.3, blue: 0.9)
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
                    .shadow(color: Color(red: 0.5, green: 0.3, blue: 0.9).opacity(0.5), radius: 20, y: 10)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.bottom, 50)
        }
    }
} 