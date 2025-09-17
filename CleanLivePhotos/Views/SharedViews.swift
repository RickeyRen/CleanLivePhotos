import SwiftUI
#if os(macOS)
import AppKit
#endif

struct FooterView: View {
    let groups: [FileGroup]
    let scannedPath: String?
    var onDelete: () -> Void
    var onGoHome: () -> Void

    private var filesToDelete: [DisplayFile] {
        groups.flatMap { $0.files }.filter { if case .delete = $0.action { return true } else { return false } }
    }
    
    
    private var totalSizeToDelete: Int64 {
        filesToDelete.reduce(0) { $0 + $1.size }
    }
    
    var body: some View {
        let hasActions = !filesToDelete.isEmpty
        
        VStack(spacing: 12) {
            Divider()
                .padding(.bottom, 8)

            if hasActions {
                ZStack {
                    VStack(spacing: 8) {
                        if !filesToDelete.isEmpty {
                            Text("Will delete \(filesToDelete.count) file(s), reclaiming \(ByteCountFormatter.string(fromByteCount: totalSizeToDelete, countStyle: .file)).")
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    
                    HStack {
                        Spacer()
                        Button(action: copySummaryToClipboard) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text("复制调试信息")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(6)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("复制详细的扫描结果和调试信息到剪贴板")
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("No redundant files found to clean.")
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 15) {
                Button(action: onGoHome) {
                    HStack {
                        Image(systemName: "house.fill")
                        Text("Start Over")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.4))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .shadow(radius: 5)
                }
                .buttonStyle(PlainButtonStyle())

                if hasActions {
                    Button(action: onDelete) {
                        HStack {
                            Image(systemName: "wrench.and.screwdriver.fill")
                            Text("Execute Plan")
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.green.opacity(0.9))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .shadow(radius: 5)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.top, 8)
        }
        .padding()
        .animation(.easeInOut, value: hasActions)
    }
    
    private func copySummaryToClipboard() {
        let summary = generateSummaryText()
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
        #endif
    }

    private func generateSummaryText() -> String {
        var summary = "Live Photos Cleaner - 调试报告\n"
        summary += "================================\n\n"

        // 添加调试信息头部
        summary += "## 扫描信息 ##\n"
        if let path = scannedPath {
            summary += "扫描路径: \(path)\n"
        }
        summary += "扫描时间: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))\n"
        summary += "总文件组数: \(groups.count)\n"
        let totalFiles = groups.flatMap { $0.files }.count
        summary += "总文件数: \(totalFiles)\n"
        let totalSize = groups.flatMap { $0.files }.reduce(0) { $0 + $1.size }
        summary += "总文件大小: \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))\n\n"

        let categoryOrder: [String: Int] = [
            "Content Duplicates": 1,
            "Live Photo Duplicates": 2,
            "Perfectly Paired & Ignored": 3
        ]

        func getCategoryPrefix(for groupName: String) -> String {
            // Live Photo Duplicates should be treated as separate category
            if groupName.starts(with: "Live Photo Duplicates:") {
                return "Live Photo Duplicates"
            }

            for prefix in categoryOrder.keys where groupName.starts(with: prefix) {
                return prefix
            }
            return "Other"
        }

        let groupedByCat = Dictionary(grouping: self.groups, by: { getCategoryPrefix(for: $0.groupName) })
        
        let sortedCategories = groupedByCat.keys.sorted {
            let order1 = categoryOrder[$0] ?? 99
            let order2 = categoryOrder[$1] ?? 99
            return order1 < order2
        }

        for categoryName in sortedCategories {
            guard let groupsInCat = groupedByCat[categoryName],
                  !groupsInCat.isEmpty,
                  !categoryName.starts(with: "Perfectly Paired") else { continue }
            
            summary += "## \(categoryName) (\(groupsInCat.count) groups) ##\n\n"

            for group in groupsInCat.sorted(by: { $0.groupName < $1.groupName }) {
                if group.groupName.starts(with: "Content Duplicates: ") {
                    let hash = group.groupName.replacingOccurrences(of: "Content Duplicates: ", with: "")
                    summary += "Group: Content Duplicates (Hash: \(hash))\n"
                } else if group.groupName.starts(with: "Live Photo Duplicates: ") {
                    let baseName = group.groupName.replacingOccurrences(of: "Live Photo Duplicates: ", with: "")
                    summary += "Group: Live Photo Duplicates (Name: \(baseName))\n"
                } else {
                    summary += "Group: \(group.groupName)\n"
                }
                
                for file in group.files {
                    summary += "- \(file.url.lastPathComponent) -> [\(file.action.reasonText)]"
                    if !file.action.isKeep {
                        summary += " (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)))"
                    }
                    summary += "\n"
                }
                summary += "\n"
            }
        }

        // Final summary of actions
        let filesToDelete = self.filesToDelete

        summary += "-----------------------------\n"
        summary += "## 总体执行计划 ##\n"
        if filesToDelete.isEmpty {
            summary += "✅ 没有发现需要清理的冗余文件！您的媒体库很干净。\n"
        } else {
            let totalSize = filesToDelete.reduce(0) { $0 + $1.size }
            summary += "🗑️ 计划删除 \(filesToDelete.count) 个文件，回收空间: \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))\n"
            summary += "💾 回收空间占总大小比例: \(String(format: "%.1f", Double(totalSize) / Double(totalSize + groups.flatMap { $0.files }.filter { $0.action.isKeep }.reduce(0) { $0 + $1.size }) * 100))%\n"
        }

        // 添加分类统计
        summary += "\n## 详细统计 ##\n"
        for (category, categoryGroups) in groupedByCat.sorted(by: { $0.key < $1.key }) {
            let categoryFiles = categoryGroups.flatMap { $0.files }
            let deletedFiles = categoryFiles.filter { !$0.action.isKeep }
            let deletedSize = deletedFiles.reduce(0) { $0 + $1.size }

            summary += "📁 \(category):\n"
            summary += "   - 文件组: \(categoryGroups.count)\n"
            summary += "   - 总文件: \(categoryFiles.count)\n"
            summary += "   - 删除文件: \(deletedFiles.count)\n"
            if deletedSize > 0 {
                summary += "   - 回收空间: \(ByteCountFormatter.string(fromByteCount: deletedSize, countStyle: .file))\n"
            }
            summary += "\n"
        }

        summary += "-----------------------------\n"
        summary += "报告生成于: CleanLivePhotos v1.0\n"

        return summary
    }
}

struct NoResultsView: View {
    var onStartOver: () -> Void
    
    @State private var isHovering = false

    var body: some View {
        Spacer()
        VStack(spacing: 20) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
            
            Text("All Clean!")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Text("Your folder is perfectly organized. No duplicates found.")
                .font(.title3)
                .foregroundColor(.secondary)
            
            Button(action: onStartOver) {
                HStack {
                    Image(systemName: "arrow.clockwise.circle.fill")
                    Text("Scan Another Folder")
                }
                .font(.headline)
                .padding(.horizontal, 25)
                .padding(.vertical, 15)
                .background(
                    Capsule()
                        .fill(isHovering ? Color.green.opacity(1.0) : Color.green.opacity(0.8))
                        .shadow(color: .green.opacity(0.4), radius: isHovering ? 15 : 8, x: 0, y: 5)
                )
                .foregroundColor(.white)
            }
            .buttonStyle(PlainButtonStyle())
            .onHover { hovering in
                withAnimation(.spring()) {
                    isHovering = hovering
                }
            }
            .padding(.top, 40)
        }
        Spacer()
    }
}

struct ErrorView: View {
    let message: String
    var onDismiss: () -> Void
    
    @State private var didCopy: Bool = false

    var body: some View {
        Spacer()
        VStack(spacing: 20) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 80))
                .foregroundColor(.red)
            
            Text("An Error Occurred")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            // Use a TextEditor for scrollable, selectable text
            TextEditor(text: .constant(message))
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color.black.opacity(0.2))
                .cornerRadius(8)
                .frame(minHeight: 100, maxHeight: 300)
                .shadow(radius: 5)
            
            HStack(spacing: 15) {
                Button(action: {
                    #if os(macOS)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(message, forType: .string)
                    #endif
                    withAnimation {
                        didCopy = true
                    }
                    // Reset the text after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            didCopy = false
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        Text(didCopy ? "Copied!" : "Copy Details")
                    }
                    .padding()
                    .frame(height: 44)
                    .background(Color.blue.opacity(0.8))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: onDismiss) {
                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Start Over")
                    }
                    .padding()
                    .frame(height: 44)
                    .background(Color.green.opacity(0.8))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(40)
        Spacer()
    }
}

// MARK: - Reusable UI Components

struct CloseButton: View {
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.headline)
                .padding(12)
                .background(.regularMaterial)
                .foregroundColor(.primary)
                .clipShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .padding()
        .transition(.opacity.animation(.easeInOut))
    }
}

// MARK: - Window Configuration Helper
#if os(macOS)
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif 