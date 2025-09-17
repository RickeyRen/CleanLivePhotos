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
    
    /// This is the master scanning function that implements the most robust cleaning logic.
    private func perfectScan(in directoryURL: URL) async throws {
        let startTime = Date()

        // --- PHASE 1: FILE DISCOVERY ---
        let progress = ScanningProgress(phase: "Phase 1: Discovering", detail: "Scanning folder for media files...", progress: 0.0, totalFiles: 0, processedFiles: 0, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
        await updateScanState(progress, animationRate: 5.0)

        var allMediaFileURLs: [URL] = []
        #if os(macOS)
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .typeIdentifierKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        
        guard let sequence = URLDirectoryAsyncSequence(url: directoryURL, options: options, resourceKeys: resourceKeys) else {
            await MainActor.run { state = .error("Failed to create file enumerator.") }
            return
        }
        
        var discoveredCount = 0
        for await fileURL in sequence {
            if Task.isCancelled { await MainActor.run { state = .welcome }; return }

            // We only care about image and movie files.
            guard let typeIdentifier = try? fileURL.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
                  let fileType = UTType(typeIdentifier),
                  (fileType.conforms(to: .image) || fileType.conforms(to: .movie)) else {
                continue
            }
            
            allMediaFileURLs.append(fileURL)
            discoveredCount += 1
            
            if discoveredCount % 50 == 0 { // Update UI periodically
                await MainActor.run {
                    let progress = ScanningProgress(phase: "Phase 1: Discovering", detail: "Found \(discoveredCount) media files...", progress: 0.05, totalFiles: discoveredCount, processedFiles: discoveredCount, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
                    self.state = .scanning(progress: progress, animationRate: 10.0) // A bit faster during discovery
                }
            }
        }
        #endif
        
        if Task.isCancelled { await MainActor.run { state = .welcome }; return }

        let totalFiles = allMediaFileURLs.count

        // --- PHASE 1.5: LIVE PHOTO PRE-PAIRING ---
        await MainActor.run {
            let progress = ScanningProgress(phase: "Phase 1.5: Live Photo Detection", detail: "Pre-pairing Live Photos before duplicate detection...", progress: 0.25, totalFiles: totalFiles, processedFiles: 0, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
            self.state = .scanning(progress: progress, animationRate: 10.0)
        }
        await Task.yield()

        // === 新的Live Photo匹配逻辑 ===

        // 第一步：基于文件名找到所有Live Photo配对组
        var livePhotoGroups: [String: (heicFiles: [URL], movFiles: [URL])] = [:]

        for url in allMediaFileURLs {
            let ext = url.pathExtension.lowercased()
            if ext == "heic" || ext == "mov" {
                let baseName = getBaseName(for: url)

                if livePhotoGroups[baseName] == nil {
                    livePhotoGroups[baseName] = (heicFiles: [], movFiles: [])
                }

                if ext == "heic" {
                    livePhotoGroups[baseName]!.heicFiles.append(url)
                } else {
                    livePhotoGroups[baseName]!.movFiles.append(url)
                }
            }
        }

        // 只保留有HEIC和MOV配对的组
        livePhotoGroups = livePhotoGroups.filter { (baseName, group) in
            !group.heicFiles.isEmpty && !group.movFiles.isEmpty
        }

        print("📸 步骤1 - 文件名配对: 找到 \(livePhotoGroups.count) 个Live Photo组")
        for (baseName, group) in livePhotoGroups {
            print("  - '\(baseName)': \(group.heicFiles.count) HEIC + \(group.movFiles.count) MOV")
        }

        // 第二步：计算所有Live Photo配对文件的哈希值（用于后续合并）
        var urlToHash: [URL: String] = [:]
        let allLivePhotoFiles = livePhotoGroups.flatMap { group in
            group.value.heicFiles + group.value.movFiles
        }

        print("📸 步骤2 - 计算哈希: 正在处理 \(allLivePhotoFiles.count) 个Live Photo配对文件")

        // 使用CPU核心数确定并发数
        let processorCount = ProcessInfo.processInfo.processorCount
        let concurrencyLimit = max(1, processorCount) // 使用全部CPU核心数
        print("🚀 使用 \(concurrencyLimit) 个并发任务处理哈希计算（CPU核心数: \(processorCount)）")

        let totalLivePhotoFiles = allLivePhotoFiles.count
        var processedCount = 0

        try await withThrowingTaskGroup(of: (URL, String?).self) { group in
            var urlIterator = allLivePhotoFiles.makeIterator()

            // 启动初始的并发任务
            for _ in 0..<concurrencyLimit {
                if let url = urlIterator.next() {
                    group.addTask {
                        let hash = calculateHash(for: url)
                        return (url, hash)
                    }
                }
            }

            // 每完成一个任务就更新UI并启动新任务
            for try await (url, hash) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    await MainActor.run { state = .welcome }
                    return
                }

                // 处理结果
                processedCount += 1
                if let hash = hash {
                    urlToHash[url] = hash
                }

                // 每完成1个文件就更新UI
                let progressValue = Double(processedCount) / Double(totalLivePhotoFiles) * 0.2 + 0.25
                let scanProgress = ScanningProgress(
                    phase: "Phase 1.5: Live Photo Detection",
                    detail: "Computing hash for \(url.lastPathComponent) (\(processedCount)/\(totalLivePhotoFiles))...",
                    progress: progressValue,
                    totalFiles: totalLivePhotoFiles,
                    processedFiles: processedCount,
                    estimatedTimeRemaining: nil,
                    processingSpeedMBps: nil
                )
                await updateScanState(scanProgress, animationRate: 12.0)

                // 启动下一个任务
                if let nextURL = urlIterator.next() {
                    group.addTask {
                        let hash = calculateHash(for: nextURL)
                        return (nextURL, hash)
                    }
                }

                // Yield控制权，避免阻塞主线程
                await Task.yield()
            }
        }

        // 第三步：基于哈希值合并相同内容的组
        var mergedGroups: [[URL]] = []

        for (_, group) in livePhotoGroups {
            let allFiles = group.heicFiles + group.movFiles
            let groupHashes = Set(allFiles.compactMap { urlToHash[$0] })

            // 检查是否与现有组有重叠的哈希值
            var foundMergeTarget = false
            for i in 0..<mergedGroups.count {
                let existingHashes = Set(mergedGroups[i].compactMap { urlToHash[$0] })
                if !groupHashes.isDisjoint(with: existingHashes) {
                    // 有重叠，合并到现有组
                    mergedGroups[i].append(contentsOf: allFiles)
                    foundMergeTarget = true
                    break
                }
            }

            if !foundMergeTarget {
                // 没找到可合并的组，创建新组
                mergedGroups.append(allFiles)
            }
        }

        // 第四步：将单独的文件通过哈希匹配加入到组中
        var remainingFiles: [URL] = []
        for url in allMediaFileURLs {
            let ext = url.pathExtension.lowercased()
            if ext == "heic" || ext == "mov" {
                let isInGroup = mergedGroups.contains { group in
                    group.contains(url)
                }
                if !isInGroup {
                    remainingFiles.append(url)
                }
            }
        }

        print("📸 步骤3 - 处理单独文件: 检查 \(remainingFiles.count) 个剩余文件")

        // 更新进度UI
        await MainActor.run {
            let scanProgress = ScanningProgress(
                phase: "Phase 1.5: Live Photo Detection",
                detail: "Processing \(remainingFiles.count) remaining files...",
                progress: 0.45,
                totalFiles: allLivePhotoFiles.count + remainingFiles.count,
                processedFiles: allLivePhotoFiles.count,
                estimatedTimeRemaining: nil,
                processingSpeedMBps: nil
            )
            self.state = .scanning(progress: scanProgress, animationRate: 8.0)
        }

        // 逐个计算剩余文件的哈希，每个文件处理完就更新UI
        for i in 0..<remainingFiles.count {
            let url = remainingFiles[i]
            let currentFile = i + 1

            // 更新UI进度 - 每个剩余文件处理完就更新
            await MainActor.run {
                let progress = 0.45 + (Double(currentFile) / Double(remainingFiles.count)) * 0.05
                let scanProgress = ScanningProgress(
                    phase: "Phase 1.5: Live Photo Detection",
                    detail: "Processing \(url.lastPathComponent) (\(currentFile)/\(remainingFiles.count))...",
                    progress: progress,
                    totalFiles: allLivePhotoFiles.count + remainingFiles.count,
                    processedFiles: allLivePhotoFiles.count + currentFile,
                    estimatedTimeRemaining: nil,
                    processingSpeedMBps: nil
                )
                self.state = .scanning(progress: scanProgress, animationRate: 12.0)
            }

            // 计算单个剩余文件的哈希
            if let hash = calculateHash(for: url) {
                urlToHash[url] = hash

                // 查找是否有组包含相同哈希的文件
                for j in 0..<mergedGroups.count {
                    let groupHashes = Set(mergedGroups[j].compactMap { urlToHash[$0] })
                    if groupHashes.contains(hash) {
                        mergedGroups[j].append(url)
                        break
                    }
                }
            }

            // 每个文件处理后让出控制权，保持UI响应
            await Task.yield()
            if Task.isCancelled { await MainActor.run { state = .welcome }; return }
        }

        print("📸 步骤4 - 最终分组: 共 \(mergedGroups.count) 个合并后的Live Photo组")

        // 标记所有处理的文件
        var pairedURLs: Set<URL> = []
        for group in mergedGroups {
            for url in group {
                pairedURLs.insert(url)
            }
        }

        // 第五步：处理每个合并后的组，保留最大文件并重命名
        var plan: [URL: FileAction] = [:]
        var processedURLs: Set<URL> = []
        var finalGroups: [FileGroup] = []

        for (groupIndex, group) in mergedGroups.enumerated() {
            var groupFiles: [DisplayFile] = []

            // 分离HEIC和MOV文件
            let heicFiles = group.filter { $0.pathExtension.lowercased() == "heic" }
            let movFiles = group.filter { $0.pathExtension.lowercased() == "mov" }

            if heicFiles.isEmpty || movFiles.isEmpty {
                print("⚠️ 跳过组 \(groupIndex): 缺少HEIC或MOV文件")
                continue
            }

            // 按文件大小排序，选择最大的
            let sortedHeicFiles = heicFiles.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
            let sortedMovFiles = movFiles.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }

            // 找到最短的基础文件名（用于重命名）
            let allBaseNames = group.map { getBaseName(for: $0) }
            let shortestBaseName = allBaseNames.min { $0.count < $1.count } ?? allBaseNames.first ?? "Unknown"

            print("📸 处理组 \(groupIndex): \(heicFiles.count) HEIC + \(movFiles.count) MOV，重命名为 '\(shortestBaseName)'")

            // 保留最大的HEIC文件
            if let bestHeic = sortedHeicFiles.first {
                let newName = "\(shortestBaseName).heic"
                plan[bestHeic] = .keepAsIs(reason: "Primary Live Photo image (rename to \(newName))")
                processedURLs.insert(bestHeic)
                groupFiles.append(DisplayFile(url: bestHeic, size: bestHeic.fileSize ?? 0, action: plan[bestHeic]!))
            }

            // 保留最大的MOV文件
            if let bestMov = sortedMovFiles.first {
                let newName = "\(shortestBaseName).mov"
                plan[bestMov] = .keepAsIs(reason: "Primary Live Photo video (rename to \(newName))")
                processedURLs.insert(bestMov)
                groupFiles.append(DisplayFile(url: bestMov, size: bestMov.fileSize ?? 0, action: plan[bestMov]!))
            }

            // 删除其他所有HEIC文件
            for duplicateHeic in sortedHeicFiles.dropFirst() {
                plan[duplicateHeic] = .delete(reason: "Duplicate Live Photo image")
                processedURLs.insert(duplicateHeic)
                groupFiles.append(DisplayFile(url: duplicateHeic, size: duplicateHeic.fileSize ?? 0, action: plan[duplicateHeic]!))
            }

            // 删除其他所有MOV文件
            for duplicateMov in sortedMovFiles.dropFirst() {
                plan[duplicateMov] = .delete(reason: "Duplicate Live Photo video")
                processedURLs.insert(duplicateMov)
                groupFiles.append(DisplayFile(url: duplicateMov, size: duplicateMov.fileSize ?? 0, action: plan[duplicateMov]!))
            }

            let deletedCount = (sortedHeicFiles.count - 1) + (sortedMovFiles.count - 1)
            let groupName = if deletedCount > 0 {
                "Live Photo Duplicates: \(shortestBaseName)"
            } else {
                "Perfectly Paired & Ignored: \(shortestBaseName)"
            }

            finalGroups.append(FileGroup(groupName: groupName, files: groupFiles))

            await Task.yield()
            if Task.isCancelled { await MainActor.run { state = .welcome }; return }
        }

        print("📸 Live Photo处理完成: \(mergedGroups.count) 个组，\(processedURLs.count) 个文件已处理")

        // --- PHASE 2: HASHING & CONTENT DUPLICATE DETECTION ---
        let hashingProgressStart = 0.0
        let hashingProgressEnd = 0.5
        
        var urlToHashMap: [URL: String] = [:]
        var hashToFileURLs: [String: [URL]] = [:]
        
        // Filter out files that are already in Live Photo groups
        let urlsToHash = allMediaFileURLs.filter { !pairedURLs.contains($0) }
        print("🔍 Hashing \(urlsToHash.count) files (skipped \(pairedURLs.count) Live Photo files)")

        // --- PHASE 2.5: Parallel Hashing with TaskGroup ---
        let hashingStartTime = Date()
        let _ = Date() // 删除未使用的lastUIUpdateTime变量
        var processedFilesCount = 0
        let totalFilesToHash = urlsToHash.count
        
        // 使用前面已定义的并发限制
        
        try await withThrowingTaskGroup(of: (URL, String?).self) { group in
            var urlIterator = urlsToHash.makeIterator()

            // 1. Start the initial batch of concurrent tasks.
            for _ in 0..<concurrencyLimit {
                if let url = urlIterator.next() {
                    group.addTask {
                        let hash = calculateHash(for: url)
                        return (url, hash)
                    }
                }
            }

            // 2. As each task finishes, process its result and start a new task for the next item.
            for try await (url, hash) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                
                // Process the result of the completed task.
                processedFilesCount += 1
                if let hash = hash {
                    urlToHashMap[url] = hash
                    hashToFileURLs[hash, default: []].append(url)
                }
                
                // Add a new task for the next URL from the iterator.
                if let nextURL = urlIterator.next() {
                    group.addTask {
                        let hash = calculateHash(for: nextURL)
                        return (nextURL, hash)
                    }
                }

                // 每个文件完成后立即更新UI（无节流）
                let hashingProgress = totalFilesToHash > 0 ? (Double(processedFilesCount) / Double(totalFilesToHash)) : 1.0
                let totalHashingElapsedTime = Date().timeIntervalSince(hashingStartTime)
                var etr: TimeInterval? = nil
                if hashingProgress > 0.01 && totalHashingElapsedTime > 1 {
                    let estimatedTotalTime = totalHashingElapsedTime / hashingProgress
                    etr = max(0, estimatedTotalTime - totalHashingElapsedTime)
                }

                // --- Update UI State ---
                let progressVal = hashingProgressStart + hashingProgress * (hashingProgressEnd - hashingProgressStart)

                let progressToUpdate = ScanningProgress(
                    phase: "Phase 2: Analyzing Content",
                    detail: "Computing hash for \(url.lastPathComponent) (\(processedFilesCount)/\(totalFilesToHash))...",
                    progress: progressVal,
                    totalFiles: totalFiles,
                    processedFiles: processedFilesCount,
                    estimatedTimeRemaining: etr,
                    processingSpeedMBps: nil
                )
                await updateScanState(progressToUpdate, animationRate: 12.0)

                // Yield控制权，避免阻塞主线程
                await Task.yield()
            }
        }
        
        if Task.isCancelled { await MainActor.run { state = .welcome }; return }
        
        // --- PHASE 3: BUILDING CLEANING PLAN ---
        let analysisProgressStart = hashingProgressEnd
        let analysisProgressEnd = 1.0
        
        await MainActor.run {
            let progress = ScanningProgress(phase: "Phase 3: Building Plan", detail: "Finding content-identical files...", progress: analysisProgressStart, totalFiles: totalFiles, processedFiles: 0, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
            self.state = .scanning(progress: progress, animationRate: 15.0) // Fixed moderate speed for planning phase
        }

        // Continue using existing plan, processedURLs, and finalGroups from Live Photo processing
        
        // --- PHASE 3.1: Merge Live Photo pairs in content duplicates ---
        await MainActor.run {
            let progress = ScanningProgress(phase: "Phase 3: Building Plan", detail: "Merging Live Photo duplicate groups...", progress: analysisProgressStart + 0.02, totalFiles: totalFiles, processedFiles: processedURLs.count, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
            self.state = .scanning(progress: progress, animationRate: 15.0)
        }

        // Find Live Photo pairs in duplicate groups and merge them
        var mergedHashToFileURLs = hashToFileURLs
        var mergedHashes: Set<String> = []

        for (hash1, urls1) in hashToFileURLs {
            if mergedHashes.contains(hash1) || urls1.count <= 1 { continue }

            // Check if this group contains image files
            let hasImages = urls1.contains { url in
                let ext = url.pathExtension.lowercased()
                return ext == "heic" || ext == "jpg" || ext == "jpeg"
            }

            if hasImages {
                // Look for corresponding MOV files with same base names
                let baseNames = Set(urls1.map { $0.deletingPathExtension().lastPathComponent })

                // Find hash groups that contain MOV files with matching base names
                for (hash2, urls2) in hashToFileURLs {
                    if hash2 == hash1 || mergedHashes.contains(hash2) || urls2.count <= 1 { continue }

                    let hasMOVs = urls2.contains { url in
                        url.pathExtension.lowercased() == "mov"
                    }

                    if hasMOVs {
                        let movBaseNames = Set(urls2.map { $0.deletingPathExtension().lastPathComponent })

                        // Check if there are any matching base names (partial or complete overlap)
                        let overlappingNames = baseNames.intersection(movBaseNames)
                        if !overlappingNames.isEmpty {
                            print("📸 Merging Live Photo duplicate groups (partial match):")
                            print("  HEIC group (\(hash1)): \(urls1.map { $0.lastPathComponent })")
                            print("  MOV group (\(hash2)): \(urls2.map { $0.lastPathComponent })")
                            print("  Overlapping names: \(overlappingNames)")

                            // Merge the groups using the first hash as the key
                            mergedHashToFileURLs[hash1] = urls1 + urls2
                            mergedHashToFileURLs.removeValue(forKey: hash2)
                            mergedHashes.insert(hash1)
                            mergedHashes.insert(hash2)

                            print("  ✅ Merged into single group with \(mergedHashToFileURLs[hash1]?.count ?? 0) files")
                            break
                        }
                    }
                }
            }
        }


        // Process content-identical files first
        let contentDuplicateGroups = mergedHashToFileURLs.filter { $0.value.count > 1 }
        let duplicateGroupsArray = Array(contentDuplicateGroups)
        for (hash, urls) in duplicateGroupsArray {
            if Task.isCancelled { await MainActor.run { state = .welcome }; return }

            var groupFiles: [DisplayFile] = []

            // Check if this is a merged Live Photo group
            let images = urls.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "heic" || ext == "jpg" || ext == "jpeg"
            }
            let videos = urls.filter { url in
                url.pathExtension.lowercased() == "mov"
            }

            let hasImages = !images.isEmpty
            let hasMOVs = !videos.isEmpty

            if hasImages && hasMOVs {
                // This is a merged Live Photo group - keep one image and one video
                let sortedImages = images.sorted { $0.lastPathComponent.count < $1.lastPathComponent.count }
                let sortedVideos = videos.sorted { $0.lastPathComponent.count < $1.lastPathComponent.count }

                // Keep the best image
                if let bestImage = sortedImages.first {
                    plan[bestImage] = .keepAsIs(reason: "Primary Live Photo image")
                    processedURLs.insert(bestImage)
                    groupFiles.append(DisplayFile(url: bestImage, size: bestImage.fileSize ?? 0, action: plan[bestImage]!))
                }

                // Keep the best video
                if let bestVideo = sortedVideos.first {
                    plan[bestVideo] = .keepAsIs(reason: "Primary Live Photo video")
                    processedURLs.insert(bestVideo)
                    groupFiles.append(DisplayFile(url: bestVideo, size: bestVideo.fileSize ?? 0, action: plan[bestVideo]!))
                }

                // Delete all other images
                for imageToDelete in sortedImages.dropFirst() {
                    plan[imageToDelete] = .delete(reason: "Duplicate Live Photo image")
                    processedURLs.insert(imageToDelete)
                    groupFiles.append(DisplayFile(url: imageToDelete, size: imageToDelete.fileSize ?? 0, action: plan[imageToDelete]!))
                }

                // Delete all other videos
                for videoToDelete in sortedVideos.dropFirst() {
                    plan[videoToDelete] = .delete(reason: "Duplicate Live Photo video")
                    processedURLs.insert(videoToDelete)
                    groupFiles.append(DisplayFile(url: videoToDelete, size: videoToDelete.fileSize ?? 0, action: plan[videoToDelete]!))
                }
            } else {
                // Regular content duplicate group - keep only one file
                let sortedURLs = urls.sorted { $0.lastPathComponent.count < $1.lastPathComponent.count }
                guard let fileToKeep = sortedURLs.first else { continue }

                plan[fileToKeep] = .keepAsIs(reason: "Best name among content duplicates")
                processedURLs.insert(fileToKeep)
                groupFiles.append(DisplayFile(url: fileToKeep, size: fileToKeep.fileSize ?? 0, action: plan[fileToKeep]!))

                for urlToDelete in sortedURLs.dropFirst() {
                    plan[urlToDelete] = .delete(reason: "Content Duplicate of \(fileToKeep.lastPathComponent)")
                    processedURLs.insert(urlToDelete)
                    groupFiles.append(DisplayFile(url: urlToDelete, size: urlToDelete.fileSize ?? 0, action: plan[urlToDelete]!))
                }
            }

            let groupName: String
            if hasImages && hasMOVs {
                // This is a merged Live Photo group - use the first URL to get base name
                let baseName = urls.first?.deletingPathExtension().lastPathComponent ?? "Unknown"
                groupName = "Live Photo Duplicates: \(baseName)"
            } else {
                groupName = "Content Duplicates: \(hash)"
            }

            finalGroups.append(FileGroup(groupName: groupName, files: groupFiles))
        }

        // Live Photo pairs are now handled by the merge logic above


        // --- PHASE 3.2: Cooperatively find remaining files ---
        let processedAfterDuplicates = processedURLs.count
        let nameAnalysisProgress = analysisProgressStart + (analysisProgressEnd - analysisProgressStart) * 0.2 // 60% -> 67%
        await MainActor.run {
            let progress = ScanningProgress(phase: "Phase 3: Building Plan", detail: "Isolating unique files...", progress: nameAnalysisProgress, totalFiles: totalFiles, processedFiles: processedAfterDuplicates, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
            self.state = .scanning(progress: progress, animationRate: 15.0)
        }
        await Task.yield() // Ensure UI updates

        var remainingURLs: [URL] = []
        remainingURLs.reserveCapacity(allMediaFileURLs.count - processedURLs.count)
        for (index, url) in allMediaFileURLs.enumerated() {
            if !processedURLs.contains(url) {
                remainingURLs.append(url)
            }
            if index % 5000 == 0 { // Yield to keep UI responsive
                await Task.yield()
                if Task.isCancelled { await MainActor.run { state = .welcome }; return }
            }
        }

        // --- PHASE 3.3: Process remaining files (fallback for edge cases) ---
        let finalProgress = analysisProgressStart + (analysisProgressEnd - analysisProgressStart) * 0.8 // 67% -> 95%
        await MainActor.run {
            let progress = ScanningProgress(phase: "Phase 3: Building Plan", detail: "Processing remaining files...", progress: finalProgress, totalFiles: totalFiles, processedFiles: processedURLs.count, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
            self.state = .scanning(progress: progress, animationRate: 15.0)
        }
        await Task.yield()

        // Note: remainingURLs should be mostly empty at this point since Live Photos are processed in Phase 1.5
        // and content duplicates are processed in Phase 2. This is mainly a safety net for edge cases.
        
        // --- FINALIZATION ---
        let trulyLeftoverURLs = allMediaFileURLs.filter { !processedURLs.contains($0) }
        for url in trulyLeftoverURLs {
             plan[url] = .keepAsIs(reason: "Unique file")
        }
        
        if Task.isCancelled { await MainActor.run { state = .welcome }; return }
        
        await MainActor.run {
            let progress = ScanningProgress(phase: "Scan Complete", detail: "Found \(finalGroups.count) groups.", progress: 1.0, totalFiles: totalFiles, processedFiles: totalFiles, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
            self.state = .scanning(progress: progress, animationRate: 5.0) // Calm down before switching view
        }
        
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s to show complete
        
        await MainActor.run {
            // New sorting logic based on categories
            let order: [String: Int] = [
                "Content Duplicates": 1,
                "Live Photo Duplicates": 2,
                "Perfectly Paired & Ignored": 3
            ]

            let sortedGroups = finalGroups.sorted { g1, g2 in
                func category(for groupName: String) -> (Int, String) {
                    // Handle Live Photo Duplicates as separate category
                    if groupName.starts(with: "Live Photo Duplicates:") {
                        let baseName = groupName.replacingOccurrences(of: "Live Photo Duplicates: ", with: "")
                        return (order["Live Photo Duplicates"]!, baseName)
                    }

                    // Handle standard categories
                    for (prefix, orderValue) in order {
                        if groupName.starts(with: prefix) {
                            let baseName = groupName.replacingOccurrences(of: "\(prefix): ", with: "")
                            return (orderValue, baseName)
                        }
                    }

                    // Default fallback for any unmatched groups
                    return (99, groupName)
                }

                let (order1, name1) = category(for: g1.groupName)
                let (order2, name2) = category(for: g2.groupName)

                if order1 != order2 {
                    return order1 < order2
                }
                
                return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
            }
            
            // This is the new, one-time categorization step.
            let groupedByCat = Dictionary(grouping: sortedGroups, by: { getCategoryPrefix(for: $0.groupName) })
            
            let categorized = groupedByCat.map { categoryName, groupsInCat -> CategorizedGroup in
                let totalSizeToDelete = groupsInCat.flatMap { $0.files }
                    .filter { !$0.action.isKeep }
                    .reduce(0) { $0 + $1.size }
                
                var category = CategorizedGroup(
                    id: categoryName,
                    categoryName: categoryName,
                    groups: groupsInCat,
                    totalSizeToDelete: totalSizeToDelete
                )
                
                // Collapse the "Ignored" group by default
                if categoryName.starts(with: "Perfectly Paired") {
                    category.isExpanded = false
                }
                
                return category
            }.sorted {
                let order1 = order[$0.categoryName] ?? 99
                let order2 = order[$1.categoryName] ?? 99
                return order1 < order2
            }
            
            self.showResults(groups: sortedGroups, categorizedGroups: categorized)
            let endTime = Date()
            print("Scan finished in \(endTime.timeIntervalSince(startTime)) seconds.")
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
        guard let index = masterCategorizedGroups.firstIndex(where: { $0.id == categoryId }) else { return }
        masterCategorizedGroups[index].isExpanded.toggle()
        rebuildDisplayItems()
    }

    private func loadMoreInCategory(categoryId: String) {
        guard let index = masterCategorizedGroups.firstIndex(where: { $0.id == categoryId }) else { return }
        let currentCount = masterCategorizedGroups[index].displayedGroupCount
        masterCategorizedGroups[index].displayedGroupCount = min(currentCount + categoryPageSize, masterCategorizedGroups[index].groups.count)
        rebuildDisplayItems()
    }
    
    /// Extracts a base name from a URL for grouping.
    private func getBaseName(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let cleanName = name.replacingOccurrences(of: "(?:[ _-](?:copy|\\d{1,2})| \\(\\d+\\)|_v\\d{1,2})$", with: "", options: [.regularExpression, .caseInsensitive])
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
        
        // 1. Update the master list of all files
        if let groupIndex = allResultGroups.firstIndex(where: { $0.files.contains(where: { $0.id == file.id }) }),
           let fileIndex = allResultGroups[groupIndex].files.firstIndex(where: { $0.id == file.id }) {
            allResultGroups[groupIndex].files[fileIndex].action = newAction
            
            // 2. Find which category this group belongs to
            let groupName = allResultGroups[groupIndex].groupName
            let categoryName = getCategoryPrefix(for: groupName)

            // 3. Update the corresponding category in the master categorized list
            if let catIndex = masterCategorizedGroups.firstIndex(where: { $0.id == categoryName }) {
                if let masterGroupIndex = masterCategorizedGroups[catIndex].groups.firstIndex(where: { $0.id == allResultGroups[groupIndex].id }),
                   let masterFileIndex = masterCategorizedGroups[catIndex].groups[masterGroupIndex].files.firstIndex(where: { $0.id == file.id }) {
                    
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
        }
    }

}


#if os(macOS)
// MARK: - Preview
#Preview {
    ContentView()
}
#endif 