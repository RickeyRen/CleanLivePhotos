import SwiftUI
#if os(macOS)
import AppKit
import CryptoKit
import Quartz
import AVKit
#else
import CryptoKit
#endif

// MARK: - Global Helpers & Models

func calculateHash(for fileURL: URL) -> String? {
    let bufferSize = 1024 * 1024 // 1MB buffer
    do {
        let file = try FileHandle(forReadingFrom: fileURL)
        defer { file.closeFile() }
        
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = file.readData(ofLength: bufferSize)
            if !data.isEmpty {
                hasher.update(data: data)
                return true // Continue
            } else {
                return false // End of file
            }
        }) {}
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    } catch {
        print("Error calculating hash for \(fileURL.path): \(error)")
        return nil
    }
}

/// Represents a single photo file (image or video).
struct PhotoFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var size: Int64
    var isMarkedForDeletion = false

    var fileName: String {
        url.lastPathComponent
    }
}

/// Groups a set of related photo files (e.g., IMG_1234.HEIC, IMG_1234.MOV, IMG_1234 (1).HEIC).
struct PhotoGroup: Identifiable {
    let id = UUID()
    let baseName: String
    var files: [PhotoFile]
    
    var displayName: String {
        if baseName.starts(with: "HASH:") {
            if let firstFile = files.first(where: { !$0.isMarkedForDeletion }) {
                if let hash = calculateHash(for: firstFile.url) {
                     return "HASH GROUP: \(hash.prefix(12))... (\(firstFile.fileName))"
                }
            }
            return "HASH GROUP"
        }
        return baseName
    }
    
    var filesToDelete: [PhotoFile] {
        files.filter(\.isMarkedForDeletion)
    }
    
    var filesToKeep: [PhotoFile] {
        files.filter { !$0.isMarkedForDeletion }
    }
}

// MARK: - Core Data Models & Enums

/// Describes the action to be taken on a file and the reason why.
enum FileAction: Hashable {
    case keepAsIs(reason: String)
    case keepAndRename(reason: String, newBaseName: String)
    case delete(reason: String)

    var isKeep: Bool {
        switch self {
        case .keepAsIs, .keepAndRename:
            return true
        case .delete:
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
    let action: FileAction

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

/// The different states the main view can be in.
enum ViewState {
    case welcome
    case scanning(progress: Double, message: String)
    case results([FileGroup])
    case error(String)
}

// MARK: - Main Content View

struct ContentView: View {
    @State private var state: ViewState = .welcome
    @State private var currentScanTask: Task<Void, Error>?
    @State private var showAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var folderAccessManager = FolderAccessManager()
    @State private var selectedFile: DisplayFile?

    var body: some View {
        ZStack {
            AuroraBackground()
            
            VStack(spacing: 0) {
                HeaderView(
                    isScanning: Binding(
                        get: {
                            if case .scanning = state { return true }
                            return false
                        },
                        set: { _ in }
                    ),
                    onScan: { handleScanRequest() },
                    onCancel: {
                        currentScanTask?.cancel()
                        state = .welcome
                    }
                )
                
                contentView
                    .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                
                if case .results(let groups) = state, !groups.isEmpty {
                    FooterView(
                        groups: groups,
                        onDelete: {
                            executeCleaningPlan(for: groups)
                        }
                    )
                }
            }
        }
        .frame(minWidth: 1200, minHeight: 700)
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch state {
        case .welcome:
            WelcomeView()
        case .scanning(let progress, let message):
            ScanningView(progress: progress, message: message)
        case .results(let groups):
            if groups.isEmpty {
                NoResultsView()
            } else {
                HStack(spacing: 0) {
                    ResultsView(
                        groups: groups,
                        selectedFile: $selectedFile
                    )
                    
                    Divider()
                    
                    PreviewPane(file: selectedFile)
                        .frame(maxWidth: .infinity)
                }
            }
        case .error(let errorMessage):
            ErrorView(message: errorMessage)
        }
    }
    
    private func handleScanRequest() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            currentScanTask = Task {
                if await folderAccessManager.requestAccess(to: url) {
                    await perfectScan(in: url)
                } else {
                    await MainActor.run {
                        self.state = .error("Failed to gain permission to access the folder.")
                    }
                }
            }
        }
    }
    
    private func executeCleaningPlan(for groups: [FileGroup]) {
        Task {
            // Start accessing the security-scoped resource.
            guard await folderAccessManager.startAccessing() else {
                await MainActor.run {
                    self.alertTitle = "Permission Error"
                    self.alertMessage = "Could not access the folder to execute the plan. Please try scanning the folder again."
                    self.showAlert = true
                }
                return
            }
            // Defer stopping access to ensure it's called even if errors occur.
            defer { folderAccessManager.stopAccessing() }

            let allFiles = groups.flatMap { $0.files }
            
            // --- Step 1: Perform Deletions ---
            var deletionSuccessCount = 0
            var deletionFailCount = 0
            let filesToDelete = allFiles.filter { if case .delete = $0.action { return true } else { return false } }
            
            for file in filesToDelete {
                do {
                    try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                    deletionSuccessCount += 1
                } catch {
                    deletionFailCount += 1
                    print("Failed to trash file at \(file.url.path): \(error.localizedDescription)")
                }
            }
            
            // --- Step 2: Perform Renames ---
            var renameSuccessCount = 0
            var renameFailCount = 0
            let filesToRename = allFiles.filter { if case .keepAndRename = $0.action { return true } else { return false } }

            for file in filesToRename {
                if case .keepAndRename(_, let newBaseName) = file.action {
                    let newFileName = newBaseName + "." + file.url.pathExtension
                    let destinationURL = file.url.deletingLastPathComponent().appendingPathComponent(newFileName)
                    
                    // Check if a file with the destination name already exists (e.g. from a failed deletion)
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        print("Skipping rename for \(file.fileName) because destination \(newFileName) already exists.")
                        renameFailCount += 1
                        continue
                    }
                    
                    do {
                        try FileManager.default.moveItem(at: file.url, to: destinationURL)
                        renameSuccessCount += 1
                    } catch {
                        renameFailCount += 1
                        print("Failed to rename file from \(file.url.path) to \(destinationURL.path): \(error.localizedDescription)")
                    }
                }
            }

            await MainActor.run {
                self.alertTitle = "Execution Complete"
                var message = ""
                message += "\(deletionSuccessCount) file(s) moved to Trash."
                if deletionFailCount > 0 { message += " (\(deletionFailCount) failed)" }
                
                message += "\n\(renameSuccessCount) file(s) successfully renamed."
                if renameFailCount > 0 { message += " (\(renameFailCount) failed)" }
                
                self.alertMessage = message
                self.showAlert = true

                // Reset the view to welcome screen as the file state has changed significantly
                self.state = .welcome
            }
        }
    }
    
