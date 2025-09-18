import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Array Extensions

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Global Models


enum HashCalculationError: Error {
    case fileNotAccessible(String)
    case fileNotReadable(String)
    case fileSizeError(String)
    case readError(String)
    case unknownError(String)

    var localizedDescription: String {
        switch self {
        case .fileNotAccessible(let path):
            return "无法访问文件: \(path)"
        case .fileNotReadable(let path):
            return "文件不可读: \(path)"
        case .fileSizeError(let path):
            return "无法获取文件大小: \(path)"
        case .readError(let details):
            return "读取文件时出错: \(details)"
        case .unknownError(let details):
            return "未知错误: \(details)"
        }
    }
}

// MARK: - 新的4阶段算法数据结构

/// Live Photo种子组（阶段1的结果）
struct LivePhotoSeedGroup: Identifiable {
    let id = UUID()
    let seedName: String           // 基础文件名
    var heicFiles: [URL] = []      // HEIC文件列表
    var movFiles: [URL] = []       // MOV文件列表

    var hasCompletePair: Bool {
        return !heicFiles.isEmpty && !movFiles.isEmpty
    }

    var allFiles: [URL] {
        return heicFiles + movFiles
    }
}

/// 内容组（阶段2-3的结果）
/// 组类型枚举
enum GroupType {
    case livePhoto        // Live Photo组
    case singleFile       // ✨ 单文件组
}

struct ContentGroup: Identifiable {
    let id = UUID()
    let seedName: String           // 来自种子组的名称
    let groupType: GroupType       // ✨ 组类型
    var files: [URL] = []          // 所有相关文件
    var relationships: [URL: FileRelationship] = [:]  // 文件关系

    // Live Photo组初始化
    init(seedGroup: LivePhotoSeedGroup) {
        self.seedName = seedGroup.seedName
        self.groupType = .livePhoto
        self.files = seedGroup.allFiles

        // 标记种子文件的关系
        for file in seedGroup.heicFiles {
            relationships[file] = .exactMatch
        }
        for file in seedGroup.movFiles {
            relationships[file] = .exactMatch
        }
    }

    // ✨ 单文件组初始化
    init(singleFile: URL) {
        self.seedName = singleFile.deletingPathExtension().lastPathComponent
        self.groupType = .singleFile
        self.files = [singleFile]
        self.relationships = [singleFile: .identicalFile]
    }

    mutating func addContentMatch(_ file: URL) {
        files.append(file)
        relationships[file] = .contentDuplicate
    }

    mutating func addSimilarFile(_ file: URL, similarity: Int) {
        files.append(file)
        let relationship: FileRelationship = groupType == .livePhoto ?
            .perceptualSimilar(hammingDistance: similarity) :
            .similarFile(hammingDistance: similarity)
        relationships[file] = relationship
    }

    // ✨ 添加相同的单文件
    mutating func addIdenticalFile(_ file: URL) {
        files.append(file)
        relationships[file] = .identicalFile
    }

    func getRelationship(_ file: URL) -> String {
        switch relationships[file] {
        case .exactMatch:
            return "精确匹配"
        case .contentDuplicate:
            return "内容重复"
        case .perceptualSimilar(let distance):
            return "视觉相似 (差异度: \(distance))"
        // ✨ 新增单文件关系类型
        case .identicalFile:
            return "完全相同"
        case .similarFile(let distance):
            return "相似文件 (差异度: \(distance))"
        case nil:
            return "未知关系"
        }
    }
}

/// 文件关系类型
enum FileRelationship {
    case exactMatch                                    // 精确文件名匹配 (Live Photo)
    case contentDuplicate                             // 内容完全相同 (Live Photo扩展)
    case perceptualSimilar(hammingDistance: Int)      // 视觉相似 (Live Photo)

    // ✨ 新增：单文件重复类型
    case identicalFile                                // 完全相同的单文件 (SHA256相同)
    case similarFile(hammingDistance: Int)            // 相似的单文件 (pHash相似)
}

/// 清理计划（阶段4的结果）
struct CleaningPlan: Identifiable {
    let id = UUID()
    let groupName: String
    var actions: [URL: CleaningAction] = [:]

    mutating func keepFile(_ file: URL, reason: String) {
        actions[file] = .keep(reason: reason)
    }

    mutating func deleteFile(_ file: URL, reason: String) {
        actions[file] = .delete(reason: reason)
    }

