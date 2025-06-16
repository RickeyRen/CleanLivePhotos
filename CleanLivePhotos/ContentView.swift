import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

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
            #if os(macOS)
            WindowAccessor()
            #endif

            switch state {
            case .welcome:
                WelcomeView(onScan: { handleScanRequest() })
                
            case .scanning(let progress, let animationRate):
                ScanningView(progressState: progress, animationRate: animationRate)
                
            case .results:
                VStack(spacing: 0) {
                    if displayedResultGroups.isEmpty {
                        NoResultsView(onStartOver: resetToWelcomeState)
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
        #if os(macOS)
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
        #endif
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
        #if os(macOS)
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
        #endif
        
        if Task.isCancelled { await MainActor.run { state = .welcome }; return }
        
        let totalFiles = allMediaFileURLs.count

        // --- PHASE 2: HASHING & CONTENT DUPLICATE DETECTION ---
        let hashingProgressStart = 0.0
        let hashingProgressEnd = 0.5
        
        var urlToHashMap: [URL: String] = [:]
        var hashToFileURLs: [String: [URL]] = [:]
        
        // --- PHASE 2.5: Parallel Hashing with TaskGroup ---
        let hashingStartTime = Date()
        var lastUIUpdateTime = Date()
        var processedFilesCount = 0
        
        // Bounded concurrency: Limit hashing tasks to the number of processor cores
        // to avoid overwhelming the system when dealing with tens of thousands of files.
        #if os(macOS)
        let concurrencyLimit = ProcessInfo.processInfo.activeProcessorCount
        #else
        let concurrencyLimit = 2
        #endif
        
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
                    urlToHashMap[url] = hash
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
        let analysisProgressEnd = 1.0
        
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
            finalGroups.append(FileGroup(groupName: "Content Duplicates: \(hash)", files: groupFiles))
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
            
            #if os(macOS)
            var images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false }
            var videos = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) ?? false }
            #else
            // A simplified logic for non-macOS platforms
            var images = urls.filter { $0.pathExtension.lowercased() == "heic" || $0.pathExtension.lowercased() == "jpg" || $0.pathExtension.lowercased() == "png" }
            var videos = urls.filter { $0.pathExtension.lowercased() == "mov" }
            #endif
            
            // A group is only interesting for name-based analysis if it's a potential Live Photo pair,
            // meaning it must contain AT LEAST one image AND one video file.
            // If not, it's just a collection of unrelated files with similar names, which we should ignore.
            // Content-based duplicates are handled separately by the hashing phase.
            guard !images.isEmpty && !videos.isEmpty else {
                continue
            }
            
            // Check for perfect, non-actionable Live Photo pairs first.
            // A pair is "perfect" if there's one of each and their names (sans extension) are identical.
            if images.count == 1,
               videos.count == 1,
               images[0].deletingPathExtension().lastPathComponent == videos[0].deletingPathExtension().lastPathComponent {
                
                let image = images[0]
                let video = videos.first!
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
                
                // Mark all other videos in the group for deletion.
                for videoToDelete in videos.dropFirst() {
                    plan[videoToDelete] = .delete(reason: "Smaller Video Version")
                    processedURLs.insert(videoToDelete)
                    groupFiles.append(DisplayFile(url: videoToDelete, size: videoToDelete.fileSize ?? 0, action: plan[videoToDelete]!))
                }
            }
            
            if let bestImage {
                if let bestVideo {
                    // Live Photo pair situation
                    let bestImageBaseName = bestImage.deletingPathExtension().lastPathComponent
                    let videoBaseName = bestVideo.deletingPathExtension().lastPathComponent
                    if bestImageBaseName != videoBaseName {
                        plan[bestImage] = .keepAndRename(reason: "Primary for Live Photo", newBaseName: videoBaseName)
                    } else {
                        plan[bestImage] = .keepAsIs(reason: "Primary for Live Photo")
                    }
                } else {
                    plan[bestImage] = .keepAsIs(reason: "Largest Image")
                }
                processedURLs.insert(bestImage)
                groupFiles.append(DisplayFile(url: bestImage, size: bestImage.fileSize ?? 0, action: plan[bestImage]!))
                
                // The final, correct logic:
                // Delete other images ONLY IF they have the same extension as the best one.
                // Keep them if the extension is different (e.g., a JPG alongside a HEIC).
                let bestImageExtension = bestImage.pathExtension.lowercased()
                for imageToDelete in images.dropFirst() {
                    if imageToDelete.pathExtension.lowercased() == bestImageExtension {
                        plan[imageToDelete] = .delete(reason: "Smaller Image Version")
                    } else {
                        plan[imageToDelete] = .keepAsIs(reason: "Unique file with similar name")
                    }
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
                    #if os(macOS)
                    if isPair1 && isPair2 {
                        let isVideo1 = UTType(filenameExtension: file1.url.pathExtension)?.conforms(to: .movie) ?? false
                        return isVideo1
                    }
                    #endif
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

            var sortedGroups = finalGroups.sorted { g1, g2 in
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
            
            // Pre-process all groups to turn their file lists into display-ready rows.
            // This is the core of the performance optimization.
            for i in 0..<sortedGroups.count {
                sortedGroups[i].rows = self.createRows(from: sortedGroups[i].files)
            }
            
            self.showResults(groups: sortedGroups)
            let endTime = Date()
            print("Scan finished in \(endTime.timeIntervalSince(startTime)) seconds.")
        }
    }
    
    /// Pre-processes a list of files into a list of display-ready rows.
    private func createRows(from files: [DisplayFile]) -> [ResultRow] {
        var items: [ResultRow] = []
        var remainingFiles = files.sorted { $0.fileName < $1.fileName }

        while !remainingFiles.isEmpty {
            let file1 = remainingFiles.removeFirst()

            // Try to find a Live Photo pair for the current file.
            if let pairIndex = remainingFiles.firstIndex(where: { file2 in
                // A valid pair must have one .mov and one image, and the base names must match.
                let f1IsMov = file1.url.pathExtension.lowercased() == "mov"
                let f2IsMov = file2.url.pathExtension.lowercased() == "mov"
                let f1IsImage = UTType(filenameExtension: file1.url.pathExtension)?.conforms(to: .image) ?? false
                let f2IsImage = UTType(filenameExtension: file2.url.pathExtension)?.conforms(to: .image) ?? false

                let baseName1 = file1.url.deletingPathExtension().lastPathComponent
                let baseName2 = file2.url.deletingPathExtension().lastPathComponent

                return (f1IsMov && f2IsImage || f1IsImage && f2IsMov) && baseName1 == baseName2
            }) {
                let file2 = remainingFiles.remove(at: pairIndex)
                let movFile = file1.url.pathExtension.lowercased() == "mov" ? file1 : file2
                let heicFile = file1.url.pathExtension.lowercased() != "mov" ? file1 : file2
                items.append(.pair(mov: movFile, heic: heicFile))
            } else {
                items.append(.single(file1))
            }
        }
        return items
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
        let cleanName = name.replacingOccurrences(of: "(?:[ _-](?:copy|\\d{1,2})| \\(\\d+\\)|_v\\d{1,2})$", with: "", options: [.regularExpression, .caseInsensitive])
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


#if os(macOS)
// MARK: - Preview
#Preview {
    ContentView()
}
#endif 