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
                    try FileManager.default.removeItem(at: file.url)
                    deletionSuccessCount += 1
                } catch {
                    print("Error deleting file \(file.fileName): \(error)")
                    deletionFailCount += 1
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
                        print("Failed to rename file from \(file.url.path) to \(destinationURL.path): \(error)")
                    }
                }
            }

            await MainActor.run {
                self.alertTitle = "Cleaning Complete"
                var message = "\(deletionSuccessCount) files were successfully deleted."
                if deletionFailCount > 0 { message += "\n\(deletionFailCount) files could not be deleted." }
                
                message += "\n\(renameSuccessCount) files were successfully renamed."
                if renameFailCount > 0 { message += "\n\(renameFailCount) files could not be renamed." }
                
                self.alertMessage = message
                self.showAlert = true
                self.state = .welcome // Reset view after cleaning
            }
        }
    }
    
    // MARK: - The "Perfect Scan" Engine
    
    /// This is the master scanning function that implements the most robust cleaning logic.
    @MainActor
    private func perfectScan(in directoryURL: URL) async {
        let startTime = Date()
        
        // --- PREPARATION ---
        state = .scanning(progress: 0.0, message: "Starting scan...")
        var allFiles: [URL] = []
        
        do {
            let fileManager = FileManager.default
            let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
            guard let enumerator = fileManager.enumerator(at: directoryURL, includingPropertiesForKeys: resourceKeys, options: .skipsHiddenFiles) else {
                state = .error("Failed to enumerate files.")
                return
            }
            
            for case let fileURL as URL in enumerator {
                allFiles.append(fileURL)
            }
        }
        
        if Task.isCancelled { state = .welcome; return }
        
        // --- STEP 1: GLOBAL HASH-BASED DUPLICATE DETECTION ---
        state = .scanning(progress: 0.1, message: "Analyzing file contents...")
        
        var fileHashes: [URL: String] = [:]
        var hashToFileURLs: [String: [URL]] = [:]
        
        for (index, url) in allFiles.enumerated() {
            if Task.isCancelled { state = .welcome; return }
            let progress = 0.1 + (Double(index) / Double(allFiles.count) * 0.4) // 10% -> 50%
            let message = "Analyzing file contents: \(url.lastPathComponent)"
            await MainActor.run {
                state = .scanning(progress: progress, message: message)
            }
            
            // We only care about image and movie files.
            guard let typeIdentifier = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
                  let fileType = UTType(typeIdentifier) else {
                continue
            }
            
            if fileType.conforms(to: .image) || fileType.conforms(to: .movie) {
                if let hash = calculateHash(for: url) {
                    fileHashes[url] = hash
                    hashToFileURLs[hash, default: []].append(url)
                }
            }
        }
        
        if Task.isCancelled { state = .welcome; return }
        
        // --- STEP 2: BUILD THE CLEANING PLAN ---
        state = .scanning(progress: 0.5, message: "Building cleaning plan...")
        
        var plan: [URL: FileAction] = [:]
        var processedURLs = Set<URL>()
        var finalGroups: [FileGroup] = []
        
        // Process content-identical files first (highest priority)
        let contentDuplicateGroups = hashToFileURLs.filter { $0.value.count > 1 }
        
        for (hash, urls) in contentDuplicateGroups {
            if Task.isCancelled { state = .welcome; return }
            
            // Sort to find the "best" name to keep (e.g., shorter, no "copy" suffix)
            let sortedURLs = urls.sorted { $0.lastPathComponent.count < $1.lastPathComponent.count }
            guard let fileToKeep = sortedURLs.first else { continue }
            
            var groupFiles: [DisplayFile] = []
            
            // Keep the first one
            plan[fileToKeep] = .keepAsIs(reason: "Best name among content-identical files")
            processedURLs.insert(fileToKeep)
            let displayFileToKeep = DisplayFile(url: fileToKeep, size: fileToKeep.fileSize ?? 0, action: plan[fileToKeep]!)
            groupFiles.append(displayFileToKeep)
            
            // Mark the rest for deletion
            for urlToDelete in sortedURLs.dropFirst() {
                plan[urlToDelete] = .delete(reason: "Content Duplicate of \(fileToKeep.lastPathComponent)")
                processedURLs.insert(urlToDelete)
                let displayFileToDelete = DisplayFile(url: urlToDelete, size: urlToDelete.fileSize ?? 0, action: plan[urlToDelete]!)
                groupFiles.append(displayFileToDelete)
            }
            
            finalGroups.append(FileGroup(groupName: "Content Duplicates (\(hash.prefix(8))...)", files: groupFiles))
        }
        
        if Task.isCancelled { state = .welcome; return }
        await MainActor.run {
            state = .scanning(progress: 0.7, message: "Analyzing file relationships...")
        }
        
        // --- STEP 3: PROCESS NAME-BASED ASSOCIATIONS FOR LIVE PHOTOS & VERSIONS ---
        let remainingURLs = allFiles.filter { !processedURLs.contains($0) }
        let nameBasedGroups = Dictionary(grouping: remainingURLs, by: { getBaseName(for: $0) })
        
        // By creating a copy, we avoid the Swift 6 async iteration error.
        let groupsToProcess = nameBasedGroups
        for (baseName, urls) in groupsToProcess {
            if Task.isCancelled { state = .welcome; return }
            
            var groupFiles: [DisplayFile] = []
            
            // Separate by major media type: IMAGES vs VIDEOS
            var images = urls.filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .image) && !processedURLs.contains(url)
            }
            
            var videos = urls.filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .movie) && !processedURLs.contains(url)
            }
            
            images.sort { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
            videos.sort { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
            
            let bestImage = images.first
            let bestVideo = videos.first
            
            // Process Videos first, as they are the anchor for renaming
            if let bestVideo {
                plan[bestVideo] = .keepAsIs(reason: "Largest Video")
                processedURLs.insert(bestVideo)
                let displayBestVideo = DisplayFile(url: bestVideo, size: bestVideo.fileSize ?? 0, action: plan[bestVideo]!)
                groupFiles.append(displayBestVideo)
                
                for videoToDelete in videos.dropFirst() {
                    plan[videoToDelete] = .delete(reason: "Smaller Video Version of \(bestVideo.lastPathComponent)")
                    processedURLs.insert(videoToDelete)
                    let displayFileToDelete = DisplayFile(url: videoToDelete, size: videoToDelete.fileSize ?? 0, action: plan[videoToDelete]!)
                    groupFiles.append(displayFileToDelete)
                }
            }
            
            // Process Images, checking against the video for renaming
            if let bestImage {
                let bestImageBaseName = bestImage.deletingPathExtension().lastPathComponent
                let videoBaseName = bestVideo?.deletingPathExtension().lastPathComponent
                
                if let videoBaseName, bestImageBaseName != videoBaseName {
                    plan[bestImage] = .keepAndRename(reason: "Largest Image", newBaseName: videoBaseName)
                } else {
                    plan[bestImage] = .keepAsIs(reason: "Largest Image")
                }
                
                processedURLs.insert(bestImage)
                let displayBestImage = DisplayFile(url: bestImage, size: bestImage.fileSize ?? 0, action: plan[bestImage]!)
                groupFiles.append(displayBestImage)

                for imageToDelete in images.dropFirst() {
                    plan[imageToDelete] = .delete(reason: "Smaller Image Version of \(bestImage.lastPathComponent)")
                    processedURLs.insert(imageToDelete)
                    let displayFileToDelete = DisplayFile(url: imageToDelete, size: imageToDelete.fileSize ?? 0, action: plan[imageToDelete]!)
                    groupFiles.append(displayFileToDelete)
                }
            }

            if !groupFiles.isEmpty {
                groupFiles.sort { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
                finalGroups.append(FileGroup(groupName: baseName, files: groupFiles))
            }
        }
        
        // --- FINALIZATION ---
        let trulyLeftoverURLs = allFiles.filter { !processedURLs.contains($0) }
        for url in trulyLeftoverURLs {
             guard let typeIdentifier = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
                  let fileType = UTType(typeIdentifier) else {
                continue
            }
            if (fileType.conforms(to: .image) || fileType.conforms(to: .movie)) && plan[url] == nil {
                 plan[url] = .keepAsIs(reason: "Unique file")
            }
        }
        
        if Task.isCancelled { state = .welcome; return }
        
        await MainActor.run {
            state = .scanning(progress: 1.0, message: "Scan complete!")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let sortedGroups = finalGroups.sorted {
                    if $0.groupName.starts(with: "Content") && !$1.groupName.starts(with: "Content") {
                        return true
                    }
                    if !$0.groupName.starts(with: "Content") && $1.groupName.starts(with: "Content") {
                        return false
                    }
                    return $0.groupName.localizedCaseInsensitiveCompare($1.groupName) == .orderedAscending
                }
                
                self.state = .results(sortedGroups)
                let endTime = Date()
                print("Scan finished in \(endTime.timeIntervalSince(startTime)) seconds.")
            }
        }
    }
    
    /// Extracts a base name from a URL for grouping.
    private func getBaseName(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let cleanName = name.replacingOccurrences(of: "(?:[ _-](?:copy|\\d+)| \\(\\d+\\)|_v\\d+)$", with: "", options: [.regularExpression, .caseInsensitive])
        return cleanName
    }
}

