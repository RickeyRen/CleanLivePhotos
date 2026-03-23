import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - Main Content View
// 职责：仅做状态路由（< 120 行）
// 所有业务逻辑由 ScanViewModel 负责

struct ContentView: View {
    @State private var viewModel = ScanViewModel()

    var body: some View {
        let bindableVM = Bindable(viewModel)
        ZStack {
            #if os(macOS)
            WindowAccessor()
            #endif

            switch viewModel.scanState {
            case .welcome:
                WelcomeView(
                    onScan: { mode in viewModel.startScan(mode: mode) },
                    sensitivity: bindableVM.scanSensitivity
                )

            case .scanning(let progress, let animationRate):
                ScanningView(progressState: progress, animationRate: animationRate)

            case .results:
                VStack(spacing: 0) {
                    if viewModel.displayItems.isEmpty {
                        NoResultsView(onStartOver: { viewModel.resetToWelcome() })
                    } else {
                        HStack(spacing: 0) {
                            ResultsView(
                                items: viewModel.displayItems,
                                selectedFile: bindableVM.selectedFile,
                                onUpdateUserAction: { viewModel.updateUserAction(for: $0) },
                                onToggleCategory: { viewModel.toggleCategory($0) },
                                onLoadMoreInCategory: { viewModel.loadMoreInCategory($0) }
                            )
                            Divider()
                                .background(.regularMaterial)
                            PreviewPane(file: viewModel.selectedFile)
                                .frame(maxWidth: .infinity)
                        }
                    }

                    if !viewModel.allResultGroups.isEmpty {
                        FooterView(
                            groups: viewModel.allResultGroups,
                            scannedPath: viewModel.scannedFolderPath,
                            onDelete: { viewModel.executeCleaningPlan(for: viewModel.allResultGroups) },
                            onGoHome: { viewModel.resetToWelcome() }
                        )
                    }
                }

            case .error(let message):
                ErrorView(
                    message: message,
                    onDismiss: { viewModel.scanState = .welcome }
                )
                .padding(.top, 44)
            }

            // 扫描中的取消按钮
            if case .scanning = viewModel.scanState, viewModel.currentScanTask != nil {
                VStack {
                    HStack {
                        Spacer()
                        CloseButton { viewModel.cancelScan() }
                    }
                    Spacer()
                }
            }
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .background(.regularMaterial)
        .ignoresSafeArea(.all)
        .alert(viewModel.alertTitle, isPresented: bindableVM.showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.alertMessage)
        }
        .sheet(isPresented: bindableVM.showErrorDialog) {
            if let error = viewModel.currentError {
                ErrorRecoveryView(
                    error: error,
                    context: viewModel.errorContext,
                    onDismiss: { viewModel.showErrorDialog = false }
                )
            }
        }
        .preferredColorScheme(.dark)
    }
}
