import SwiftUI
import UniformTypeIdentifiers

struct ResultsView: View {
    let groups: [FileGroup]
    @Binding var selectedFile: DisplayFile?
    let hasMoreResults: Bool
    let onLoadMore: () -> Void
    @Binding var expandedCategories: [String: Bool]
    let onUpdateUserAction: (DisplayFile) -> Void
    
    private struct CategorizedGroups: Identifiable {
        let id: String
        let categoryName: String
        let groups: [FileGroup]
    }

    private var categorizedResults: [CategorizedGroups] {
        let categoryOrder: [String: Int] = [
            "Content Duplicates": 1,
            "Live Photo Pair to Repair": 2,
            "Redundant Versions to Delete": 3,
            "Perfectly Paired & Ignored": 4
        ]
        
        func getCategoryPrefix(for groupName: String) -> String {
            for prefix in categoryOrder.keys where groupName.starts(with: prefix) {
                return prefix
            }
            return "Other" // Fallback, should not be reached with current logic
        }

        let groupedByCat = Dictionary(grouping: groups, by: { getCategoryPrefix(for: $0.groupName) })
        
        return groupedByCat.map { categoryName, groupsInCat in
            CategorizedGroups(id: categoryName, categoryName: categoryName, groups: groupsInCat)
        }.sorted {
            let order1 = categoryOrder[$0.categoryName] ?? 99
            let order2 = categoryOrder[$1.categoryName] ?? 99
            return order1 < order2
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 35) {
                ForEach(categorizedResults) { category in
                    VStack(alignment: .leading, spacing: 15) {
                        let totalSizeToDelete = category.groups.flatMap { $0.files }
                            .filter { !$0.action.isKeep }
                            .reduce(0) { $0 + $1.size }

                        CategoryHeaderView(
                            title: category.categoryName,
                            count: category.groups.count,
                            totalSizeToDelete: totalSizeToDelete,
                            isExpanded: Binding(
                                get: { expandedCategories[category.categoryName, default: true] },
                                set: { expandedCategories[category.categoryName] = $0 }
                            )
                        )
                        if expandedCategories[category.categoryName, default: true] {
                            ForEach(category.groups) { group in
                                FileGroupCard(
                                    group: group,
                                    selectedFile: $selectedFile,
                                    onUpdateUserAction: onUpdateUserAction
                                )
                            }
                        }
                    }
                }
                
                if hasMoreResults {
                    ProgressView("Loading More...")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .onAppear(perform: onLoadMore)
                }
            }
            .padding()
        }
        .frame(minWidth: 600)
    }
    
    private func getCategoryPrefix(for groupName: String) -> String {
        let categoryOrder: [String: Int] = [
            "Content Duplicates": 1,
            "Live Photo Pair to Repair": 2,
            "Redundant Versions to Delete": 3,
            "Perfectly Paired & Ignored": 4
        ]
        for prefix in categoryOrder.keys where groupName.starts(with: prefix) {
            return prefix
        }
        return "Other"
    }
}

struct CategoryHeaderView: View {
    let title: String
    let count: Int
    let totalSizeToDelete: Int64
    @Binding var isExpanded: Bool

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("(\(count) Groups)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)

                if totalSizeToDelete > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: totalSizeToDelete, countStyle: .file))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.25))
                        .foregroundColor(Color.red)
                        .cornerRadius(7)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.red.opacity(0.5), lineWidth: 1)
                        )
                }
                
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

fileprivate enum RowItem: Identifiable {
    case single(DisplayFile)
    case pair(DisplayFile, DisplayFile)

    var id: UUID {
        switch self {
        case .single(let file):
            return file.id
        case .pair(let file1, _):
            return file1.id
        }
    }
}

