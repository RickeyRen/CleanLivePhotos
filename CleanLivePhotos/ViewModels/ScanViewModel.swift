import Foundation
import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - ScanViewModel
// @MainActor 保证所有属性和方法在主线程执行，SwiftUI 可以直接绑定。
// 扫描计算通过 ScanEngine（nonisolated struct）在协作线程池执行。

@Observable
@MainActor
final class ScanViewModel {

    // MARK: - UI 状态（原 ContentView 的所有 @State）

    var scanState: ViewState = .welcome
    var isCancelRequested = false
    var showAlert = false
    var alertTitle = ""
    var alertMessage = ""
    var showErrorDialog = false
    var currentError: DetailedError?
    var errorContext: ErrorContext?
    var progressManager = ScanProgressManager()
    var scanSensitivity: ScanSensitivity = .standard
    var selectedFile: DisplayFile?
    var scannedFolderPath: String?
    var allResultGroups: [FileGroup] = []
    var masterCategorizedGroups: [CategorizedGroup] = []
    var displayItems: [ResultDisplayItem] = []
    var originalFileActions: [UUID: FileAction] = [:]

    // MARK: - 内部状态

    private(set) var currentScanTask: Task<Void, Error>?
    var folderAccessManager = FolderAccessManager()
    private let engine = ScanEngine()
    private let categoryPageSize = 50

    // MARK: - 智能阶段进度管理器（防止进度倒退）

    private class SmartPhaseProgressManager {
        private var currentProgress: Double = 0.0
        private var currentPhaseBase: Double = 0.0
        private var currentPhaseRange: Double = 0.0
        private var currentPhaseName: String = ""

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
            let mappedProgress = currentPhaseBase + (internalProgress * currentPhaseRange)
            currentProgress = max(currentProgress, mappedProgress)
            return currentProgress
        }

