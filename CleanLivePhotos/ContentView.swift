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
    case userKeep // User override to keep a file that was marked for deletion.
    case userDelete // User override to delete a file that was marked for keeping.

    var isKeep: Bool {
        switch self {
        case .keepAsIs, .keepAndRename, .userKeep:
            return true
        case .delete, .userDelete:
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

// MARK: - Main Content View

struct ContentView: View {
    @State private var state: ViewState = .welcome
    @State private var currentScanTask: Task<Void, Error>?
    @State private var showAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var folderAccessManager = FolderAccessManager()
    @State private var selectedFile: DisplayFile?
    @State private var lastProgressUpdate: (date: Date, progress: Double)?

    // State for paginated results display
    @State private var allResultGroups: [FileGroup] = []
    @State private var displayedResultGroups: [FileGroup] = []
    @State private var expandedCategories: [String: Bool] = [:]
    
    // Store original actions to allow "Automatic" state to be restored.
    @State private var originalFileActions: [UUID: FileAction] = [:]
    
    private let resultsPageSize = 50

    var body: some View {
        contentView
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var contentView: some View {
        ZStack {
            WindowAccessor()

            switch state {
            case .welcome:
                WelcomeView(onScan: { handleScanRequest() })
                
            case .scanning(let progress, let animationRate):
                ScanningView(progressState: progress, animationRate: animationRate)
                    .padding(.top, 44)
                
            case .results:
                VStack(spacing: 0) {
                    if displayedResultGroups.isEmpty {
                        NoResultsView()
                            .padding(.top, 44)
                    } else {
                        HStack(spacing: 0) {
                            ResultsView(
                                groups: displayedResultGroups,
                                selectedFile: $selectedFile,
                                hasMoreResults: displayedResultGroups.count < allResultGroups.count,
                                onLoadMore: loadMoreResults,
                                expandedCategories: $expandedCategories,
                                onUpdateUserAction: updateUserAction
                            )
                            Divider()
                                .background(.regularMaterial)
                            PreviewPane(file: selectedFile)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.top, 44)
                    }
                    
                    if !allResultGroups.isEmpty {
                        FooterView(
                            groups: allResultGroups,
                            onDelete: { executeCleaningPlan(for: allResultGroups) },
                            onGoHome: resetToWelcomeState
                        )
                    }
                }
            case .error(let errorMessage):
                ErrorView(
                    message: errorMessage,
                    onDismiss: { self.state = .welcome }
                )
                .padding(.top, 44)
            }
            
            if case .scanning = state, currentScanTask != nil {
                VStack {
                    HStack {
                        Spacer()
                        CloseButton {
                            currentScanTask?.cancel()
                            state = .welcome
                        }
                    }
                    Spacer()
                }
            } else if case .results = state {
                // This close button is being removed as per user request.
                // The functionality will be moved to a new button in the FooterView.
            }
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .background(.regularMaterial)
        .ignoresSafeArea(.all)
    }
    
    private func handleScanRequest() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            currentScanTask = Task {
                if await folderAccessManager.requestAccess(to: url) {
                    // Reset progress tracking state before starting a new scan.
                    await MainActor.run {
                        self.lastProgressUpdate = nil
                    }
                    // Start accessing the security-scoped resource before scanning.
                    guard await folderAccessManager.startAccessing() else {
                        await MainActor.run {
                            let detailedError = "Failed to start access to the folder. This might be a permissions issue. Please try selecting the folder again."
                            self.state = .error(detailedError)
                        }
                        return
                    }
                    // Ensure we stop accessing the resource when the scan is complete or fails.
                    defer { folderAccessManager.stopAccessing() }
                    
                    do {
                        try await perfectScan(in: url)
                    } catch is CancellationError {
                        // This is expected when the user cancels, just reset the state.
                        await MainActor.run {
                            self.state = .welcome
                        }
                    } catch {
                        await MainActor.run {
                            let detailedError = """
                            An unexpected error occurred during the scan.

                            Details:
                            \(error.localizedDescription)

                            ---
                            Technical Info:
                            \(String(describing: error))
                            """
                            self.state = .error(detailedError)
                        }
                    }
                } else {
                    await MainActor.run {
                        self.state = .error("Failed to gain permission to access the folder. Please select the folder and grant permission when prompted.")
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
    private func perfectScan(in directoryURL: URL) async throws {
        let startTime = Date()

        // --- PHASE 1: FILE DISCOVERY ---
        await MainActor.run {
            let progress = ScanningProgress(phase: "Phase 1: Discovering", detail: "Scanning folder for media files...", progress: 0.0, totalFiles: 0, processedFiles: 0, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
            self.state = .scanning(progress: progress, animationRate: 5.0) // Start with a default calm rate
        }

        var allMediaFileURLs: [URL] = []
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .typeIdentifierKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        
        guard let sequence = URLDirectoryAsyncSequence(url: directoryURL, options: options, resourceKeys: resourceKeys) else {
            await MainActor.run { state = .error("Failed to create file enumerator.") }
            return
        }
        
        var discoveredCount = 0
        for await fileURL in sequence {
            if Task.isCancelled { await MainActor.run { state = .welcome }; return }

            // We only care about image and movie files.
            guard let typeIdentifier = try? fileURL.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
                  let fileType = UTType(typeIdentifier),
                  (fileType.conforms(to: .image) || fileType.conforms(to: .movie)) else {
                continue
            }
            
            allMediaFileURLs.append(fileURL)
            discoveredCount += 1
            
            if discoveredCount % 50 == 0 { // Update UI periodically
                await MainActor.run {
                    let progress = ScanningProgress(phase: "Phase 1: Discovering", detail: "Found \(discoveredCount) media files...", progress: 0.05, totalFiles: discoveredCount, processedFiles: discoveredCount, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
                    self.state = .scanning(progress: progress, animationRate: 10.0) // A bit faster during discovery
                }
            }
        }
        
        if Task.isCancelled { await MainActor.run { state = .welcome }; return }
        
        let totalFiles = allMediaFileURLs.count

        // --- PHASE 2: HASHING & CONTENT DUPLICATE DETECTION ---
        let hashingProgressStart = 0.05
        let hashingProgressEnd = 0.60
        
        var fileHashes: [URL: String] = [:]
        var hashToFileURLs: [String: [URL]] = [:]
        
        // --- PHASE 2.5: Parallel Hashing with TaskGroup ---
        let hashingStartTime = Date()
        var lastUIUpdateTime = Date()
        var processedFilesCount = 0
        
        // Bounded concurrency: Limit hashing tasks to the number of processor cores
        // to avoid overwhelming the system when dealing with tens of thousands of files.
        let concurrencyLimit = ProcessInfo.processInfo.activeProcessorCount
        
        try await withThrowingTaskGroup(of: (URL, String?).self) { group in
            var urlIterator = allMediaFileURLs.makeIterator()

            // 1. Start the initial batch of concurrent tasks.
            for _ in 0..<concurrencyLimit {
                if let url = urlIterator.next() {
                    group.addTask {
                        let hash = calculateHash(for: url)
                        return (url, hash)
                    }
                }
            }

            // 2. As each task finishes, process its result and start a new task for the next item.
            for try await (url, hash) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                
                // Process the result of the completed task.
                processedFilesCount += 1
                if let hash = hash {
                    fileHashes[url] = hash
                    hashToFileURLs[hash, default: []].append(url)
                }
                
                // Add a new task for the next URL from the iterator.
                if let nextURL = urlIterator.next() {
                    group.addTask {
                        let hash = calculateHash(for: nextURL)
                        return (nextURL, hash)
                    }
                }

                // Throttle UI updates to avoid overwhelming the main thread.
                if Date().timeIntervalSince(lastUIUpdateTime) > 0.1 {
                    
                    // --- Calculate Stats ---
                    let hashingProgress = (Double(processedFilesCount) / Double(totalFiles))
                    let totalHashingElapsedTime = Date().timeIntervalSince(hashingStartTime)
                    var etr: TimeInterval? = nil
                    if hashingProgress > 0.01 && totalHashingElapsedTime > 1 {
                        let estimatedTotalTime = totalHashingElapsedTime / hashingProgress
                        etr = max(0, estimatedTotalTime - totalHashingElapsedTime)
                    }
                    
                    // --- Update UI State ---
                    let progressVal = hashingProgressStart + hashingProgress * (hashingProgressEnd - hashingProgressStart)
                    
                    await MainActor.run {
                        let now = Date()
                        var newAnimationRate = 5.0 // Default
                        if let lastUpdate = self.lastProgressUpdate {
                            let timeDelta = now.timeIntervalSince(lastUpdate.date)
                            let progressDelta = progressVal - lastUpdate.progress
                            
                            if timeDelta > 0.01 { // Avoid division by zero and extreme values on first update
                                let progressPerSecond = progressDelta / timeDelta
                                // Map progress-per-second to a visually pleasing animation rate.
                                // Base rate of 5, scaling up to ~50 for very fast processing.
                                newAnimationRate = 5.0 + (progressPerSecond * 300.0)
                            }
                        }
                        self.lastProgressUpdate = (now, progressVal)
                        
                        let progress = ScanningProgress(
                            phase: "Phase 2: Analyzing Content",
                            detail: url.lastPathComponent,
                            progress: progressVal,
                            totalFiles: totalFiles,
                            processedFiles: processedFilesCount,
                            estimatedTimeRemaining: etr,
                            processingSpeedMBps: nil // Speed calculation is complex in parallel; defer for simplicity
                        )
                        self.state = .scanning(progress: progress, animationRate: newAnimationRate)
                    }
                    
                    lastUIUpdateTime = Date()
                }
            }
        }
        
        if Task.isCancelled { await MainActor.run { state = .welcome }; return }
        
        // --- PHASE 3: BUILDING CLEANING PLAN ---
        let analysisProgressStart = hashingProgressEnd
        let analysisProgressEnd = 0.95
        
        await MainActor.run {
            let progress = ScanningProgress(phase: "Phase 3: Building Plan", detail: "Finding content-identical files...", progress: analysisProgressStart, totalFiles: totalFiles, processedFiles: 0, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
            self.state = .scanning(progress: progress, animationRate: 15.0) // Fixed moderate speed for planning phase
        }
        
        var plan: [URL: FileAction] = [:]
        var processedURLs = Set<URL>()
        var finalGroups: [FileGroup] = []
        
        // Process content-identical files first
        let contentDuplicateGroups = hashToFileURLs.filter { $0.value.count > 1 }
        let duplicateGroupsArray = Array(contentDuplicateGroups)
        for (hash, urls) in duplicateGroupsArray {
            if Task.isCancelled { await MainActor.run { state = .welcome }; return }
            
            let sortedURLs = urls.sorted { $0.lastPathComponent.count < $1.lastPathComponent.count }
            guard let fileToKeep = sortedURLs.first else { continue }
            
            var groupFiles: [DisplayFile] = []
            
            plan[fileToKeep] = .keepAsIs(reason: "Best name among content duplicates")
            processedURLs.insert(fileToKeep)
            groupFiles.append(DisplayFile(url: fileToKeep, size: fileToKeep.fileSize ?? 0, action: plan[fileToKeep]!))
            
            for urlToDelete in sortedURLs.dropFirst() {
                plan[urlToDelete] = .delete(reason: "Content Duplicate of \(fileToKeep.lastPathComponent)")
                processedURLs.insert(urlToDelete)
                groupFiles.append(DisplayFile(url: urlToDelete, size: urlToDelete.fileSize ?? 0, action: plan[urlToDelete]!))
            }
            finalGroups.append(FileGroup(groupName: "Content Duplicates (\(hash.prefix(8))...)", files: groupFiles))
        }
        
        // --- PHASE 3.2: Cooperatively find remaining files ---
        let processedAfterDuplicates = processedURLs.count
        let nameAnalysisProgress = analysisProgressStart + (analysisProgressEnd - analysisProgressStart) * 0.2 // 60% -> 67%
        await MainActor.run {
            let progress = ScanningProgress(phase: "Phase 3: Building Plan", detail: "Isolating unique files...", progress: nameAnalysisProgress, totalFiles: totalFiles, processedFiles: processedAfterDuplicates, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
            self.state = .scanning(progress: progress, animationRate: 15.0)
        }
        await Task.yield() // Ensure UI updates

        var remainingURLs: [URL] = []
        remainingURLs.reserveCapacity(allMediaFileURLs.count - processedURLs.count)
        for (index, url) in allMediaFileURLs.enumerated() {
            if !processedURLs.contains(url) {
                remainingURLs.append(url)
            }
            if index % 5000 == 0 { // Yield to keep UI responsive
                await Task.yield()
                if Task.isCancelled { await MainActor.run { state = .welcome }; return }
            }
        }

        // --- PHASE 3.3: Cooperatively group remaining files by name ---
        let groupingProgress = analysisProgressStart + (analysisProgressEnd - analysisProgressStart) * 0.4 // 67% -> 74%
        await MainActor.run {
            let progress = ScanningProgress(phase: "Phase 3: Building Plan", detail: "Grouping files by name...", progress: groupingProgress, totalFiles: totalFiles, processedFiles: processedAfterDuplicates, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
            self.state = .scanning(progress: progress, animationRate: 15.0)
        }
        await Task.yield()
        
        var nameBasedGroups: [String: [URL]] = [:]
        nameBasedGroups.reserveCapacity(remainingURLs.count)
        for (index, url) in remainingURLs.enumerated() {
            let baseName = getBaseName(for: url)
            nameBasedGroups[baseName, default: []].append(url)

            if index % 5000 == 0 { // Yield to keep UI responsive
                await Task.yield()
                if Task.isCancelled { await MainActor.run { state = .welcome }; return }
            }
        }
        
        // --- PHASE 3.4: Process the name-based groups ---
        let nameProcessingProgress = analysisProgressStart + (analysisProgressEnd - analysisProgressStart) * 0.6 // 74% -> 81%
        await MainActor.run {
            let progress = ScanningProgress(phase: "Phase 3: Building Plan", detail: "Analyzing Live Photo pairs...", progress: nameProcessingProgress, totalFiles: totalFiles, processedFiles: processedURLs.count, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
            self.state = .scanning(progress: progress, animationRate: 15.0)
        }
        await Task.yield()

        // Iterate over a copy of the keys to avoid Swift 6 concurrency errors.
        // Sorting gives a deterministic order to the processing.
        let nameBasedKeys = nameBasedGroups.keys.sorted()
        for baseName in nameBasedKeys {
            guard let urls = nameBasedGroups[baseName] else { continue }

            if Task.isCancelled { await MainActor.run { state = .welcome }; return }
            
            var images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false }
            var videos = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) ?? false }
            
            // Check for perfect, non-actionable Live Photo pairs first.
            // A pair is "perfect" if there's one of each and their names (sans extension) are identical.
            if images.count == 1,
               videos.count == 1,
               images[0].deletingPathExtension().lastPathComponent == videos[0].deletingPathExtension().lastPathComponent {
                
                let image = images[0]
                let video = videos[0]
                var groupFiles: [DisplayFile] = []

                plan[image] = .keepAsIs(reason: "Perfectly Paired")
                processedURLs.insert(image)
                groupFiles.append(DisplayFile(url: image, size: image.fileSize ?? 0, action: plan[image]!))
                
                plan[video] = .keepAsIs(reason: "Perfectly Paired")
                processedURLs.insert(video)
                groupFiles.append(DisplayFile(url: video, size: video.fileSize ?? 0, action: plan[video]!))
                
                // Each perfect pair is its own group.
                let groupName = "Perfectly Paired & Ignored: \(baseName)"
                finalGroups.append(FileGroup(groupName: groupName, files: groupFiles))

                continue // Skip to the next group, as this one is handled.
            }
            
            var groupFiles: [DisplayFile] = []
            
            images.sort { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
            videos.sort { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
            
            let bestImage = images.first
            let bestVideo = videos.first
            
            if let bestVideo {
                plan[bestVideo] = .keepAsIs(reason: "Largest Video")
                processedURLs.insert(bestVideo)
                groupFiles.append(DisplayFile(url: bestVideo, size: bestVideo.fileSize ?? 0, action: plan[bestVideo]!))
                
                for videoToDelete in videos.dropFirst() {
                    plan[videoToDelete] = .delete(reason: "Smaller Video Version")
                    processedURLs.insert(videoToDelete)
                    groupFiles.append(DisplayFile(url: videoToDelete, size: videoToDelete.fileSize ?? 0, action: plan[videoToDelete]!))
                }
            }
            
            if let bestImage {
                if let bestVideo {
                    // This is a Live Photo pair situation. The image is the primary visual.
                    let bestImageBaseName = bestImage.deletingPathExtension().lastPathComponent
                    let videoBaseName = bestVideo.deletingPathExtension().lastPathComponent
                    
                    if bestImageBaseName != videoBaseName {
                        plan[bestImage] = .keepAndRename(reason: "Primary for Live Photo", newBaseName: videoBaseName)
                    } else {
                        plan[bestImage] = .keepAsIs(reason: "Primary for Live Photo")
                    }
                } else {
                    // No video in this group, so it's just the largest image.
                    plan[bestImage] = .keepAsIs(reason: "Largest Image")
                }
                processedURLs.insert(bestImage)
                groupFiles.append(DisplayFile(url: bestImage, size: bestImage.fileSize ?? 0, action: plan[bestImage]!))
                
                for imageToDelete in images.dropFirst() {
                    plan[imageToDelete] = .delete(reason: "Smaller Image Version")
                    processedURLs.insert(imageToDelete)
                    groupFiles.append(DisplayFile(url: imageToDelete, size: imageToDelete.fileSize ?? 0, action: plan[imageToDelete]!))
                }
            }

            // Categorize the group based on the actions taken.
            let hasRenameAction = groupFiles.contains { if case .keepAndRename = $0.action { return true } else { return false } }
            let hasDeleteAction = groupFiles.contains { if case .delete = $0.action { return true } else { return false } }

            if hasRenameAction {
                let groupName = "Live Photo Pair to Repair: \(baseName)"
                groupFiles.sort { file1, file2 in
                    let isPair1 = file1.action.isLivePhotoPairPart
                    let isPair2 = file2.action.isLivePhotoPairPart
                    if isPair1 && !isPair2 { return true }
                    if !isPair1 && isPair2 { return false }
                    if isPair1 && isPair2 {
                        let isVideo1 = UTType(filenameExtension: file1.url.pathExtension)?.conforms(to: .movie) ?? false
                        return isVideo1
                    }
                    return file1.fileName.localizedCaseInsensitiveCompare(file2.fileName) == .orderedAscending
                }
                finalGroups.append(FileGroup(groupName: groupName, files: groupFiles))
            } else if hasDeleteAction {
                let groupName = "Redundant Versions to Delete: \(baseName)"
                groupFiles.sort { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
                finalGroups.append(FileGroup(groupName: groupName, files: groupFiles))
            }
        }
        

        
        // --- FINALIZATION ---
        let trulyLeftoverURLs = allMediaFileURLs.filter { !processedURLs.contains($0) }
        for url in trulyLeftoverURLs {
             plan[url] = .keepAsIs(reason: "Unique file")
        }
        
        if Task.isCancelled { await MainActor.run { state = .welcome }; return }
        
        await MainActor.run {
            let progress = ScanningProgress(phase: "Scan Complete", detail: "Found \(finalGroups.count) groups.", progress: 1.0, totalFiles: totalFiles, processedFiles: totalFiles, estimatedTimeRemaining: nil, processingSpeedMBps: nil)
            self.state = .scanning(progress: progress, animationRate: 5.0) // Calm down before switching view
        }
        
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s to show complete
        
        await MainActor.run {
            // New sorting logic based on categories
            let order: [String: Int] = [
                "Content Duplicates": 1,
                "Live Photo Pair to Repair": 2,
                "Redundant Versions to Delete": 3,
                "Perfectly Paired & Ignored": 4
            ]

            let sortedGroups = finalGroups.sorted { g1, g2 in
                func category(for groupName: String) -> (Int, String) {
                    for (prefix, orderValue) in order {
                        if groupName.starts(with: prefix) {
                            // Return the base name for alphabetical sorting within the category
                            let baseName = groupName.replacingOccurrences(of: "\(prefix): ", with: "")
                            return (orderValue, baseName)
                        }
                    }
                    // Handle the special cases that don't have a prefix
                    if groupName.starts(with: "Perfectly Paired") { return (order["Perfectly Paired & Ignored"]!, groupName) }
                    if groupName.starts(with: "Content Duplicates") { return (order["Content Duplicates"]!, groupName) }
                    
                    return (99, g1.groupName) // Should not happen
                }

                let (order1, name1) = category(for: g1.groupName)
                let (order2, name2) = category(for: g2.groupName)

                if order1 != order2 {
                    return order1 < order2
                }
                
                return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
            }
            
            self.showResults(groups: sortedGroups)
            let endTime = Date()
            print("Scan finished in \(endTime.timeIntervalSince(startTime)) seconds.")
        }
    }
    
    private func resetToWelcomeState() {
        // Reset state before switching views to prevent crashes.
        // The order is important: clear selection first, then data, then switch view state.
        self.selectedFile = nil
        self.allResultGroups = []
        self.displayedResultGroups = []
        self.originalFileActions = [:]
        self.expandedCategories = [:]
        self.lastProgressUpdate = nil
        self.state = .welcome
    }
    
    private func showResults(groups: [FileGroup]) {
        self.allResultGroups = groups
        let initialDisplayGroups = Array(groups.prefix(resultsPageSize))
        self.displayedResultGroups = initialDisplayGroups
        
        // Store the original, AI-determined actions so we can revert back to "Automatic"
        self.originalFileActions = Dictionary(
            uniqueKeysWithValues: groups.flatMap { $0.files }.map { ($0.id, $0.action) }
        )
        
        let allCategories = Set(groups.map { getCategoryPrefix(for: $0.groupName) })
        self.expandedCategories = Dictionary(uniqueKeysWithValues: allCategories.map { ($0, true) })
        // Always collapse the ignored group by default
        self.expandedCategories["Perfectly Paired & Ignored"] = false

        self.state = .results
    }
    
    private func loadMoreResults() {
        let currentCount = displayedResultGroups.count
        let nextBatchEndIndex = min(currentCount + resultsPageSize, allResultGroups.count)
        let newGroups = allResultGroups[currentCount..<nextBatchEndIndex]
        displayedResultGroups.append(contentsOf: newGroups)
    }
    
    /// Extracts a base name from a URL for grouping.
    private func getBaseName(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let cleanName = name.replacingOccurrences(of: "(?:[ _-](?:copy|\\d+)| \\(\\d+\\)|_v\\d+)$", with: "", options: [.regularExpression, .caseInsensitive])
        return cleanName
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

    private func updateUserAction(for file: DisplayFile) {
        guard let originalAction = originalFileActions[file.id] else { return }

        let newAction: FileAction

        // If the current action is a user override, the next state is to revert to the original automatic action.
        if file.action.isUserOverride {
            newAction = originalAction
        } else {
            // If the current action is the automatic one, the next state is the user override.
            // The override is the opposite of the original action.
            if originalAction.isKeep {
                newAction = .userDelete
            } else {
                newAction = .userKeep
            }
        }

        func findAndReplace(in collection: inout [FileGroup]) {
            for i in 0..<collection.count {
                if let j = collection[i].files.firstIndex(where: { $0.id == file.id }) {
                    collection[i].files[j].action = newAction
                    return
                }
            }
        }
        
        findAndReplace(in: &allResultGroups)
        findAndReplace(in: &displayedResultGroups)
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

struct AppLogoView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32)
                .fill(.black.opacity(0.3))
                .frame(width: 160, height: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .stroke(LinearGradient(
                            gradient: Gradient(colors: [.white.opacity(0.3), .white.opacity(0.1)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ), lineWidth: 2)
                )
            
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.9))
            
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundColor(Color(red: 0.8, green: 0.6, blue: 1.0))
                .offset(x: 30, y: -30)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        }
    }
}

struct WelcomeView: View {
    var onScan: () -> Void
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            AppLogoView()
                .padding(.bottom, 20)
            
            VStack(spacing: 8) {
                Text("欢迎使用 CleanLivePhotos")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("开始一次快速而全面的扫描来整理您的照片库。")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            Button(action: onScan) {
                Text("开始扫描")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .padding()
                    .frame(width: 180, height: 60)
                    .background(
                        ZStack {
                            Color(red: 0.5, green: 0.3, blue: 0.9)
                            RadialGradient(
                                gradient: Gradient(colors: [.white.opacity(0.3), .clear]),
                                center: .center,
                                startRadius: 1,
                                endRadius: 80
                            )
                        }
                    )
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .shadow(color: Color(red: 0.5, green: 0.3, blue: 0.9).opacity(0.5), radius: 20, y: 10)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.bottom, 50)
        }
    }
}

struct ScanningView: View {
    let progressState: ScanningProgress
    let animationRate: Double

    private var phaseColor: Color {
        // Assign a unique, high-tech color to each scanning phase.
        switch progressState.phase {
        case "Phase 1: Discovering":
            return Color(red: 0.2, green: 0.8, blue: 1.0) // Data Blue
        case "Phase 2: Analyzing Content":
            return Color(red: 0.9, green: 0.3, blue: 0.8) // Processing Purple
        case "Phase 3: Building Plan":
            return Color(red: 1.0, green: 0.8, blue: 0.3) // Wisdom Gold
        case "Scan Complete":
            return Color(red: 0.4, green: 1.0, blue: 0.7) // Success Green
        default:
            return .white // Fallback color
        }
    }

    var body: some View {
        ZStack {
            MatrixAnimationView(rate: animationRate)
                .ignoresSafeArea()
            
            // This VStack is now the single, unified panel for all content.
            VStack(spacing: 25) {
                ZStack {
                    Circle()
                        .stroke(lineWidth: 20)
                        .opacity(0.1)
                        .foregroundColor(.primary.opacity(0.3))

                    Circle()
                        .trim(from: 0.0, to: CGFloat(min(progressState.progress, 1.0)))
                        .stroke(style: StrokeStyle(lineWidth: 20, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(
                            LinearGradient(gradient: Gradient(colors: [phaseColor, phaseColor.opacity(0.7)]), startPoint: .top, endPoint: .bottom)
                        )
                        .rotationEffect(Angle(degrees: 270.0))
                        .animation(.linear(duration: 0.2), value: progressState.progress)
                        .shadow(color: phaseColor.opacity(0.5), radius: 10)
                        .animation(.easeInOut(duration: 0.5), value: phaseColor)
                    
                    // A capsule-shaped indicator that rotates with the progress arc.
                    let progress = CGFloat(min(progressState.progress, 1.0))
                    if progress > 0.0 {
                        Capsule()
                            .fill(Color.white)
                            .frame(width: 8, height: 22)
                            .shadow(color: phaseColor.opacity(0.7), radius: 8)
                            .offset(y: -80)
                            .rotationEffect(.degrees(360 * progress))
                            .animation(.linear(duration: 0.2), value: progressState.progress)
                    }

                    Text(String(format: "%.0f%%", min(progressState.progress, 1.0) * 100.0))
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .animation(.none, value: progressState.progress)
                }
                .frame(width: 180, height: 180)

                // The textual content is now directly inside the main panel VStack.
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Text(progressState.phase)
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)

                        Text(progressState.detail)
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if progressState.totalFiles > 0 {
                            Text("\(progressState.processedFiles) / \(progressState.totalFiles)")
                                .font(.body.monospacedDigit())
                                .foregroundColor(.secondary)
                                .padding(.top, 5)
                        }
                    }

                    // --- Detailed Stats ---
                    if progressState.estimatedTimeRemaining != nil || progressState.processingSpeedMBps != nil {
                        HStack(spacing: 30) {
                            if let etr = progressState.estimatedTimeRemaining {
                                VStack(spacing: 4) {
                                    Text("ETR")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(formatTimeInterval(etr))
                                        .font(.system(.headline, design: .monospaced))
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                        .contentTransition(.numericText(countsDown: true))
                                        .animation(.easeInOut, value: Int(etr))
                                }
                            }

                            if let speed = progressState.processingSpeedMBps {
                                VStack(spacing: 4) {
                                    Text("SPEED")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.1f MB/s", speed))
                                        .font(.system(.headline, design: .monospaced))
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
                }
            }
            // All styling is now applied to the unified container VStack.
            .padding(.vertical, 40)
            .padding(.horizontal, 50)
            .background(
                RoundedRectangle(cornerRadius: 35, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 35, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.4), .white.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: .black.opacity(0.2), radius: 25, y: 10)
        }
    }

    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "--:--" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        if interval >= 3600 {
            formatter.allowedUnits = [.hour, .minute, .second]
        }
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: interval) ?? "--:--"
    }
}

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

    private var rowItems: [RowItem] {
        var items: [RowItem] = []
        let files = group.files
        var currentIndex = 0
        while currentIndex < files.count {
            let file = files[currentIndex]
            
            // Check if the current file and the next form a Live Photo pair
            let isPair = file.action.isLivePhotoPairPart && currentIndex + 1 < files.count && files[currentIndex + 1].action.isLivePhotoPairPart
            
            if isPair {
                let nextFile = files[currentIndex + 1]
                items.append(.pair(file, nextFile))
                currentIndex += 2
            } else {
                items.append(.single(file))
                currentIndex += 1
            }
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(group.groupName)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .padding([.horizontal, .top])

            if !group.groupName.starts(with: "Perfectly Paired") {
                 Divider().background(Color.primary.opacity(0.2)).padding(.horizontal)
            }

            ForEach(rowItems) { item in
                switch item {
                case .single(let file):
                    FileRowView(
                        file: file,
                        isSelected: file.id == selectedFile?.id,
                        onSelect: { self.selectedFile = file },
                        onUpdateUserAction: onUpdateUserAction
                    )
                    .padding(.horizontal)
                
                case .pair(let file1, let file2):
                    VStack(spacing: 0) {
                        FileRowView(
                            file: file1,
                            isSelected: file1.id == selectedFile?.id,
                            onSelect: { self.selectedFile = file1 },
                            onUpdateUserAction: onUpdateUserAction
                        )
                        .padding(.vertical, 4)
                        
                        FileRowView(
                            file: file2,
                            isSelected: file2.id == selectedFile?.id,
                            onSelect: { self.selectedFile = file2 },
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

extension FileAction {
    var reasonText: String {
        switch self {
        case .keepAsIs(let reason):
            return reason
        case .keepAndRename(let reason, _):
             return "\(reason) (rename to match video)"
        case .delete(let reason):
            return reason
        case .userKeep:
            return "Forced Keep by User"
        case .userDelete:
            return "Forced Deletion by User"
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

    var isLivePhotoPairPart: Bool {
        switch self {
        case .keepAndRename:
            return true
        case .keepAsIs(let reason):
            // A file is part of a pair if it's the video half of a rename-pair,
            // the image half of any pair, or if it's part of a "perfectly paired" group.
            return reason == "Largest Video" || reason == "Primary for Live Photo" || reason == "Perfectly Paired"
        default:
            return false
        }
    }
}

struct FooterView: View {
    let groups: [FileGroup]
    var onDelete: () -> Void
    var onGoHome: () -> Void

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
        
        VStack(spacing: 12) {
            Divider()
                .padding(.bottom, 8)

            if hasActions {
                VStack(spacing: 8) {
                    if !filesToDelete.isEmpty {
                        Text("Will delete \(filesToDelete.count) file(s), reclaiming \(ByteCountFormatter.string(fromByteCount: totalSizeToDelete, countStyle: .file)).")
                    }
                    if !filesToRename.isEmpty {
                        Text("Will repair \(filesToRename.count) file pair(s) by renaming.")
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("No redundant files found to clean or repair.")
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
                .foregroundColor(.primary)
            
            Text("Your folder is perfectly organized. No duplicates found.")
                .font(.title3)
                .foregroundColor(.secondary)
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
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(message, forType: .string)
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

// MARK: - Embedded Preview Pane

/// A typealias for a list of metadata items, making the data model flexible.
typealias FileMetadata = [(label: String, value: String, icon: String)]

/// A single row for displaying a piece of metadata.
struct MetadataRow: View {
    let label: String
    let value: String
    let icon: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .center)
            Text(label)
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundColor(.primary)
        }
    }
}

struct PreviewPane: View {
    let file: DisplayFile?
    @State private var metadata: FileMetadata?
    @State private var player: AVPlayer?
    @State private var metadataTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Use the file's ID for the transition, so it animates when the selection changes.
            if let file = file {
                VStack(spacing: 20) {
                    // Media View
                    mediaPlayerView(for: file.url)
                        // By constraining the max height of the media player, we break a potential
                        // layout cycle where the player's aspect ratio and the container's height
                        // depend on each other. This resolves the "AttributeGraph cycle" warnings.
                        .frame(maxHeight: 450)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                    
                    // Details Section
                    VStack(spacing: 12) {
                        Text(file.fileName)
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        
                        if case .keepAndRename(_, let newBaseName) = file.action {
                            let newFileName = newBaseName + "." + file.url.pathExtension
                            Text("Will be renamed to \(newFileName)")
                                .font(.subheadline)
                                .foregroundColor(.blue.opacity(0.9))
                        }
                        
                        if let metadata = metadata, !metadata.isEmpty {
                            VStack(spacing: 10) {
                                Divider()
                                ForEach(metadata, id: \.label) { item in
                                    MetadataRow(label: item.label, value: item.value, icon: item.icon)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
                .padding(.vertical, 20)
                .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                
            } else {
                ContentUnavailableView(label: "Select a file to preview", icon: "magnifyingglass")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.1))
        .onChange(of: file) { oldFile, newFile in
            // Cancel any existing task and start a new one for the new file.
            metadataTask?.cancel()
            updatePreview(for: newFile)
        }
        .onAppear {
            updatePreview(for: file)
        }
        .onDisappear {
            // When the view disappears, cancel any in-flight tasks and release the player.
            metadataTask?.cancel()
            player = nil
        }
    }
    
    private func updatePreview(for displayFile: DisplayFile?) {
        // When the file is nil, there's nothing to show.
        guard let url = displayFile?.url else {
            self.metadata = nil
            self.player = nil
            return
        }
        
        // Set up the player or clear it for images.
        if isVideo(url) {
            self.player = AVPlayer(url: url)
        } else {
            self.player = nil
        }
        
        // Launch a new, cancellable task to fetch metadata.
        metadataTask = Task {
            // Must check for nil again inside the task, as the file selection
            // could change rapidly.
            guard let displayFile = displayFile else { return }
            
            let newMetadata = await fetchMetadata(for: displayFile)
            
            // Before updating the UI, check if the task has been cancelled.
            if Task.isCancelled { return }
            
            await MainActor.run {
                self.metadata = newMetadata
            }
        }
    }
    
    @ViewBuilder
    private func mediaPlayerView(for url: URL) -> some View {
        if isVideo(url), let player = self.player {
            VideoPlayer(player: player)
                .aspectRatio(16/9, contentMode: .fit)
        } else if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            ContentUnavailableView(label: "Preview Unavailable", icon: "eye.slash.fill")
                .aspectRatio(16/9, contentMode: .fit)
        }
    }

    private func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .movie)
    }
    
    private func fetchMetadata(for file: DisplayFile) async -> FileMetadata {
        var details: FileMetadata = []
        
        // --- General Info (Always Available) ---
        details.append(("Size", ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file), "doc.text"))
        if let creationDate = (try? file.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
            details.append(("Created", creationDate.formatted(date: .long, time: .shortened), "calendar"))
        }

        // --- Media-Specific Info ---
        if isVideo(file.url) {
            if Task.isCancelled { return [] }
            let asset = AVAsset(url: file.url)
            
            // --- Load basic properties concurrently ---
            async let duration = try? asset.load(.duration).seconds
            async let track = try? asset.loadTracks(withMediaType: .video).first
            // Correctly load the common metadata collection.
            async let commonMetadata = try? await asset.load(.commonMetadata)

            if let duration = await duration, duration > 0 {
                 if Task.isCancelled { return [] }
                details.append(("Duration", formatDuration(duration), "clock"))
            }
            if let track = await track,
               let size = try? await track.load(.naturalSize) {
                 if Task.isCancelled { return [] }
                details.append(("Dimensions", "\(Int(size.width)) x \(Int(size.height))", "arrow.up.left.and.arrow.down.right"))
            }

            // --- Process rich common metadata ---
            if let metadataItems = await commonMetadata {
                for item in metadataItems {
                    if Task.isCancelled { return [] }
                    
                    // Corrected: The key is synchronous, only the value needs async loading.
                    guard let key = item.commonKey?.rawValue,
                          let value = try? await item.load(.stringValue) else {
                        continue
                    }

                    switch key {
                    case "make":
                        details.append(("Make", value, "hammer"))
                    case "model":
                        details.append(("Model", value, "camera.shutter.button"))
                    case "software":
                        details.append(("Software", value, "computermouse"))
                    case "creationDate":
                        // Often more accurate than file system date for videos.
                        // Attempt to find and replace the existing creation date if this one is more specific.
                        if let index = details.firstIndex(where: { $0.label == "Created" }) {
                            details[index] = ("Shot On", value, "camera")
                        } else {
                            details.append(("Shot On", value, "camera"))
                        }
                    default:
                        // You could add more cases here if needed, e.g., for "artist", "albumName", etc.
                        break
                    }
                }
            }
            
        } else if let imageSource = CGImageSourceCreateWithURL(file.url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            
            if Task.isCancelled { return [] }

            // --- Image Dimensions ---
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            if width > 0 && height > 0 {
                details.append(("Dimensions", "\(width) x \(height)", "arrow.up.left.and.arrow.down.right"))
            }

            // --- EXIF Data ---
            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                if let originalDate = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                    details.append(("Shot On", originalDate, "camera"))
                }
                if let lensModel = exif[kCGImagePropertyExifLensModel] as? String {
                    details.append(("Lens", lensModel, "camera.filters"))
                }
                if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
                     details.append(("Aperture", "ƒ/\(String(format: "%.1f", fNumber))", "camera.aperture"))
                }
                if let exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double {
                    details.append(("Exposure", "\(fractionalExposureTime(exposureTime))s", "timer"))
                }
                if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
                    details.append(("ISO", "\(iso)", "camera.metering.matrix"))
                }
            }

            // --- TIFF Data for Camera Model ---
            if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let make = tiff[kCGImagePropertyTIFFMake] as? String ?? ""
                let model = tiff[kCGImagePropertyTIFFModel] as? String ?? ""
                if !make.isEmpty || !model.isEmpty {
                    details.append(("Device", "\(make) \(model)".trimmingCharacters(in: .whitespaces), "camera.shutter.button"))
                }
            }
        }
        
        return details
    }

    private func fractionalExposureTime(_ exposureTime: Double) -> String {
        if exposureTime < 1.0 {
            return "1/\(Int(1.0 / exposureTime))"
        } else {
            return String(format: "%.2f", exposureTime)
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: interval) ?? "0:00"
    }
}

struct ContentUnavailableView: View {
    let label: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 60, weight: .thin))
                .foregroundColor(.secondary.opacity(0.3))
            
            Text(label)
                .font(.system(.title3, design: .rounded))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Window Configuration Helper
fileprivate struct WindowAccessor: NSViewRepresentable {
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

// MARK: - Asynchronous File Enumerator

/// Wraps FileManager.DirectoryEnumerator in an AsyncSequence to allow safe, responsive iteration in Swift 6 concurrency.
struct URLDirectoryAsyncSequence: AsyncSequence {
    typealias Element = URL

    let enumerator: FileManager.DirectoryEnumerator

    init?(url: URL, options: FileManager.DirectoryEnumerationOptions, resourceKeys: [URLResourceKey]?) {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: options
        ) else {
            return nil
        }
        self.enumerator = enumerator
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let enumerator: FileManager.DirectoryEnumerator

        mutating func next() async -> URL? {
            // nextObject() is a blocking call, but since this will be consumed
            // in a `for await` loop inside a background Task, it will yield
            // to the scheduler appropriately without blocking the UI thread.
            return enumerator.nextObject() as? URL
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(enumerator: enumerator)
    }
}

#if os(macOS)
// MARK: - Preview
#Preview {
    ContentView()
}
#endif