    var filesToKeep: [URL] {
        return actions.compactMap { key, value in
            if case .keep = value { return key }
            return nil
        }
    }

    var filesToDelete: [URL] {
        return actions.compactMap { key, value in
            if case .delete = value { return key }
            return nil
        }
    }
}

/// 清理动作
enum CleaningAction {
    case keep(reason: String)
    case delete(reason: String)
}

// MARK: - pHash感知哈希算法

/// 计算pHash（感知哈希算法，比dHash更准确）
func calculateDHash(for imageURL: URL) throws -> UInt64 {
    #if os(macOS)
    // 🚀 优化0: 检查文件大小，跳过过大的文件
    do {
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: imageURL.path)
        if let fileSize = fileAttributes[.size] as? Int64, fileSize > 100 * 1024 * 1024 { // 100MB
            throw HashCalculationError.unknownError("文件过大，跳过感知哈希计算")
        }
    } catch {
        // 如果无法获取文件大小，继续处理
    }

    // 🚀 优化1: 使用ImageIO直接创建缩略图，避免加载全尺寸图片
    guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
        throw HashCalculationError.fileNotReadable(imageURL.path)
    }

    // 🚀 优化2: 创建缩略图选项 - pHash需要32×32像素以获得足够的频域信息
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 32, // pHash推荐32×32像素
        kCGImageSourceShouldCache: false // 不缓存，节省内存
    ]

    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
        throw HashCalculationError.unknownError("无法创建缩略图")
    }

    // 🚀 优化3: 使用pHash算法计算感知哈希
    return computePHashFromCGImage(thumbnail)
    #else
    throw HashCalculationError.unknownError("不支持的平台")
    #endif
}

/// 从CGImage计算pHash（感知哈希）
private func computePHashFromCGImage(_ cgImage: CGImage) -> UInt64 {
    let size = 32 // pHash标准尺寸

    // 1. 转换为32×32灰度图像
    var grayPixels: [Double] = Array(repeating: 0, count: size * size)

    let colorSpace = CGColorSpaceCreateDeviceGray()
    let context = CGContext(data: nil,
                           width: size,
                           height: size,
                           bitsPerComponent: 8,
                           bytesPerRow: size,
                           space: colorSpace,
                           bitmapInfo: CGImageAlphaInfo.none.rawValue)

    context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

    // 获取像素数据
    if let data = context?.data {
        let pixelBuffer = data.bindMemory(to: UInt8.self, capacity: size * size)
        for i in 0..<(size * size) {
            grayPixels[i] = Double(pixelBuffer[i])
        }
    }

    // 2. 计算离散余弦变换 (DCT)
    let dctData = computeDCT(grayPixels, size: size)

    // 3. 提取低频分量 (8×8左上角区域，去掉DC分量)
    var lowFreq: [Double] = []
    for y in 0..<8 {
        for x in 0..<8 {
            if !(x == 0 && y == 0) { // 跳过DC分量
                lowFreq.append(dctData[y * size + x])
            }
    }
    }

    // 4. 计算中位数
    let sortedFreq = lowFreq.sorted()
    let median = sortedFreq[sortedFreq.count / 2]

    // 5. 生成64位哈希值
    var hash: UInt64 = 0
    for i in 0..<min(64, lowFreq.count) {
        if lowFreq[i] > median {
            hash |= (1 << i)
        }
    }

    return hash
}

/// 简化的2D离散余弦变换 (DCT)
private func computeDCT(_ data: [Double], size: Int) -> [Double] {
    var result = Array(repeating: 0.0, count: size * size)

    for u in 0..<size {
        for v in 0..<size {
            var sum = 0.0

            for x in 0..<size {
                for y in 0..<size {
                    let pixel = data[y * size + x]
                    let cosU = cos(Double.pi * Double(u) * (Double(x) + 0.5) / Double(size))
                    let cosV = cos(Double.pi * Double(v) * (Double(y) + 0.5) / Double(size))
                    sum += pixel * cosU * cosV
                }
            }

            // 应用DCT系数
            let cu = u == 0 ? 1.0 / sqrt(2.0) : 1.0
            let cv = v == 0 ? 1.0 / sqrt(2.0) : 1.0

            result[v * size + u] = sum * cu * cv * 2.0 / Double(size)
        }
    }

    return result
}

/// 计算汉明距离
func hammingDistance(_ hash1: UInt64, _ hash2: UInt64) -> Int {
    let xor = hash1 ^ hash2
    return xor.nonzeroBitCount
}