    // MARK: - Scanning Logic (Perfect Scan)
    
    @MainActor
    private func updateScanState(message: String, progress: Double) {
        self.state = .scanning(progress: progress, message: message)
    }
    
    @MainActor
    private func finalizeScan(with groups: [FileGroup], feedback: String) {
        if Task.isCancelled {
            self.state = .welcome
        } else {
            self.state = .results(groups)
        }
    }

    private func perfectScan(in directory: URL) async {
        await updateScanState(message: "Discovering files...", progress: 0.0)

        // --- STAGE 0: File Discovery ---
        let allFileURLs = discoverFiles(in: directory)
        if allFileURLs.isEmpty {
            await finalizeScan(with: [], feedback: "No supported files found.")
            return
        }
        
        if Task.isCancelled { await finalizeScan(with: [], feedback: "Scan cancelled."); return }

        // --- STAGE 1: Global Hashing for Exact Duplicates ---
        let (hashBasedGroups, survivors) = await processHashing(for: allFileURLs, totalFiles: allFileURLs.count)
        if Task.isCancelled { await finalizeScan(with: [], feedback: "Scan cancelled."); return }
        
        // --- STAGE 2: Global Intelligent Association ---
        await updateScanState(message: "Associating all related files...", progress: 0.7)
        let associatedGroupsByName = associateSurvivors(from: survivors)

        // --- STAGE 3: Final Judgement within Each Group ---
        await updateScanState(message: "Making final decisions...", progress: 0.9)
        var nameBasedGroups: [FileGroup] = []
        for (baseName, files) in associatedGroupsByName {
            if Task.isCancelled { await finalizeScan(with: [], feedback: "Scan cancelled."); return }
            
            var displayFiles: [DisplayFile] = []
            
            let images = files.filter { $0.url.pathExtension.lowercased() != "mov" }
            let videos = files.filter { $0.url.pathExtension.lowercased() == "mov" }

            processFinalCategory(files: images, baseReason: "Image", videoKeeper: videos.max(by: { $0.size < $1.size }), &displayFiles)
            processFinalCategory(files: videos, baseReason: "Video", videoKeeper: videos.max(by: { $0.size < $1.size }), &displayFiles)
            
            if displayFiles.contains(where: { !$0.action.isKeep }) {
                nameBasedGroups.append(FileGroup(groupName: baseName, files: displayFiles.sorted(by: { $0.fileName < $1.fileName })))
            }
        }
        
        let finalGroups = (hashBasedGroups + nameBasedGroups).sorted(by: { $0.groupName < $1.groupName })
        await finalizeScan(with: finalGroups, feedback: "Scan complete.")
    }
    