// MARK: - Helper Extensions

extension URL {
    var fileSize: Int64? {
        let values = try? resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

// MARK: - UI Components

struct AuroraBackground: View {
    @State private var blobPositions: [CGPoint] = []
    
    let colors: [Color] = [
        Color(red: 0.1, green: 0.5, blue: 1.0, opacity: 0.6),
        Color(red: 0.8, green: 0.2, blue: 0.6, opacity: 0.6),
        Color(red: 0.4, green: 0.3, blue: 1.0, opacity: 0.6)
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                
                ZStack {
                    ForEach(0..<blobPositions.count, id: \.self) { index in
                        Circle()
                            .fill(colors[index])
                            .frame(width: proxy.size.width / 1.5, height: proxy.size.width / 1.5)
                            .position(blobPositions[index])
                            .blur(radius: 100)
                    }
                }
                .drawingGroup()
            }
            .onAppear {
                // Initialize positions
                if blobPositions.isEmpty {
                    for _ in 0..<colors.count {
                        blobPositions.append(randomPosition(in: proxy.size))
                    }
                }
                
                // Start animation loop
                startAnimation(in: proxy.size)
            }
        }
        .ignoresSafeArea()
    }
    
    private func startAnimation(in size: CGSize) {
        withAnimation(
            .spring(response: 10, dampingFraction: 0.7).repeatForever(autoreverses: true)
        ) {
            for i in 0..<blobPositions.count {
                blobPositions[i] = randomPosition(in: size)
            }
        }
    }
    
