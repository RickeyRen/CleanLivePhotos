import SwiftUI
import AVFoundation
import ImageIO
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - Main Content View

struct ContentView: View {
    @State private var state: ViewState = .welcome
    @State private var currentScanTask: Task<Void, Error>?
    @State private var isCancelRequested = false
    @State private var showAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""

    // 错误处理状态
    @State private var showErrorDialog: Bool = false
    @State private var currentError: DetailedError?
    @State private var errorContext: ErrorContext?

    // 统一的扫描进度管理器
    @State private var progressManager = ScanProgressManager()
    @State private var folderAccessManager = FolderAccessManager()
    @State private var scanSensitivity: ScanSensitivity = .standard
    @State private var selectedFile: DisplayFile?
    @State private var scannedFolderPath: String?

    // State for results display
    @State private var allResultGroups: [FileGroup] = [] // Source of truth for all files
    @State private var masterCategorizedGroups: [CategorizedGroup] = [] // Source of truth for categories
    @State private var displayItems: [ResultDisplayItem] = [] // Flattened list for the View
    private let categoryPageSize = 50 // How many items to load at a time within a category
    
    // Store original actions to allow "Automatic" state to be restored.
    @State private var originalFileActions: [UUID: FileAction] = [:]
    

    var body: some View {
        contentView
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .sheet(isPresented: $showErrorDialog) {
                if let error = currentError {
                    ErrorRecoveryView(
                        error: error,
                        context: errorContext,
                        onDismiss: { showErrorDialog = false }
                    )
                }
            }
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var contentView: some View {
        ZStack {
            #if os(macOS)
            WindowAccessor()
            #endif

            switch state {
            case .welcome:
                WelcomeView(onScan: { mode in handleScanRequest(mode: mode) }, sensitivity: $scanSensitivity)
                
            case .scanning(let progress, let animationRate):
                ScanningView(progressState: progress, animationRate: animationRate)
                
            case .results:
                VStack(spacing: 0) {
                    if displayItems.isEmpty {
                        NoResultsView(onStartOver: resetToWelcomeState)
                    } else {
                        HStack(spacing: 0) {
                            ResultsView(
                                items: displayItems,
                                selectedFile: $selectedFile,
                                onUpdateUserAction: updateUserAction,
                                onToggleCategory: toggleCategory,
                                onLoadMoreInCategory: loadMoreInCategory
                            )
                            Divider()
                                .background(.regularMaterial)
                            PreviewPane(file: selectedFile)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    
                    if !allResultGroups.isEmpty {
                        FooterView(
                            groups: allResultGroups,
                            scannedPath: scannedFolderPath,
                            onDelete: { executeCleaningPlan(for: allResultGroups) },
                            onGoHome: resetToWelcomeState
                        )
                    }
                }
            case .error(let errorMessage):
                ErrorView(
                    message: errorMessage,
                    onDismiss: { self.state = .welcome }
                )
                .padding(.top, 44)
            }
            
            if case .scanning = state, currentScanTask != nil {
                VStack {
                    HStack {
                        Spacer()
                        CloseButton {
                            isCancelRequested = true
                            currentScanTask?.cancel()
                            state = .welcome
                        }
                    }
                    Spacer()
                }
            } else if case .results = state {
                // This close button is being removed as per user request.
                // The functionality will be moved to a new button in the FooterView.
            }
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .background(.regularMaterial)
        .ignoresSafeArea(.all)
    }
    
    private func handleScanRequest(mode: ScanMode) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            isCancelRequested = false
            ScannerConfig.sensitivity = scanSensitivity
            currentScanTask = Task {
                if await folderAccessManager.requestAccess(to: url) {
                    await MainActor.run {
                        scannedFolderPath = url.path
                    }
                    guard await folderAccessManager.startAccessing() else {
                        await MainActor.run {
                            self.state = .error("无法获取文件夹访问权限，请重新选择文件夹。")
                        }
                        return
                    }
                    defer { folderAccessManager.stopAccessing() }

                    do {
                        switch mode {
                        case .exactDeduplication:
                            try await engineExactDedup(in: url)
                        case .similarPhotos:
                            try await engineSimilarPhotos(in: url)
                        }
                    } catch is CancellationError {
                        await MainActor.run { self.state = .welcome }
                    } catch {
                        await MainActor.run {
                            self.state = .error("扫描过程中发生错误：\(error.localizedDescription)\n\n技术信息：\(String(describing: error))")
                        }
                    }
                } else {
                    await MainActor.run {
                        self.state = .error("无法获取文件夹访问权限，请重新选择文件夹并授权。")
                    }
                }
            }
        }
        #endif
    }
    
    private func executeCleaningPlan(for groups: [FileGroup]) {
        Task {
            guard await folderAccessManager.startAccessing() else {
                await MainActor.run {
                    self.alertTitle = "权限错误"
                    self.alertMessage = "无法访问文件夹，请重新选择文件夹并授权。"
                    self.showAlert = true
                }
                return
            }
            defer { folderAccessManager.stopAccessing() }

            let allFiles = groups.flatMap { $0.files }

            // --- 步骤1：执行链接修复（移动/重命名 MOV）---
            var moveSuccessCount = 0
            var moveFailCount = 0
            let filesToMove = allFiles.filter { $0.action.isMoveAction }

            for file in filesToMove {
                guard case .move(let targetURL, _) = file.action else { continue }
                do {
                    // 如果目标已有同内容文件，直接删除源文件
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        let srcHash = try? calculateHash(for: file.url)
                        let dstHash = try? calculateHash(for: targetURL)
                        if srcHash != nil && srcHash == dstHash {
                            try FileManager.default.removeItem(at: file.url)
                            moveSuccessCount += 1
                            print("🔗 目标已有相同内容，删除源文件: \(file.url.lastPathComponent)")
                            continue
                        } else {
                            // 目标有不同文件，跳过（不覆盖）
                            print("⚠️ 目标路径已有不同文件，跳过: \(targetURL.lastPathComponent)")
                            moveFailCount += 1
                            continue
                        }
                    }
                    try FileManager.default.moveItem(at: file.url, to: targetURL)
                    moveSuccessCount += 1
                    print("✅ 修复链接: \(file.url.lastPathComponent) → \(targetURL.lastPathComponent)")
                } catch {
                    print("❌ 修复链接失败: \(file.url.lastPathComponent) - \(error)")
                    moveFailCount += 1
                }
            }

            // --- 步骤2：执行删除 ---
            var deletionSuccessCount = 0
            var deletionFailCount = 0
            let filesToDelete = allFiles.filter { if case .delete = $0.action { return true } else { return false } }

            for file in filesToDelete {
                do {
                    try FileManager.default.removeItem(at: file.url)
                    deletionSuccessCount += 1
                } catch {
                    print("❌ 删除失败: \(file.fileName) - \(error)")
                    deletionFailCount += 1
                }
            }

            await MainActor.run {
                self.alertTitle = "清理完成"
                var message = ""
                if moveSuccessCount > 0 { message += "修复链接：\(moveSuccessCount) 个文件\n" }
                if moveFailCount > 0 { message += "修复失败：\(moveFailCount) 个文件\n" }
                message += "删除成功：\(deletionSuccessCount) 个文件"
                if deletionFailCount > 0 { message += "\n删除失败：\(deletionFailCount) 个文件" }
                self.alertMessage = message
                self.showAlert = true
                self.state = .welcome
            }
        }
    }
    
    // MARK: - 引擎1：精确去重（SHA256 only + EXIF 质量评分）

    /// 仅检测字节完全相同的 Live Photo 副本，用 EXIF 质量评分选最佳保留。
    /// 不运行 pHash，不合并相似组，安全可自动执行。
    private func engineExactDedup(in directoryURL: URL) async throws {
        progressManager.startScanning()
        var sha256Cache: [URL: String] = [:]

        await MainActor.run {
            self.state = .scanning(progress: ScanningProgress(
                phase: "精确去重", detail: "正在初始化...",
                progress: 0.0, totalFiles: 0, processedFiles: 0,
                estimatedTimeRemaining: nil, processingSpeedMBps: nil, confidence: .medium
            ), animationRate: 8.0)
        }

        // S1: 文件发现
        await updateUIPhase("📁 搜索文件", detail: "正在搜索媒体文件...")
        progressManager.startPhase(.fileDiscovery, totalWork: 1000)
        let allMediaFiles = try await stage1_FileDiscovery(in: directoryURL)
        print("📁 S1完成: 发现 \(allMediaFiles.count) 个媒体文件")

        // S2: 同目录配对（修复版）
        await updateUIPhase("📝 识别Live Photos", detail: "正在按目录识别Live Photo配对...")
        progressManager.startPhase(.exactNameMatching, totalWork: allMediaFiles.count)
        let pairingResult = try await stage2_SameDirectoryPairing(files: allMediaFiles)
        print("📝 S2完成: \(pairingResult.completePairs.count) 完整对，孤立 \(pairingResult.orphanHEICs.count + pairingResult.orphanMOVs.count) 个")

        // S3: Content ID 跨目录配对
        await updateUIPhase("🔗 跨目录配对", detail: "正在用 Content ID 匹配孤立文件...")
        progressManager.updateTotalWork(pairingResult.orphanHEICs.count + pairingResult.orphanMOVs.count)
        let (crossDirPairs, stillOrphanHEICs, stillOrphanMOVs) = try await stage3_ContentIDPairing(
            orphanHEICs: pairingResult.orphanHEICs,
            orphanMOVs: pairingResult.orphanMOVs
        )

        // 所有种子组 = 同目录完整对 + Content ID 跨目录对
        let allSeedGroups = pairingResult.completePairs + crossDirPairs
        // 孤立文件 = 两次配对后仍未配对的文件（全部作为单文件处理）
        let allOrphanFiles = stillOrphanHEICs + stillOrphanMOVs
        print("🔗 S3完成: 总种子组 \(allSeedGroups.count) 个，孤立单文件 \(allOrphanFiles.count) 个")

        // S4: SHA256 内容哈希扩展（基于所有种子组）
        await updateUIPhase("🔍 检查文件内容", detail: "正在计算 SHA256 找重复副本...")
        progressManager.startPhase(.contentHashExpansion, totalWork: allMediaFiles.count)
        let expandedGroups = try await stage3_ContentHashExpansion(
            seedGroups: allSeedGroups,
            allFiles: allMediaFiles,
            sha256Cache: &sha256Cache
        )
        print("🔗 S4完成: 扩展为 \(expandedGroups.count) 个内容组")

        // S4.2: SHA256 跨组合并
        await updateUIPhase("🔀 合并重复内容", detail: "正在合并完全相同的文件组...")
        progressManager.updateTotalWork(expandedGroups.count)
        let contentGroups = try await stage3_2_CrossGroupSHA256Merging(
            contentGroups: expandedGroups,
            sha256Cache: sha256Cache
        )
        print("🚀 S4.2完成: 合并后剩余 \(contentGroups.count) 个内容组")

        // S5: 孤立单文件重复检测（SHA256 only）
        await updateUIPhase("🔍 查找重复文件", detail: "正在查找重复的单文件...")
        var dummyDHashCache: [URL: UInt64] = [:]
        let processedByLivePhoto = Set(contentGroups.flatMap { $0.files })
        let singleFileGroups = try await detectSingleFileDuplicates(
            allFiles: allMediaFiles,
            processedFiles: processedByLivePhoto,
            sha256Cache: &sha256Cache,
            dHashCache: &dummyDHashCache
        )
        print("🔍 S5完成: 发现 \(singleFileGroups.count) 个单文件重复组")

        // 找出所有已分组的文件（Live Photo 组 + 单文件重复组）
        let allGroupedFiles = Set((contentGroups + singleFileGroups).flatMap { $0.files })
        // 孤立文件：经过所有配对和重复检测后仍未出现在任何组中的文件
        // 这类文件是真正孤立的（无配对 HEIC/MOV，也无任何重复副本）
        let isolatedOrphanGroups = allOrphanFiles
            .filter { !allGroupedFiles.contains($0) }
            .map { ContentGroup(singleFile: $0) }
        if !isolatedOrphanGroups.isEmpty {
            print("⚠️ 发现 \(isolatedOrphanGroups.count) 个孤立文件（无配对、无重复副本）")
        }

        let allGroups = contentGroups + singleFileGroups + isolatedOrphanGroups

        // S6: EXIF 质量评分选优 + 链接修复分析
        await updateUIPhase("⚖️ 制定清理方案", detail: "正在用 EXIF 质量评分选最佳副本...")
        progressManager.startPhase(.fileSizeOptimization, totalWork: allGroups.count)
        let (duplicatePlans, cleanPlans) = try await stage5_QualityOptimization(contentGroups: allGroups)
        print("⚖️ S6完成: \(duplicatePlans.count) 个重复组, \(cleanPlans.count) 个干净组")

        let finalResults = convertToDisplayFormat(duplicatePlans: duplicatePlans, cleanPlans: cleanPlans)
        await MainActor.run {
            self.showResults(groups: finalResults.fileGroups, categorizedGroups: finalResults.categorizedGroups)
        }
    }

    // MARK: - 引擎2：相似清理（pHash only，不做 SHA256 合并）

    /// 对所有图片计算 pHash，检测视觉相似照片组。
    /// 跳过 SHA256 步骤，避免相同内容被合并后无法单独比较。
    /// 结果全部标记为"保留"，用户需手动选择删除哪些。
    private func engineSimilarPhotos(in directoryURL: URL) async throws {
        progressManager.startScanning()
        var dHashCache: [URL: UInt64] = [:]

        await MainActor.run {
            self.state = .scanning(progress: ScanningProgress(
                phase: "相似清理", detail: "正在初始化...",
                progress: 0.0, totalFiles: 0, processedFiles: 0,
                estimatedTimeRemaining: nil, processingSpeedMBps: nil, confidence: .medium
            ), animationRate: 8.0)
        }

        // 阶段1: 文件发现
        await updateUIPhase("📁 搜索文件", detail: "正在搜索媒体文件...")
        progressManager.startPhase(.fileDiscovery, totalWork: 1000)
        let allMediaFiles = try await stage1_FileDiscovery(in: directoryURL)
        print("📁 发现 \(allMediaFiles.count) 个媒体文件")

        // 预计算所有图片的 pHash
        await updateUIPhase("🧮 分析图片特征", detail: "正在计算感知哈希...")
        let imageFiles = allMediaFiles.filter { isImageFile($0) }
        progressManager.startPhase(.contentHashExpansion, totalWork: imageFiles.count)
        try await precomputeImageHashes(allFiles: allMediaFiles, dHashCache: &dHashCache)
        print("🧮 pHash 计算完成: \(dHashCache.count) 张图片")

        // 构建单文件 pHash 相似组（不经过 SHA256 合并）
        await updateUIPhase("👀 检测相似图片", detail: "正在检测视觉相似的照片...")
        progressManager.startPhase(.perceptualSimilarity, totalWork: imageFiles.count)
        let fileToHash = dHashCache.filter { isImageFile($0.key) }
        let similarGroups = try await applySimilarityDetection(fileToHash: fileToHash)
        print("👀 相似组检测完成: \(similarGroups.count) 个组")

        // 将相似组转为清理计划，全部标记为"保留"（用户手动决定）
        await updateUIPhase("⚖️ 整理结果", detail: "正在整理相似照片分组...")
        progressManager.startPhase(.fileSizeOptimization, totalWork: similarGroups.count)
        let (duplicatePlans, cleanPlans) = try await stage5_SimilarPhotosAllKeep(contentGroups: similarGroups)
        print("📋 相似清理: \(duplicatePlans.count) 组需审阅, \(cleanPlans.count) 组无相似")

        let finalResults = convertToDisplayFormat(duplicatePlans: duplicatePlans, cleanPlans: cleanPlans)
        await MainActor.run {
            self.showResults(groups: finalResults.fileGroups, categorizedGroups: finalResults.categorizedGroups)
        }
    }

    // MARK: - 阶段1: 文件发现
    private func stage1_FileDiscovery(in directoryURL: URL) async throws -> [URL] {
        var allMediaFiles: [URL] = []
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .typeIdentifierKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]

        guard let sequence = URLDirectoryAsyncSequence(url: directoryURL, options: options, resourceKeys: resourceKeys) else {
            throw NSError(domain: "ScanError", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建文件枚举器"])
        }

        var discoveredCount = 0
        var lastUpdateTime = Date()
        let updateInterval: TimeInterval = 0.5 // 每500ms更新一次，避免过度更新

        // 🎯 使用发现模式：显示转圈动画而不是具体进度
        await updateDiscoveryProgress(
            discovered: 0,
            detail: "正在搜索媒体文件...",
            isDiscovering: true
        )

        for await fileURL in sequence {
            if Task.isCancelled { throw CancellationError() }

            guard let typeIdentifier = try? fileURL.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
                  let fileType = UTType(typeIdentifier),
                  (fileType.conforms(to: .image) || fileType.conforms(to: .movie)) else {
                continue
            }

            allMediaFiles.append(fileURL)
            discoveredCount += 1

            // 🚀 节流更新进度，避免UI卡顿
            let now = Date()
            if now.timeIntervalSince(lastUpdateTime) >= updateInterval {
                await updateDiscoveryProgress(
                    discovered: discoveredCount,
                    detail: "已发现 \(discoveredCount) 个媒体文件...",
                    isDiscovering: true
                )
                lastUpdateTime = now
            }
        }

        // 🎉 发现完成，显示最终结果
        await updateDiscoveryProgress(
            discovered: discoveredCount,
            detail: "文件发现完成，共发现 \(discoveredCount) 个媒体文件",
            isDiscovering: false
        )

        return allMediaFiles
    }

    // MARK: - 阶段2: 同目录 Live Photo 配对（修复版）
    //
    // 【关键改动】只在同一目录内配对 HEIC + MOV：
    //   key = 目录路径 + "/" + 文件基础名
    // 跨目录同名文件不配对，避免 iPhone 文件名计数器重置造成的误配对。
    // 孤立文件（无同目录配对）输出到 orphanHEICs / orphanMOVs，
    // 后续由 Stage 3 Content ID 配对或 SHA256 重复检测处理。

    private func stage2_SameDirectoryPairing(files: [URL]) async throws -> PairingResult {
        // key = "dirPath|||baseName"，只在同目录内配对
        var dirGroups: [String: LivePhotoSeedGroup] = [:]

        for (index, url) in files.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            let ext = url.pathExtension.lowercased()
            guard ext == "heic" || ext == "mov" else { continue }

            let dir  = url.deletingLastPathComponent().path
            let base = url.deletingPathExtension().lastPathComponent
            let key  = "\(dir)||||\(base)"

            if dirGroups[key] == nil {
                dirGroups[key] = LivePhotoSeedGroup(seedName: base)
            }
            if ext == "heic" { dirGroups[key]!.heicFiles.append(url) }
            else              { dirGroups[key]!.movFiles.append(url)  }

            if index % 20 == 0 {
                await updateSmartProgress(
                    completed: index + 1,
                    detail: "正在按目录配对 (\(index + 1)/\(files.count))...",
                    totalFiles: files.count
                )
                await Task.yield()
            }
        }

        var completePairs: [LivePhotoSeedGroup] = []
        var orphanHEICs: [URL] = []
        var orphanMOVs: [URL] = []

        for group in dirGroups.values {
            if group.hasCompletePair {
                completePairs.append(group)
            } else {
                orphanHEICs.append(contentsOf: group.heicFiles)
                orphanMOVs.append(contentsOf: group.movFiles)
            }
        }

        await updateSmartProgress(
            completed: files.count,
            detail: "同目录配对完成：\(completePairs.count) 对，孤立 HEIC \(orphanHEICs.count) 个，孤立 MOV \(orphanMOVs.count) 个",
            totalFiles: files.count
        )
        print("📝 Stage 2: \(completePairs.count) 完整对，\(orphanHEICs.count) 孤立HEIC，\(orphanMOVs.count) 孤立MOV")

        return PairingResult(completePairs: completePairs, orphanHEICs: orphanHEICs, orphanMOVs: orphanMOVs)
    }