    private func discoverFiles(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        let allowedExtensions = ["heic", "jpg", "jpeg", "mov"]
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) else {
            return []
        }
        return enumerator.allObjects.compactMap { $0 as? URL }.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
    }
    
    private func processHashing(for fileURLs: [URL], totalFiles: Int) async -> (groups: [FileGroup], survivors: [(url: URL, size: Int64)]) {
        var filesByHash = [String: [(url: URL, size: Int64)]]()
        var processedCount = 0

        for fileURL in fileURLs {
            if Task.isCancelled { return ([], []) }
            processedCount += 1
            await updateScanState(message: "Hashing files... (\(processedCount)/\(totalFiles))", progress: Double(processedCount) / Double(totalFiles) * 0.5)

            guard let hash = calculateHash(for: fileURL) else { continue }
            do {
                let resources = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                filesByHash[hash, default: []].append((url: fileURL, size: Int64(resources.fileSize ?? 0)))
            } catch {
                print("Error getting file size for \(fileURL.path): \(error)")
            }
        }

        var hashBasedGroups: [FileGroup] = []
        var survivors: [(url: URL, size: Int64)] = []

        for (_, files) in filesByHash {
            if Task.isCancelled { return ([], []) }
            if files.count > 1 {
                let sortedFiles = files.sorted { $0.url.lastPathComponent.count < $1.url.lastPathComponent.count }
                guard let keeper = sortedFiles.first else { continue }
                survivors.append(keeper)
                
                var displayFiles: [DisplayFile] = [DisplayFile(url: keeper.url, size: keeper.size, action: .keepAsIs(reason: "Best Named Duplicate"))]
                for fileToDiscard in sortedFiles.dropFirst() {
                    displayFiles.append(DisplayFile(url: fileToDiscard.url, size: fileToDiscard.size, action: .delete(reason: "Content Identical")))
                }
                
                let groupName = "HASH: \(keeper.url.deletingPathExtension().lastPathComponent)"
                hashBasedGroups.append(FileGroup(groupName: groupName, files: displayFiles))
            } else if let firstFile = files.first {
                survivors.append(firstFile)
            }
        }
        return (hashBasedGroups, survivors)
    }
    
    private func associateSurvivors(from survivors: [(url: URL, size: Int64)]) -> [String: [(url: URL, size: Int64)]] {
        var associatedGroups = [String: [(url: URL, size: Int64)]]()
        for file in survivors {
            let baseName = file.url.deletingPathExtension().lastPathComponent
            let cleanBaseName = baseName.replacingOccurrences(of: "(?:[ _-](?:copy|\\d+)| \\(\\d+\\)|_v\\d+)$", with: "", options: [.regularExpression, .caseInsensitive])
            associatedGroups[cleanBaseName, default: []].append(file)
        }
        return associatedGroups
    }

    private func processFinalCategory(files: [(url: URL, size: Int64)], baseReason: String, videoKeeper: (url: URL, size: Int64)?, _ displayFiles: inout [DisplayFile]) {
        guard !files.isEmpty else { return }
        
        let keeper = files.max { $0.size < $1.size }
        
        for file in files {
            if file.url == keeper?.url {
                // This is the keeper of its category (image or video)
                if baseReason == "Video" {
                    // The video keeper's name is always the canonical one, so it's never renamed.
                     displayFiles.append(DisplayFile(url: file.url, size: file.size, action: .keepAsIs(reason: "Largest Video")))
                } else {
                    // This is an image keeper. Check if it needs renaming to match the video keeper.
                    if let videoKeeper = videoKeeper {
                        let videoBaseName = videoKeeper.url.deletingPathExtension().lastPathComponent
                        let imageBaseName = file.url.deletingPathExtension().lastPathComponent
                        if imageBaseName != videoBaseName {
                            displayFiles.append(DisplayFile(url: file.url, size: file.size, action: .keepAndRename(reason: "Largest Image", newBaseName: videoBaseName)))
                        } else {
                            displayFiles.append(DisplayFile(url: file.url, size: file.size, action: .keepAsIs(reason: "Largest Image")))
                        }
                    } else {
                        // No video keeper in the group, so the image keeper defines the name. No rename needed.
                        displayFiles.append(DisplayFile(url: file.url, size: file.size, action: .keepAsIs(reason: "Largest Image")))
                    }
                }
            } else {
                // This is not the keeper, so mark for deletion.
                displayFiles.append(DisplayFile(url: file.url, size: file.size, action: .delete(reason: "Smaller/Duplicate \(baseReason)")))
            }
        }
    }
    
    private func calculateHash(for fileURL: URL) -> String? {
        let bufferSize = 1024 * 1024
        do {
            let file = try FileHandle(forReadingFrom: fileURL)
            defer { file.closeFile() }
            
            var hasher = SHA256()
            while autoreleasepool(invoking: {
                let data = file.readData(ofLength: bufferSize)
                if !data.isEmpty {
                    hasher.update(data: data)
                    return true
                } else {
                    return false
                }
            }) {}
            
            let digest = hasher.finalize()
            return digest.map { String(format: "%02hhx", $0) }.joined()
        } catch {
            print("Error calculating hash for \(fileURL.path): \(error)")
            return nil
        }
    }
}

