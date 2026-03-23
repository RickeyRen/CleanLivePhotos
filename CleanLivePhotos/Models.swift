import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import AVFoundation
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
    case imageDecodingError(String) // 新增：图像解码错误（HEIC/HJPG等）
    case unknownError(String)

    var localizedDescription: String {
        switch self {
        case .fileNotAccessible(let path):
            return "无法访问文件: \(path)"
        case .fileNotReadable(let path):
            return "文件不可读: \(path)"
        case .fileSizeError(let path):
            return "无法获取文件大小: \(path)"
        case .imageDecodingError(let path):
            return "图像解码失败: \(path)"
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
    var isSuspiciousPairing: Bool = false  // Content ID 配对但文件名不一致（需人工核实）

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
    var isSuspiciousPairing: Bool = false  // Content ID 配对但文件名不一致

    // Live Photo组初始化
    init(seedGroup: LivePhotoSeedGroup) {
        self.seedName = seedGroup.seedName
        self.groupType = .livePhoto
        self.files = seedGroup.allFiles
        self.isSuspiciousPairing = seedGroup.isSuspiciousPairing

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
    var isSuspiciousPairing: Bool = false  // Content ID 配对但文件名不一致（需人工核实）
    var actions: [URL: CleaningAction] = [:]

    mutating func keepFile(_ file: URL, reason: String) {
        actions[file] = .keep(reason: reason)
    }

    mutating func deleteFile(_ file: URL, reason: String) {
        actions[file] = .delete(reason: reason)
    }

    mutating func moveFile(_ file: URL, to targetURL: URL, reason: String) {
        actions[file] = .move(to: targetURL, reason: reason)
    }

    var filesToKeep: [URL] {
        return actions.compactMap { key, value in
            switch value {
            case .keep, .move: return key
            default: return nil
            }
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
    case move(to: URL, reason: String)  // 修复链接：重命名/移动 MOV 文件
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

    // 🛡️ 先检查图像源状态，避免尝试解码损坏的HEIC文件
    let imageCount = CGImageSourceGetCount(imageSource)
    guard imageCount > 0 else {
        throw HashCalculationError.imageDecodingError(imageURL.path)
    }

    // 🚀 优化2: 创建缩略图选项 - pHash需要32×32像素以获得足够的频域信息
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 32, // pHash推荐32×32像素
        kCGImageSourceShouldCache: false // 不缓存，节省内存
    ]

    // 🛡️ 静默处理HEIC/HJPG解码错误，避免控制台错误信息泛滥
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
        // 特别标识HEIC/HJPG解码错误，用于静默处理
        let fileExtension = imageURL.pathExtension.lowercased()
        if fileExtension == "heic" || fileExtension == "hjpg" {
            throw HashCalculationError.imageDecodingError(imageURL.path)
        } else {
            throw HashCalculationError.unknownError("无法创建缩略图")
        }
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

/// 预计算 DCT 余弦查找表（全局懒加载，只初始化一次）
/// 针对 pHash 固定尺寸 32×32，节省每张图片重复计算 cos() 的开销
private let _dctCosTable: [[Double]] = {
    let size = 32
    return (0..<size).map { k in
        (0..<size).map { n in
            cos(Double.pi * Double(k) * (Double(n) + 0.5) / Double(size))
        }
    }
}()

/// 可分离 2D DCT（比朴素四重循环快约 32 倍）
///
/// 原理：2D DCT 可分解为两次 1D DCT
///   - 第一步：逐行做 1D DCT → 中间矩阵 G
///   - 第二步：逐列对 G 做 1D DCT + 归一化 → 最终结果
/// 复杂度：O(n³) vs 朴素实现的 O(n⁴)
private func computeDCT(_ data: [Double], size: Int) -> [Double] {
    let cosTable = _dctCosTable  // 局部引用，避免重复全局查找

    // 第一步：逐行 1D DCT（不含归一化系数）
    var intermediate = Array(repeating: 0.0, count: size * size)
    for y in 0..<size {
        let rowOffset = y * size
        for u in 0..<size {
            var sum = 0.0
            let cosRow = cosTable[u]
            for x in 0..<size {
                sum += data[rowOffset + x] * cosRow[x]
            }
            intermediate[rowOffset + u] = sum
        }
    }

    // 第二步：逐列 1D DCT + 归一化
    var result = Array(repeating: 0.0, count: size * size)
    let scale = 2.0 / Double(size)
    for u in 0..<size {
        let cu = u == 0 ? 1.0 / sqrt(2.0) : 1.0
        for v in 0..<size {
            var sum = 0.0
            let cosCol = cosTable[v]
            for y in 0..<size {
                sum += intermediate[y * size + u] * cosCol[y]
            }
            let cv = v == 0 ? 1.0 / sqrt(2.0) : 1.0
            result[v * size + u] = sum * cu * cv * scale
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

/// 文件大小阈值：超过此值使用部分哈希（首尾各3MB）
/// 覆盖了 iPhone 所有 Live Photo / HEIC / MOV 文件（通常 < 50MB）
/// ⚠️ 安全说明：50MB 以下的文件始终计算完整 SHA256，杜绝误判
private let fullHashThreshold: UInt64 = 50 * 1024 * 1024  // 50MB

func calculateHash(for fileURL: URL) throws -> String {
    let chunkSize = 1024 * 1024 // 1MB per chunk
    let largeFileChunkSize = 3 * 1024 * 1024 // 3MB per chunk for large files
    do {
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

        // 🛡️ 安全修复：50MB 以下的文件（覆盖所有典型照片/Live Photo）始终完整哈希
        // 这消除了头尾部分哈希可能导致不同文件被误判为重复的风险
        if fileSize <= fullHashThreshold {
            try file.seek(toOffset: 0)
            var shouldContinue = true
            while shouldContinue {
                shouldContinue = autoreleasepool {
                    do {
                        let data = try file.read(upToCount: chunkSize) ?? Data()
                        if !data.isEmpty {
                            hasher.update(data: data)
                            return true
                        } else {
                            return false
                        }
                    } catch {
                        print("读取文件数据时出错 \(fileURL.path): \(error.localizedDescription)")
                        return false
                    }
                }
            }
        } else {
            // 超大文件（> 50MB）：使用首尾各3MB + 文件大小做组合哈希
            // 同时将文件大小编入哈希，使不同大小的文件即使头尾相同也不会碰撞
            // ⚠️ 注意：此路径不应被常规照片/视频触发，仅用于原始视频素材等超大文件
            do {
                // 将文件大小写入哈希，防止不同大小文件碰撞
                var fileSizeBytes = fileSize.bigEndian
                let sizeData = withUnsafeBytes(of: &fileSizeBytes) { Data($0) }
                hasher.update(data: sizeData)

                // 哈希首部 3MB
                try file.seek(toOffset: 0)
                let headData = try file.read(upToCount: largeFileChunkSize) ?? Data()
                if !headData.isEmpty { hasher.update(data: headData) }

                // 哈希中间 3MB（文件正中间，降低碰撞概率）
                let midOffset = fileSize / 2
                let safeMidOffset = midOffset > UInt64(largeFileChunkSize) ? midOffset - UInt64(largeFileChunkSize / 2) : 0
                try file.seek(toOffset: safeMidOffset)
                let midData = try file.read(upToCount: largeFileChunkSize) ?? Data()
                if !midData.isEmpty { hasher.update(data: midData) }

                // 哈希尾部 3MB
                let lastChunkOffset = fileSize > UInt64(largeFileChunkSize) ? fileSize - UInt64(largeFileChunkSize) : 0
                try file.seek(toOffset: lastChunkOffset)
                let tailData = try file.read(upToCount: largeFileChunkSize) ?? Data()
                if !tailData.isEmpty { hasher.update(data: tailData) }
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
    /// 修复 Live Photo 链接：将 MOV 移动/重命名到目标路径
    case move(to: URL, reason: String)
    case userKeep   // 用户手动标记保留
    case userDelete // 用户手动标记删除

    var isKeep: Bool {
        switch self {
        case .keepAsIs, .userKeep, .move:
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

    var isMoveAction: Bool {
        if case .move = self { return true }
        return false
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

    // ✨ ETA更新控制 - 每2秒更新一次，减少波动
    private var lastETAUpdate: Date?
    private var cachedETA: TimeInterval?
    private var cachedConfidence: ETAConfidence = .low
    private let etaUpdateInterval: TimeInterval = 2.0  // 2秒更新间隔，减少频繁变化

    // 🎯 ETA平滑处理
    private var etaHistory: [TimeInterval] = []  // 存储最近几次的ETA计算结果
    private let etaHistorySize = 3  // 保留最近3次ETA用于平均

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
        recordOverallProgress(currentProgress)
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

        // 🚀 记录阶段特定进度历史
        recordPhaseProgress(completed)

        // ✨ 控制ETA更新频率 - 每1秒更新一次
        let (eta, confidence) = getThrottledETA(currentProgress: overallProgress, completed: completed)

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
        recordOverallProgress(phase.progressEnd)

        let progress = ScanningProgress(
            phase: "\(phase.rawValue) - Completed",
            detail: "Phase completed",
            progress: phase.progressEnd,
            totalFiles: 0,
            processedFiles: 0,
            estimatedTimeRemaining: calculatePhaseAwareETA(currentProgress: phase.progressEnd).0,
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

    // MARK: - 🚀 全新阶段感知ETA计算系统

    /// 阶段性能基线数据（每1000个文件的预期时间，秒）
    private let phaseBaselines: [ScanPhase: Double] = [
        .fileDiscovery: 2.0,           // 文件发现很快
        .exactNameMatching: 1.5,       // 精确名称匹配很快
        .contentHashExpansion: 30.0,   // 内容哈希扩展最耗时（包含SHA256+pHash）
        .perceptualSimilarity: 8.0,    // 感知相似性检测中等耗时
        .fileSizeOptimization: 1.0     // 文件大小优化很快
    ]

    /// 阶段特定的历史记录
    private var phaseSpecificHistory: [ScanPhase: [(timestamp: Date, completed: Int)]] = [:]

    /// 记录阶段进度历史点
    private func recordPhaseProgress(_ completed: Int) {
        guard let phase = currentPhase else { return }

        let now = Date()
        if phaseSpecificHistory[phase] == nil {
            phaseSpecificHistory[phase] = []
        }

        phaseSpecificHistory[phase]?.append((timestamp: now, completed: completed))

        // 保持每个阶段最多20个历史点
        if let count = phaseSpecificHistory[phase]?.count, count > 20 {
            phaseSpecificHistory[phase]?.removeFirst()
        }

        // 同时记录整体进度用于阶段间预测
        let overallProgress = phase.progressStart + (min(1.0, Double(completed) / Double(phaseTotalWork)) * phase.weight)
        recordOverallProgress(overallProgress)
    }

    /// 记录整体进度历史点
    private func recordOverallProgress(_ progress: Double) {
        let now = Date()
        overallProgressHistory.append((timestamp: now, progress: progress))

        if overallProgressHistory.count > historyWindow {
            overallProgressHistory.removeFirst()
        }
    }

    /// ✨ 获取受控制的ETA - 每2秒更新一次减少波动
    private func getThrottledETA(currentProgress: Double, completed: Int = 0) -> (TimeInterval?, ETAConfidence) {
        let now = Date()

        // 检查是否需要更新ETA（首次调用或超过更新间隔）
        let shouldUpdate = lastETAUpdate == nil ||
                          now.timeIntervalSince(lastETAUpdate!) >= 2.0  // 改为2秒间隔

        if shouldUpdate {
            // 使用新的阶段感知算法计算ETA
            let (rawETA, newConfidence) = calculatePhaseAwareETA(currentProgress: currentProgress, completed: completed)

            // 🎯 温和平滑ETA处理
            let smoothedETA = gentlySmoothETA(rawETA: rawETA)

            // 更新缓存
            cachedETA = smoothedETA
            cachedConfidence = newConfidence
            lastETAUpdate = now

            return (smoothedETA, newConfidence)
        } else {
            // 使用缓存的ETA，但逐步递减模拟时间流逝
            if let cached = cachedETA, cached > 0 {
                let timeElapsed = now.timeIntervalSince(lastETAUpdate!)
                let adjustedETA = max(0, cached - timeElapsed)
                return (adjustedETA > 1 ? adjustedETA : nil, cachedConfidence)
            }
            return (cachedETA, cachedConfidence)
        }
    }

    /// 🎯 温和平滑ETA - 大幅减少跳动
    private func gentlySmoothETA(rawETA: TimeInterval?) -> TimeInterval? {
        guard let rawETA = rawETA, rawETA > 0 else { return nil }

        // 添加到历史记录
        etaHistory.append(rawETA)
        if etaHistory.count > 5 {  // 减少历史窗口
            etaHistory.removeFirst()
        }

        // 使用中位数过滤异常值
        let sortedHistory = etaHistory.sorted()
        let median = sortedHistory[sortedHistory.count / 2]

        // 与缓存ETA比较，限制变化幅度
        if let lastCached = cachedETA, lastCached > 0 {
            let changeRatio = abs(median - lastCached) / lastCached

            // 如果变化超过20%，渐进调整
            if changeRatio > 0.2 {
                let maxChange = lastCached * 0.15  // 每次最多变化15%
                if median > lastCached {
                    return lastCached + maxChange
                } else {
                    return lastCached - maxChange
                }
            }
        }

        return median
    }

    /// 🚀 全新阶段感知ETA计算算法
    private func calculatePhaseAwareETA(currentProgress: Double, completed: Int = 0) -> (TimeInterval?, ETAConfidence) {
        guard let startTime = overallStartTime,
              let _ = currentPhase,
              phaseTotalWork > 0 else {
            return (nil, .low)
        }

        let now = Date()
        let totalElapsed = now.timeIntervalSince(startTime)

        // 🎯 当前阶段剩余时间计算
        let currentPhaseETA = calculateCurrentPhaseETA(completed: completed)

        // 🎯 后续阶段预估时间计算
        let remainingPhasesETA = calculateRemainingPhasesETA()

        // 🎯 总ETA = 当前阶段剩余时间 + 后续阶段时间
        guard let currentETA = currentPhaseETA else {
            return (remainingPhasesETA, .low)
        }

        let totalETA = currentETA + remainingPhasesETA

        // 🎯 计算置信度
        let confidence = calculatePhaseAwareConfidence(
            currentPhaseProgress: Double(completed) / Double(phaseTotalWork),
            totalElapsed: totalElapsed
        )

        return (totalETA, confidence)
    }

    /// 计算当前阶段剩余时间
    private func calculateCurrentPhaseETA(completed: Int) -> TimeInterval? {
        guard let currentPhase = currentPhase,
              phaseTotalWork > 0,
              completed < phaseTotalWork else {
            return 0  // 当前阶段已完成
        }

        let remainingWork = phaseTotalWork - completed

        // 🎯 方法1: 基于阶段历史性能
        if let history = phaseSpecificHistory[currentPhase], history.count >= 2 {
            let recentHistory = Array(history.suffix(min(5, history.count)))
            if recentHistory.count >= 2 {
                let firstPoint = recentHistory.first!
                let lastPoint = recentHistory.last!
                let timeSpan = lastPoint.timestamp.timeIntervalSince(firstPoint.timestamp)
                let workDone = lastPoint.completed - firstPoint.completed

                if timeSpan > 2.0 && workDone > 0 {  // 至少2秒数据且有进展
                    let currentSpeed = Double(workDone) / timeSpan  // 每秒处理量
                    return Double(remainingWork) / currentSpeed
                }
            }
        }

        // 🎯 方法2: 使用基线估算
        if let baseline = phaseBaselines[currentPhase] {
            let estimatedTimeFor1000 = baseline
            let scaledTime = estimatedTimeFor1000 * (Double(remainingWork) / 1000.0)
            return scaledTime
        }

        return nil
    }

    /// 计算后续阶段预估时间
    private func calculateRemainingPhasesETA() -> TimeInterval {
        guard let currentPhase = currentPhase else { return 0 }

        let allPhases = ScanPhase.allCases
        guard let currentIndex = allPhases.firstIndex(of: currentPhase) else { return 0 }

        let remainingPhases = Array(allPhases.suffix(from: currentIndex + 1))

        var totalRemainingTime: TimeInterval = 0

        for phase in remainingPhases {
            if let baseline = phaseBaselines[phase] {
                // 使用预估的总文件数计算各阶段时间
                let estimatedFiles = max(phaseTotalWork, 1000)  // 至少按1000个文件估算
                let scaledTime = baseline * (Double(estimatedFiles) / 1000.0)
                totalRemainingTime += scaledTime
            }
        }

        return totalRemainingTime
    }

    /// 计算阶段感知置信度
    private func calculatePhaseAwareConfidence(currentPhaseProgress: Double, totalElapsed: TimeInterval) -> ETAConfidence {
        // 基于当前阶段进度和总耗时判断
        if currentPhaseProgress > 0.8 {
            return .veryHigh  // 当前阶段接近完成
        } else if currentPhaseProgress > 0.3 && totalElapsed > 30 {
            return .high      // 当前阶段有实质进展且有充足观察时间
        } else if currentPhaseProgress > 0.1 && totalElapsed > 10 {
            return .medium    // 有一定进展
        } else {
            return .low       // 刚开始
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

// MARK: - 扫描灵敏度

/// 扫描灵敏度等级（用户可在扫描前选择）
/// 汉明距离：0 = 完全相同，64 = 完全不同
enum ScanSensitivity: String, CaseIterable, Identifiable {
    case conservative = "保守"
    case standard = "标准"
    case aggressive = "激进"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .conservative: return "减少误判，适合珍贵照片库"
        case .standard: return "平衡准确率与召回率"
        case .aggressive: return "找出更多相似照片，可能包含略有不同的版本"
        }
    }

    var icon: String {
        switch self {
        case .conservative: return "shield.checkered"
        case .standard: return "slider.horizontal.3"
        case .aggressive: return "bolt.fill"
        }
    }
}

// MARK: - 扫描器配置

/// 集中管理所有相似度阈值，避免散落在代码各处导致不一致
/// 汉明距离：0 = 完全相同，64 = 完全相反
enum ScannerConfig {
    /// 当前扫描灵敏度（由用户在 WelcomeView 选择，扫描前设置）
    static var sensitivity: ScanSensitivity = .standard

    /// 组内扩展阈值（Live Photo 组内寻找其他相似照片）
    /// 较宽松：同一 Live Photo 可能有轻微剪裁/亮度调整的版本
    static var intraGroupSimilarityThreshold: Int {
        switch sensitivity {
        case .conservative: return 8
        case .standard:     return 15
        case .aggressive:   return 22
        }
    }

    /// 跨组合并阈值（不同 Live Photo 组之间合并）
    /// 中等：防止不同场景的照片被误合并，但允许轻微相似
    static var crossGroupSimilarityThreshold: Int {
        switch sensitivity {
        case .conservative: return 5
        case .standard:     return 10
        case .aggressive:   return 16
        }
    }

    /// 单文件相似度阈值（非 Live Photo 的普通照片去重）
    /// 较严格：单文件误删风险更高，要求更高相似度才认为是重复
    static var singleFileSimilarityThreshold: Int {
        switch sensitivity {
        case .conservative: return 4
        case .standard:     return 8
        case .aggressive:   return 12
        }
    }

    /// 哈希桶跨桶检查的最大桶数限制
    /// 桶数超过此值时改为随机抽样，避免 O(桶数²) 性能退化
    static let maxBucketsForCrossBucketCheck = 1000

    /// 单个哈希桶的最大组数，超过时分批处理避免 UI 卡顿
    static let maxGroupsPerBucketBeforeBatching = 50
}

extension FileAction {
    var reasonText: String {
        switch self {
        case .keepAsIs(let reason):
            return reason
        case .delete(let reason):
            return reason
        case .move(let target, let reason):
            return "\(reason) → \(target.path)"
        case .userKeep:
            return "Forced Keep by User"
        case .userDelete:
            return "Forced Deletion by User"
        }
    }
}

// MARK: - 扫描模式

enum ScanMode: Equatable {
    /// 精确去重：仅 SHA256，基于 EXIF 质量评分保留最佳副本，安全可自动执行
    case exactDeduplication
    /// 相似清理：仅 pHash 感知哈希，需用户手动审阅后决定删除
    case similarPhotos
}

// MARK: - 配对结果（Stage 2 输出）

struct PairingResult {
    var completePairs: [LivePhotoSeedGroup]   // 同目录完整对（HEIC + MOV 在同一文件夹且同名）
    var orphanHEICs: [URL]                    // 有 HEIC 但同目录无对应 MOV
    var orphanMOVs: [URL]                     // 有 MOV 但同目录无对应 HEIC
}

// MARK: - EXIF 质量评分（改进版）

struct LivePhotoQualityScore {
    let heicURL: URL
    let movURL: URL?
    let isSameDirPair: Bool        // MOV 是否在同一目录（true = 无需修复链接）
    let totalFileSize: Int64       // HEIC + MOV 总字节数
    let hasGPS: Bool
    let hasCameraModel: Bool
    let hasLensInfo: Bool
    let exifFieldCount: Int        // EXIF 字段数量（越多越完整）
    let dateAuthScore: Double      // 日期真实性分（EXIF日期≈文件创建日期说明未被重处理）

    /// 综合质量分数（越高越好，用于比较同一 Live Photo 的不同副本）
    var totalScore: Double {
        var s = 0.0
        // EXIF 完整性
        if hasGPS         { s += 50 }
        if hasCameraModel { s += 30 }
        if hasLensInfo    { s += 20 }
        s += Double(min(exifFieldCount, 40)) * 1.5  // 最多 60 分
        // 文件大小（质量代理）
        s += Double(totalFileSize) / (1024 * 1024)  // 每 MB 加 1 分
        // 日期真实性
        s += dateAuthScore
        // 配对质量
        if movURL != nil {
            s += isSameDirPair ? 200 : 100  // 同目录配对 > 跨目录配对
        }
        return s
    }
}

/// 日期真实性评分：EXIF DateTimeOriginal ≈ 文件创建时间 → 文件未被备份软件重新处理
func dateAuthenticityScore(heicURL: URL) -> Double {
    guard let source = CGImageSourceCreateWithURL(heicURL as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
          let dateStr = exif["DateTimeOriginal"] as? String
    else { return 0 }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    guard let exifDate = formatter.date(from: dateStr) else { return 0 }

    guard let fileDate = try? heicURL.resourceValues(forKeys: [.creationDateKey]).creationDate
    else { return 0 }

    let diffHours = abs(exifDate.timeIntervalSince(fileDate)) / 3600
    if diffHours < 24  { return 40 }   // < 1天：高可信度
    if diffHours < 168 { return 20 }   // < 7天：中可信度
    return 0                            // > 7天：被重新处理过
}

/// 计算 HEIC 的完整质量评分
func computeQualityScore(heicURL: URL, movURL: URL?) -> LivePhotoQualityScore {
    var hasGPS = false, hasCameraModel = false, hasLensInfo = false
    var exifFieldCount = 0

    if let source = CGImageSourceCreateWithURL(heicURL as CFURL, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let gps  = props[kCGImagePropertyGPSDictionary  as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        hasGPS = !gps.isEmpty
        hasCameraModel = tiff["Model"] != nil
        hasLensInfo = exif["LensModel"] != nil || exif["LensSpecification"] != nil
        exifFieldCount = exif.count
    }

    let heicDir  = heicURL.deletingLastPathComponent()
    let heicBase = heicURL.deletingPathExtension().lastPathComponent
    let isSameDirPair: Bool
    if let mov = movURL {
        let movDir  = mov.deletingLastPathComponent()
        let movBase = mov.deletingPathExtension().lastPathComponent
        isSameDirPair = (heicDir == movDir) && (heicBase == movBase)
    } else {
        isSameDirPair = false
    }

    let heicSize = getFileSize(heicURL)
    let movSize  = movURL.map { getFileSize($0) } ?? 0

    return LivePhotoQualityScore(
        heicURL: heicURL,
        movURL: movURL,
        isSameDirPair: isSameDirPair,
        totalFileSize: heicSize + movSize,
        hasGPS: hasGPS,
        hasCameraModel: hasCameraModel,
        hasLensInfo: hasLensInfo,
        exifFieldCount: exifFieldCount,
        dateAuthScore: dateAuthenticityScore(heicURL: heicURL)
    )
}

// MARK: - Live Photo Content Identifier

/// 从 HEIC 文件读取 Apple Live Photo Content Identifier（Maker Note key "17"）
func readHEICContentIdentifier(_ url: URL) -> String? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let makerApple = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
    else { return nil }
    return makerApple["17"] as? String
}

/// 从 MOV 文件读取 Apple Live Photo Content Identifier（QuickTime metadata）
func readMOVContentIdentifier(_ url: URL) async -> String? {
    let asset = AVURLAsset(url: url)
    guard let metadata = try? await asset.load(.metadata) else { return nil }
    for item in metadata {
        guard let identifier = item.identifier else { continue }
        if identifier.rawValue.contains("com.apple.quicktime.content.identifier") {
            return try? await item.load(.stringValue)
        }
    }
    return nil
}