/// 文件大小获取
func getFileSize(_ url: URL) -> Int64 {
    do {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(resourceValues.fileSize ?? 0)
    } catch {
        return 0
    }
}

/// 检查是否为图片文件
func isImageFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ["heic", "jpg", "jpeg", "png", "tiff", "bmp"].contains(ext)
}

// MARK: - Union-Find数据结构（用于高效组合并）

/// Union-Find数据结构，用于高效的组合并操作
class UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(size: Int) {
        parent = Array(0..<size)
        rank = Array(repeating: 0, count: size)
    }

    /// 查找根节点（带路径压缩）
    func find(_ x: Int) -> Int {
        if parent[x] != x {
            parent[x] = find(parent[x]) // 路径压缩
        }
        return parent[x]
    }

    /// 合并两个集合（按秩合并）
    func union(_ x: Int, _ y: Int) {
        let rootX = find(x)
        let rootY = find(y)

        if rootX != rootY {
            // 按秩合并，保持树的平衡
            if rank[rootX] < rank[rootY] {
                parent[rootX] = rootY
            } else if rank[rootX] > rank[rootY] {
                parent[rootY] = rootX
            } else {
                parent[rootY] = rootX
                rank[rootX] += 1
            }
        }
    }

    /// 判断两个元素是否在同一个集合中
    func connected(_ x: Int, _ y: Int) -> Bool {
        return find(x) == find(y)
    }
}

/// 检查是否为视频文件
func isVideoFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ["mov", "mp4", "m4v", "avi", "mkv"].contains(ext)
}