    // MARK: - 阶段3: Content Identifier 跨目录孤立文件配对（新增）
    //
    // 对同目录没有配对的孤立 HEIC/MOV，读取 Apple 内嵌的 Content Identifier UUID，
    // 用 UUID 匹配跨目录的 Live Photo 对（如 HEIC 在 2023目录，MOV 在 2024目录）。
    // 匹配失败的文件继续作为孤立单文件处理。

    private func stage3_ContentIDPairing(
        orphanHEICs: [URL],
        orphanMOVs: [URL]
    ) async throws -> (crossDirPairs: [LivePhotoSeedGroup], stillOrphanHEICs: [URL], stillOrphanMOVs: [URL]) {
        await updateSmartProgress(
            completed: 0,
            detail: "正在读取 Content Identifier 配对跨目录 Live Photo...",
            totalFiles: orphanHEICs.count + orphanMOVs.count
        )

        // 读取所有孤立 HEIC 的 Content ID
        var heicByContentID: [String: URL] = [:]
        for (i, heic) in orphanHEICs.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            if let cid = readHEICContentIdentifier(heic) {
                heicByContentID[cid] = heic
            }
            if i % 10 == 0 {
                await updateSmartProgress(
                    completed: i + 1,
                    detail: "读取 HEIC Content ID (\(i + 1)/\(orphanHEICs.count))...",
                    totalFiles: orphanHEICs.count + orphanMOVs.count
                )
                await Task.yield()
            }
        }