// MARK: - UI Components

struct AuroraBackground: View {
    var body: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                Color(red: 0.1, green: 0.0, blue: 0.2),
                Color(red: 0.0, green: 0.1, blue: 0.3),
                Color(red: 0.2, green: 0.0, blue: 0.1)
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct HeaderView: View {
    @Binding var isScanning: Bool
    var onScan: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack {
            Text("CleanLivePhotos")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Spacer()
            
            Button(action: isScanning ? onCancel : onScan) {
                HStack {
                    Image(systemName: isScanning ? "xmark.circle.fill" : "sparkles.magnifyingglass")
                    Text(isScanning ? "Cancel Scan" : "Start Perfect Scan")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(isScanning ? Color.red.opacity(0.8) : Color.blue.opacity(0.8))
                .foregroundColor(.white)
                .clipShape(Capsule())
                .shadow(radius: 5)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

struct WelcomeView: View {
    var body: some View {
        Spacer()
        VStack(spacing: 20) {
            Image(systemName: "sparkles.magnifyingglass")
                .font(.system(size: 80))
                .foregroundColor(.white.opacity(0.8))
            
            Text("Welcome to CleanLivePhotos")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("Intelligently scan and clean duplicate Live Photos to reclaim your disk space.")
                .font(.title3)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 50)
        }
        Spacer()
    }
}

struct ScanningView: View {
    let progress: Double
    let message: String
    
    var body: some View {
        Spacer()
        VStack(spacing: 20) {
            ProgressView(value: progress)
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(2.0)

            Text(message)
                .font(.title3)
                .foregroundColor(.white.opacity(0.8))
                .padding(.top, 20)
        }
        Spacer()
    }
}

struct ResultsView: View {
    let groups: [FileGroup]
    @Binding var selectedFile: DisplayFile?
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(groups) { group in
                    FileGroupCard(
                        group: group,
                        selectedFile: $selectedFile
                    )
                }
            }
            .padding()
        }
        .frame(minWidth: 600)
    }
}

struct FileGroupCard: View {
    let group: FileGroup
    @Binding var selectedFile: DisplayFile?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.groupName)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal)
            
            Divider().background(Color.white.opacity(0.3))
            
            ForEach(group.files) { file in
                FileRowView(
                    file: file,
                    isSelected: file.id == selectedFile?.id,
                    onSelect: { self.selectedFile = file }
                )
            }
        }
        .padding()
        .background(.black.opacity(0.2))
        .cornerRadius(15)
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }
}

struct FileRowView: View {
    let file: DisplayFile
    let isSelected: Bool
    let onSelect: () -> Void
    
    private var statusColor: Color {
        switch file.action {
        case .keepAsIs: return .green
        case .keepAndRename: return .blue
        case .delete: return .red
        }
    }
    
    private var statusIcon: String {
        switch file.action {
        case .keepAsIs: return "checkmark.circle.fill"
        case .keepAndRename: return "pencil.circle.fill"
        case .delete: return "trash.circle.fill"
        }
    }
    
