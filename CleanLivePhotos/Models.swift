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
struct ContentGroup: Identifiable {
    let id = UUID()
    let seedName: String           // 来自种子组的名称
    var files: [URL] = []          // 所有相关文件
    var relationships: [URL: FileRelationship] = [:]  // 文件关系

    init(seedGroup: LivePhotoSeedGroup) {
        self.seedName = seedGroup.seedName
        self.files = seedGroup.allFiles

        // 标记种子文件的关系
        for file in seedGroup.heicFiles {
            relationships[file] = .exactMatch
        }
        for file in seedGroup.movFiles {
            relationships[file] = .exactMatch
        }
    }

    mutating func addContentMatch(_ file: URL) {
        files.append(file)
        relationships[file] = .contentDuplicate
    }

    mutating func addSimilarFile(_ file: URL, similarity: Int) {
        files.append(file)
        relationships[file] = .perceptualSimilar(hammingDistance: similarity)
    }

    func getRelationship(_ file: URL) -> String {
        switch relationships[file] {
        case .exactMatch:
            return "精确匹配"
        case .contentDuplicate:
            return "内容重复"
        case .perceptualSimilar(let distance):
            return "视觉相似 (差异度: \(distance))"
        case nil:
            return "未知关系"
        }
    }
}

/// 文件关系类型
enum FileRelationship {
    case exactMatch                                    // 精确文件名匹配
    case contentDuplicate                             // 内容完全相同
    case perceptualSimilar(hammingDistance: Int)      // 视觉相似
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
        print("🔢 开始计算哈希: \(fileURL.lastPathComponent)")

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

/// 统一的扫描进度管理器
class ScanProgressManager {
    private var etaCalculator = ETACalculator()
    private var currentPhase: ScanPhase?
    private var overallStartTime: Date?
    private var phaseStartTime: Date?
    private var phaseTotalWork: Int = 0

    /// 开始整个扫描过程
    func startScanning() {
        overallStartTime = Date()
        etaCalculator = ETACalculator() // 重置ETA计算器
    }

