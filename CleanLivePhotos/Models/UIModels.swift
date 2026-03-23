import Foundation

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

// A typealias for a list of metadata items, making the data model flexible.
typealias FileMetadata = [(label: String, value: String, icon: String)]

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