    private func randomPosition(in size: CGSize) -> CGPoint {
        return CGPoint(
            x: .random(in: -size.width * 0.2 ... size.width * 1.2),
            y: .random(in: -size.height * 0.2 ... size.height * 1.2)
        )
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
        .background(.ultraThinMaterial)
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
        case .keepAndRename(let reason, _):
             return "\(reason) (rename to match video)"
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
        let hasActions = !filesToDelete.isEmpty || !filesToRename.isEmpty
        
        VStack(spacing: 10) {
            if hasActions {
                VStack {
                    if !filesToDelete.isEmpty {
                        Text("Will delete \(filesToDelete.count) file(s), reclaiming \(ByteCountFormatter.string(fromByteCount: totalSizeToDelete, countStyle: .file)).")
                    }
                    if !filesToRename.isEmpty {
                         Text("Will repair \(filesToRename.count) file pair(s) by renaming.")
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
                 HStack(spacing: 8) {
                     Image(systemName: "checkmark.seal.fill")
                         .foregroundColor(.green)
                     Text("No redundant files found to clean or repair.")
                        .foregroundColor(.white.opacity(0.8))
                 }
            }
        }
        .padding()
        .background {
            if hasActions {
                Color.clear.background(.ultraThinMaterial)
            } else {
                Color.clear
            }
        }
        .animation(.easeInOut, value: hasActions)
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
                VStack {
                    Text(file.fileName)
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    if case .keepAndRename(_, let newBaseName) = file.action {
                        let newFileName = newBaseName + "." + file.url.pathExtension
                        Text("Will be renamed to \(newFileName)")
                            .font(.subheadline)
                            .foregroundColor(.blue.opacity(0.9))
                    }
                }
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
        .background(.clear)
    }
    
    private func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .movie)
    }
}

struct ContentUnavailableView: View {
    let label: String
    let icon: String
    
    var body: some View {
        Spacer()
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 80))
                .foregroundColor(.white.opacity(0.2))
            
            Text(label)
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.white.opacity(0.3))
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

#if os(macOS)
// MARK: - Preview
#Preview {
    ContentView()
}
#endif