    /// 开始新阶段
    func startPhase(_ phase: ScanPhase, totalWork: Int) {
        currentPhase = phase
        phaseTotalWork = totalWork
        phaseStartTime = Date()
        etaCalculator.startPhase(phase.rawValue, totalWork: totalWork, weight: phase.weight)
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

        let (eta, confidence) = etaCalculator.updateProgress(phase: phase.rawValue, completed: completed)

        // 计算该阶段内的进度比例（防止除零）
        let phaseProgress = phaseTotalWork > 0 ? Double(completed) / Double(phaseTotalWork) : 0.0

        // 计算总体进度
        let overallProgress = phase.progressStart + (min(1.0, phaseProgress) * phase.weight)

        return ScanningProgress(
            phase: phase.rawValue,
            detail: detail,
            progress: min(1.0, overallProgress),
            totalFiles: totalFiles,
            processedFiles: completed,
            estimatedTimeRemaining: eta,
            processingSpeedMBps: nil, // 可以后续添加
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

        let progress = ScanningProgress(
            phase: "\(phase.rawValue) - Completed",
            detail: "Phase completed",
            progress: phase.progressEnd,
            totalFiles: 0,
            processedFiles: 0,
            estimatedTimeRemaining: nil,
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
}

/// 智能ETA计算器
class ETACalculator {
    private struct PhaseData {
        let startTime: Date
        let totalWork: Int
        let completedWork: Int
        var workHistory: [(timestamp: Date, completed: Int, processingTime: TimeInterval)] = []
        let phaseWeight: Double // 该阶段占总体进度的权重
    }

    private var phases: [String: PhaseData] = [:]
    private var overallStartTime: Date?
    private let smoothingWindow = 10 // 移动平均窗口大小

    /// 开始新阶段
    func startPhase(_ phaseName: String, totalWork: Int, weight: Double) {
        if overallStartTime == nil {
            overallStartTime = Date()
        }

        phases[phaseName] = PhaseData(
            startTime: Date(),
            totalWork: totalWork,
            completedWork: 0,
            phaseWeight: weight
        )
    }

    /// 更新阶段进度并计算ETA
    func updateProgress(phase: String, completed: Int) -> (eta: TimeInterval?, confidence: ETAConfidence) {
        guard var phaseData = phases[phase] else {
            return (nil, .low)
        }

        let now = Date()
        let processingTime = now.timeIntervalSince(phaseData.startTime)

        // 记录历史数据
        phaseData.workHistory.append((
            timestamp: now,
            completed: completed,
            processingTime: processingTime
        ))

        // 保持移动窗口大小
        if phaseData.workHistory.count > smoothingWindow {
            phaseData.workHistory.removeFirst()
        }

        phaseData = PhaseData(
            startTime: phaseData.startTime,
            totalWork: phaseData.totalWork,
            completedWork: completed,
            workHistory: phaseData.workHistory,
            phaseWeight: phaseData.phaseWeight
        )
        phases[phase] = phaseData

        return calculateSmartETA(for: phase, phaseData: phaseData)
    }

    /// 智能ETA计算
    private func calculateSmartETA(for phase: String, phaseData: PhaseData) -> (eta: TimeInterval?, confidence: ETAConfidence) {
        guard phaseData.completedWork > 0 && phaseData.totalWork > phaseData.completedWork else {
            return (nil, .low)
        }

        let historyCount = phaseData.workHistory.count
        var confidence: ETAConfidence = .low

        // 根据历史数据量确定置信度
        if historyCount >= 20 {
            confidence = .veryHigh
        } else if historyCount >= 10 {
            confidence = .high
        } else if historyCount >= 5 {
            confidence = .medium
        }

        // 使用多种算法计算ETA，然后加权平均
        var estimates: [TimeInterval] = []

        // 1. 简单线性预测
        let linearETA = calculateLinearETA(phaseData: phaseData)
        estimates.append(linearETA)

        // 2. 移动平均速度预测
        if let movingAvgETA = calculateMovingAverageETA(phaseData: phaseData) {
            estimates.append(movingAvgETA)
        }

        // 3. 指数衰减预测（给近期数据更高权重）
        if let exponentialETA = calculateExponentialETA(phaseData: phaseData) {
            estimates.append(exponentialETA)
        }

        // 注意：文件大小加权预测暂未实现

        // 加权平均多个预测结果
        let weightedETA = calculateWeightedAverage(estimates: estimates, confidence: confidence)

        // 应用边界检查和平滑处理
        let smoothedETA = applySmoothingAndBounds(eta: weightedETA, phaseData: phaseData)

        return (smoothedETA, confidence)
    }

    // MARK: - 各种ETA算法实现

    private func calculateLinearETA(phaseData: PhaseData) -> TimeInterval {
        let elapsed = Date().timeIntervalSince(phaseData.startTime)
        let progress = Double(phaseData.completedWork) / Double(phaseData.totalWork)
        let estimatedTotal = elapsed / progress
        return max(0, estimatedTotal - elapsed)
    }

    private func calculateMovingAverageETA(phaseData: PhaseData) -> TimeInterval? {
        guard phaseData.workHistory.count >= 2 else { return nil }

        let recent = Array(phaseData.workHistory.suffix(min(5, phaseData.workHistory.count)))
        var speeds: [Double] = []

        // 安全遍历，避免数组越界
        for i in 1..<recent.count {
            guard i < recent.count && i-1 >= 0 && i-1 < recent.count else {
                print("⚠️ ETA计算中数组访问越界，跳过索引 \(i)")
                continue
            }
            let timeDiff = recent[i].timestamp.timeIntervalSince(recent[i-1].timestamp)
            let workDiff = recent[i].completed - recent[i-1].completed
            if timeDiff > 0 && workDiff > 0 {
                speeds.append(Double(workDiff) / timeDiff)
            }
        }

        guard !speeds.isEmpty else { return nil }

        let avgSpeed = speeds.reduce(0, +) / Double(speeds.count)
        let remainingWork = phaseData.totalWork - phaseData.completedWork
        return Double(remainingWork) / avgSpeed
    }

    private func calculateExponentialETA(phaseData: PhaseData) -> TimeInterval? {
        guard phaseData.workHistory.count >= 3 else { return nil }

        var weightedSpeed: Double = 0
        var totalWeight: Double = 0
        let history = phaseData.workHistory

        // 安全遍历，避免数组越界
        for i in 1..<history.count {
            guard i < history.count && i-1 >= 0 && i-1 < history.count else {
                print("⚠️ 指数ETA计算中数组访问越界，跳过索引 \(i)")
                continue
            }
            let timeDiff = history[i].timestamp.timeIntervalSince(history[i-1].timestamp)
            let workDiff = history[i].completed - history[i-1].completed

            if timeDiff > 0 && workDiff > 0 {
                let speed = Double(workDiff) / timeDiff
                let weight = pow(0.8, Double(history.count - i)) // 指数衰减权重

                weightedSpeed += speed * weight
                totalWeight += weight
            }
        }

        guard totalWeight > 0 else { return nil }

        let avgSpeed = weightedSpeed / totalWeight
        let remainingWork = phaseData.totalWork - phaseData.completedWork
        return Double(remainingWork) / avgSpeed
    }


    private func calculateWeightedAverage(estimates: [TimeInterval], confidence: ETAConfidence) -> TimeInterval {
        guard !estimates.isEmpty else { return 0 }

        // 根据置信度调整算法权重
        let weights: [Double]
        switch confidence {
        case .low:
            weights = [0.6, 0.4] // 偏向简单算法
        case .medium:
            weights = [0.4, 0.4, 0.2] // 平衡
        case .high:
            weights = [0.2, 0.3, 0.5] // 偏向复杂算法
        case .veryHigh:
            weights = [0.1, 0.2, 0.7] // 主要依靠指数衰减
        }

        var weightedSum: Double = 0
        var totalWeight: Double = 0

        for (i, estimate) in estimates.enumerated() {
            let weight = i < weights.count ? weights[i] : 0.1
            weightedSum += estimate * weight
            totalWeight += weight
        }

        return totalWeight > 0 ? weightedSum / totalWeight : estimates.first ?? 0
    }

    private func applySmoothingAndBounds(eta: TimeInterval, phaseData: PhaseData) -> TimeInterval {
        let minETA: TimeInterval = 1 // 最少1秒
        let maxETA: TimeInterval = 3600 // 最多1小时

        var smoothedETA = max(minETA, min(maxETA, eta))

        // 如果接近完成，进一步限制ETA
        let progress = Double(phaseData.completedWork) / Double(phaseData.totalWork)
        if progress > 0.95 {
            smoothedETA = min(smoothedETA, 30) // 接近完成时最多30秒
        } else if progress > 0.90 {
            smoothedETA = min(smoothedETA, 60) // 90%完成时最多1分钟
        }

        return smoothedETA
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