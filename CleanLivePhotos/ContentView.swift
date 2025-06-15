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
    case scanning(progress: ScanningProgress)
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

    // State for paginated results display
    @State private var allResultGroups: [FileGroup] = []
    @State private var displayedResultGroups: [FileGroup] = []
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
                
            case .scanning(let progress):
                ScanningView(progressState: progress)
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
                                onLoadMore: loadMoreResults
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
                            onDelete: { executeCleaningPlan(for: allResultGroups) }
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
                VStack {
                    HStack {
                        Spacer()
                        CloseButton {
                            state = .welcome
                            // Reset results state
                            allResultGroups = []
                            displayedResultGroups = []
                        }
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            self.state = .scanning(progress: progress)
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
                    self.state = .scanning(progress: progress)
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
                        let progress = ScanningProgress(
                            phase: "Phase 2: Analyzing Content",
                            detail: url.lastPathComponent,
                            progress: progressVal,
                            totalFiles: totalFiles,
                            processedFiles: processedFilesCount,
                            estimatedTimeRemaining: etr,
                            processingSpeedMBps: nil // Speed calculation is complex in parallel; defer for simplicity
                        )
                        self.state = .scanning(progress: progress)
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
            self.state = .scanning(progress: progress)
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
            self.state = .scanning(progress: progress)
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
            self.state = .scanning(progress: progress)
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
            self.state = .scanning(progress: progress)
        }
        await Task.yield()

        // Iterate over a copy of the keys to avoid Swift 6 concurrency errors.
        // Sorting gives a deterministic order to the processing.
        let nameBasedKeys = nameBasedGroups.keys.sorted()
        for baseName in nameBasedKeys {
            guard let urls = nameBasedGroups[baseName] else { continue }

            if Task.isCancelled { await MainActor.run { state = .welcome }; return }
            
            var groupFiles: [DisplayFile] = []
            var images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false }
            var videos = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) ?? false }
            
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
                let bestImageBaseName = bestImage.deletingPathExtension().lastPathComponent
                let videoBaseName = bestVideo?.deletingPathExtension().lastPathComponent
                
                if let videoBaseName, bestImageBaseName != videoBaseName {
                    plan[bestImage] = .keepAndRename(reason: "Primary for Live Photo", newBaseName: videoBaseName)
                } else {
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

            if !groupFiles.isEmpty {
                // Sort pairs to the top, then sort alphabetically.
                groupFiles.sort { file1, file2 in
                    let isPair1 = file1.action.isLivePhotoPairPart
                    let isPair2 = file2.action.isLivePhotoPairPart

                    if isPair1 && !isPair2 { return true } // Pair parts come first
                    if !isPair1 && isPair2 { return false }

                    if isPair1 && isPair2 {
                        // Both are pair parts, sort video before image
                        let isVideo1 = UTType(filenameExtension: file1.url.pathExtension)?.conforms(to: .movie) ?? false
                        return isVideo1 // true if file1 is video, so it comes first
                    }

                    // Neither are pair parts, sort by name
                    return file1.fileName.localizedCaseInsensitiveCompare(file2.fileName) == .orderedAscending
                }
                finalGroups.append(FileGroup(groupName: baseName, files: groupFiles))
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
            self.state = .scanning(progress: progress)
        }
        
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s to show complete
        
        await MainActor.run {
            let sortedGroups = finalGroups.sorted {
                if $0.groupName.starts(with: "Content") && !$1.groupName.starts(with: "Content") { return true }
                if !$0.groupName.starts(with: "Content") && $1.groupName.starts(with: "Content") { return false }
                return $0.groupName.localizedCaseInsensitiveCompare($1.groupName) == .orderedAscending
            }
            
            self.showResults(groups: sortedGroups)
            let endTime = Date()
            print("Scan finished in \(endTime.timeIntervalSince(startTime)) seconds.")
        }
    }
    
    private func showResults(groups: [FileGroup]) {
        self.allResultGroups = groups
        self.displayedResultGroups = Array(groups.prefix(resultsPageSize))
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

    var body: some View {
        Spacer()
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
                        LinearGradient(gradient: Gradient(colors: [.white, Color(white: 0.85)]), startPoint: .top, endPoint: .bottom)
                    )
                    .rotationEffect(Angle(degrees: 270.0))
                    .animation(.linear(duration: 0.2), value: progressState.progress)
                    .shadow(color: .white.opacity(0.5), radius: 10)

                Text(String(format: "%.0f%%", min(progressState.progress, 1.0) * 100.0))
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .animation(.none, value: progressState.progress)
            }
            .frame(width: 180, height: 180)

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
                .padding(.top, 15)
            }
        }
        .padding(40)
        Spacer()
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
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(groups) { group in
                    FileGroupCard(
                        group: group,
                        selectedFile: $selectedFile
                    )
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

            Divider().background(Color.primary.opacity(0.2)).padding(.horizontal)

            ForEach(rowItems) { item in
                switch item {
                case .single(let file):
                    FileRowView(
                        file: file,
                        isSelected: file.id == selectedFile?.id,
                        onSelect: { self.selectedFile = file }
                    )
                    .padding(.horizontal)
                
                case .pair(let file1, let file2):
                    VStack(spacing: 0) {
                        FileRowView(
                            file: file1,
                            isSelected: file1.id == selectedFile?.id,
                            onSelect: { self.selectedFile = file1 }
                        )
                        .padding(.vertical, 4)
                        
                        FileRowView(
                            file: file2,
                            isSelected: file2.id == selectedFile?.id,
                            onSelect: { self.selectedFile = file2 }
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

    var isLivePhotoPairPart: Bool {
        switch self {
        case .keepAndRename:
            return true
        case .keepAsIs(let reason):
            // This is specific to the logic in perfectScan where the primary video of a pair is marked this way.
            return reason == "Largest Video"
        default:
            return false
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
                .padding(.top, 8)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("No redundant files found to clean or repair.")
                        .foregroundColor(.secondary)
                }
            }
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

struct PreviewPane: View {
    let file: DisplayFile?

    var body: some View {
        VStack {
            if let file = file {
                VStack {
                    Text(file.fileName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
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
                ContentUnavailableView(label: "Select a file to preview", icon: "magnifyingglass")
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
                .foregroundColor(.secondary.opacity(0.2))
            
            Text(label)
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.secondary.opacity(0.5))
        }
        Spacer()
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

