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
        await updateUIPhase("Phase 1: File Discovery", detail: "正在发现文件...")
        let allMediaFiles = try await stage1_FileDiscovery(in: directoryURL)
        print("📁 阶段1完成: 发现 \(allMediaFiles.count) 个媒体文件")

        // === 阶段2: 精确文件名匹配 ===
        await updateUIPhase("Phase 2: Exact Name Matching", detail: "正在进行精确文件名匹配...")
        let seedGroups = try await stage2_ExactNameMatching(files: allMediaFiles)
        print("📝 阶段2完成: 发现 \(seedGroups.count) 个Live Photo种子组")

        // === 阶段3.1: 内容哈希扩展 ===
        await updateUIPhase("Phase 3.1: Content Hash Expansion", detail: "正在扩展内容组...")
        let expandedGroups = try await stage3_ContentHashExpansion(seedGroups: seedGroups, allFiles: allMediaFiles, sha256Cache: &sha256Cache)
        print("🔗 阶段3.1完成: 扩展为 \(expandedGroups.count) 个内容组")

        // === 阶段3.2: SHA256跨组合并 ===
        await updateUIPhase("Phase 3.2: Cross-Group SHA256 Merging", detail: "正在合并具有相同内容的组...")
        let contentGroups = try await stage3_2_CrossGroupSHA256Merging(contentGroups: expandedGroups, sha256Cache: sha256Cache)
        print("🚀 阶段3.2完成: 合并后剩余 \(contentGroups.count) 个内容组")

        // === 阶段3.5: 预计算所有图片的pHash（优化性能）===
        await updateUIPhase("Phase 3.5: Precomputing Image Hashes", detail: "正在预计算图片感知哈希...")
        await precomputeImageHashes(allFiles: allMediaFiles, dHashCache: &dHashCache)
        print("🚀 阶段3.5完成: 预计算pHash完成，缓存 \(dHashCache.count) 个图片")

        // === 阶段4: 感知哈希相似性 ===
        await updateUIPhase("Phase 4: Perceptual Similarity", detail: "正在检测感知相似性...")
        let finalGroups = try await stage4_PerceptualSimilarity(contentGroups: contentGroups, allFiles: allMediaFiles, dHashCache: &dHashCache)
        print("👁️ 阶段4完成: 感知相似性检测完成")

        // === ✨ 新阶段: 单文件重复检测 ===
        await updateUIPhase("Phase 4.5: Single File Detection", detail: "正在检测单文件重复...")

        // 收集所有Live Photo处理过的文件
        let processedFiles = Set(finalGroups.flatMap { $0.files })
        let singleFileGroups = try await detectSingleFileDuplicates(
            allFiles: allMediaFiles,
            processedFiles: processedFiles,
            sha256Cache: &sha256Cache,
            dHashCache: &dHashCache
        )
        print("🔍 单文件检测完成: 发现 \(singleFileGroups.count) 个重复组")

        // 合并Live Photo组和单文件组
        let allGroups = finalGroups + singleFileGroups

        // === 阶段5: 文件大小优选和分组 ===
        await updateUIPhase("Phase 5: File Size Optimization", detail: "正在进行文件大小优选和分组...")
        let (duplicatePlans, cleanPlans) = try await stage5_FileSizeOptimization(contentGroups: allGroups)
        print("⚖️ 阶段5完成: 生成 \(duplicatePlans.count) 个重复清理计划, \(cleanPlans.count) 个干净计划")

        // 转换为现有的UI数据结构
        let finalResults = convertToDisplayFormat(duplicatePlans: duplicatePlans, cleanPlans: cleanPlans)

        // 打印缓存统计信息
        print("📊 缓存统计:")
        print("  SHA256缓存: \(sha256Cache.count) 个文件")
        print("  pHash缓存: \(dHashCache.count) 个图片")

        // 估算节省的计算量
        let estimatedSHA256Savings = max(0, (allMediaFiles.count * seedGroups.count) - sha256Cache.count)
        let estimatedPHashSavings = max(0, (dHashCache.count * allMediaFiles.filter(isImageFile).count) - dHashCache.count)
        print("  估算节省SHA256计算: ~\(estimatedSHA256Savings) 次")
        print("  估算节省pHash计算: ~\(estimatedPHashSavings) 次")

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

            // 🚀 每处理一个文件就更新进度
            await updateSmartProgress(
                completed: discoveredCount,
                detail: "已发现 \(discoveredCount) 个媒体文件...",
                totalFiles: max(discoveredCount * 2, 100) // 估算总文件数
            )
        }

        await updateSmartProgress(
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

            // 🚀 每处理一个文件就更新进度
            await updateProgress(
                completed: index + 1,
                detail: "正在匹配文件名 (\(index + 1)/\(files.count))...",
                totalFiles: files.count
            )
        }

        // 🚀 只保留真正的Live Photo配对 - 优化UI响应性
        await updateProgress(
            completed: files.count,
            detail: "正在筛选有效Live Photo配对...",
            totalFiles: files.count
        )

        var seedGroups: [LivePhotoSeedGroup] = []
        let allGroups = Array(groups.values)

        for (index, group) in allGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            if group.hasCompletePair {
                seedGroups.append(group)
            }

            // 🚀 每筛选一个组就更新进度和让出CPU时间
            await updateProgress(
                completed: files.count,
                detail: "筛选Live Photo配对 (\(index + 1)/\(allGroups.count))...",
                totalFiles: files.count
            )
            await Task.yield()
        }

        // ✨ 新增：创建单文件组
        await updateProgress(
            completed: files.count,
            detail: "创建单文件组...",
            totalFiles: files.count
        )

        await updateProgress(
            completed: files.count,
            detail: "精确匹配完成，发现 \(seedGroups.count) 个Live Photo组",
            totalFiles: files.count
        )

        return seedGroups
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

        await updateProgress(
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
        await updateProgress(
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

        for (originalIndex, originalGroup) in contentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            let root = unionFind.find(originalIndex)

            if let existingGroup = rootToNewGroup[root] {
                // 合并到现有组
                var mergedGroup = existingGroup
                for file in originalGroup.files {
                    if !mergedGroup.files.contains(file) {
                        mergedGroup.files.append(file)
                        mergedGroup.relationships[file] = originalGroup.relationships[file] ?? .contentDuplicate
                    }
                }
                rootToNewGroup[root] = mergedGroup
            } else {
                // 创建新的根组
                rootToNewGroup[root] = originalGroup
            }

            if originalIndex % 10 == 0 {
                await updateProgress(
                    completed: originalIndex + 1,
                    detail: "正在扩展内容组 (\(originalIndex + 1)/\(contentGroups.count))...",
                    totalFiles: contentGroups.count
                )
                await Task.yield() // 🚀 关键：让出CPU时间，避免卡顿
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

        await updateProgress(
            completed: contentGroups.count,
            detail: "SHA256跨组合并完成，减少 \(savedGroups) 个重复组",
            totalFiles: contentGroups.count
        )

        return mergedGroups
    }

    // MARK: - 阶段4: 感知哈希跨组相似性检测与合并
    private func stage4_PerceptualSimilarity(contentGroups: [ContentGroup], allFiles: [URL], dHashCache: inout [URL: UInt64]) async throws -> [ContentGroup] {
        startPhase(.perceptualSimilarity, totalWork: contentGroups.count * contentGroups.count)

        // 立即更新UI显示当前阶段
        await updateProgress(
            completed: 0,
            detail: "开始跨组感知相似性检测...",
            totalFiles: contentGroups.count * contentGroups.count
        )

        print("🔍 开始pHash跨组相似性分析，检查 \(contentGroups.count) 个组...")

        // 🚀 阶段4.1: 组内相似性扩展 (保留原有逻辑)
        var mutableContentGroups = try await stage4_1_IntraGroupSimilarity(contentGroups: contentGroups, allFiles: allFiles, dHashCache: &dHashCache)

        // 🚀 阶段4.2: 跨组相似性合并 (新增核心功能)
        mutableContentGroups = try await stage4_2_CrossGroupSimilarity(contentGroups: mutableContentGroups, dHashCache: dHashCache)

        await updateProgress(
            completed: contentGroups.count * contentGroups.count,
            detail: "感知相似性检测和合并完成",
            totalFiles: contentGroups.count * contentGroups.count
        )

        return mutableContentGroups
    }

    // MARK: - 阶段4.1: 组内相似性扩展
    private func stage4_1_IntraGroupSimilarity(contentGroups: [ContentGroup], allFiles: [URL], dHashCache: inout [URL: UInt64]) async throws -> [ContentGroup] {
        await updateProgress(
            completed: 0,
            detail: "正在进行组内相似性扩展...",
            totalFiles: contentGroups.count
        )

        var mutableContentGroups = contentGroups
        var processedFiles: Set<URL> = []
        let SIMILARITY_THRESHOLD = 15 // 组内扩展阈值

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
            await updateProgress(
                completed: groupIndex,
                detail: "组内扩展 (\(groupIndex + 1)/\(contentGroups.count))...",
                totalFiles: contentGroups.count
            )
        }

        return mutableContentGroups
    }

    // MARK: - 阶段4.2: 高性能pHash哈希桶合并算法
    private func stage4_2_CrossGroupSimilarity(contentGroups: [ContentGroup], dHashCache: [URL: UInt64]) async throws -> [ContentGroup] {
        await updateProgress(
            completed: 0,
            detail: "正在进行高性能跨组相似性分析...",
            totalFiles: contentGroups.count
        )

        print("🚀 启动高性能pHash哈希桶算法，分析 \(contentGroups.count) 个组...")

        // 🎯 优化参数
        let SIMILARITY_THRESHOLD = 10 // 相似度阈值

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
            await updateProgress(
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

                    // 🚀 更频繁的进度更新，每5次比较就更新
                    if totalComparisons % 5 == 0 {
                        await updateProgress(
                            completed: min(contentGroups.count, totalComparisons * 3),
                            detail: "桶内精确比较 (已比较 \(totalComparisons) 对)...",
                            totalFiles: contentGroups.count * 4
                        )
                        await Task.yield() // 让出CPU时间
                    }
                }
            }

            processedBuckets += 1

            // 🚀 每处理一个桶就更新进度
            await updateProgress(
                completed: min(contentGroups.count, processedBuckets * 5),
                detail: "桶内比较进度 (\(processedBuckets)/\(hashBuckets.count) 桶)...",
                totalFiles: contentGroups.count * 4
            )
        }

        // 🚀 算法3: 跨桶高相似性检查（可选，限制范围）
        if hashBuckets.count <= 1000 { // 只在桶数不太多时执行
            print("🔍 执行跨桶高相似性检查...")

            let bucketKeys = Array(hashBuckets.keys).sorted()
            for i in 0..<bucketKeys.count {
                for j in (i + 1)..<bucketKeys.count {
                    let keyA = bucketKeys[i]
                    let keyB = bucketKeys[j]

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
            }
        }

        // 重建合并后的组
        var rootToMergedGroup: [Int: ContentGroup] = [:]

        for (originalIndex, originalGroup) in contentGroups.enumerated() {
            let root = unionFind.find(originalIndex)

            if let existingGroup = rootToMergedGroup[root] {
                var mergedGroup = existingGroup
                for file in originalGroup.files {
                    if !mergedGroup.files.contains(file) {
                        mergedGroup.files.append(file)
                        mergedGroup.relationships[file] = originalGroup.relationships[file] ?? .perceptualSimilar(hammingDistance: SIMILARITY_THRESHOLD)
                    }
                }
                rootToMergedGroup[root] = mergedGroup
            } else {
                rootToMergedGroup[root] = originalGroup
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
        let similarGroups = try await detectSimilarFiles(files: remainingFiles, dHashCache: &dHashCache)
        print("📊 相似性检测完成：\(similarGroups.count) 个相似组")

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
            await updateProgress(
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

            let hash: UInt64
            if let cachedHash = dHashCache[file] {
                hash = cachedHash
            } else {
                hash = try calculateDHash(for: file)
                dHashCache[file] = hash
            }

            fileToHash[file] = hash

            processedCount += 1
            // 🚀 每处理一个文件就更新进度和让出CPU
            await updateProgress(
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
        let SIMILARITY_THRESHOLD = 8

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

            var plan = CleaningPlan(groupName: group.seedName)

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
        var livePhotoDuplicateGroups: [FileGroup] = []
        var singleFileDuplicateGroups: [FileGroup] = []
        var cleanFileGroups: [FileGroup] = []

        // 🚀 处理重复文件组，分别处理Live Photo和单文件重复
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
                // ✨ 根据文件类型判断是Live Photo重复还是单文件重复
                let extensions = Set(groupFiles.map { $0.url.pathExtension.lowercased() })
                let isLivePhotoGroup = extensions.contains("heic") && extensions.contains("mov")

                if isLivePhotoGroup {
                    let group = FileGroup(groupName: "📸 Live Photo重复: \(plan.groupName)", files: groupFiles)
                    livePhotoDuplicateGroups.append(group)
                    allFileGroups.append(group)
                } else {
                    let group = FileGroup(groupName: "📄 单文件重复: \(plan.groupName)", files: groupFiles)
                    singleFileDuplicateGroups.append(group)
                    allFileGroups.append(group)
                }
            }
        }

        // 🚀 处理干净的文件组
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
                // ✨ 根据文件类型判断是Live Photo还是单文件
                let extensions = Set(groupFiles.map { $0.url.pathExtension.lowercased() })
                let isLivePhotoGroup = extensions.contains("heic") && extensions.contains("mov")

                if isLivePhotoGroup {
                    let group = FileGroup(groupName: "✅ 完整Live Photo: \(plan.groupName)", files: groupFiles)
                    cleanFileGroups.append(group)
                    allFileGroups.append(group)
                } else {
                    let group = FileGroup(groupName: "📝 独立文件: \(plan.groupName)", files: groupFiles)
                    cleanFileGroups.append(group)
                    allFileGroups.append(group)
                }
            }
        }

        // ✨ 创建分类组 - 支持多种重复类型
        var categorizedGroups: [CategorizedGroup] = []

        // Live Photo重复文件分类组
        if !livePhotoDuplicateGroups.isEmpty {
            let duplicateCategory = CategorizedGroup(
                id: "Live Photo Duplicates",
                categoryName: "📸 Live Photo 重复文件 (\(livePhotoDuplicateGroups.count) 组)",
                groups: livePhotoDuplicateGroups,
                totalSizeToDelete: livePhotoDuplicateGroups.flatMap { $0.files }
                    .filter { if case .delete = $0.action { return true }; return false }
                    .reduce(0) { $0 + $1.size },
                isExpanded: true,
                displayedGroupCount: livePhotoDuplicateGroups.count
            )
            categorizedGroups.append(duplicateCategory)
        }

        // ✨ 单文件重复分类组
        if !singleFileDuplicateGroups.isEmpty {
            let singleFileCategory = CategorizedGroup(
                id: "Single File Duplicates",
                categoryName: "📄 单文件重复 (\(singleFileDuplicateGroups.count) 组)",
                groups: singleFileDuplicateGroups,
                totalSizeToDelete: singleFileDuplicateGroups.flatMap { $0.files }
                    .filter { if case .delete = $0.action { return true }; return false }
                    .reduce(0) { $0 + $1.size },
                isExpanded: true,
                displayedGroupCount: singleFileDuplicateGroups.count
            )
            categorizedGroups.append(singleFileCategory)
        }

        // 干净文件分类组
        if !cleanFileGroups.isEmpty {
            let cleanCategory = CategorizedGroup(
                id: "Clean Files",
                categoryName: "✅ 无重复文件 (\(cleanFileGroups.count) 组)",
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
    /// 🚀 智能阶段进度管理器 - 防止进度倒退
    private class SmartPhaseProgressManager {
        private var currentProgress: Double = 0.0
        private var currentPhaseBase: Double = 0.0
        private var currentPhaseRange: Double = 0.0
        private var currentPhaseName: String = ""

        /// 阶段定义：每个阶段的进度范围
        private let phaseRanges: [(name: String, start: Double, end: Double)] = [
            ("Phase 1: File Discovery", 0.0, 0.10),
            ("Phase 2: Exact Name Matching", 0.10, 0.15),
            ("Phase 3.1: Content Hash Expansion", 0.15, 0.30),
            ("Phase 3.2: Cross-Group SHA256 Merging", 0.30, 0.35),
            ("Phase 3.5: Precomputing Image Hashes", 0.35, 0.50),
            ("Phase 4: Perceptual Similarity", 0.50, 0.80),
            ("Phase 4.5: Single File Detection", 0.80, 0.90),
            ("Phase 5: File Size Optimization", 0.90, 1.0)
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
    private func precomputeImageHashes(allFiles: [URL], dHashCache: inout [URL: UInt64]) async {
        let imageFiles = allFiles.filter { isImageFile($0) }
        // 🚀 优化: 根据CPU核心数调整并发数，但设置上限避免过载
        let processorCount = ProcessInfo.processInfo.processorCount
        let batchSize = min(max(processorCount * 2, 20), 50) // 至少20个，最多50个并发

        await updateSmartProgress(
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
                            print("⚠️ 预计算pHash失败: \(imageURL.lastPathComponent) - \(error)")
                            return (imageURL, nil)
                        }
                    }
                }

                for try await (url, hash) in group {
                    if let hash = hash {
                        dHashCache[url] = hash
                    }
                    completed += 1

                    // 🚀 每计算一个文件就更新进度
                    await updateSmartProgress(
                        completed: completed,
                        detail: "预计算pHash (\(completed)/\(imageFiles.count))...",
                        totalFiles: imageFiles.count
                    )
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
    /// 🚀 智能进度更新 - 防止倒退的动态进度更新
    private func updateSmartProgress(completed: Int, detail: String, totalFiles: Int) async {
        let internalProgress = totalFiles > 0 ? Double(completed) / Double(totalFiles) : 0.0
        let globalProgress = smartProgressManager.updatePhaseProgress(internalProgress)
        let currentPhaseName = smartProgressManager.getCurrentPhaseName()

        await MainActor.run {
            let scanProgress = ScanningProgress(
                phase: currentPhaseName, // 保持当前阶段名称
                detail: detail,
                progress: globalProgress,
                totalFiles: totalFiles,
                processedFiles: completed,
                estimatedTimeRemaining: nil,
                processingSpeedMBps: nil,
                confidence: .medium
            )
            self.state = .scanning(progress: scanProgress, animationRate: 12.0)
        }
    }

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