        func getCurrentProgress() -> Double { currentProgress }
        func getCurrentPhaseName() -> String { currentPhaseName }
    }

    private let smartProgressManager = SmartPhaseProgressManager()

    // MARK: - 扫描入口

    func startScan(mode: ScanMode) {
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
                    scannedFolderPath = url.path
                    guard await folderAccessManager.startAccessing() else {
                        self.scanState = .error("无法获取文件夹访问权限，请重新选择文件夹。")
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
                        self.scanState = .welcome
                    } catch {
                        self.scanState = .error("扫描过程中发生错误：\(error.localizedDescription)\n\n技术信息：\(String(describing: error))")
                    }
                } else {
                    self.scanState = .error("无法获取文件夹访问权限，请重新选择文件夹并授权。")
                }
            }
        }
        #endif
    }

    func cancelScan() {
        isCancelRequested = true
        currentScanTask?.cancel()
        scanState = .welcome
    }

    // MARK: - 引擎1：精确去重（SHA256 + EXIF 质量评分）

    private func engineExactDedup(in directoryURL: URL) async throws {
        progressManager.startScanning()
        var sha256Cache: [URL: String] = [:]

        self.scanState = .scanning(progress: ScanningProgress(
            phase: "精确去重", detail: "正在初始化...",
            progress: 0.0, totalFiles: 0, processedFiles: 0,
            estimatedTimeRemaining: nil, processingSpeedMBps: nil, confidence: .medium
        ), animationRate: 8.0)

        // S1: 文件发现
        await updateUIPhase("📁 搜索文件", detail: "正在搜索媒体文件...")
        progressManager.startPhase(.fileDiscovery, totalWork: 1000)
        let allMediaFiles = try await engine.stage1_FileDiscovery(
            in: directoryURL,
            onDiscoveryProgress: { [weak self] discovered, detail, isDiscovering in
                await self?.updateDiscoveryProgress(discovered: discovered, detail: detail, isDiscovering: isDiscovering)
            }
        )
        print("📁 S1完成: 发现 \(allMediaFiles.count) 个媒体文件")

        // S2: 同目录配对
        await updateUIPhase("📝 识别Live Photos", detail: "正在按目录识别Live Photo配对...")
        progressManager.startPhase(.exactNameMatching, totalWork: allMediaFiles.count)
        let pairingResult = try await engine.stage2_SameDirectoryPairing(
            files: allMediaFiles,
            onProgress: { [weak self] completed, detail, total in
                await self?.updateProgress(completed: completed, detail: detail, total: total)
            }
        )
        print("📝 S2完成: \(pairingResult.completePairs.count) 完整对，孤立 \(pairingResult.orphanHEICs.count + pairingResult.orphanMOVs.count) 个")

        // S3: Content ID 跨目录配对
        await updateUIPhase("🔗 跨目录配对", detail: "正在用 Content ID 匹配孤立文件...")
        progressManager.updateTotalWork(pairingResult.orphanHEICs.count + pairingResult.orphanMOVs.count)
        let (crossDirPairs, stillOrphanHEICs, stillOrphanMOVs) = try await engine.stage3_ContentIDPairing(
            orphanHEICs: pairingResult.orphanHEICs,
            orphanMOVs: pairingResult.orphanMOVs,
            onProgress: { [weak self] completed, detail, total in
                await self?.updateProgress(completed: completed, detail: detail, total: total)
            }
        )

        let allSeedGroups = pairingResult.completePairs + crossDirPairs
        let allOrphanFiles = stillOrphanHEICs + stillOrphanMOVs
        print("🔗 S3完成: 总种子组 \(allSeedGroups.count) 个，孤立单文件 \(allOrphanFiles.count) 个")

        // S4: SHA256 内容哈希扩展
        await updateUIPhase("🔍 检查文件内容", detail: "正在计算 SHA256 找重复副本...")
        progressManager.startPhase(.contentHashExpansion, totalWork: allMediaFiles.count)
        let expandedGroups = try await engine.stage3_ContentHashExpansion(
            seedGroups: allSeedGroups,
            allFiles: allMediaFiles,
            sha256Cache: &sha256Cache,
            onProgress: { [weak self] completed, detail, total in
                await self?.updateProgress(completed: completed, detail: detail, total: total)
            }
        )
        print("🔗 S4完成: 扩展为 \(expandedGroups.count) 个内容组")

        // S4.2: SHA256 跨组合并
        await updateUIPhase("🔀 合并重复内容", detail: "正在合并完全相同的文件组...")
        progressManager.updateTotalWork(expandedGroups.count)
        let contentGroups = try await engine.stage3_2_CrossGroupSHA256Merging(
            contentGroups: expandedGroups,
            sha256Cache: sha256Cache,
            onProgress: { [weak self] completed, detail, total in
                await self?.updateProgress(completed: completed, detail: detail, total: total)
            }
        )
        print("🚀 S4.2完成: 合并后剩余 \(contentGroups.count) 个内容组")

        // S5: 孤立单文件重复检测
        await updateUIPhase("🔍 查找重复文件", detail: "正在查找重复的单文件...")
        var dummyDHashCache: [URL: UInt64] = [:]
        let processedByLivePhoto = Set(contentGroups.flatMap { $0.files })
        let singleFileGroups = try await engine.detectSingleFileDuplicates(
            allFiles: allMediaFiles,
            processedFiles: processedByLivePhoto,
            sha256Cache: &sha256Cache,
            dHashCache: &dummyDHashCache,
            onProgress: { [weak self] completed, detail, total in
                await self?.updateProgress(completed: completed, detail: detail, total: total)
            }
        )
        print("🔍 S5完成: 发现 \(singleFileGroups.count) 个单文件重复组")

        let allGroupedFiles = Set((contentGroups + singleFileGroups).flatMap { $0.files })
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
        let (duplicatePlans, cleanPlans) = try await engine.stage5_QualityOptimization(
            contentGroups: allGroups,
            onProgress: { [weak self] completed, detail, total in
                await self?.updateProgress(completed: completed, detail: detail, total: total)
            }
        )
        print("⚖️ S6完成: \(duplicatePlans.count) 个重复组, \(cleanPlans.count) 个干净组")

        let finalResults = convertToDisplayFormat(duplicatePlans: duplicatePlans, cleanPlans: cleanPlans)
        showResults(groups: finalResults.fileGroups, categorizedGroups: finalResults.categorizedGroups)
    }

    // MARK: - 引擎2：相似清理（pHash only）

    private func engineSimilarPhotos(in directoryURL: URL) async throws {
        progressManager.startScanning()
        var dHashCache: [URL: UInt64] = [:]

        self.scanState = .scanning(progress: ScanningProgress(
            phase: "相似清理", detail: "正在初始化...",
            progress: 0.0, totalFiles: 0, processedFiles: 0,
            estimatedTimeRemaining: nil, processingSpeedMBps: nil, confidence: .medium
        ), animationRate: 8.0)

        // 阶段1: 文件发现
        await updateUIPhase("📁 搜索文件", detail: "正在搜索媒体文件...")
        progressManager.startPhase(.fileDiscovery, totalWork: 1000)
        let allMediaFiles = try await engine.stage1_FileDiscovery(
            in: directoryURL,
            onDiscoveryProgress: { [weak self] discovered, detail, isDiscovering in
                await self?.updateDiscoveryProgress(discovered: discovered, detail: detail, isDiscovering: isDiscovering)
            }
        )
        print("📁 发现 \(allMediaFiles.count) 个媒体文件")

        // 预计算所有图片的 pHash
        await updateUIPhase("🧮 分析图片特征", detail: "正在计算感知哈希...")
        let imageFiles = allMediaFiles.filter { isImageFile($0) }
        progressManager.startPhase(.contentHashExpansion, totalWork: imageFiles.count)
        try await engine.precomputeImageHashes(
            allFiles: allMediaFiles,
            dHashCache: &dHashCache,
            onProgress: { [weak self] completed, detail, total in
                await self?.updateProgress(completed: completed, detail: detail, total: total)
            }
        )
        print("🧮 pHash 计算完成: \(dHashCache.count) 张图片")

        // 构建单文件 pHash 相似组
        await updateUIPhase("👀 检测相似图片", detail: "正在检测视觉相似的照片...")
        progressManager.startPhase(.perceptualSimilarity, totalWork: imageFiles.count)
        let fileToHash = dHashCache.filter { isImageFile($0.key) }
        let similarGroups = try await engine.applySimilarityDetection(fileToHash: fileToHash)
        print("👀 相似组检测完成: \(similarGroups.count) 个组")

        // 将相似组转为清理计划，全部标记为"保留"
        await updateUIPhase("⚖️ 整理结果", detail: "正在整理相似照片分组...")
        progressManager.startPhase(.fileSizeOptimization, totalWork: similarGroups.count)
        let (duplicatePlans, cleanPlans) = try await engine.stage5_SimilarPhotosAllKeep(
            contentGroups: similarGroups,
            onProgress: { [weak self] completed, detail, total in
                await self?.updateProgress(completed: completed, detail: detail, total: total)
            }
        )
        print("📋 相似清理: \(duplicatePlans.count) 组需审阅, \(cleanPlans.count) 组无相似")

        let finalResults = convertToDisplayFormat(duplicatePlans: duplicatePlans, cleanPlans: cleanPlans)
        showResults(groups: finalResults.fileGroups, categorizedGroups: finalResults.categorizedGroups)
    }

    // MARK: - UI 更新（均在 @MainActor 上执行，线程安全）

    private func updateUIPhase(_ phase: String, detail: String, internalProgress: Double = 0.0) async {
        let globalProgress = smartProgressManager.startPhase(phase)
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
        self.scanState = .scanning(progress: scanProgress, animationRate: 12.0)
    }

    private func updateDiscoveryProgress(discovered: Int, detail: String, isDiscovering: Bool) async {
        let currentPhaseName = smartProgressManager.getCurrentPhaseName()
        let scanProgress = ScanningProgress(
            phase: currentPhaseName,
            detail: detail,
            progress: isDiscovering ? -1.0 : smartProgressManager.getCurrentProgress(),
            totalFiles: isDiscovering ? 0 : discovered,
            processedFiles: discovered,
            estimatedTimeRemaining: nil,
            processingSpeedMBps: nil,
            confidence: .medium
        )
        self.scanState = .scanning(progress: scanProgress, animationRate: isDiscovering ? 20.0 : 12.0)
    }

    private func updateProgress(completed: Int, detail: String, total: Int) async {
        let internalProgress = total > 0 ? Double(completed) / Double(total) : 0.0
        let globalProgress = smartProgressManager.updatePhaseProgress(internalProgress)
        let currentPhaseName = smartProgressManager.getCurrentPhaseName()

        let progressWithETA = progressManager.updateProgress(
            completed: completed,
            detail: detail,
            totalFiles: total
        )

        let scanProgress = ScanningProgress(
            phase: currentPhaseName,
            detail: detail,
            progress: globalProgress,
            totalFiles: total,
            processedFiles: completed,
            estimatedTimeRemaining: progressWithETA.estimatedTimeRemaining,
            processingSpeedMBps: progressWithETA.processingSpeedMBps,
            confidence: progressWithETA.confidence
        )
        self.scanState = .scanning(progress: scanProgress, animationRate: 12.0)
    }

    private func updateScanState(_ progress: ScanningProgress, animationRate: Double) {
        if !isCancelRequested {
            self.scanState = .scanning(progress: progress, animationRate: animationRate)
        }
    }

    // MARK: - 结果展示

    func showResults(groups: [FileGroup], categorizedGroups: [CategorizedGroup]) {
        self.allResultGroups = groups
        self.masterCategorizedGroups = categorizedGroups

        self.originalFileActions = Dictionary(
            uniqueKeysWithValues: groups.flatMap { $0.files }.map { ($0.id, $0.action) }
        )

        rebuildDisplayItems()
        self.scanState = .results
    }

    // MARK: - Display & Interaction Logic

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

    func toggleCategory(_ categoryId: String) {
        guard let index = masterCategorizedGroups.firstIndex(where: { $0.id == categoryId }),
              index < masterCategorizedGroups.count else {
            print("⚠️ 分类不存在或索引越界，无法切换展开状态")
            return
        }
        masterCategorizedGroups[index].isExpanded.toggle()
        rebuildDisplayItems()
    }

    func loadMoreInCategory(_ categoryId: String) {
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

    func updateUserAction(for file: DisplayFile) {
        guard let originalAction = originalFileActions[file.id] else { return }

        let newAction: FileAction
        if file.action.isUserOverride {
            newAction = originalAction
        } else {
            if originalAction.isKeep {
                newAction = .userDelete
            } else {
                newAction = .userKeep
            }
        }

        guard let groupIndex = allResultGroups.firstIndex(where: { $0.files.contains(where: { $0.id == file.id }) }),
              groupIndex < allResultGroups.count,
              let fileIndex = allResultGroups[groupIndex].files.firstIndex(where: { $0.id == file.id }),
              fileIndex < allResultGroups[groupIndex].files.count else {
            print("⚠️ 无法找到要更新的文件，可能已被删除")
            return
        }

        allResultGroups[groupIndex].files[fileIndex].action = newAction

        let targetGroupID = allResultGroups[groupIndex].id
        guard let catIndex = masterCategorizedGroups.firstIndex(where: { category in
            category.groups.contains(where: { $0.id == targetGroupID })
        }), catIndex < masterCategorizedGroups.count else {
            print("⚠️ 无法找到对应的分类，跳过分类更新")
            rebuildDisplayItems()
            return
        }

        guard let masterGroupIndex = masterCategorizedGroups[catIndex].groups.firstIndex(where: { $0.id == targetGroupID }),
              masterGroupIndex < masterCategorizedGroups[catIndex].groups.count,
              let masterFileIndex = masterCategorizedGroups[catIndex].groups[masterGroupIndex].files.firstIndex(where: { $0.id == file.id }),
              masterFileIndex < masterCategorizedGroups[catIndex].groups[masterGroupIndex].files.count else {
            print("⚠️ 无法找到分类中的文件，可能数据不同步")
            rebuildDisplayItems()
            return
        }

        masterCategorizedGroups[catIndex].groups[masterGroupIndex].files[masterFileIndex].action = newAction

        let newTotalSize = masterCategorizedGroups[catIndex].groups.flatMap { $0.files }
            .filter { !$0.action.isKeep }
            .reduce(0) { $0 + $1.size }
        masterCategorizedGroups[catIndex].totalSizeToDelete = newTotalSize

        rebuildDisplayItems()
    }

    func resetToWelcome() {
        self.selectedFile = nil
        self.allResultGroups = []
        self.masterCategorizedGroups = []
        self.displayItems = []
        self.originalFileActions = [:]
        self.scanState = .welcome
    }

    // MARK: - 错误处理

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

    func handleFileProcessingError(
        _ error: Error,
        fileURL: URL,
        phase: String,
        processedFiles: Int,
        totalFiles: Int,
        canSkip: Bool = true
    ) {
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
                print("⚠️ 静默跳过损坏的图像文件: \(hashError.localizedDescription)")
                return
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

    // MARK: - 结果转换

    func convertToDisplayFormat(
        duplicatePlans: [CleaningPlan],
        cleanPlans: [CleaningPlan]
    ) -> (fileGroups: [FileGroup], categorizedGroups: [CategorizedGroup]) {
        var allFileGroups: [FileGroup] = []
        var suspiciousGroups: [FileGroup] = []
        var repairGroups: [FileGroup] = []
        var livePhotoDuplicateGroups: [FileGroup] = []
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

        for plan in duplicatePlans {
            let groupFiles = buildDisplayFiles(from: plan)
            guard !groupFiles.isEmpty else { continue }

            let hasRepair = groupFiles.contains { $0.action.isMoveAction }
            let exts = Set(groupFiles.map { $0.url.pathExtension.lowercased() })
            let isLivePhoto = exts.contains("heic") && exts.contains("mov")

            if plan.isSuspiciousPairing {
                // 可疑配对优先单独收集，无论有无修复操作
                let name = hasRepair
                    ? "❓ 可疑配对（含修复）: \(plan.groupName)"
                    : "❓ 可疑配对: \(plan.groupName)"
                let group = FileGroup(groupName: name, files: groupFiles)
                suspiciousGroups.append(group)
                allFileGroups.append(group)
            } else if hasRepair {
                let name = isLivePhoto
                    ? "🔧 修复Live Photo链接: \(plan.groupName)"
                    : "🔧 需要修复: \(plan.groupName)"
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

        for plan in cleanPlans {
            let groupFiles = buildDisplayFiles(from: plan)
            guard !groupFiles.isEmpty else { continue }
            let exts = Set(groupFiles.map { $0.url.pathExtension.lowercased() })
            let isMOVOnly = exts == ["mov"]
            let isHEICOnly = exts == ["heic"] || exts == ["jpg"] || exts == ["jpeg"]

            if plan.isSuspiciousPairing {
                // 可疑配对单独收集
                let group = FileGroup(groupName: "❓ 可疑配对: \(plan.groupName)", files: groupFiles)
                suspiciousGroups.append(group)
                allFileGroups.append(group)
                continue
            }

            let name: String
            if exts.contains("heic") && exts.contains("mov") {
                name = "✅ 完整Live Photo: \(plan.groupName)"
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

        var categorizedGroups: [CategorizedGroup] = []

        // 可疑配对排在最前，需要用户优先处理
        if !suspiciousGroups.isEmpty {
            categorizedGroups.append(CategorizedGroup(
                id: "Suspicious Pairings",
                categoryName: "❓ 需人工核实：可疑配对 (\(suspiciousGroups.count) 组)",
                groups: suspiciousGroups,
                totalSizeToDelete: 0,
                isExpanded: true,
                displayedGroupCount: suspiciousGroups.count
            ))
        }

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

    // MARK: - 清理执行

    func executeCleaningPlan(for groups: [FileGroup]) {
        Task {
            guard await folderAccessManager.startAccessing() else {
                self.alertTitle = "权限错误"
                self.alertMessage = "无法访问文件夹，请重新选择文件夹并授权。"
                self.showAlert = true
                return
            }
            defer { folderAccessManager.stopAccessing() }

            let allFiles = groups.flatMap { $0.files }

            // 步骤1：执行链接修复（移动/重命名 MOV）
            var moveSuccessCount = 0
            var moveFailCount = 0
            let filesToMove = allFiles.filter { $0.action.isMoveAction }

            for file in filesToMove {
                guard case .move(let targetURL, _) = file.action else { continue }
                do {
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        let srcHash = try? calculateHash(for: file.url)
                        let dstHash = try? calculateHash(for: targetURL)
                        if srcHash != nil && srcHash == dstHash {
                            try FileManager.default.removeItem(at: file.url)
                            moveSuccessCount += 1
                            print("🔗 目标已有相同内容，删除源文件: \(file.url.lastPathComponent)")
                            continue
                        } else {
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

            // 步骤2：执行删除
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

            self.alertTitle = "清理完成"
            var message = ""
            if moveSuccessCount > 0 { message += "修复链接：\(moveSuccessCount) 个文件\n" }
            if moveFailCount > 0 { message += "修复失败：\(moveFailCount) 个文件\n" }
            message += "删除成功：\(deletionSuccessCount) 个文件"
            if deletionFailCount > 0 { message += "\n删除失败：\(deletionFailCount) 个文件" }
            self.alertMessage = message
            self.showAlert = true
            self.scanState = .welcome
        }
    }
}
