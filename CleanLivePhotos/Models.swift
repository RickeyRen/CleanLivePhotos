import Foundation
import CryptoKit

// MARK: - Global Models


func calculateHash(for fileURL: URL) -> String? {
    let chunkSize = 1024 * 1024 // 1MB
    do {
        let file = try FileHandle(forReadingFrom: fileURL)
        defer { file.closeFile() }

        let fileSize = try file.seekToEnd()
        
        var hasher = SHA256()

        // If file is small (<= 2MB), hash the whole thing for accuracy.
        if fileSize <= UInt64(chunkSize * 2) {
            try file.seek(toOffset: 0)
            while autoreleasepool(invoking: {
                let data = file.readData(ofLength: chunkSize)
                if !data.isEmpty {
                    hasher.update(data: data)
                    return true // Continue
                } else {
                    return false // End of file
                }
            }) {}
        } else {
            // For larger files, hash only the first and last 1MB.
            // This is a massive performance boost for large video files.
            
            // Hash the first 1MB chunk.
            try file.seek(toOffset: 0)
            let headData = file.readData(ofLength: chunkSize)
            hasher.update(data: headData)

            // Hash the last 1MB chunk.
            try file.seek(toOffset: fileSize - UInt64(chunkSize))
            let tailData = file.readData(ofLength: chunkSize)
            hasher.update(data: tailData)
        }
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    } catch {
        print("Error calculating partial hash for \(fileURL.path): \(error)")
        return nil
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
}

/// The different states the main view can be in.
enum ViewState {
    case welcome
    case scanning(progress: ScanningProgress, animationRate: Double)
    case results
    case error(String)
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