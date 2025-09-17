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
                WelcomeView(onScan: { handleScanRequest() })
                
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
    
    private func handleScanRequest() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            isCancelRequested = false // 重置取消标记
            currentScanTask = Task {
                if await folderAccessManager.requestAccess(to: url) {
                    // 保存扫描路径用于调试信息
                    await MainActor.run {
                        scannedFolderPath = url.path
                    }
                    // Reset state before starting a new scan.
                    // Start accessing the security-scoped resource before scanning.
                    guard await folderAccessManager.startAccessing() else {
                        await MainActor.run {
                            let detailedError = "Failed to start access to the folder. This might be a permissions issue. Please try selecting the folder again."
                            self.state = .error(detailedError)
                        }
                        return
                    }
                    // Ensure we stop accessing the resource when the scan is complete or fails.
                    defer { folderAccessManager.stopAccessing() }
                    
                    do {
                        try await perfectScan(in: url)
                    } catch is CancellationError {
                        // This is expected when the user cancels, just reset the state.
                        await MainActor.run {
                            self.state = .welcome
                        }
                    } catch {
                        await MainActor.run {
                            let detailedError = """
                            An unexpected error occurred during the scan.

                            Details:
                            \(error.localizedDescription)

                            ---
                            Technical Info:
                            \(String(describing: error))
                            """
                            self.state = .error(detailedError)
                        }
                    }
                } else {
                    await MainActor.run {
                        self.state = .error("Failed to gain permission to access the folder. Please select the folder and grant permission when prompted.")
                    }
                }
            }
        }
        #endif
    }
    
    private func executeCleaningPlan(for groups: [FileGroup]) {
        Task {
            // Start accessing the security-scoped resource.
            guard await folderAccessManager.startAccessing() else {
                await MainActor.run {
                    self.alertTitle = "Permission Error"
                    self.alertMessage = "Could not access the folder to execute the plan. Please try scanning the folder again."
                    self.showAlert = true
                }
                return
            }
            // Defer stopping access to ensure it's called even if errors occur.
            defer { folderAccessManager.stopAccessing() }

            let allFiles = groups.flatMap { $0.files }
            
            // --- Step 1: Perform Deletions ---
            var deletionSuccessCount = 0
            var deletionFailCount = 0
            let filesToDelete = allFiles.filter { if case .delete = $0.action { return true } else { return false } }
            
            for file in filesToDelete {
                do {
                    try FileManager.default.removeItem(at: file.url)
                    deletionSuccessCount += 1
                } catch {
                    print("Error deleting file \(file.fileName): \(error)")
                    deletionFailCount += 1
                }
            }
            

            await MainActor.run {
                self.alertTitle = "Cleaning Complete"
                var message = "\(deletionSuccessCount) files were successfully deleted."
                if deletionFailCount > 0 { message += "\n\(deletionFailCount) files could not be deleted." }

                self.alertMessage = message
                self.showAlert = true
                self.state = .welcome // Reset view after cleaning
            }
        }
    }
    
    // MARK: - The "Perfect Scan" Engine
    
    /// 新的4阶段扫描算法实现
    private func perfectScan(in directoryURL: URL) async throws {
        progressManager.startScanning()

        // 初始化哈希缓存
        var sha256Cache: [URL: String] = [:]
        var dHashCache: [URL: UInt64] = [:]

        // 设置初始扫描状态
        await MainActor.run {
            let initialProgress = ScanningProgress(
                phase: "开始扫描",
                detail: "正在初始化扫描...",
                progress: 0.0,
                totalFiles: 0,
                processedFiles: 0,
                estimatedTimeRemaining: nil,
                processingSpeedMBps: nil,
                confidence: .medium
            )
            self.state = .scanning(progress: initialProgress, animationRate: 8.0)
        }

        // === 阶段1: 文件发现 ===
        let allMediaFiles = try await stage1_FileDiscovery(in: directoryURL)
        print("📁 阶段1完成: 发现 \(allMediaFiles.count) 个媒体文件")

        // === 阶段2: 精确文件名匹配 ===
        let seedGroups = try await stage2_ExactNameMatching(files: allMediaFiles)
        print("📝 阶段2完成: 发现 \(seedGroups.count) 个Live Photo种子组")

        // === 阶段3: 内容哈希扩展 ===
        await updateUIPhase("Phase 3: Content Hash Expansion", detail: "正在扩展内容组...", progress: 0.15)
        let contentGroups = try await stage3_ContentHashExpansion(seedGroups: seedGroups, allFiles: allMediaFiles, sha256Cache: &sha256Cache)
        print("🔗 阶段3完成: 扩展为 \(contentGroups.count) 个内容组")

        // === 阶段3.5: 预计算所有图片的dHash（优化性能）===
        await updateUIPhase("Phase 3.5: Precomputing Image Hashes", detail: "正在预计算图片感知哈希...", progress: 0.35)
        await precomputeImageHashes(allFiles: allMediaFiles, dHashCache: &dHashCache)
        print("🚀 阶段3.5完成: 预计算dHash完成，缓存 \(dHashCache.count) 个图片")

        // === 阶段4: 感知哈希相似性 ===
        await updateUIPhase("Phase 4: Perceptual Similarity", detail: "正在检测感知相似性...", progress: 0.75)
        let expandedGroups = try await stage4_PerceptualSimilarity(contentGroups: contentGroups, allFiles: allMediaFiles, dHashCache: &dHashCache)
        print("👁️ 阶段4完成: 感知相似性检测完成")

        // === 阶段5: 文件大小优选和分组 ===
        await updateUIPhase("Phase 5: File Size Optimization", detail: "正在进行文件大小优选和分组...", progress: 0.95)
        let (duplicatePlans, cleanPlans) = try await stage5_FileSizeOptimization(contentGroups: expandedGroups)
        print("⚖️ 阶段5完成: 生成 \(duplicatePlans.count) 个重复清理计划, \(cleanPlans.count) 个干净计划")

        // 转换为现有的UI数据结构
        let finalResults = convertToDisplayFormat(duplicatePlans: duplicatePlans, cleanPlans: cleanPlans)

        // 打印缓存统计信息
        print("📊 缓存统计:")
        print("  SHA256缓存: \(sha256Cache.count) 个文件")
        print("  dHash缓存: \(dHashCache.count) 个图片")

        // 估算节省的计算量
        let estimatedSHA256Savings = max(0, (allMediaFiles.count * seedGroups.count) - sha256Cache.count)
        let estimatedDHashSavings = max(0, (dHashCache.count * allMediaFiles.filter(isImageFile).count) - dHashCache.count)
        print("  估算节省SHA256计算: ~\(estimatedSHA256Savings) 次")
        print("  估算节省dHash计算: ~\(estimatedDHashSavings) 次")

        await MainActor.run {
            self.showResults(groups: finalResults.fileGroups, categorizedGroups: finalResults.categorizedGroups)
        }
    }

    // MARK: - 阶段1: 文件发现
    private func stage1_FileDiscovery(in directoryURL: URL) async throws -> [URL] {
        startPhase(.fileDiscovery, totalWork: 1000) // 估算值

        var allMediaFiles: [URL] = []
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .typeIdentifierKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]

        guard let sequence = URLDirectoryAsyncSequence(url: directoryURL, options: options, resourceKeys: resourceKeys) else {
            throw NSError(domain: "ScanError", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建文件枚举器"])
        }

        var discoveredCount = 0

        for await fileURL in sequence {
            if Task.isCancelled { throw CancellationError() }

            guard let typeIdentifier = try? fileURL.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
                  let fileType = UTType(typeIdentifier),
                  (fileType.conforms(to: .image) || fileType.conforms(to: .movie)) else {
                continue
            }

            allMediaFiles.append(fileURL)
            discoveredCount += 1

            if discoveredCount % 50 == 0 {
                await updateProgress(
                    completed: discoveredCount,
                    detail: "已发现 \(discoveredCount) 个媒体文件...",
                    totalFiles: discoveredCount * 2
                )
            }
        }

        await updateProgress(
            completed: discoveredCount,
            detail: "文件发现完成，共发现 \(discoveredCount) 个媒体文件",
            totalFiles: discoveredCount
        )

        return allMediaFiles
    }

    // MARK: - 阶段2: 精确文件名匹配
    private func stage2_ExactNameMatching(files: [URL]) async throws -> [LivePhotoSeedGroup] {
        startPhase(.exactNameMatching, totalWork: files.count)

        var groups: [String: LivePhotoSeedGroup] = [:]

        for (index, url) in files.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            let baseName = url.deletingPathExtension().lastPathComponent // 不做任何处理
            let ext = url.pathExtension.lowercased()

            if ext == "heic" || ext == "mov" {
                if groups[baseName] == nil {
                    groups[baseName] = LivePhotoSeedGroup(seedName: baseName)
                }

                if ext == "heic" {
                    groups[baseName]!.heicFiles.append(url)
                } else {
                    groups[baseName]!.movFiles.append(url)
                }
            }

            if index % 100 == 0 {
                await updateProgress(
                    completed: index + 1,
                    detail: "正在匹配文件名 (\(index + 1)/\(files.count))...",
                    totalFiles: files.count
                )
            }
        }

        // 只保留真正的Live Photo配对
        let seedGroups = groups.values.filter { $0.hasCompletePair }

        await updateProgress(
            completed: files.count,
            detail: "精确匹配完成，发现 \(seedGroups.count) 个Live Photo组",
            totalFiles: files.count
        )

        return Array(seedGroups)
    }

    // MARK: - 阶段3: 内容哈希扩展
    private func stage3_ContentHashExpansion(seedGroups: [LivePhotoSeedGroup], allFiles: [URL], sha256Cache: inout [URL: String]) async throws -> [ContentGroup] {
        startPhase(.contentHashExpansion, totalWork: allFiles.count)

        // 立即更新UI显示当前阶段
        await updateProgress(
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
                        print("🔢 计算SHA256: \(file.lastPathComponent)")
                    }
                    seedHashes.insert(hash)
                    processedFiles.insert(file)
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
        let totalWork = remainingFiles.count
        var completedWork = 0

        print("🚀 Phase 3 优化算法：单次扫描 \(remainingFiles.count) 个文件...")

        for file in remainingFiles {
            if Task.isCancelled { throw CancellationError() }

            do {
                let fileHash: String
                if let cachedHash = sha256Cache[file] {
                    fileHash = cachedHash
                } else {
                    fileHash = try calculateHash(for: file)
                    sha256Cache[file] = fileHash
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

            // 更频繁的进度更新
            if completedWork % 10 == 0 {
                await updateProgress(
                    completed: completedWork,
                    detail: "单次扫描处理中 (\(completedWork)/\(remainingFiles.count) 文件)...",
                    totalFiles: totalWork
                )
                await Task.yield()
            }
        }

        // 3. 收集最终结果
        for groupIndex in 0..<seedGroups.count {
            if let contentGroup = contentGroupsDict[groupIndex] {
                contentGroups.append(contentGroup)
            }
        }

        await updateProgress(
            completed: totalWork,
            detail: "内容哈希扩展完成",
            totalFiles: totalWork
        )

        return contentGroups
    }

    // MARK: - 阶段4: 感知哈希相似性
    private func stage4_PerceptualSimilarity(contentGroups: [ContentGroup], allFiles: [URL], dHashCache: inout [URL: UInt64]) async throws -> [ContentGroup] {
        startPhase(.perceptualSimilarity, totalWork: contentGroups.count * 50) // 估算工作量

        // 立即更新UI显示当前阶段
        await updateProgress(
            completed: 0,
            detail: "开始感知相似性检测...",
            totalFiles: contentGroups.count
        )

        var mutableContentGroups = contentGroups // 创建可变副本
        var processedFiles: Set<URL> = []
        let SIMILARITY_THRESHOLD = 8 // dHash汉明距离阈值（约85%相似）

        // 收集已处理的文件
        for group in contentGroups {
            processedFiles.formUnion(group.files)
        }

        // 🚀 优化: 收集所有未处理的图片文件用于并发比较
        let remainingImageFiles = allFiles.filter { file in
            !processedFiles.contains(file) && isImageFile(file)
        }

        var workCompleted = 0
        let processorCount = ProcessInfo.processInfo.processorCount
        let batchSize = min(max(processorCount, 10), 30) // 10-30个并发任务

        for (groupIndex, group) in mutableContentGroups.enumerated() {
            // 检查任务是否被取消
            if Task.isCancelled {
                throw CancellationError()
            }

            let imageFiles = group.files.filter { isImageFile($0) }

            for seedImage in imageFiles {
                do {
                    // 使用dHash缓存
                    let seedPHash: UInt64
                    if let cachedHash = dHashCache[seedImage] {
                        seedPHash = cachedHash
                        print("📋 使用dHash缓存: \(seedImage.lastPathComponent)")
                    } else {
                        seedPHash = try calculateDHash(for: seedImage)
                        dHashCache[seedImage] = seedPHash
                        print("👁️ 计算dHash: \(seedImage.lastPathComponent)")
                    }

                    // 🚀 优化: 分批并发处理相似性检测
                    var similarFiles: [(URL, Int)] = []

                    for batch in remainingImageFiles.chunked(into: batchSize) {
                        // 创建本地缓存副本避免inout参数捕获问题
                        let localCache = dHashCache

                        let batchResults = try await withThrowingTaskGroup(of: (URL, UInt64?, Int?).self, returning: [(URL, Int, UInt64?)].self) { group in
                            for remainingFile in batch {
                                // 跳过已处理的文件
                                if processedFiles.contains(remainingFile) {
                                    continue
                                }

                                group.addTask {
                                    do {
                                        let filePHash: UInt64
                                        if let cachedHash = localCache[remainingFile] {
                                            filePHash = cachedHash
                                            // 从缓存获取，不需要重新计算
                                            let similarity = hammingDistance(seedPHash, filePHash)
                                            if similarity <= SIMILARITY_THRESHOLD {
                                                return (remainingFile, filePHash, similarity)
                                            } else {
                                                return (remainingFile, filePHash, nil)
                                            }
                                        } else {
                                            let hash = try calculateDHash(for: remainingFile)
                                            let similarity = hammingDistance(seedPHash, hash)
                                            if similarity <= SIMILARITY_THRESHOLD {
                                                return (remainingFile, hash, similarity)
                                            } else {
                                                return (remainingFile, hash, nil)
                                            }
                                        }
                                    } catch {
                                        print("⚠️ 计算感知哈希失败: \(remainingFile.lastPathComponent) - \(error)")
                                        return (remainingFile, nil, nil)
                                    }
                                }
                            }

                            var results: [(URL, Int, UInt64?)] = []
                            for try await (url, hash, similarity) in group {
                                // 收集结果，包含哈希值用于后续缓存更新
                                if let similarity = similarity {
                                    results.append((url, similarity, hash))
                                } else if let hash = hash {
                                    // 即使不相似也要记录哈希用于缓存
                                    results.append((url, -1, hash)) // -1表示不相似
                                }
                            }
                            return results
                        }

                        // 更新缓存和收集相似文件
                        for (url, similarity, hash) in batchResults {
                            if let hash = hash, dHashCache[url] == nil {
                                dHashCache[url] = hash
                            }
                            if similarity >= 0 && similarity <= SIMILARITY_THRESHOLD {
                                similarFiles.append((url, similarity))
                            }
                        }

                        // 每批处理后让出控制权
                        await Task.yield()
                    }

                    // 添加找到的相似文件到组中
                    for (similarFile, similarity) in similarFiles {
                        mutableContentGroups[groupIndex].addSimilarFile(similarFile, similarity: similarity)
                        processedFiles.insert(similarFile)
                        print("🎯 发现相似图片: \(similarFile.lastPathComponent) (差异度: \(similarity))")
                    }

                } catch {
                    print("⚠️ 计算种子图片感知哈希失败: \(seedImage.lastPathComponent) - \(error)")
                }

                workCompleted += 1
                // 更频繁的UI更新
                if workCompleted % 3 == 0 {
                    await updateProgress(
                        completed: workCompleted,
                        detail: "正在检测相似性 (组 \(groupIndex + 1)/\(mutableContentGroups.count))...",
                        totalFiles: mutableContentGroups.count * imageFiles.count
                    )
                }

                // 确保UI响应性
                await Task.yield()
            }
        }

        await updateProgress(
            completed: workCompleted,
            detail: "感知相似性检测完成",
            totalFiles: workCompleted
        )

        return mutableContentGroups
    }

    // MARK: - 阶段5: 文件大小优选和分组
    private func stage5_FileSizeOptimization(contentGroups: [ContentGroup]) async throws -> (duplicatePlans: [CleaningPlan], cleanPlans: [CleaningPlan]) {
        startPhase(.fileSizeOptimization, totalWork: contentGroups.count)

        // 立即更新UI显示当前阶段
        await updateProgress(
            completed: 0,
            detail: "开始文件大小优选和分组...",
            totalFiles: contentGroups.count
        )

        var duplicatePlans: [CleaningPlan] = []  // 有重复的组
        var cleanPlans: [CleaningPlan] = []      // 干净的Live Photo对

        for (index, group) in contentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            let heicFiles = group.files.filter { $0.pathExtension.lowercased() == "heic" }
            let movFiles = group.files.filter { $0.pathExtension.lowercased() == "mov" }

            // 🚀 判断是否为"干净的"Live Photo对
            let isDuplicateGroup = group.files.count > 2 || // 超过一对文件
                                   heicFiles.count > 1 ||    // 多个HEIC文件
                                   movFiles.count > 1        // 多个MOV文件

            var plan = CleaningPlan(groupName: group.seedName)

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
                print("📋 重复组: \(group.seedName) (共\(group.files.count)个文件)")

            } else {
                // 干净的Live Photo对：标记为保留，无需删除任何文件
                for file in group.files {
                    let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(file), countStyle: .file)
                    let fileType = file.pathExtension.uppercased()
                    plan.keepFile(file, reason: "干净的\(fileType)文件 (\(sizeStr))")
                }

                cleanPlans.append(plan)
                print("✅ 干净组: \(group.seedName) (完整Live Photo对)")
            }

            await updateProgress(
                completed: index + 1,
                detail: "正在优选文件 (\(index + 1)/\(contentGroups.count))...",
                totalFiles: contentGroups.count
            )
        }

        print("📊 分组统计: 重复组 \(duplicatePlans.count) 个，干净组 \(cleanPlans.count) 个")
        return (duplicatePlans: duplicatePlans, cleanPlans: cleanPlans)
    }

    // MARK: - 结果转换
    private func convertToDisplayFormat(duplicatePlans: [CleaningPlan], cleanPlans: [CleaningPlan]) -> (fileGroups: [FileGroup], categorizedGroups: [CategorizedGroup]) {
        var allFileGroups: [FileGroup] = []
        var duplicateFileGroups: [FileGroup] = []
        var cleanFileGroups: [FileGroup] = []

        // 🚀 处理重复文件组
        for plan in duplicatePlans {
            var groupFiles: [DisplayFile] = []

            for (url, action) in plan.actions {
                let fileSize = getFileSize(url)
                let displayAction: FileAction

                switch action {
                case .keep(let reason):
                    displayAction = .keepAsIs(reason: reason)
                case .delete(let reason):
                    displayAction = .delete(reason: reason)
                }

                let displayFile = DisplayFile(url: url, size: fileSize, action: displayAction)
                groupFiles.append(displayFile)
            }

            if !groupFiles.isEmpty {
                let group = FileGroup(groupName: "🔄 重复: \(plan.groupName)", files: groupFiles)
                duplicateFileGroups.append(group)
                allFileGroups.append(group)
            }
        }

        // 🚀 处理干净的Live Photo对
        for plan in cleanPlans {
            var groupFiles: [DisplayFile] = []

            for (url, action) in plan.actions {
                let fileSize = getFileSize(url)
                let displayAction: FileAction

                switch action {
                case .keep(let reason):
                    displayAction = .keepAsIs(reason: reason)
                case .delete(let reason):
                    displayAction = .delete(reason: reason)
                }

                let displayFile = DisplayFile(url: url, size: fileSize, action: displayAction)
                groupFiles.append(displayFile)
            }

            if !groupFiles.isEmpty {
                let group = FileGroup(groupName: "✅ 干净: \(plan.groupName)", files: groupFiles)
                cleanFileGroups.append(group)
                allFileGroups.append(group)
            }
        }

        // 创建分类组
        var categorizedGroups: [CategorizedGroup] = []

        // 重复文件分类组
        if !duplicateFileGroups.isEmpty {
            let duplicateCategory = CategorizedGroup(
                id: "Live Photo Duplicates",
                categoryName: "🔄 Live Photo 重复文件 (\(duplicateFileGroups.count) 组)",
                groups: duplicateFileGroups,
                totalSizeToDelete: duplicateFileGroups.flatMap { $0.files }
                    .filter { if case .delete = $0.action { return true }; return false }
                    .reduce(0) { $0 + $1.size },
                isExpanded: true,
                displayedGroupCount: duplicateFileGroups.count
            )
            categorizedGroups.append(duplicateCategory)
        }

        // 干净文件分类组
        if !cleanFileGroups.isEmpty {
            let cleanCategory = CategorizedGroup(
                id: "Clean Live Photos",
                categoryName: "✅ 干净的 Live Photo 对 (\(cleanFileGroups.count) 组)",
                groups: cleanFileGroups,
                totalSizeToDelete: 0, // 干净的组不需要删除任何文件
                isExpanded: false, // 默认折叠，因为这些文件不需要处理
                displayedGroupCount: cleanFileGroups.count
            )
            categorizedGroups.append(cleanCategory)
        }

        return (fileGroups: allFileGroups, categorizedGroups: categorizedGroups)
    }

    // MARK: - UI更新辅助函数

    /// 更新UI显示的阶段信息
    private func updateUIPhase(_ phase: String, detail: String, progress: Double = 0.0) async {
        await MainActor.run {
            let scanProgress = ScanningProgress(
                phase: phase,
                detail: detail,
                progress: progress,
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

    /// 预计算所有图片的dHash以提高阶段4性能
    private func precomputeImageHashes(allFiles: [URL], dHashCache: inout [URL: UInt64]) async {
        let imageFiles = allFiles.filter { isImageFile($0) }
        // 🚀 优化: 根据CPU核心数调整并发数，但设置上限避免过载
        let processorCount = ProcessInfo.processInfo.processorCount
        let batchSize = min(max(processorCount * 2, 20), 50) // 至少20个，最多50个并发

        await updateProgress(
            completed: 0,
            detail: "预计算图片感知哈希...",
            totalFiles: imageFiles.count
        )

        var completed = 0

        // 分批并发处理
        for batch in imageFiles.chunked(into: batchSize) {
            try? await withThrowingTaskGroup(of: (URL, UInt64?).self) { group in
                for imageURL in batch {
                    // 跳过已缓存的
                    if dHashCache[imageURL] != nil {
                        completed += 1
                        continue
                    }

                    group.addTask {
                        do {
                            let hash = try calculateDHash(for: imageURL)
                            return (imageURL, hash)
                        } catch {
                            print("⚠️ 预计算dHash失败: \(imageURL.lastPathComponent) - \(error)")
                            return (imageURL, nil)
                        }
                    }
                }

                for try await (url, hash) in group {
                    if let hash = hash {
                        dHashCache[url] = hash
                    }
                    completed += 1

                    // 🚀 优化: 更频繁的进度更新，让用户看到实时进展
                    if completed % 3 == 0 || completed == imageFiles.count {
                        await updateProgress(
                            completed: completed,
                            detail: "预计算dHash (\(completed)/\(imageFiles.count))...",
                            totalFiles: imageFiles.count
                        )
                    }
                }
            }

            // 每批处理后让出控制权
            await Task.yield()
        }
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
    
    /// Extracts a base name from a URL for grouping.
    private func getBaseName(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        // 扩展正则表达式以支持中文模式和更多变体
        let cleanName = name.replacingOccurrences(of: "(?:[ _-](?:copy|\\d{1,2}|副本\\d*)| \\(\\d+\\)|_v\\d{1,2}|_副本\\d*)$", with: "", options: [.regularExpression, .caseInsensitive])
        print("🔍 BaseName: '\(name)' -> '\(cleanName)'")
        return cleanName
    }

    private func getCategoryPrefix(for groupName: String) -> String {
        let categoryOrder: [String: Int] = [
            "Content Duplicates": 1,
            "Live Photo Duplicates": 2,
            "Perfectly Paired & Ignored": 3
        ]

        // Live Photo Duplicates should be treated as separate category
        if groupName.starts(with: "Live Photo Duplicates:") {
            return "Live Photo Duplicates"
        }

        for prefix in categoryOrder.keys where groupName.starts(with: prefix) {
            return prefix
        }
        return "Other"
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
    private func updateProgress(completed: Int, detail: String, totalFiles: Int) async {
        let scanProgress = progressManager.updateProgress(
            completed: completed,
            detail: detail,
            totalFiles: totalFiles
        )
        await updateScanState(scanProgress, animationRate: 12.0)
    }

    /// 开始新的扫描阶段
    private func startPhase(_ phase: ScanPhase, totalWork: Int) {
        progressManager.startPhase(phase, totalWork: totalWork)
    }

    /// 更新阶段总工作量
    private func updateTotalWork(_ newTotal: Int) {
        progressManager.updateTotalWork(newTotal)
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

        // 2. Find which category this group belongs to
        let groupName = allResultGroups[groupIndex].groupName
        let categoryName = getCategoryPrefix(for: groupName)

        // 3. Update the corresponding category in the master categorized list
        guard let catIndex = masterCategorizedGroups.firstIndex(where: { $0.id == categoryName }),
              catIndex < masterCategorizedGroups.count else {
            print("⚠️ 无法找到对应的分类，跳过分类更新")
            rebuildDisplayItems()
            return
        }

        guard let masterGroupIndex = masterCategorizedGroups[catIndex].groups.firstIndex(where: { $0.id == allResultGroups[groupIndex].id }),
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