struct FileGroupCard: View {
    let group: FileGroup
    @Binding var selectedFile: DisplayFile?
    let onUpdateUserAction: (DisplayFile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupTitleView(groupName: group.groupName)
                .padding([.horizontal, .top])

            if !group.groupName.starts(with: "Perfectly Paired") {
                 Divider().background(Color.primary.opacity(0.2)).padding(.horizontal)
            }

            ForEach(group.rows) { item in
                switch item {
                case .single(let file):
                    FileRowView(
                        file: file,
                        isSelected: file.id == selectedFile?.id,
                        onSelect: { self.selectedFile = file },
                        onUpdateUserAction: onUpdateUserAction
                    )
                    .padding(.horizontal)
                
                case .pair(let movFile, let heicFile):
                    VStack(spacing: 0) {
                        FileRowView(
                            file: movFile,
                            isSelected: movFile.id == selectedFile?.id,
                            onSelect: { self.selectedFile = movFile },
                            onUpdateUserAction: onUpdateUserAction
                        )
                        .padding(.vertical, 4)
                        
                        FileRowView(
                            file: heicFile,
                            isSelected: heicFile.id == selectedFile?.id,
                            onSelect: { self.selectedFile = heicFile },
                            onUpdateUserAction: onUpdateUserAction
                        )
                        .padding(.vertical, 4)
                    }
                    .padding(8)
                    .background(
                        ZStack {
                            Color.blue.opacity(0.1)
                            LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.2), Color.blue.opacity(0.0)]), startPoint: .top, endPoint: .bottom)
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.blue.opacity(0.5), lineWidth: 1)
                    )
                    .cornerRadius(16)
                    .padding(.horizontal)
                }
            }
        }
        .padding(.bottom)
        .background(Color.black.opacity(0.15))
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.2), lineWidth: 1)
        )
    }
}

struct GroupTitleView: View {
    let groupName: String

    var body: some View {
        if groupName.starts(with: "Content Duplicates: ") {
            let hash = groupName.replacingOccurrences(of: "Content Duplicates: ", with: "")
            VStack(alignment: .leading, spacing: 4) {
                Text("Content Duplicates")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Text(hash)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Text(groupName)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.primary)
        }
    }
}

struct FileRowView: View {
    let file: DisplayFile
    let isSelected: Bool
    let onSelect: () -> Void
    let onUpdateUserAction: (DisplayFile) -> Void
    
    private var reasonTagColor: Color {
        switch file.action {
        case .keepAsIs:
            return .green.opacity(0.7)
        case .keepAndRename:
            return .blue.opacity(0.7)
        case .delete(let reason):
            return reason.contains("Content") ? .orange.opacity(0.8) : .purple.opacity(0.8)
        case .userKeep:
            return .cyan.opacity(0.9)
        case .userDelete:
            return .pink.opacity(0.9)
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            
            ActionToggleButton(action: file.action) {
                onUpdateUserAction(file)
            }
            
            VStack(alignment: .leading) {
                Text(file.fileName)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(file.action.reasonText)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(reasonTagColor)
                .foregroundColor(.white)
                .cornerRadius(8)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(
            (isSelected ? Color.blue.opacity(0.4) : Color.clear)
                .cornerRadius(8)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help("Click the icon to change action. Click text to preview.")
    }
}

/// A custom button style that gives a "squishy" feedback when pressed.
struct SquishableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct ActionToggleButton: View {
    let action: FileAction
    let onToggle: () -> Void
    @State private var isHovering = false

    private var systemName: String {
        switch action {
        case .keepAsIs, .keepAndRename, .userKeep:
            return "checkmark"
        case .delete, .userDelete:
            return "trash"
        }
    }

    private var color: Color {
        switch action {
        case .userKeep: return .cyan
        case .userDelete: return .pink
        case .keepAsIs, .keepAndRename: return .green
        case .delete: return .red
        }
    }

    private var isOverridable: Bool {
        if case .keepAndRename = action { return false }
        return true
    }
    
    var body: some View {
        if isOverridable {
            Button(action: onToggle) {
                ZStack {
                    // Glossy background gradient
                    Circle()
                        .fill(LinearGradient(
                            gradient: Gradient(colors: [color.opacity(0.9), color.opacity(0.5)]),
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                    
                    // Inner glow for depth
                    Circle()
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1.5)
                        .blur(radius: 2)

                    Image(systemName: systemName)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                }
                .frame(width: 30, height: 30)
                .shadow(color: action.isUserOverride ? color.opacity(0.6) : color.opacity(0.4), radius: isHovering ? 8 : 4, y: isHovering ? 3 : 1)
                .contentTransition(.symbolEffect(.replace.downUp))
                .scaleEffect(isHovering ? 1.18 : 1.0)
            }
            .buttonStyle(SquishableButtonStyle())
            .onHover { hovering in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    isHovering = hovering
                }
            }
        } else {
            // Non-interactive version for non-overridable actions like 'rename'
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        gradient: Gradient(colors: [Color.blue.opacity(0.9), Color.blue.opacity(0.5)]),
                        startPoint: .top,
                        endPoint: .bottom
                    ))

                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            }
            .frame(width: 30, height: 30)
            .shadow(color: .blue.opacity(0.4), radius: 4, y: 1)
        }
    }
} 