func calculateHash(for fileURL: URL) throws -> String {
    let chunkSize = 1024 * 1024 // 1MB
    do {
        // 在沙盒环境中，不需要对子文件调用startAccessingSecurityScopedResource
        // 目录级别的权限应该已经足够
        // 🔧 移除重复日志，由调用方统一处理

        // 检查文件是否存在且可读
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw HashCalculationError.fileNotReadable(fileURL.path)
        }

        // 获取文件属性，检查文件大小
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let fileSize = fileAttributes[.size] as? UInt64, fileSize > 0 else {
            throw HashCalculationError.fileSizeError(fileURL.path)
        }

        let file = try FileHandle(forReadingFrom: fileURL)
        defer {
            do {
                try file.close()
            } catch {
                print("关闭文件句柄时出错: \(error)")
            }
        }

        var hasher = SHA256()

        // If file is small (<= 2MB), hash the whole thing for accuracy.
        if fileSize <= UInt64(chunkSize * 2) {
            try file.seek(toOffset: 0)
            var shouldContinue = true
            while shouldContinue {
                shouldContinue = autoreleasepool {
                    do {
                        let data = try file.read(upToCount: chunkSize) ?? Data()
                        if !data.isEmpty {
                            hasher.update(data: data)
                            return true // Continue
                        } else {
                            return false // End of file
                        }
                    } catch {
                        // 记录错误但不抛出，让外层处理
                        print("读取小文件数据时出错 \(fileURL.path): \(error.localizedDescription)")
                        return false // Stop on error
                    }
                }
            }
        } else {
            // For larger files, hash only the first and last 1MB.
            // This is a massive performance boost for large video files.

            do {
                // Hash the first 1MB chunk.
                try file.seek(toOffset: 0)
                let headData = try file.read(upToCount: chunkSize) ?? Data()
                if !headData.isEmpty {
                    hasher.update(data: headData)
                }

                // Hash the last 1MB chunk.
                let lastChunkOffset = fileSize > UInt64(chunkSize) ? fileSize - UInt64(chunkSize) : 0
                try file.seek(toOffset: lastChunkOffset)
                let tailData = try file.read(upToCount: chunkSize) ?? Data()
                if !tailData.isEmpty {
                    hasher.update(data: tailData)
                }
            } catch {
                throw HashCalculationError.readError("读取大文件数据时出错 \(fileURL.path): \(error.localizedDescription)")
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    } catch let hashError as HashCalculationError {
        throw hashError
    } catch {
        throw HashCalculationError.unknownError("计算哈希时出错 \(fileURL.path): \(error.localizedDescription)")
    }
}

// MARK: - Core Data Models & Enums

/// Describes the action to be taken on a file and the reason why.
enum FileAction: Hashable {
    case keepAsIs(reason: String)
    case delete(reason: String)
    case userKeep // User override to keep a file that was marked for deletion.
    case userDelete // User override to delete a file that was marked for keeping.

    var isKeep: Bool {
        switch self {
        case .keepAsIs, .userKeep:
            return true
        case .delete, .userDelete:
            return false
        }
    }

    var isUserOverride: Bool {
        switch self {
        case .userKeep, .userDelete:
            return true
        default:
            return false
        }
    }
}

/// A file representation used for display purposes in the UI.
struct DisplayFile: Identifiable, Hashable {
    static func == (lhs: DisplayFile, rhs: DisplayFile) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    let id = UUID()
    let url: URL
    let size: Int64
    var action: FileAction

    var fileName: String {
        url.lastPathComponent
    }
}

/// A group of related files (either by hash or by name).
struct FileGroup: Identifiable {
    let id = UUID()
    let groupName: String
    var files: [DisplayFile]
}

/// A structure that holds all data and UI state for a category.
struct CategorizedGroup: Identifiable {
    let id: String // Category name, used for identification
    let categoryName: String
    var groups: [FileGroup]
    var totalSizeToDelete: Int64
    
    // UI state
    var isExpanded: Bool = true
    var displayedGroupCount: Int = 50 // Initial number of groups to show
}

/// Represents a single item in the flattened, displayable list.
enum ResultDisplayItem: Identifiable, Hashable {
    // Hashable conformance
    static func == (lhs: ResultDisplayItem, rhs: ResultDisplayItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    case categoryHeader(id: String, title: String, groupCount: Int, size: Int64, isExpanded: Bool)
    case fileGroup(FileGroup)
    case loadMore(categoryId: String)

    var id: String {
        switch self {
        case .categoryHeader(let id, _, _, _, _):
            return "header_\(id)"
        case .fileGroup(let group):
            return group.id.uuidString
        case .loadMore(let categoryId):
            return "loadMore_\(categoryId)"
        }
    }
}

/// Represents a single, displayable row in the results list.
enum ResultRow: Identifiable, Hashable {
    case single(DisplayFile)
    case pair(mov: DisplayFile, heic: DisplayFile)

    var id: UUID {
        switch self {
        case .single(let file):
            return file.id
        case .pair(let mov, _):
            return mov.id
        }
    }
}

/// A structure to hold detailed scanning progress information.
struct ScanningProgress {
    let phase: String
    let detail: String
    let progress: Double // Overall progress from 0.0 to 1.0
    let totalFiles: Int
    let processedFiles: Int

    // New detailed parameters
    let estimatedTimeRemaining: TimeInterval?
    let processingSpeedMBps: Double?
    let confidence: ETAConfidence?
}

/// ETA置信度等级
enum ETAConfidence {
    case low        // 初始阶段，数据不足
    case medium     // 有一定数据基础
    case high       // 数据充足，预测较准确
    case veryHigh   // 接近完成，预测非常准确

    var description: String {
        switch self {
        case .low: return "估算中"
        case .medium: return "计算中"
        case .high: return "约"
        case .veryHigh: return "即将完成"
        }
    }
}

/// 新的4阶段扫描定义
enum ScanPhase: String, CaseIterable {
    case fileDiscovery = "Phase 1: File Discovery"
    case exactNameMatching = "Phase 2: Exact Name Matching"
    case contentHashExpansion = "Phase 3: Content Hash Expansion"
    case perceptualSimilarity = "Phase 4: Perceptual Similarity"
    case fileSizeOptimization = "Phase 5: File Size Optimization"

    /// 阶段权重（占总体进度的比例）
    var weight: Double {
        switch self {
        case .fileDiscovery: return 0.10
        case .exactNameMatching: return 0.05
        case .contentHashExpansion: return 0.60  // 哈希计算最耗时
        case .perceptualSimilarity: return 0.20
        case .fileSizeOptimization: return 0.05
        }
    }

    /// 阶段起始进度值
    var progressStart: Double {
        let previousWeights = ScanPhase.allCases.prefix(while: { $0 != self }).map { $0.weight }
        return previousWeights.reduce(0, +)
    }

    /// 阶段结束进度值
    var progressEnd: Double {
        return progressStart + weight
    }
}

/// 统一的扫描进度管理器 - 实现整体ETA计算
class ScanProgressManager {
    private var overallStartTime: Date?
    private var currentPhase: ScanPhase?
    private var phaseTotalWork: Int = 0

    // 🚀 整体进度跟踪
    private var overallProgressHistory: [(timestamp: Date, progress: Double)] = []
    private let historyWindow = 20  // 保留最近20个进度点用于ETA计算

    // ✨ ETA更新控制 - 每1秒更新一次
    private var lastETAUpdate: Date?
    private var cachedETA: TimeInterval?
    private var cachedConfidence: ETAConfidence = .low
    private let etaUpdateInterval: TimeInterval = 1.0  // 1秒更新间隔

    /// 开始整个扫描过程
    func startScanning() {
        overallStartTime = Date()
        overallProgressHistory = []
        // ✨ 重置ETA缓存
        lastETAUpdate = nil
        cachedETA = nil
        cachedConfidence = .low
    }

    /// 开始新阶段
    func startPhase(_ phase: ScanPhase, totalWork: Int) {
        currentPhase = phase
        phaseTotalWork = totalWork

        // 记录阶段开始的整体进度
        let currentProgress = phase.progressStart
        recordProgress(currentProgress)
    }

    /// 更新当前阶段进度
    func updateProgress(completed: Int, detail: String, totalFiles: Int) -> ScanningProgress {
        guard let phase = currentPhase else {
            return ScanningProgress(
                phase: "Unknown",
                detail: detail,
                progress: 0.0,
                totalFiles: totalFiles,
                processedFiles: completed,
                estimatedTimeRemaining: nil,
                processingSpeedMBps: nil,
                confidence: .low
            )
        }

        // 计算该阶段内的进度比例（防止除零）
        let phaseProgress = phaseTotalWork > 0 ? Double(completed) / Double(phaseTotalWork) : 0.0

        // 计算总体进度
        let overallProgress = phase.progressStart + (min(1.0, phaseProgress) * phase.weight)

        // 🚀 记录进度历史用于整体ETA计算
        recordProgress(overallProgress)

        // ✨ 控制ETA更新频率 - 每1秒更新一次
        let (eta, confidence) = getThrottledETA(currentProgress: overallProgress)

        return ScanningProgress(
            phase: phase.rawValue,
            detail: detail,
            progress: min(1.0, overallProgress),
            totalFiles: totalFiles,
            processedFiles: completed,
            estimatedTimeRemaining: eta,
            processingSpeedMBps: nil,
            confidence: confidence
        )
    }

    /// 更新阶段总工作量（动态调整）
    func updateTotalWork(_ newTotal: Int) {
        phaseTotalWork = max(phaseTotalWork, newTotal)
    }

    /// 完成当前阶段
    func completePhase() -> ScanningProgress? {
        guard let phase = currentPhase else { return nil }

        // 记录阶段完成的整体进度
        recordProgress(phase.progressEnd)

        let progress = ScanningProgress(
            phase: "\(phase.rawValue) - Completed",
            detail: "Phase completed",
            progress: phase.progressEnd,
            totalFiles: 0,
            processedFiles: 0,
            estimatedTimeRemaining: calculateOverallETA(currentProgress: phase.progressEnd).0,
            processingSpeedMBps: nil,
            confidence: .veryHigh
        )

        return progress
    }

    /// 获取总体进度信息
    func getOverallProgress() -> (elapsed: TimeInterval, phase: String?) {
        let elapsed = overallStartTime?.timeIntervalSinceNow ?? 0
        return (elapsed: -elapsed, phase: currentPhase?.rawValue)
    }

    // MARK: - 🚀 统一ETA计算核心方法

    /// 记录进度历史点
    private func recordProgress(_ progress: Double) {
        let now = Date()
        overallProgressHistory.append((timestamp: now, progress: progress))

        // 保持历史记录在合理范围内
        if overallProgressHistory.count > historyWindow {
            overallProgressHistory.removeFirst()
        }
    }

    /// ✨ 获取受控制的ETA - 每1秒更新一次
    private func getThrottledETA(currentProgress: Double) -> (TimeInterval?, ETAConfidence) {
        let now = Date()

        // 检查是否需要更新ETA（首次调用或超过更新间隔）
        let shouldUpdate = lastETAUpdate == nil ||
                          now.timeIntervalSince(lastETAUpdate!) >= etaUpdateInterval

        if shouldUpdate {
            // 重新计算ETA
            let (newETA, newConfidence) = calculateOverallETA(currentProgress: currentProgress)

            // 更新缓存
            cachedETA = newETA
            cachedConfidence = newConfidence
            lastETAUpdate = now

            return (newETA, newConfidence)
        } else {
            // 使用缓存的ETA
            return (cachedETA, cachedConfidence)
        }
    }

    /// 基于整体进度计算统一的ETA
    private func calculateOverallETA(currentProgress: Double) -> (TimeInterval?, ETAConfidence) {
        guard let startTime = overallStartTime,
              overallProgressHistory.count >= 2,
              currentProgress > 0.0,
              currentProgress < 1.0 else {
            return (nil, .low)
        }

        let now = Date()
        let totalElapsed = now.timeIntervalSince(startTime)

        // 🎯 方法1: 基于整体平均速度
        let avgProgress = currentProgress / totalElapsed
        let remainingProgress = 1.0 - currentProgress
        let etaByAverage = remainingProgress / avgProgress

        // 🎯 方法2: 基于最近进度速度（更准确）
        let recentHistory = Array(overallProgressHistory.suffix(min(10, overallProgressHistory.count)))
        if recentHistory.count >= 2 {
            let firstPoint = recentHistory.first!
            let lastPoint = recentHistory.last!
            let timeSpan = lastPoint.timestamp.timeIntervalSince(firstPoint.timestamp)
            let progressSpan = lastPoint.progress - firstPoint.progress

            if timeSpan > 0 && progressSpan > 0 {
                let recentSpeed = progressSpan / timeSpan
                let etaByRecent = remainingProgress / recentSpeed

                // 🎯 智能加权：结合两种方法
                let weight = min(1.0, totalElapsed / 30.0) // 30秒后逐渐信任最近速度
                let finalEta = etaByAverage * (1 - weight) + etaByRecent * weight

                // 🎯 计算置信度
                let confidence = calculateConfidence(
                    elapsed: totalElapsed,
                    progress: currentProgress,
                    historyCount: overallProgressHistory.count
                )

                return (finalEta, confidence)
            }
        }

        // 默认使用平均速度
        let confidence = calculateConfidence(
            elapsed: totalElapsed,
            progress: currentProgress,
            historyCount: overallProgressHistory.count
        )

        return (etaByAverage, confidence)
    }

    /// 计算ETA置信度
    private func calculateConfidence(elapsed: TimeInterval, progress: Double, historyCount: Int) -> ETAConfidence {
        // 基于时间、进度和历史数据点数量综合判断
        if progress > 0.8 {
            return .veryHigh  // 接近完成
        } else if elapsed > 60 && historyCount >= 15 && progress > 0.3 {
            return .high      // 有充足数据且已完成较多
        } else if elapsed > 20 && historyCount >= 8 && progress > 0.1 {
            return .medium    // 有一定数据基础
        } else {
            return .low       // 初始阶段
        }
    }
}


/// The different states the main view can be in.
enum ViewState {
    case welcome
    case scanning(progress: ScanningProgress, animationRate: Double)
    case results
    case error(String)
}

/// 错误恢复选项
enum ErrorRecoveryOption {
    case retry(title: String, action: () async -> Void)
    case skip(title: String, action: () async -> Void)
    case abort(title: String, action: () async -> Void)
    case continueWithoutFile(title: String, action: () async -> Void)
}

/// 详细的错误信息结构
struct DetailedError {
    let title: String
    let message: String
    let technicalDetails: String?
    let recoveryOptions: [ErrorRecoveryOption]
    let canContinue: Bool

    init(title: String, message: String, technicalDetails: String? = nil, recoveryOptions: [ErrorRecoveryOption] = [], canContinue: Bool = false) {
        self.title = title
        self.message = message
        self.technicalDetails = technicalDetails
        self.recoveryOptions = recoveryOptions
        self.canContinue = canContinue
    }
}

/// 错误上下文，用于在错误恢复时保存必要的状态信息
struct ErrorContext {
    let fileURL: URL?
    let currentPhase: String
    let totalFiles: Int
    let processedFiles: Int
    let canSkipFile: Bool
    let resumeOperation: (() async -> Void)?
}

// A typealias for a list of metadata items, making the data model flexible.
typealias FileMetadata = [(label: String, value: String, icon: String)]

extension FileAction {
    var reasonText: String {
        switch self {
        case .keepAsIs(let reason):
            return reason
        case .delete(let reason):
            return reason
        case .userKeep:
            return "Forced Keep by User"
        case .userDelete:
            return "Forced Deletion by User"
        }
    }
} 