    private var reasonTagColor: Color {
        switch file.action {
        case .keepAsIs:
            return .green.opacity(0.7)
        case .keepAndRename:
            return .blue.opacity(0.7)
        case .delete(let reason):
            return reason.contains("Content") ? .orange.opacity(0.8) : .purple.opacity(0.8)
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .font(.title2)
            
            VStack(alignment: .leading) {
                Text(file.fileName)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
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
        .help("Click to preview this file")
    }
}

extension FileAction {
    var reasonText: String {
        switch self {
        case .keepAsIs(let reason):
            return reason
        case .keepAndRename(let reason, let newBaseName):
            return "\(reason) (will be renamed to match video)"
        case .delete(let reason):
            return reason
        }
    }
}

struct FooterView: View {
    let groups: [FileGroup]
    var onDelete: () -> Void
    
    private var filesToDelete: [DisplayFile] {
        groups.flatMap { $0.files }.filter { if case .delete = $0.action { return true } else { return false } }
    }
    
    private var filesToRename: [DisplayFile] {
        groups.flatMap { $0.files }.filter { if case .keepAndRename = $0.action { return true } else { return false } }
    }
    
    private var totalSizeToDelete: Int64 {
        filesToDelete.reduce(0) { $0 + $1.size }
    }
    
    var body: some View {
        VStack(spacing: 10) {
            let deletionCount = filesToDelete.count
            let renameCount = filesToRename.count
            
            if deletionCount > 0 || renameCount > 0 {
                
                VStack {
                    if deletionCount > 0 {
                        Text("Will delete \(deletionCount) file(s), reclaiming \(ByteCountFormatter.string(fromByteCount: totalSizeToDelete, countStyle: .file)).")
                    }
                    if renameCount > 0 {
                        Text("Will repair \(renameCount) file pair(s) by renaming.")
                    }
                }
                .foregroundColor(.white.opacity(0.8))
                
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
            } else {
                 Text("No redundant files found to clean or repair.")
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

struct NoResultsView: View {
    var body: some View {
        Spacer()
        VStack(spacing: 20) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
            
            Text("All Clean!")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("Your folder is perfectly organized. No duplicates found.")
                .font(.title3)
                .foregroundColor(.white.opacity(0.7))
        }
        Spacer()
    }
}

struct ErrorView: View {
    let message: String
    
    var body: some View {
        Spacer()
        VStack(spacing: 20) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 80))
                .foregroundColor(.red)
            
            Text("An Error Occurred")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.title3)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        Spacer()
    }
}

// MARK: - Embedded Preview Pane

struct PreviewPane: View {
    let file: DisplayFile?

    var body: some View {
        VStack {
            if let file = file {
                Text(file.fileName)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                
                Divider()
                
                if isVideo(file.url) {
                    VideoPlayer(player: AVPlayer(url: file.url))
                        .frame(maxHeight: .infinity)
                } else if let image = NSImage(contentsOf: file.url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: .infinity)
                } else {
                    ContentUnavailableView(label: "Preview Unavailable", icon: "eye.slash.fill")
                }
            } else {
                ContentUnavailableView(label: "Select a file to preview", icon: "sparkles.magnifyingglass")
            }
        }
        .background(Color.black.opacity(0.15))
    }
    
    private func isVideo(_ url: URL) -> Bool {
        let videoExtensions = ["mov"]
        return videoExtensions.contains(url.pathExtension.lowercased())
    }
}

struct ContentUnavailableView: View {
    let label: String
    let icon: String
    
    var body: some View {
        Spacer()
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.5))
            
            Text(label)
                .font(.title2)
                .foregroundColor(.white.opacity(0.6))
        }
        Spacer()
    }
}

// MARK: - Security Scoped Bookmark Manager
class FolderAccessManager {
    private var bookmark: Data?
    private var accessedURL: URL?

    @MainActor
    func requestAccess(to url: URL) async -> Bool {
        do {
            self.bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            return true
        } catch {
            print("Failed to create bookmark for \(url.path): \(error.localizedDescription)")
            self.bookmark = nil
            return false
        }
    }

    func startAccessing() async -> Bool {
        guard let bookmark = bookmark else {
            print("No bookmark available to start accessing.")
            return false
        }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            
            if isStale {
                print("Bookmark is stale, requesting new one is needed.")
                // In a real app, you might need to re-request access here.
                return false
            }

            if url.startAccessingSecurityScopedResource() {
                self.accessedURL = url
                return true
            } else {
                print("Failed to start accessing security scoped resource.")
                return false
            }
        } catch {
            print("Failed to resolve bookmark: \(error.localizedDescription)")
            return false
        }
    }

    func stopAccessing() {
        if let url = accessedURL {
            url.stopAccessingSecurityScopedResource()
            accessedURL = nil
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
