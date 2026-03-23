import Foundation

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

// MARK: - 扫描模式

enum ScanMode: Equatable {
    /// 精确去重：仅 SHA256，基于 EXIF 质量评分保留最佳副本，安全可自动执行
    case exactDeduplication
    /// 相似清理：仅 pHash 感知哈希，需用户手动审阅后决定删除
    case similarPhotos
}