        // 用 MOV 的 Content ID 匹配孤立 HEIC
        var crossDirPairs: [LivePhotoSeedGroup] = []
        var matchedHEICs: Set<URL> = []
        var matchedMOVs: Set<URL> = []

        for (i, mov) in orphanMOVs.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            if let cid = await readMOVContentIdentifier(mov),
               let pairedHEIC = heicByContentID[cid] {
                var group = LivePhotoSeedGroup(seedName: pairedHEIC.deletingPathExtension().lastPathComponent)
                group.heicFiles = [pairedHEIC]
                group.movFiles  = [mov]
                // 文件名不一致时标记为可疑配对（备份工具可能重命名了 MOV）
                let heicBase = pairedHEIC.deletingPathExtension().lastPathComponent
                let movBase  = mov.deletingPathExtension().lastPathComponent
                group.isSuspiciousPairing = heicBase != movBase
                crossDirPairs.append(group)
                matchedHEICs.insert(pairedHEIC)
                matchedMOVs.insert(mov)
                if group.isSuspiciousPairing {
                    print("⚠️ 可疑 Content ID 配对（文件名不一致）: \(pairedHEIC.lastPathComponent) ↔ \(mov.lastPathComponent)")
                } else {
                    print("🔗 Content ID 跨目录配对: \(pairedHEIC.lastPathComponent) ↔ \(mov.lastPathComponent)")
                }
            }
            if i % 5 == 0 {
                await updateSmartProgress(
                    completed: orphanHEICs.count + i + 1,
                    detail: "Content ID 配对 (\(i + 1)/\(orphanMOVs.count))...",
                    totalFiles: orphanHEICs.count + orphanMOVs.count
                )
                await Task.yield()
            }
        }

        let stillOrphanHEICs = orphanHEICs.filter { !matchedHEICs.contains($0) }
        let stillOrphanMOVs  = orphanMOVs.filter  { !matchedMOVs.contains($0) }

        print("🔗 Stage 3: Content ID 配对 \(crossDirPairs.count) 对，剩余孤立 \(stillOrphanHEICs.count + stillOrphanMOVs.count) 个")
        return (crossDirPairs: crossDirPairs, stillOrphanHEICs: stillOrphanHEICs, stillOrphanMOVs: stillOrphanMOVs)
    }

    // MARK: - 阶段3: 内容哈希扩展
    private func stage3_ContentHashExpansion(seedGroups: [LivePhotoSeedGroup], allFiles: [URL], sha256Cache: inout [URL: String]) async throws -> [ContentGroup] {
        // 立即更新UI显示当前阶段
        await updateSmartProgress(
            completed: 0,
            detail: "开始内容哈希扩展...",
            totalFiles: allFiles.count
        )

        // 🚀 算法优化：从 O(N×M) 降低到 O(M)
        var contentGroups: [ContentGroup] = []
        var processedFiles: Set<URL> = []

        // 1. 首先收集所有种子组的哈希值
        var seedGroupHashes: [Int: Set<String>] = [:] // 种子组索引 -> 哈希集合
        var contentGroupsDict: [Int: ContentGroup] = [:] // 种子组索引 -> 内容组

        print("🔄 Phase 3 优化算法：预处理种子组...")
        for (groupIndex, seedGroup) in seedGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            let contentGroup = ContentGroup(seedGroup: seedGroup)
            var seedHashes: Set<String> = []

            // 计算种子组文件的哈希
            for file in seedGroup.allFiles {
                do {
                    let hash: String
                    if let cachedHash = sha256Cache[file] {
                        hash = cachedHash
                        print("📋 使用SHA256缓存: \(file.lastPathComponent)")
                    } else {
                        hash = try calculateHash(for: file)
                        sha256Cache[file] = hash
                        print("🔢 计算SHA256 [\(sha256Cache.count)]: \(file.lastPathComponent)")
                    }
                    seedHashes.insert(hash)
                    processedFiles.insert(file)

                    // 🚀 实时更新进度显示种子文件处理
                    await updateSmartProgress(
                        completed: processedFiles.count,
                        detail: "预处理种子组 (\(processedFiles.count)/\(allFiles.count) 文件)...",
                        totalFiles: allFiles.count
                    )

                    // 🚀 每计算一个SHA256就让出CPU时间
                    await Task.yield()
                } catch {
                    print("⚠️ 计算种子文件哈希失败: \(file.lastPathComponent) - \(error)")
                    processedFiles.insert(file)
                }
            }

            seedGroupHashes[groupIndex] = seedHashes
            contentGroupsDict[groupIndex] = contentGroup
        }

        // 2. 只扫描一次所有剩余文件，然后分发到对应的组
        let remainingFiles = allFiles.filter { !processedFiles.contains($0) }
        _ = remainingFiles.count
        var completedWork = 0

        print("🚀 Phase 3 优化算法：单次扫描 \(remainingFiles.count) 个文件...")

        for file in remainingFiles {
            if Task.isCancelled { throw CancellationError() }

            do {
                let fileHash: String
                if let cachedHash = sha256Cache[file] {
                    fileHash = cachedHash
                    print("📋 使用缓存 [\(sha256Cache.count)]: \(file.lastPathComponent)")
                } else {
                    fileHash = try calculateHash(for: file)
                    sha256Cache[file] = fileHash
                    print("🔢 新计算SHA256 [\(sha256Cache.count)]: \(file.lastPathComponent)")
                }

                // 🚀 关键优化：检查这个哈希属于哪些种子组
                for (groupIndex, seedHashes) in seedGroupHashes {
                    if seedHashes.contains(fileHash) {
                        contentGroupsDict[groupIndex]?.addContentMatch(file)
                        print("🔗 内容匹配: \(file.lastPathComponent) -> 组\(groupIndex + 1)")
                    }
                }

            } catch {
                print("⚠️ 计算文件哈希失败: \(file.lastPathComponent) - \(error)")
            }

            completedWork += 1

            // 🚀 更频繁的UI更新和CPU让出 - 每3个文件
            if completedWork % 3 == 0 {
                await updateSmartProgress(
                    completed: processedFiles.count + completedWork,
                    detail: "单次扫描处理中 (\(completedWork)/\(remainingFiles.count) 文件)...",
                    totalFiles: allFiles.count
                )
                await Task.yield() // 🚀 关键：让出CPU时间给UI更新
            }
        }

        // 3. 收集最终结果
        for groupIndex in 0..<seedGroups.count {
            if let contentGroup = contentGroupsDict[groupIndex] {
                contentGroups.append(contentGroup)
            }
        }

        await updateSmartProgress(
            completed: allFiles.count,
            detail: "内容哈希扩展完成",
            totalFiles: allFiles.count
        )

        return contentGroups
    }

    // MARK: - 阶段3.2: SHA256跨组合并
    private func stage3_2_CrossGroupSHA256Merging(contentGroups: [ContentGroup], sha256Cache: [URL: String]) async throws -> [ContentGroup] {
        // 🚀 不重新开始阶段，继续使用当前阶段的进度
        // 立即更新UI显示当前子阶段
        await updateSmartProgress(
            completed: 0,
            detail: "正在扩展内容组...",
            totalFiles: contentGroups.count
        )

        print("🔍 开始SHA256跨组分析，检查 \(contentGroups.count) 个组...")

        // 🚀 高性能算法：基于Union-Find的组合并
        var hashToFileGroups: [String: [URL]] = [:]  // SHA256哈希 -> 具有相同哈希的文件列表
        var fileToOriginalGroup: [URL: Int] = [:]    // 文件 -> 原始组索引

        // 1. 构建哈希到文件的映射
        for (groupIndex, group) in contentGroups.enumerated() {
            for file in group.files {
                fileToOriginalGroup[file] = groupIndex

                if let fileHash = sha256Cache[file] {
                    if hashToFileGroups[fileHash] == nil {
                        hashToFileGroups[fileHash] = []
                    }
                    hashToFileGroups[fileHash]!.append(file)
                }
            }
        }

        // 2. 找出需要合并的组
        let unionFind = UnionFind(size: contentGroups.count)
        var mergeCount = 0

        for (hash, filesWithSameHash) in hashToFileGroups {
            if filesWithSameHash.count > 1 {
                // 这些文件具有相同SHA256，需要合并它们所在的组
                let groupIndices = Set(filesWithSameHash.compactMap { fileToOriginalGroup[$0] })
                if groupIndices.count > 1 {
                    // 确实有多个不同组需要合并
                    let sortedIndices = Array(groupIndices).sorted()
                    let primaryGroup = sortedIndices[0]

                    for i in 1..<sortedIndices.count {
                        unionFind.union(primaryGroup, sortedIndices[i])
                        mergeCount += 1
                    }

                    print("🔗 哈希合并: \(hash.prefix(8))... 合并 \(groupIndices.count) 个组")
                }
            }
        }

        // 3. 根据Union-Find结果重建组
        var rootToNewGroup: [Int: ContentGroup] = [:]
        var mergedGroups: [ContentGroup] = []

        // 🛡️ Fix: 用 Set<URL> 跟踪已有文件，将 contains 从 O(N) 降为 O(1)
        var rootToMergedFilesSet: [Int: Set<URL>] = [:]

        for (originalIndex, originalGroup) in contentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            let root = unionFind.find(originalIndex)

            if let existingGroup = rootToNewGroup[root] {
                // 合并到现有组：使用 Set 进行 O(1) 去重查找
                var mergedGroup = existingGroup
                var mergedFilesSet = rootToMergedFilesSet[root] ?? Set(existingGroup.files)
                for file in originalGroup.files {
                    if !mergedFilesSet.contains(file) {
                        mergedGroup.files.append(file)
                        mergedFilesSet.insert(file)
                        mergedGroup.relationships[file] = originalGroup.relationships[file] ?? .contentDuplicate
                    }
                }
                rootToNewGroup[root] = mergedGroup
                rootToMergedFilesSet[root] = mergedFilesSet
            } else {
                // 创建新的根组
                rootToNewGroup[root] = originalGroup
                rootToMergedFilesSet[root] = Set(originalGroup.files)
            }

            if originalIndex % 10 == 0 {
                await updateSmartProgress(
                    completed: originalIndex + 1,
                    detail: "正在扩展内容组 (\(originalIndex + 1)/\(contentGroups.count))...",
                    totalFiles: contentGroups.count
                )
                await Task.yield()
            }
        }

        // 4. 收集最终结果
        mergedGroups = Array(rootToNewGroup.values)

        let originalCount = contentGroups.count
        let mergedCount = mergedGroups.count
        let savedGroups = originalCount - mergedCount

        print("🚀 SHA256跨组合并完成:")
        print("  原始组数: \(originalCount)")
        print("  合并后组数: \(mergedCount)")
        print("  减少组数: \(savedGroups) (节省 \(String(format: "%.1f", Double(savedGroups) / Double(originalCount) * 100))%)")
        print("  执行合并操作: \(mergeCount) 次")
        print("  估算减少pHash计算: ~\(savedGroups * (savedGroups + mergedCount)) 次")

        await updateSmartProgress(
            completed: contentGroups.count,
            detail: "SHA256跨组合并完成，减少 \(savedGroups) 个重复组",
            totalFiles: contentGroups.count
        )

        return mergedGroups
    }

    // MARK: - 阶段4: 感知哈希跨组相似性检测与合并
    private func stage4_PerceptualSimilarity(contentGroups: [ContentGroup], allFiles: [URL], dHashCache: inout [URL: UInt64]) async throws -> [ContentGroup] {
        // 立即更新UI显示当前阶段
        await updateSmartProgress(
            completed: 0,
            detail: "开始跨组感知相似性检测...",
            totalFiles: contentGroups.count * contentGroups.count
        )

        print("🔍 开始pHash跨组相似性分析，检查 \(contentGroups.count) 个组...")

        // 🚀 阶段4.1: 组内相似性扩展 (保留原有逻辑)
        var mutableContentGroups = try await stage4_1_IntraGroupSimilarity(contentGroups: contentGroups, allFiles: allFiles, dHashCache: &dHashCache)

        // 🚀 阶段4.2: 跨组相似性合并 (新增核心功能)
        mutableContentGroups = try await stage4_2_CrossGroupSimilarity(contentGroups: mutableContentGroups, dHashCache: dHashCache)

        await updateSmartProgress(
            completed: contentGroups.count * contentGroups.count,
            detail: "感知相似性检测和合并完成",
            totalFiles: contentGroups.count * contentGroups.count
        )

        return mutableContentGroups
    }

    // MARK: - 阶段4.1: 组内相似性扩展
    private func stage4_1_IntraGroupSimilarity(contentGroups: [ContentGroup], allFiles: [URL], dHashCache: inout [URL: UInt64]) async throws -> [ContentGroup] {
        await updateSmartProgress(
            completed: 0,
            detail: "正在进行组内相似性扩展...",
            totalFiles: contentGroups.count
        )

        var mutableContentGroups = contentGroups
        var processedFiles: Set<URL> = []
        // 使用 ScannerConfig 统一管理阈值（组内较宽松，允许同一Live Photo的轻微变体）
        let SIMILARITY_THRESHOLD = ScannerConfig.intraGroupSimilarityThreshold

        // 收集已处理的文件
        for group in contentGroups {
            processedFiles.formUnion(group.files)
        }

        let remainingImageFiles = allFiles.filter { file in
            !processedFiles.contains(file) && isImageFile(file)
        }

        // 组内扩展逻辑（保持原有实现但简化）
        for (groupIndex, group) in mutableContentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            let imageFiles = group.files.filter { isImageFile($0) }

            for seedImage in imageFiles {
                guard let seedPHash = dHashCache[seedImage] else { continue }

                for remainingFile in remainingImageFiles {
                    if processedFiles.contains(remainingFile) { continue }

                    if let filePHash = dHashCache[remainingFile] {
                        let similarity = hammingDistance(seedPHash, filePHash)
                        if similarity <= SIMILARITY_THRESHOLD {
                            mutableContentGroups[groupIndex].addSimilarFile(remainingFile, similarity: similarity)
                            processedFiles.insert(remainingFile)
                            print("📎 组内扩展: \(remainingFile.lastPathComponent) -> 组\(groupIndex + 1) (差异度: \(similarity))")
                        }
                    }
                }
            }

            // 🚀 每处理一个组就更新进度
            await updateSmartProgress(
                completed: groupIndex,
                detail: "组内扩展 (\(groupIndex + 1)/\(contentGroups.count))...",
                totalFiles: contentGroups.count
            )
        }

        return mutableContentGroups
    }

    // MARK: - 阶段4.2: 高性能pHash哈希桶合并算法
    private func stage4_2_CrossGroupSimilarity(contentGroups: [ContentGroup], dHashCache: [URL: UInt64]) async throws -> [ContentGroup] {
        await updateSmartProgress(
            completed: 0,
            detail: "正在进行高性能跨组相似性分析...",
            totalFiles: contentGroups.count
        )

        print("🚀 启动高性能pHash哈希桶算法，分析 \(contentGroups.count) 个组...")

        // 使用 ScannerConfig 统一管理阈值（跨组比组内更严格，防止不同场景误合并）
        let SIMILARITY_THRESHOLD = ScannerConfig.crossGroupSimilarityThreshold

        // 🚀 算法1: 哈希桶预分组 - 将相似pHash归入同一桶
        var hashBuckets: [UInt64: [Int]] = [:] // 桶哈希 -> 组索引列表
        var groupToRepresentativeHash: [Int: UInt64] = [:] // 组 -> 代表性哈希

        // 为每个组提取代表性pHash
        for (groupIndex, group) in contentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            let imageFiles = group.files.filter { isImageFile($0) }

            // 选择第一个有效的pHash作为代表
            for imageFile in imageFiles {
                if let hash = dHashCache[imageFile] {
                    groupToRepresentativeHash[groupIndex] = hash

                    // 🔧 关键优化：使用高位作为桶键，忽略低位噪音
                    let bucketKey = hash >> 16 // 取前48位作为桶键

                    if hashBuckets[bucketKey] == nil {
                        hashBuckets[bucketKey] = []
                    }
                    hashBuckets[bucketKey]!.append(groupIndex)
                    break // 每组只需要一个代表性哈希
                }
            }

            // 🚀 更频繁的进度更新和CPU让步
            // 🚀 每处理一个组就更新进度
            await updateSmartProgress(
                completed: groupIndex + 1,
                detail: "构建哈希桶 (\(groupIndex + 1)/\(contentGroups.count))...",
                totalFiles: contentGroups.count
            )

            // 让出CPU时间，保持UI响应
            await Task.yield()
        }

        print("📊 哈希桶统计: \(hashBuckets.count) 个桶, 平均每桶 \(Double(contentGroups.count) / Double(hashBuckets.count)) 个组")

        // 🚀 算法2: 桶内精确比较 - 只比较同桶内的组
        let unionFind = UnionFind(size: contentGroups.count)
        var totalComparisons = 0
        var mergeCount = 0
        var processedBuckets = 0

        for (bucketKey, groupIndices) in hashBuckets {
            if Task.isCancelled { throw CancellationError() }
            if groupIndices.count < 2 { continue } // 单独的组无需比较

            // 🛡️ Fix 4: 大桶警告 - 超过阈值时记录，并保证分批让出CPU
            if groupIndices.count > ScannerConfig.maxGroupsPerBucketBeforeBatching {
                print("⚠️ 哈希桶过大: \(groupIndices.count) 个组，进行分批处理避免UI卡顿")
            }

            print("🔍 处理桶 \(String(bucketKey, radix: 16)): \(groupIndices.count) 个组")

            // 只在同桶内进行O(n²)比较
            for i in 0..<groupIndices.count {
                for j in (i + 1)..<groupIndices.count {
                    let groupA = groupIndices[i]
                    let groupB = groupIndices[j]

                    guard let hashA = groupToRepresentativeHash[groupA],
                          let hashB = groupToRepresentativeHash[groupB] else { continue }

                    let distance = hammingDistance(hashA, hashB)
                    totalComparisons += 1

                    if distance <= SIMILARITY_THRESHOLD {
                        unionFind.union(groupA, groupB)
                        mergeCount += 1
                        print("✅ 桶内合并: 组\(groupA + 1) + 组\(groupB + 1) (差异度: \(distance))")
                    }

                    // 🛡️ Fix 4: 每5次比较让出CPU，大桶时也能保持UI响应
                    if totalComparisons % 5 == 0 {
                        await updateSmartProgress(
                            completed: min(contentGroups.count, totalComparisons * 3),
                            detail: "桶内精确比较 (已比较 \(totalComparisons) 对)...",
                            totalFiles: contentGroups.count * 4
                        )
                        await Task.yield()
                    }
                }
            }

            processedBuckets += 1

            // 每处理完一个桶让出CPU
            await updateSmartProgress(
                completed: min(contentGroups.count, processedBuckets * 5),
                detail: "桶内比较进度 (\(processedBuckets)/\(hashBuckets.count) 桶)...",
                totalFiles: contentGroups.count * 4
            )
            await Task.yield()
        }

        // 🚀 算法3: 跨桶高相似性检查（智能降级：大桶数时随机抽样）
        let allBucketKeys = Array(hashBuckets.keys).sorted()
        let isLargeBucketSet = hashBuckets.count > ScannerConfig.maxBucketsForCrossBucketCheck

        // 大桶数时随机抽样 2%，小桶数时全量检查
        let effectiveBucketKeys: [UInt64]
        if isLargeBucketSet {
            let sampleCount = max(40, Int(Double(allBucketKeys.count) * 0.02))
            effectiveBucketKeys = Array(allBucketKeys.shuffled().prefix(sampleCount))
            print("⚡ 跨桶检查：桶数 \(hashBuckets.count) > \(ScannerConfig.maxBucketsForCrossBucketCheck)，随机抽样 \(sampleCount) 个桶（覆盖率 \(String(format: "%.1f", Double(sampleCount) / Double(allBucketKeys.count) * 100))%）")
        } else {
            effectiveBucketKeys = allBucketKeys
        }

        print("🔍 执行跨桶高相似性检查（检查 \(effectiveBucketKeys.count) 个桶）...")

        for i in 0..<effectiveBucketKeys.count {
            for j in (i + 1)..<effectiveBucketKeys.count {
                let keyA = effectiveBucketKeys[i]
                let keyB = effectiveBucketKeys[j]

                // 🔧 只检查桶键相近的桶（前48位接近）
                let bucketDistance = hammingDistance(keyA, keyB)
                if bucketDistance <= 3 { // 桶键差异很小
                    let groupsA = hashBuckets[keyA]!
                    let groupsB = hashBuckets[keyB]!

                    // 检查最相似的代表
                    for groupA in groupsA.prefix(2) { // 限制检查数量
                        for groupB in groupsB.prefix(2) {
                            guard let hashA = groupToRepresentativeHash[groupA],
                                  let hashB = groupToRepresentativeHash[groupB] else { continue }

                            let distance = hammingDistance(hashA, hashB)
                            totalComparisons += 1

                            if distance <= SIMILARITY_THRESHOLD {
                                unionFind.union(groupA, groupB)
                                mergeCount += 1
                                print("✅ 跨桶合并: 组\(groupA + 1) + 组\(groupB + 1) (差异度: \(distance))")
                            }
                        }
                    }
                }
            }
            // 每处理一个桶键让出 CPU，避免大量桶时卡顿
            if i % 50 == 0 { await Task.yield() }
        }

        // 重建合并后的组
        // 🛡️ Fix: 同样用 Set<URL> 去重，避免 O(N²) 线性扫描
        var rootToMergedGroup: [Int: ContentGroup] = [:]
        var rootToMergedFilesSetPhase4: [Int: Set<URL>] = [:]

        for (originalIndex, originalGroup) in contentGroups.enumerated() {
            let root = unionFind.find(originalIndex)

            if let existingGroup = rootToMergedGroup[root] {
                var mergedGroup = existingGroup
                var mergedFilesSet = rootToMergedFilesSetPhase4[root] ?? Set(existingGroup.files)
                for file in originalGroup.files {
                    if !mergedFilesSet.contains(file) {
                        mergedGroup.files.append(file)
                        mergedFilesSet.insert(file)
                        mergedGroup.relationships[file] = originalGroup.relationships[file] ?? .perceptualSimilar(hammingDistance: SIMILARITY_THRESHOLD)
                    }
                }
                rootToMergedGroup[root] = mergedGroup
                rootToMergedFilesSetPhase4[root] = mergedFilesSet
            } else {
                rootToMergedGroup[root] = originalGroup
                rootToMergedFilesSetPhase4[root] = Set(originalGroup.files)
            }
        }

        let finalGroups = Array(rootToMergedGroup.values)
        let originalCount = contentGroups.count
        let mergedCount = finalGroups.count
        let savedGroups = originalCount - mergedCount

        print("🚀 高性能pHash合并完成:")
        print("  原始组数: \(originalCount)")
        print("  合并后组数: \(mergedCount)")
        print("  哈希桶数: \(hashBuckets.count)")
        print("  总比较次数: \(totalComparisons) (节省 \(String(format: "%.1f", (1.0 - Double(totalComparisons) / Double(originalCount * (originalCount - 1) / 2)) * 100))%)")
        print("  执行合并: \(mergeCount) 次")
        print("  减少组数: \(savedGroups)")

        return finalGroups
    }

    // MARK: - ✨ 新阶段: 高性能单文件重复检测
    private func detectSingleFileDuplicates(allFiles: [URL], processedFiles: Set<URL>, sha256Cache: inout [URL: String], dHashCache: inout [URL: UInt64]) async throws -> [ContentGroup] {
        // 找出未被Live Photo处理的文件
        let remainingFiles = allFiles.filter { !processedFiles.contains($0) }

        guard !remainingFiles.isEmpty else { return [] }

        print("🚀 开始高性能单文件重复检测：\(remainingFiles.count) 个文件")

        // ✨ 第1步：SHA256完全重复检测 (O(N)算法)
        let sha256Groups = try await detectSHA256Duplicates(files: remainingFiles, sha256Cache: &sha256Cache)
        print("📊 SHA256重复检测完成：\(sha256Groups.count) 个重复组")

        // ✨ 第2步：pHash相似性检测 (哈希桶优化算法)
        // 🛡️ 排除已被 SHA256 精确匹配的文件，防止同一对文件出现在两个重复组中
        let sha256MatchedFiles = Set(sha256Groups.flatMap { $0.files })
        let filesForPHash = remainingFiles.filter { !sha256MatchedFiles.contains($0) }
        let similarGroups = try await detectSimilarFiles(files: filesForPHash, dHashCache: &dHashCache)
        print("📊 相似性检测完成：\(similarGroups.count) 个相似组（已排除 \(sha256MatchedFiles.count) 个SHA256精确重复文件）")

        return sha256Groups + similarGroups
    }

    // MARK: - 高性能SHA256重复检测
    private func detectSHA256Duplicates(files: [URL], sha256Cache: inout [URL: String]) async throws -> [ContentGroup] {
        var hashToFiles: [String: [URL]] = [:]
        var processedCount = 0

        for file in files {
            if Task.isCancelled { throw CancellationError() }

            let hash: String
            if let cachedHash = sha256Cache[file] {
                hash = cachedHash
            } else {
                hash = try calculateHash(for: file)
                sha256Cache[file] = hash
            }

            if hashToFiles[hash] == nil {
                hashToFiles[hash] = []
            }
            hashToFiles[hash]!.append(file)

            processedCount += 1
            // 🚀 每处理一个文件就更新进度和让出CPU
            await updateSmartProgress(
                completed: processedCount,
                detail: "SHA256重复检测 (\(processedCount)/\(files.count) 文件)...",
                totalFiles: files.count
            )

            // 🚀 更频繁的CPU让出 - 每5个文件
            if processedCount % 5 == 0 {
                await Task.yield()
            }
        }

        // 只保留有重复的组
        var duplicateGroups: [ContentGroup] = []
        for (_, fileList) in hashToFiles where fileList.count > 1 {
            let primaryFile = fileList[0]
            var group = ContentGroup(singleFile: primaryFile)

            for file in fileList.dropFirst() {
                group.addIdenticalFile(file)
            }

            duplicateGroups.append(group)
            print("🔗 发现SHA256重复组: \(fileList.count) 个文件")
        }

        return duplicateGroups
    }

    // MARK: - 高性能pHash相似性检测
    private func detectSimilarFiles(files: [URL], dHashCache: inout [URL: UInt64]) async throws -> [ContentGroup] {
        let imageFiles = files.filter { isImageFile($0) }
        guard !imageFiles.isEmpty else { return [] }

        var fileToHash: [URL: UInt64] = [:]
        var processedCount = 0

        for file in imageFiles {
            if Task.isCancelled { throw CancellationError() }

            let hash: UInt64?
            if let cachedHash = dHashCache[file] {
                hash = cachedHash
            } else {
                do {
                    hash = try calculateDHash(for: file)
                    dHashCache[file] = hash
                } catch {
                    // 🛡️ 智能错误处理：静默处理HEIC解码错误，其他错误正常报告
                    if let hashError = error as? HashCalculationError,
                       case .imageDecodingError = hashError {
                        // 静默跳过损坏的图像文件
                        hash = nil
                    } else {
                        print("⚠️ 单文件相似性检测pHash失败: \(file.lastPathComponent) - \(error)")
                        hash = nil
                    }
                }
            }

            // 只有成功获取hash的文件才加入检测
            if let validHash = hash {
                fileToHash[file] = validHash
            }

            processedCount += 1
            // 🚀 每处理一个文件就更新进度和让出CPU
            await updateSmartProgress(
                completed: processedCount,
                detail: "pHash相似性检测 (\(processedCount)/\(files.count) 文件)...",
                totalFiles: files.count
            )

            if processedCount % 5 == 0 {
                await Task.yield()
            }
        }

        // 使用哈希桶算法检测相似性
        return try await applySimilarityDetection(fileToHash: fileToHash)
    }

    // MARK: - 应用相似性检测算法
    private func applySimilarityDetection(fileToHash: [URL: UInt64]) async throws -> [ContentGroup] {
        // 使用 ScannerConfig 统一阈值（单文件最严格，防止误删）
        let SIMILARITY_THRESHOLD = ScannerConfig.singleFileSimilarityThreshold

        // 哈希桶算法
        var hashBuckets: [UInt64: [URL]] = [:]
        for (file, hash) in fileToHash {
            let bucketKey = hash >> 16
            if hashBuckets[bucketKey] == nil {
                hashBuckets[bucketKey] = []
            }
            hashBuckets[bucketKey]!.append(file)
        }

        // Union-Find合并
        let fileArray = Array(fileToHash.keys)
        let fileToIndex = Dictionary(uniqueKeysWithValues: fileArray.enumerated().map { ($1, $0) })
        let unionFind = UnionFind(size: fileArray.count)

        for (_, filesInBucket) in hashBuckets where filesInBucket.count > 1 {
            for i in 0..<filesInBucket.count {
                for j in (i + 1)..<filesInBucket.count {
                    let fileA = filesInBucket[i]
                    let fileB = filesInBucket[j]

                    guard let hashA = fileToHash[fileA],
                          let hashB = fileToHash[fileB],
                          let indexA = fileToIndex[fileA],
                          let indexB = fileToIndex[fileB] else { continue }

                    let distance = hammingDistance(hashA, hashB)
                    if distance <= SIMILARITY_THRESHOLD {
                        unionFind.union(indexA, indexB)
                    }
                }
            }
            await Task.yield()
        }

        // 构建相似组
        var rootToGroup: [Int: ContentGroup] = [:]
        for (index, file) in fileArray.enumerated() {
            let root = unionFind.find(index)

            if rootToGroup[root] == nil {
                rootToGroup[root] = ContentGroup(singleFile: file)
            } else {
                let hash = fileToHash[file]!
                let rootFile = fileArray[root]
                let rootHash = fileToHash[rootFile]!
                let similarity = hammingDistance(hash, rootHash)
                rootToGroup[root]!.addSimilarFile(file, similarity: similarity)
            }
        }

        return rootToGroup.values.filter { $0.files.count > 1 }.map { $0 }
    }

    // MARK: - 阶段5: 文件大小优选和分组
    private func stage5_FileSizeOptimization(contentGroups: [ContentGroup]) async throws -> (duplicatePlans: [CleaningPlan], cleanPlans: [CleaningPlan]) {
        // 立即更新UI显示当前阶段
        await updateSmartProgress(
            completed: 0,
            detail: "开始文件大小优选和分组...",
            totalFiles: contentGroups.count
        )

        var duplicatePlans: [CleaningPlan] = []  // 有重复的组
        var cleanPlans: [CleaningPlan] = []      // 干净的Live Photo对

        for (index, group) in contentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            var plan = CleaningPlan(groupName: group.seedName)
            plan.isSuspiciousPairing = group.isSuspiciousPairing

            // ✨ 根据组类型处理不同逻辑
            switch group.groupType {
            case .livePhoto:
                // Live Photo组的处理逻辑
                let heicFiles = group.files.filter { $0.pathExtension.lowercased() == "heic" }
                let movFiles = group.files.filter { $0.pathExtension.lowercased() == "mov" }

                // 🚀 判断是否为"干净的"Live Photo对
                let isDuplicateGroup = group.files.count > 2 || // 超过一对文件
                                       heicFiles.count > 1 ||    // 多个HEIC文件
                                       movFiles.count > 1        // 多个MOV文件

                if isDuplicateGroup {
                    // 有重复的组：选择最大的HEIC和MOV文件
                    let bestHEIC = heicFiles.max { getFileSize($0) < getFileSize($1) }
                    let bestMOV = movFiles.max { getFileSize($0) < getFileSize($1) }

                    // 标记保留最佳配对
                    if let bestHEIC = bestHEIC {
                        let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(bestHEIC), countStyle: .file)
                        plan.keepFile(bestHEIC, reason: "最大HEIC文件 (\(sizeStr))")
                    }
                    if let bestMOV = bestMOV {
                        let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(bestMOV), countStyle: .file)
                        plan.keepFile(bestMOV, reason: "最大MOV文件 (\(sizeStr))")
                    }

                    // 标记删除其他文件
                    for file in group.files {
                        if file != bestHEIC && file != bestMOV {
                            let reason = group.getRelationship(file)
                            plan.deleteFile(file, reason: reason)
                        }
                    }

                    duplicatePlans.append(plan)
                    print("📋 Live Photo重复组: \(group.seedName) (共\(group.files.count)个文件)")

                } else {
                    // 干净的Live Photo对：标记为保留，无需删除任何文件
                    for file in group.files {
                        let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(file), countStyle: .file)
                        let fileType = file.pathExtension.uppercased()
                        plan.keepFile(file, reason: "干净的\(fileType)文件 (\(sizeStr))")
                    }

                    cleanPlans.append(plan)
                    print("✅ 干净Live Photo组: \(group.seedName) (完整Live Photo对)")
                }

            case .singleFile:
                // ✨ 单文件重复组的处理逻辑
                if group.files.count > 1 {
                    // 单文件重复：保留最大的文件，删除其他
                    let bestFile = group.files.max { getFileSize($0) < getFileSize($1) }!
                    let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(bestFile), countStyle: .file)
                    plan.keepFile(bestFile, reason: "最大文件 (\(sizeStr))")

                    // 标记删除其他文件
                    for file in group.files {
                        if file != bestFile {
                            let reason = group.getRelationship(file)
                            plan.deleteFile(file, reason: reason)
                        }
                    }

                    duplicatePlans.append(plan)
                    print("📋 单文件重复组: \(group.seedName) (共\(group.files.count)个文件)")
                } else {
                    // 单个文件：标记为保留
                    for file in group.files {
                        let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(file), countStyle: .file)
                        let fileType = file.pathExtension.uppercased()
                        plan.keepFile(file, reason: "单独\(fileType)文件 (\(sizeStr))")
                    }

                    cleanPlans.append(plan)
                    print("✅ 单独文件: \(group.seedName)")
                }
            }

            await updateSmartProgress(
                completed: index + 1,
                detail: "正在优选文件 (\(index + 1)/\(contentGroups.count))...",
                totalFiles: contentGroups.count
            )
        }

        print("📊 分组统计: 重复组 \(duplicatePlans.count) 个，干净组 \(cleanPlans.count) 个")
        return (duplicatePlans: duplicatePlans, cleanPlans: cleanPlans)
    }

    // MARK: - 阶段5（引擎1）：EXIF 质量评分优选 + 链接修复检测

    /// 对精确去重引擎：
    /// 1. 用 EXIF 质量评分（含路径语义、日期真实性）选最佳 HEIC
    /// 2. 选最佳 MOV（同目录同名优先）
    /// 3. 若 bestHEIC 和 bestMOV 不在同一目录或不同名 → 生成 .move 修复动作
    private func stage5_QualityOptimization(contentGroups: [ContentGroup]) async throws -> (duplicatePlans: [CleaningPlan], cleanPlans: [CleaningPlan]) {
        var duplicatePlans: [CleaningPlan] = []
        var cleanPlans: [CleaningPlan] = []

        for (index, group) in contentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            var plan = CleaningPlan(groupName: group.seedName)
            plan.isSuspiciousPairing = group.isSuspiciousPairing

            switch group.groupType {
            case .livePhoto:
                let heicFiles = group.files.filter { $0.pathExtension.lowercased() == "heic" }
                let movFiles  = group.files.filter { $0.pathExtension.lowercased() == "mov" }
                let isDuplicate = group.files.count > 2 || heicFiles.count > 1 || movFiles.count > 1

                if isDuplicate {
                    // 为每个 HEIC 计算质量分：
                    // 传入同目录同名的 MOV（用于 isSameDirPair 评分）
                    let scoredHEICs: [(URL, Double)] = heicFiles.map { heic in
                        let heicDir  = heic.deletingLastPathComponent()
                        let heicBase = heic.deletingPathExtension().lastPathComponent
                        let sameDirMOV = movFiles.first {
                            $0.deletingLastPathComponent() == heicDir &&
                            $0.deletingPathExtension().lastPathComponent == heicBase
                        }
                        let score = computeQualityScore(heicURL: heic, movURL: sameDirMOV)
                        return (heic, score.totalScore)
                    }
                    // 平局决胜规则：分数相差 < 0.5 时，优先选择路径更短的文件
                    // （路径越短 = 离根目录越近 = 越可能是原始文件而非备份副本）
                    guard let bestHEIC = scoredHEICs.max(by: { a, b in
                        let diff = a.1 - b.1
                        if abs(diff) > 0.5 { return diff < 0 }
                        return a.0.path.count > b.0.path.count   // 路径短的优先（count 小 = 更优）
                    })?.0 else {
                        continue
                    }

                    // 用最优 HEIC 的文件名作为组名（防止种子文件名是"_copy"等副本名）
                    plan = CleaningPlan(groupName: bestHEIC.deletingPathExtension().lastPathComponent)
                    plan.isSuspiciousPairing = group.isSuspiciousPairing

                    // 最佳 MOV 选取优先级：
                    // ① 与 bestHEIC 同目录同名 ② 与 bestHEIC 同名（跨目录） ③ 最大 MOV
                    let bestHEICDir  = bestHEIC.deletingLastPathComponent()
                    let bestHEICBase = bestHEIC.deletingPathExtension().lastPathComponent
                    let bestMOV: URL? = {
                        if let m = movFiles.first(where: {
                            $0.deletingLastPathComponent() == bestHEICDir &&
                            $0.deletingPathExtension().lastPathComponent == bestHEICBase
                        }) { return m }
                        if let m = movFiles.first(where: {
                            $0.deletingPathExtension().lastPathComponent == bestHEICBase
                        }) { return m }
                        return movFiles.max { getFileSize($0) < getFileSize($1) }
                    }()

                    // 标记最佳 HEIC 保留
                    let bestScore = scoredHEICs.first { $0.0 == bestHEIC }?.1 ?? 0
                    plan.keepFile(bestHEIC, reason: "EXIF质量最佳 (得分:\(Int(bestScore)))")

                    // 检查 MOV 是否需要链接修复
                    if let mov = bestMOV {
                        let movDir  = mov.deletingLastPathComponent()
                        let movBase = mov.deletingPathExtension().lastPathComponent
                        let sameDir  = movDir  == bestHEICDir
                        let sameName = movBase == bestHEICBase

                        if sameDir && sameName {
                            // 完美配对，无需修复
                            let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(mov), countStyle: .file)
                            plan.keepFile(mov, reason: "配对MOV (\(sizeStr))")
                        } else {
                            // 需要修复链接：将 MOV 移动到 bestHEIC 所在目录并重命名
                            let targetURL = bestHEICDir
                                .appendingPathComponent(bestHEICBase)
                                .appendingPathExtension("MOV")
                            // 冲突检查：目标路径是否已有文件（理论上已被删除，但防御性检查）
                            plan.moveFile(mov, to: targetURL, reason: "修复Live Photo链接")
                        }
                    }

                    // 删除其余副本
                    for file in group.files where file != bestHEIC && file != bestMOV {
                        plan.deleteFile(file, reason: group.getRelationship(file))
                    }
                    duplicatePlans.append(plan)

                } else {
                    // 无重复，但检查单对的链接是否需要修复
                    if let heic = heicFiles.first, let mov = movFiles.first {
                        let sameDir  = heic.deletingLastPathComponent() == mov.deletingLastPathComponent()
                        let sameName = heic.deletingPathExtension().lastPathComponent == mov.deletingPathExtension().lastPathComponent

                        plan.keepFile(heic, reason: "完整Live Photo对")
                        if sameDir && sameName {
                            let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(mov), countStyle: .file)
                            plan.keepFile(mov, reason: "配对MOV (\(sizeStr))")
                            cleanPlans.append(plan)
                        } else {
                            // 跨目录或跨名称的单对，需要修复链接
                            let targetURL = heic.deletingLastPathComponent()
                                .appendingPathComponent(heic.deletingPathExtension().lastPathComponent)
                                .appendingPathExtension("MOV")
                            plan.moveFile(mov, to: targetURL, reason: "修复Live Photo链接")
                            duplicatePlans.append(plan)  // 放进 duplicate 显示，让用户看到修复操作
                        }
                    } else {
                        // 不完整（只有 HEIC 或只有 MOV）
                        for file in group.files {
                            let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(file), countStyle: .file)
                            plan.keepFile(file, reason: "孤立\(file.pathExtension.uppercased()) (\(sizeStr))")
                        }
                        cleanPlans.append(plan)
                    }
                }

            case .singleFile:
                if group.files.count > 1 {
                    let bestFile = group.files.max { getFileSize($0) < getFileSize($1) }!
                    let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(bestFile), countStyle: .file)
                    plan.keepFile(bestFile, reason: "最大文件 (\(sizeStr))")
                    for file in group.files where file != bestFile {
                        plan.deleteFile(file, reason: group.getRelationship(file))
                    }
                    duplicatePlans.append(plan)
                } else {
                    for file in group.files {
                        let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(file), countStyle: .file)
                        plan.keepFile(file, reason: "单独\(file.pathExtension.uppercased()) (\(sizeStr))")
                    }
                    cleanPlans.append(plan)
                }
            }

            await updateSmartProgress(
                completed: index + 1,
                detail: "正在评分文件 (\(index + 1)/\(contentGroups.count))...",
                totalFiles: contentGroups.count
            )
        }

        print("📊 分组统计: 重复/修复组 \(duplicatePlans.count) 个，干净组 \(cleanPlans.count) 个")
        return (duplicatePlans: duplicatePlans, cleanPlans: cleanPlans)
    }

    // MARK: - 阶段5（引擎2）：相似照片全部标记为保留

    /// 将相似组全部标记为"保留"，用户在结果视图手动选择删除哪些。
    private func stage5_SimilarPhotosAllKeep(contentGroups: [ContentGroup]) async throws -> (duplicatePlans: [CleaningPlan], cleanPlans: [CleaningPlan]) {
        var duplicatePlans: [CleaningPlan] = []
        var cleanPlans: [CleaningPlan] = []

        for (index, group) in contentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            var plan = CleaningPlan(groupName: group.seedName)
            plan.isSuspiciousPairing = group.isSuspiciousPairing
            let isSimilarGroup = group.files.count > 1

            for file in group.files {
                let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(file), countStyle: .file)
                if isSimilarGroup {
                    plan.keepFile(file, reason: "相似照片（需手动审阅）— \(sizeStr)")
                } else {
                    plan.keepFile(file, reason: "独立照片 (\(sizeStr))")
                }
            }

            if isSimilarGroup {
                duplicatePlans.append(plan)
            } else {
                cleanPlans.append(plan)
            }

            await updateSmartProgress(
                completed: index + 1,
                detail: "正在整理相似组 (\(index + 1)/\(contentGroups.count))...",
                totalFiles: contentGroups.count
            )
        }

        return (duplicatePlans: duplicatePlans, cleanPlans: cleanPlans)
    }

    // MARK: - 结果转换
    private func convertToDisplayFormat(duplicatePlans: [CleaningPlan], cleanPlans: [CleaningPlan]) -> (fileGroups: [FileGroup], categorizedGroups: [CategorizedGroup]) {
        var allFileGroups: [FileGroup] = []
        var repairGroups: [FileGroup] = []           // 需要修复链接的组（含 .move 动作）
        var livePhotoDuplicateGroups: [FileGroup] = [] // 直接删除重复（无需修复）
        var singleFileDuplicateGroups: [FileGroup] = []
        var cleanFileGroups: [FileGroup] = []

        func buildDisplayFiles(from plan: CleaningPlan) -> [DisplayFile] {
            plan.actions.map { (url, action) in
                let displayAction: FileAction
                switch action {
                case .keep(let reason):   displayAction = .keepAsIs(reason: reason)
                case .delete(let reason): displayAction = .delete(reason: reason)
                case .move(let to, let reason): displayAction = .move(to: to, reason: reason)
                }
                return DisplayFile(url: url, size: getFileSize(url), action: displayAction)
            }
        }

        // 处理重复文件组（含修复组）
        for plan in duplicatePlans {
            let groupFiles = buildDisplayFiles(from: plan)
            guard !groupFiles.isEmpty else { continue }

            let hasRepair = groupFiles.contains { $0.action.isMoveAction }
            let exts = Set(groupFiles.map { $0.url.pathExtension.lowercased() })
            let isLivePhoto = exts.contains("heic") && exts.contains("mov")

            if hasRepair {
                let name: String
                if plan.isSuspiciousPairing {
                    name = "❓ 可疑配对（请核实）: \(plan.groupName)"
                } else if isLivePhoto {
                    name = "🔧 需要修复链接: \(plan.groupName)"
                } else {
                    name = "🔧 需要修复: \(plan.groupName)"
                }
                let group = FileGroup(groupName: name, files: groupFiles)
                repairGroups.append(group)
                allFileGroups.append(group)
            } else if isLivePhoto {
                let group = FileGroup(groupName: "📸 Live Photo重复: \(plan.groupName)", files: groupFiles)
                livePhotoDuplicateGroups.append(group)
                allFileGroups.append(group)
            } else {
                let group = FileGroup(groupName: "📄 单文件重复: \(plan.groupName)", files: groupFiles)
                singleFileDuplicateGroups.append(group)
                allFileGroups.append(group)
            }
        }

        // 处理干净文件组
        for plan in cleanPlans {
            let groupFiles = buildDisplayFiles(from: plan)
            guard !groupFiles.isEmpty else { continue }
            let exts = Set(groupFiles.map { $0.url.pathExtension.lowercased() })
            let isMOVOnly = exts == ["mov"]
            let isHEICOnly = exts == ["heic"] || exts == ["jpg"] || exts == ["jpeg"]
            let name: String
            if exts.contains("heic") && exts.contains("mov") {
                name = plan.isSuspiciousPairing
                    ? "❓ 可疑配对（请核实）: \(plan.groupName)"
                    : "✅ 完整Live Photo: \(plan.groupName)"
            } else if isMOVOnly {
                name = "⚠️ 孤立视频: \(plan.groupName)"
            } else if isHEICOnly {
                name = "⚠️ 孤立照片: \(plan.groupName)"
            } else {
                name = "📝 独立文件: \(plan.groupName)"
            }
            let group = FileGroup(groupName: name, files: groupFiles)
            cleanFileGroups.append(group)
            allFileGroups.append(group)
        }

        // 创建分类组
        var categorizedGroups: [CategorizedGroup] = []

        // 需要修复链接的组（最高优先级，排第一）
        if !repairGroups.isEmpty {
            let repairMOVCount = repairGroups.flatMap { $0.files }.filter { $0.action.isMoveAction }.count
            categorizedGroups.append(CategorizedGroup(
                id: "Link Repair",
                categoryName: "🔧 需要修复链接 (\(repairGroups.count) 组，\(repairMOVCount) 个文件将被重命名)",
                groups: repairGroups,
                totalSizeToDelete: repairGroups.flatMap { $0.files }
                    .filter { if case .delete = $0.action { return true }; return false }
                    .reduce(0) { $0 + $1.size },
                isExpanded: true,
                displayedGroupCount: repairGroups.count
            ))
        }

        // Live Photo 重复（直接删除）
        if !livePhotoDuplicateGroups.isEmpty {
            categorizedGroups.append(CategorizedGroup(
                id: "Live Photo Duplicates",
                categoryName: "📸 Live Photo 重复 (\(livePhotoDuplicateGroups.count) 组)",
                groups: livePhotoDuplicateGroups,
                totalSizeToDelete: livePhotoDuplicateGroups.flatMap { $0.files }
                    .filter { if case .delete = $0.action { return true }; return false }
                    .reduce(0) { $0 + $1.size },
                isExpanded: true,
                displayedGroupCount: livePhotoDuplicateGroups.count
            ))
        }

        // 单文件重复
        if !singleFileDuplicateGroups.isEmpty {
            categorizedGroups.append(CategorizedGroup(
                id: "Single File Duplicates",
                categoryName: "📄 单文件重复 (\(singleFileDuplicateGroups.count) 组)",
                groups: singleFileDuplicateGroups,
                totalSizeToDelete: singleFileDuplicateGroups.flatMap { $0.files }
                    .filter { if case .delete = $0.action { return true }; return false }
                    .reduce(0) { $0 + $1.size },
                isExpanded: true,
                displayedGroupCount: singleFileDuplicateGroups.count
            ))
        }

        // 干净文件（默认折叠）
        if !cleanFileGroups.isEmpty {
            categorizedGroups.append(CategorizedGroup(
                id: "Clean Files",
                categoryName: "✅ 无重复文件 (\(cleanFileGroups.count) 组)",
                groups: cleanFileGroups,
                totalSizeToDelete: 0,
                isExpanded: false,
                displayedGroupCount: cleanFileGroups.count
            ))
        }

        return (fileGroups: allFileGroups, categorizedGroups: categorizedGroups)
    }

    // MARK: - UI更新辅助函数

    /// 更新UI显示的阶段信息
    /// 🚀 智能阶段进度管理器 - 防止进度倒退
    private class SmartPhaseProgressManager {
        private var currentProgress: Double = 0.0
        private var currentPhaseBase: Double = 0.0
        private var currentPhaseRange: Double = 0.0
        private var currentPhaseName: String = ""

        /// 阶段定义：每个阶段的进度范围
        private let phaseRanges: [(name: String, start: Double, end: Double)] = [
            ("📁 搜索文件", 0.0, 0.10),
            ("📝 识别Live Photos", 0.10, 0.15),
            ("🔍 检查文件内容", 0.15, 0.30),
            ("🔀 合并重复内容", 0.30, 0.35),
            ("🧮 分析图片特征", 0.35, 0.50),
            ("👀 检测相似图片", 0.50, 0.80),
            ("🔍 查找重复文件", 0.80, 0.90),
            ("⚖️ 制定清理方案", 0.90, 1.0)
        ]

        func startPhase(_ phaseName: String) -> Double {
            currentPhaseName = phaseName
            // 更精确的阶段匹配
            let phaseKey = String(phaseName.split(separator: ":")[0])
            if let phase = phaseRanges.first(where: { $0.name.contains(phaseKey) }) {
                currentPhaseBase = phase.start
                currentPhaseRange = phase.end - phase.start
                currentProgress = max(currentProgress, phase.start)
                print("🎯 开始阶段: \(phaseName), 进度范围: \(phase.start*100)%-\(phase.end*100)%, 当前进度: \(currentProgress*100)%")
                return currentProgress
            }
            print("⚠️ 未找到阶段配置: \(phaseName)")
            return currentProgress
        }

        func updatePhaseProgress(_ internalProgress: Double) -> Double {
            // 将阶段内部进度映射到全局进度
            let mappedProgress = currentPhaseBase + (internalProgress * currentPhaseRange)
            currentProgress = max(currentProgress, mappedProgress)
            return currentProgress
        }

        func getCurrentProgress() -> Double {
            return currentProgress
        }

        func getCurrentPhaseName() -> String {
            return currentPhaseName
        }
    }

    private let smartProgressManager = SmartPhaseProgressManager()

    private func updateUIPhase(_ phase: String, detail: String, internalProgress: Double = 0.0) async {
        let globalProgress = smartProgressManager.startPhase(phase)
        await MainActor.run {
            let scanProgress = ScanningProgress(
                phase: phase,
                detail: detail,
                progress: globalProgress,
                totalFiles: 0,
                processedFiles: 0,
                estimatedTimeRemaining: nil,
                processingSpeedMBps: nil,
                confidence: .medium
            )
            self.state = .scanning(progress: scanProgress, animationRate: 12.0)
        }
    }

    // MARK: - 缓存优化函数

    /// 预计算所有图片的pHash以提高阶段4性能
    /// - Returns: 无法计算pHash的文件数量（用于用户提示）
    @discardableResult
    private func precomputeImageHashes(allFiles: [URL], dHashCache: inout [URL: UInt64]) async throws -> Int {
        let imageFiles = allFiles.filter { isImageFile($0) }
        let processorCount = ProcessInfo.processInfo.processorCount
        let batchSize = min(max(processorCount * 2, 20), 50)

        await updateSmartProgress(
            completed: 0,
            detail: "预计算图片感知哈希...",
            totalFiles: imageFiles.count
        )

        var completed = 0
        // 🛡️ Fix 5: 追踪 pHash 计算失败的文件（之前静默丢弃）
        var failedCount = 0
        var failedFiles: [String] = []

        for batch in imageFiles.chunked(into: batchSize) {
            if Task.isCancelled { throw CancellationError() }

            try? await withThrowingTaskGroup(of: (URL, UInt64?).self) { group in
                for imageURL in batch {
                    if Task.isCancelled { throw CancellationError() }

                    // 跳过已缓存的（注意：nil 值表示之前计算失败，不需要重试）
                    if dHashCache[imageURL] != nil {
                        completed += 1
                        continue
                    }

                    group.addTask {
                        if Task.isCancelled { throw CancellationError() }
                        do {
                            let hash = try calculateDHash(for: imageURL)
                            return (imageURL, hash)
                        } catch {
                            if let hashError = error as? HashCalculationError,
                               case .imageDecodingError = hashError {
                                // 静默处理 HEIC/HJPG 解码错误（格式不兼容）
                                return (imageURL, nil)
                            } else {
                                print("⚠️ 预计算pHash失败: \(imageURL.lastPathComponent) - \(error)")
                                return (imageURL, nil)
                            }
                        }
                    }
                }

                for try await (url, hash) in group {
                    if Task.isCancelled { throw CancellationError() }

                    if let hash = hash {
                        dHashCache[url] = hash
                    } else {
                        // 🛡️ Fix 5: 记录失败文件（而非静默丢弃）
                        failedCount += 1
                        if failedFiles.count < 10 { // 最多记录10个用于日志
                            failedFiles.append(url.lastPathComponent)
                        }
                    }
                    completed += 1

                    await updateSmartProgress(
                        completed: completed,
                        detail: "预计算pHash (\(completed)/\(imageFiles.count))...",
                        totalFiles: imageFiles.count
                    )
                }
            }

            await Task.yield()
        }

        // 🛡️ Fix 5: 向控制台报告跳过的文件统计（方便调试，不打扰用户）
        if failedCount > 0 {
            print("ℹ️ pHash 跳过统计: \(failedCount)/\(imageFiles.count) 个文件无法计算感知哈希")
            if !failedFiles.isEmpty {
                print("   示例文件: \(failedFiles.joined(separator: ", "))\(failedCount > 10 ? " 等..." : "")")
            }
            print("   原因：这些文件不会参与视觉相似度检测，但仍会通过 SHA256 检测完全重复")
        }

        return failedCount
    }

    private func resetToWelcomeState() {
        // Reset state before switching views to prevent crashes.
        // The order is important: clear selection first, then data, then switch view state.
        self.selectedFile = nil
        self.allResultGroups = []
        self.masterCategorizedGroups = []
        self.displayItems = []
        self.originalFileActions = [:]
        self.state = .welcome
    }

    /// 安全的UI状态更新，检查取消标记防止竞争条件
    private func updateScanState(_ progress: ScanningProgress, animationRate: Double) async {
        await MainActor.run {
            // 如果用户已请求取消，不要更新UI状态
            if !isCancelRequested {
                self.state = .scanning(progress: progress, animationRate: animationRate)
            }
        }
    }
    
    private func showResults(groups: [FileGroup], categorizedGroups: [CategorizedGroup]) {
        self.allResultGroups = groups
        self.masterCategorizedGroups = categorizedGroups
        
        // Store the original, AI-determined actions so we can revert back to "Automatic"
        self.originalFileActions = Dictionary(
            uniqueKeysWithValues: groups.flatMap { $0.files }.map { ($0.id, $0.action) }
        )
        
        rebuildDisplayItems()
        self.state = .results
    }
    
    // MARK: - Display & Interaction Logic
    
    /// Rebuilds the entire flattened `displayItems` array from the `masterCategorizedGroups`.
    private func rebuildDisplayItems() {
        var items: [ResultDisplayItem] = []
        for category in masterCategorizedGroups {
            items.append(.categoryHeader(
                id: category.id,
                title: category.categoryName,
                groupCount: category.groups.count,
                size: category.totalSizeToDelete,
                isExpanded: category.isExpanded
            ))

            if category.isExpanded {
                let displayedGroups = category.groups.prefix(category.displayedGroupCount)
                items.append(contentsOf: displayedGroups.map { .fileGroup($0) })

                if category.groups.count > category.displayedGroupCount {
                    items.append(.loadMore(categoryId: category.id))
                }
            }
        }
        self.displayItems = items
    }
    
    private func toggleCategory(categoryId: String) {
        guard let index = masterCategorizedGroups.firstIndex(where: { $0.id == categoryId }),
              index < masterCategorizedGroups.count else {
            print("⚠️ 分类不存在或索引越界，无法切换展开状态")
            return
        }
        masterCategorizedGroups[index].isExpanded.toggle()
        rebuildDisplayItems()
    }

    private func loadMoreInCategory(categoryId: String) {
        guard let index = masterCategorizedGroups.firstIndex(where: { $0.id == categoryId }),
              index < masterCategorizedGroups.count else {
            print("⚠️ 分类不存在或索引越界，无法加载更多")
            return
        }
        let currentCount = masterCategorizedGroups[index].displayedGroupCount
        let maxGroups = masterCategorizedGroups[index].groups.count
        masterCategorizedGroups[index].displayedGroupCount = min(currentCount + categoryPageSize, maxGroups)
        rebuildDisplayItems()
    }
    

    /// 显示错误恢复对话框
    private func showErrorRecovery(
        title: String,
        message: String,
        technicalDetails: String? = nil,
        context: ErrorContext? = nil
    ) {
        let error = DetailedError(
            title: title,
            message: message,
            technicalDetails: technicalDetails,
            canContinue: context?.canSkipFile ?? false
        )

        currentError = error
        errorContext = context
        showErrorDialog = true
    }

    /// 统一的进度更新函数
    /// 🎨 文件发现专用进度更新 - 支持转圈动画
    private func updateDiscoveryProgress(discovered: Int, detail: String, isDiscovering: Bool) async {
        let currentPhaseName = smartProgressManager.getCurrentPhaseName()

        await MainActor.run {
            let scanProgress = ScanningProgress(
                phase: currentPhaseName,
                detail: detail,
                progress: isDiscovering ? -1.0 : smartProgressManager.getCurrentProgress(), // -1表示转圈模式
                totalFiles: isDiscovering ? 0 : discovered,
                processedFiles: discovered,
                estimatedTimeRemaining: nil,
                processingSpeedMBps: nil,
                confidence: .medium
            )
            // 🎯 发现阶段使用较快的动画速度
            self.state = .scanning(progress: scanProgress, animationRate: isDiscovering ? 20.0 : 12.0)
        }
    }

    /// 🚀 智能进度更新 - 防止倒退的动态进度更新 + ETA计算
    private func updateSmartProgress(completed: Int, detail: String, totalFiles: Int) async {
        let internalProgress = totalFiles > 0 ? Double(completed) / Double(totalFiles) : 0.0
        let globalProgress = smartProgressManager.updatePhaseProgress(internalProgress)
        let currentPhaseName = smartProgressManager.getCurrentPhaseName()

        // 🎯 使用原始progressManager计算ETA和速度信息
        let progressWithETA = progressManager.updateProgress(
            completed: completed,
            detail: detail,
            totalFiles: totalFiles
        )

        await MainActor.run {
            let scanProgress = ScanningProgress(
                phase: currentPhaseName, // 保持当前阶段名称
                detail: detail,
                progress: globalProgress, // 🚀 使用智能进度（防倒退）
                totalFiles: totalFiles,
                processedFiles: completed,
                estimatedTimeRemaining: progressWithETA.estimatedTimeRemaining, // 🎯 恢复ETA显示
                processingSpeedMBps: progressWithETA.processingSpeedMBps,       // 🎯 恢复速度显示
                confidence: progressWithETA.confidence                          // 🎯 恢复置信度
            )
            self.state = .scanning(progress: scanProgress, animationRate: 12.0)
        }
    }




    /// 处理文件计算错误
    private func handleFileProcessingError(
        _ error: Error,
        fileURL: URL,
        phase: String,
        processedFiles: Int,
        totalFiles: Int,
        canSkip: Bool = true
    ) async {
        await MainActor.run {
            let context = ErrorContext(
                fileURL: fileURL,
                currentPhase: phase,
                totalFiles: totalFiles,
                processedFiles: processedFiles,
                canSkipFile: canSkip,
                resumeOperation: nil
            )

            let title = "文件处理错误"
            var message = "处理文件时遇到问题"
            var technicalDetails: String? = nil

            if let hashError = error as? HashCalculationError {
                switch hashError {
                case .fileNotAccessible:
                    message = "无法访问文件，可能是权限问题。"
                case .fileNotReadable:
                    message = "文件无法读取，可能文件已损坏或被其他程序占用。"
                case .fileSizeError:
                    message = "无法获取文件大小信息。"
                case .readError:
                    message = "读取文件数据时出错。"
                case .imageDecodingError:
                    // 🛡️ 静默处理HEIC/HJPG解码错误，不显示错误对话框
                    print("⚠️ 静默跳过损坏的图像文件: \(hashError.localizedDescription)")
                    return // 直接返回，不显示错误界面
                case .unknownError:
                    message = "处理文件时发生未知错误。"
                }
                technicalDetails = hashError.localizedDescription
            } else {
                technicalDetails = error.localizedDescription
            }

            showErrorRecovery(
                title: title,
                message: message,
                technicalDetails: technicalDetails,
                context: context
            )
        }
    }

    private func updateUserAction(for file: DisplayFile) {
        guard let originalAction = originalFileActions[file.id] else { return }

        let newAction: FileAction

        // If the current action is a user override, the next state is to revert to the original automatic action.
        if file.action.isUserOverride {
            newAction = originalAction
        } else {
            // If the current action is the automatic one, the next state is the user override.
            // The override is the opposite of the original action.
            if originalAction.isKeep {
                newAction = .userDelete
            } else {
                newAction = .userKeep
            }
        }

        // --- Find and update the file in all data sources ---
        
        // 安全的数组更新，添加边界检查
        guard let groupIndex = allResultGroups.firstIndex(where: { $0.files.contains(where: { $0.id == file.id }) }),
              groupIndex < allResultGroups.count,
              let fileIndex = allResultGroups[groupIndex].files.firstIndex(where: { $0.id == file.id }),
              fileIndex < allResultGroups[groupIndex].files.count else {
            print("⚠️ 无法找到要更新的文件，可能已被删除")
            return
        }

        // 1. Update the master list of all files
        allResultGroups[groupIndex].files[fileIndex].action = newAction

        // 2. 通过组 UUID 直接搜索对应的分类（替换掉失效的字符串前缀匹配）
        // 原 getCategoryPrefix 使用旧命名方案（"Content Duplicates"等），与当前
        // convertToDisplayFormat 输出的 ID（"Live Photo Duplicates" 等）不匹配
        let targetGroupID = allResultGroups[groupIndex].id
        guard let catIndex = masterCategorizedGroups.firstIndex(where: { category in
            category.groups.contains(where: { $0.id == targetGroupID })
        }), catIndex < masterCategorizedGroups.count else {
            print("⚠️ 无法找到对应的分类，跳过分类更新")
            rebuildDisplayItems()
            return
        }

        // 3. 找到分类内的具体组和文件
        guard let masterGroupIndex = masterCategorizedGroups[catIndex].groups.firstIndex(where: { $0.id == targetGroupID }),
              masterGroupIndex < masterCategorizedGroups[catIndex].groups.count,
              let masterFileIndex = masterCategorizedGroups[catIndex].groups[masterGroupIndex].files.firstIndex(where: { $0.id == file.id }),
              masterFileIndex < masterCategorizedGroups[catIndex].groups[masterGroupIndex].files.count else {
            print("⚠️ 无法找到分类中的文件，可能数据不同步")
            rebuildDisplayItems()
            return
        }

        masterCategorizedGroups[catIndex].groups[masterGroupIndex].files[masterFileIndex].action = newAction

        // 4. Recalculate the total size to delete for the updated category
        let newTotalSize = masterCategorizedGroups[catIndex].groups.flatMap { $0.files }
            .filter { !$0.action.isKeep }
            .reduce(0) { $0 + $1.size }
        masterCategorizedGroups[catIndex].totalSizeToDelete = newTotalSize

        // 5. Rebuild the display list to reflect the change
        rebuildDisplayItems()
    }

}


#if os(macOS)
// MARK: - Preview
#Preview {
    ContentView()
}
#endif
