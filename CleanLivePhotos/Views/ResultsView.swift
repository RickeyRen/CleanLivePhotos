import SwiftUI
import UniformTypeIdentifiers

struct ResultsView: View {
    let items: [ResultDisplayItem]
    @Binding var selectedFile: DisplayFile?
    let onUpdateUserAction: (DisplayFile) -> Void
    let onToggleCategory: (String) -> Void
    let onLoadMoreInCategory: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    switch item {
                    case .categoryHeader(let id, let title, let groupCount, let size, let isExpanded):
                        CategoryHeaderView(
                            title: title,
                            count: groupCount,
                            totalSizeToDelete: size,
                            isExpanded: .constant(isExpanded)
                        )
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                onToggleCategory(id)
                            }
                        }
                        .padding(.top, 20)

                    case .fileGroup(let group):
                        FileGroupCard(
                            group: group,
                            selectedFile: $selectedFile,
                            onUpdateUserAction: onUpdateUserAction
                        )

                    case .loadMore(let categoryId):
                        HStack {
                            Spacer()
                            ProgressView("Loading More...")
                            Spacer()
                        }
                        .padding()
                        .onAppear {
                            onLoadMoreInCategory(categoryId)
                        }
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 600)
    }
}

struct CategoryHeaderView: View {
    let title: String
    let count: Int
    let totalSizeToDelete: Int64
    @Binding var isExpanded: Bool

    var body: some View {
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
        .contentShape(Rectangle())
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

    private var rows: [ResultRow] {
        generateRows(from: group.files)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupTitleView(groupName: group.groupName)
                .padding([.horizontal, .top])
                .padding(.bottom, 12)

            if !group.groupName.starts(with: "Perfectly Paired") {
                 Divider().background(Color.primary.opacity(0.2)).padding(.horizontal)
            }

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { item in
                    switch item {
                    case .single(let file):
                        FileRowView(
                            file: file,
                            isSelected: file.id == selectedFile?.id,
                            onSelect: { self.selectedFile = file },
                            onUpdateUserAction: onUpdateUserAction
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    
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
                        .padding(.vertical, 6)
                    }
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
    
    /// Pre-processes a list of files into a list of display-ready rows.
    private func generateRows(from files: [DisplayFile]) -> [ResultRow] {
        var items: [ResultRow] = []
        // Sort by name first to get a consistent order.
        var remainingFiles = files.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }

        while !remainingFiles.isEmpty {
            let file1 = remainingFiles.removeFirst()

            // Try to find a Live Photo pair for the current file.
            if let pairIndex = remainingFiles.firstIndex(where: { file2 in
                // A valid pair must have one .mov and one image, and the base names must match.
                let f1IsMov = file1.url.pathExtension.lowercased() == "mov"
                let f2IsMov = file2.url.pathExtension.lowercased() == "mov"
                
                // Use UTType for robust type checking.
                let f1IsImage = UTType(filenameExtension: file1.url.pathExtension)?.conforms(to: .image) ?? false
                let f2IsImage = UTType(filenameExtension: file2.url.pathExtension)?.conforms(to: .image) ?? false

                let baseName1 = file1.url.deletingPathExtension().lastPathComponent
                let baseName2 = file2.url.deletingPathExtension().lastPathComponent

                return (f1IsMov && f2IsImage || f1IsImage && f2IsMov) && baseName1 == baseName2
            }) {
                let file2 = remainingFiles.remove(at: pairIndex)
                
                // Re-declare variables here, as they are out of scope from the closure above.
                let f1IsMov = file1.url.pathExtension.lowercased() == "mov"
                
                // Ensure correct assignment to mov and heic/image files.
                let movFile = f1IsMov ? file1 : file2
                let heicFile = f1IsMov ? file2 : file1
                items.append(.pair(mov: movFile, heic: heicFile))
            } else {
                items.append(.single(file1))
            }
        }
        return items
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
        .contextMenu {
            Button {
                openFileInFinder(file.url)
            } label: {
                Label("在Finder中显示", systemImage: "folder")
            }

            Button {
                copyFilePathToClipboard(file.url)
            } label: {
                Label("复制文件路径", systemImage: "doc.on.doc")
            }

            Divider()

            Button {
                previewFile(file.url)
            } label: {
                Label("快速预览", systemImage: "eye")
            }
        }
        .help("Click the icon to change action. Click text to preview. Right-click for more options.")
    }

    private func openFileInFinder(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    private func copyFilePathToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    private func previewFile(_ url: URL) {
        NSWorkspace.shared.open(url)
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