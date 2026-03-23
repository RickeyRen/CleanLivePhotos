import Foundation
import AVFoundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import CryptoKit

// MARK: - ScanEngine
// 纯计算引擎：所有方法均为 nonisolated（struct 默认），可在任意线程执行。
// 进度通过回调传出，由 ViewModel 在 @MainActor 上更新 UI。

struct ScanEngine {

    // MARK: - 进度回调类型
    typealias ProgressCallback = @Sendable (Int, String, Int) async -> Void
    // 参数：(completed, detail, totalFiles)

    typealias DiscoveryCallback = @Sendable (Int, String, Bool) async -> Void
    // 参数：(discovered, detail, isDiscovering)

    // MARK: - 阶段1: 文件发现

    func stage1_FileDiscovery(
        in directoryURL: URL,
        onDiscoveryProgress: @escaping DiscoveryCallback
    ) async throws -> [URL] {
        var allMediaFiles: [URL] = []
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .typeIdentifierKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]

        guard let sequence = URLDirectoryAsyncSequence(url: directoryURL, options: options, resourceKeys: resourceKeys) else {
            throw NSError(domain: "ScanError", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建文件枚举器"])
        }

        var discoveredCount = 0
        var lastUpdateTime = Date()
        let updateInterval: TimeInterval = 0.5

        await onDiscoveryProgress(0, "正在搜索媒体文件...", true)

        for await fileURL in sequence {
            if Task.isCancelled { throw CancellationError() }

            guard let typeIdentifier = try? fileURL.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
                  let fileType = UTType(typeIdentifier),
                  (fileType.conforms(to: .image) || fileType.conforms(to: .movie)) else {
                continue
            }

            allMediaFiles.append(fileURL)
            discoveredCount += 1

            let now = Date()
            if now.timeIntervalSince(lastUpdateTime) >= updateInterval {
                await onDiscoveryProgress(discoveredCount, "已发现 \(discoveredCount) 个媒体文件...", true)
                lastUpdateTime = now
            }
        }

        await onDiscoveryProgress(
            discoveredCount,
            "文件发现完成，共发现 \(discoveredCount) 个媒体文件",
            false
        )

        return allMediaFiles
    }

    // MARK: - 阶段2: 同目录 Live Photo 配对

    func stage2_SameDirectoryPairing(
        files: [URL],
        onProgress: @escaping ProgressCallback
    ) async throws -> PairingResult {
        var dirGroups: [String: LivePhotoSeedGroup] = [:]

        for (index, url) in files.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            let ext = url.pathExtension.lowercased()
            guard ext == "heic" || ext == "mov" else { continue }

            let dir  = url.deletingLastPathComponent().path
            let base = url.deletingPathExtension().lastPathComponent
            let key  = "\(dir)||||\(base)"

            if dirGroups[key] == nil {
                dirGroups[key] = LivePhotoSeedGroup(seedName: base)
            }
            if ext == "heic" { dirGroups[key]!.heicFiles.append(url) }
            else              { dirGroups[key]!.movFiles.append(url)  }

            if index % 20 == 0 {
                await onProgress(
                    index + 1,
                    "正在按目录配对 (\(index + 1)/\(files.count))...",
                    files.count
                )
                await Task.yield()
            }
        }

        var completePairs: [LivePhotoSeedGroup] = []
        var orphanHEICs: [URL] = []
        var orphanMOVs: [URL] = []

        for group in dirGroups.values {
            if group.hasCompletePair {
                completePairs.append(group)
            } else {
                orphanHEICs.append(contentsOf: group.heicFiles)
                orphanMOVs.append(contentsOf: group.movFiles)
            }
        }

        await onProgress(
            files.count,
            "同目录配对完成：\(completePairs.count) 对，孤立 HEIC \(orphanHEICs.count) 个，孤立 MOV \(orphanMOVs.count) 个",
            files.count
        )
        print("📝 Stage 2: \(completePairs.count) 完整对，\(orphanHEICs.count) 孤立HEIC，\(orphanMOVs.count) 孤立MOV")

        return PairingResult(completePairs: completePairs, orphanHEICs: orphanHEICs, orphanMOVs: orphanMOVs)
    }

    // MARK: - 阶段3: Content Identifier 跨目录孤立文件配对

    func stage3_ContentIDPairing(
        orphanHEICs: [URL],
        orphanMOVs: [URL],
        onProgress: @escaping ProgressCallback
    ) async throws -> (crossDirPairs: [LivePhotoSeedGroup], stillOrphanHEICs: [URL], stillOrphanMOVs: [URL]) {
        await onProgress(
            0,
            "正在读取 Content Identifier 配对跨目录 Live Photo...",
            orphanHEICs.count + orphanMOVs.count
        )

        var heicByContentID: [String: URL] = [:]
        await withTaskGroup(of: (String, URL)?.self) { group in
            for heic in orphanHEICs {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    guard let cid = readHEICContentIdentifier(heic) else { return nil }
                    return (cid, heic)
                }
            }
            var completed = 0
            for await result in group {
                if let (cid, heic) = result {
                    heicByContentID[cid] = heic
                }
                completed += 1
                if completed % 20 == 0 {
                    await onProgress(
                        completed,
                        "读取 HEIC Content ID (\(completed)/\(orphanHEICs.count))...",
                        orphanHEICs.count + orphanMOVs.count
                    )
                }
            }
        }

        var crossDirPairs: [LivePhotoSeedGroup] = []
        var matchedHEICs: Set<URL> = []
        var matchedMOVs: Set<URL> = []

        for (i, mov) in orphanMOVs.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            if let cid = await readMOVContentIdentifier(mov),
               let pairedHEIC = heicByContentID[cid] {
                var group = LivePhotoSeedGroup(seedName: pairedHEIC.deletingPathExtension().lastPathComponent)
                group.heicFiles = [pairedHEIC]
                group.movFiles  = [mov]
                let heicBase = pairedHEIC.deletingPathExtension().lastPathComponent
                let movBase  = mov.deletingPathExtension().lastPathComponent
                group.isSuspiciousPairing = heicBase != movBase
                crossDirPairs.append(group)
                matchedHEICs.insert(pairedHEIC)
                matchedMOVs.insert(mov)
                if group.isSuspiciousPairing {
                    print("⚠️ 可疑 Content ID 配对（文件名不一致）: \(pairedHEIC.lastPathComponent) ↔ \(mov.lastPathComponent)")
                } else {
                    print("🔗 Content ID 跨目录配对: \(pairedHEIC.lastPathComponent) ↔ \(mov.lastPathComponent)")
                }
            }
            if i % 5 == 0 {
                await onProgress(
                    orphanHEICs.count + i + 1,
                    "Content ID 配对 (\(i + 1)/\(orphanMOVs.count))...",
                    orphanHEICs.count + orphanMOVs.count
                )
                await Task.yield()
            }
        }

        let stillOrphanHEICs = orphanHEICs.filter { !matchedHEICs.contains($0) }
        let stillOrphanMOVs  = orphanMOVs.filter  { !matchedMOVs.contains($0) }

        print("🔗 Stage 3: Content ID 配对 \(crossDirPairs.count) 对，剩余孤立 \(stillOrphanHEICs.count + stillOrphanMOVs.count) 个")
        return (crossDirPairs: crossDirPairs, stillOrphanHEICs: stillOrphanHEICs, stillOrphanMOVs: stillOrphanMOVs)
    }

    // MARK: - 阶段3: 内容哈希扩展

    func stage3_ContentHashExpansion(
        seedGroups: [LivePhotoSeedGroup],
        allFiles: [URL],
        sha256Cache: inout [URL: String],
        onProgress: @escaping ProgressCallback
    ) async throws -> [ContentGroup] {
        await onProgress(0, "开始内容哈希扩展...", allFiles.count)

        var contentGroups: [ContentGroup] = []
        var processedFiles: Set<URL> = []

        var seedGroupHashes: [Int: Set<String>] = [:]
        var contentGroupsDict: [Int: ContentGroup] = [:]

        print("🔄 Phase 3 优化算法：预处理种子组...")
        for (groupIndex, seedGroup) in seedGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            let contentGroup = ContentGroup(seedGroup: seedGroup)
            var seedHashes: Set<String> = []

            for file in seedGroup.allFiles {
                do {
                    let hash: String
                    if let cachedHash = sha256Cache[file] {
                        hash = cachedHash
                        print("📋 使用SHA256缓存: \(file.lastPathComponent)")
                    } else {
                        hash = try calculateHash(for: file)
                        sha256Cache[file] = hash
                        print("🔢 计算SHA256 [\(sha256Cache.count)]: \(file.lastPathComponent)")
                    }
                    seedHashes.insert(hash)
                    processedFiles.insert(file)

                    await onProgress(
                        processedFiles.count,
                        "预处理种子组 (\(processedFiles.count)/\(allFiles.count) 文件)...",
                        allFiles.count
                    )

                    await Task.yield()
                } catch {
                    print("⚠️ 计算种子文件哈希失败: \(file.lastPathComponent) - \(error)")
                    processedFiles.insert(file)
                }
            }

            seedGroupHashes[groupIndex] = seedHashes
            contentGroupsDict[groupIndex] = contentGroup
        }

        let remainingFiles = allFiles.filter { !processedFiles.contains($0) }
        _ = remainingFiles.count
        var completedWork = 0

        print("🚀 Phase 3 优化算法：单次扫描 \(remainingFiles.count) 个文件...")

        for file in remainingFiles {
            if Task.isCancelled { throw CancellationError() }

            do {
                let fileHash: String
                if let cachedHash = sha256Cache[file] {
                    fileHash = cachedHash
                    print("📋 使用缓存 [\(sha256Cache.count)]: \(file.lastPathComponent)")
                } else {
                    fileHash = try calculateHash(for: file)
                    sha256Cache[file] = fileHash
                    print("🔢 新计算SHA256 [\(sha256Cache.count)]: \(file.lastPathComponent)")
                }

                for (groupIndex, seedHashes) in seedGroupHashes {
                    if seedHashes.contains(fileHash) {
                        contentGroupsDict[groupIndex]?.addContentMatch(file)
                        print("🔗 内容匹配: \(file.lastPathComponent) -> 组\(groupIndex + 1)")
                    }
                }

            } catch {
                print("⚠️ 计算文件哈希失败: \(file.lastPathComponent) - \(error)")
            }

            completedWork += 1

            if completedWork % 3 == 0 {
                await onProgress(
                    processedFiles.count + completedWork,
                    "单次扫描处理中 (\(completedWork)/\(remainingFiles.count) 文件)...",
                    allFiles.count
                )
                await Task.yield()
            }
        }

        for groupIndex in 0..<seedGroups.count {
            if let contentGroup = contentGroupsDict[groupIndex] {
                contentGroups.append(contentGroup)
            }
        }

        await onProgress(allFiles.count, "内容哈希扩展完成", allFiles.count)

        return contentGroups
    }

    // MARK: - 阶段3.2: SHA256跨组合并

    func stage3_2_CrossGroupSHA256Merging(
        contentGroups: [ContentGroup],
        sha256Cache: [URL: String],
        onProgress: @escaping ProgressCallback
    ) async throws -> [ContentGroup] {
        await onProgress(0, "正在扩展内容组...", contentGroups.count)

        print("🔍 开始SHA256跨组分析，检查 \(contentGroups.count) 个组...")

        var hashToFileGroups: [String: [URL]] = [:]
        var fileToOriginalGroup: [URL: Int] = [:]

        for (groupIndex, group) in contentGroups.enumerated() {
            for file in group.files {
                fileToOriginalGroup[file] = groupIndex

                if let fileHash = sha256Cache[file] {
                    if hashToFileGroups[fileHash] == nil {
                        hashToFileGroups[fileHash] = []
                    }
                    hashToFileGroups[fileHash]!.append(file)
                }
            }
        }

        let unionFind = UnionFind(size: contentGroups.count)
        var mergeCount = 0

        for (hash, filesWithSameHash) in hashToFileGroups {
            if filesWithSameHash.count > 1 {
                let groupIndices = Set(filesWithSameHash.compactMap { fileToOriginalGroup[$0] })
                if groupIndices.count > 1 {
                    let sortedIndices = Array(groupIndices).sorted()
                    let primaryGroup = sortedIndices[0]

                    for i in 1..<sortedIndices.count {
                        unionFind.union(primaryGroup, sortedIndices[i])
                        mergeCount += 1
                    }

                    print("🔗 哈希合并: \(hash.prefix(8))... 合并 \(groupIndices.count) 个组")
                }
            }
        }

        var rootToNewGroup: [Int: ContentGroup] = [:]
        var mergedGroups: [ContentGroup] = []
        var rootToMergedFilesSet: [Int: Set<URL>] = [:]

        for (originalIndex, originalGroup) in contentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            let root = unionFind.find(originalIndex)

            if let existingGroup = rootToNewGroup[root] {
                var mergedGroup = existingGroup
                var mergedFilesSet = rootToMergedFilesSet[root] ?? Set(existingGroup.files)
                for file in originalGroup.files {
                    if !mergedFilesSet.contains(file) {
                        mergedGroup.files.append(file)
                        mergedFilesSet.insert(file)
                        mergedGroup.relationships[file] = originalGroup.relationships[file] ?? .contentDuplicate
                    }
                }
                rootToNewGroup[root] = mergedGroup
                rootToMergedFilesSet[root] = mergedFilesSet
            } else {
                rootToNewGroup[root] = originalGroup
                rootToMergedFilesSet[root] = Set(originalGroup.files)
            }

            if originalIndex % 10 == 0 {
                await onProgress(
                    originalIndex + 1,
                    "正在扩展内容组 (\(originalIndex + 1)/\(contentGroups.count))...",
                    contentGroups.count
                )
                await Task.yield()
            }
        }

        mergedGroups = Array(rootToNewGroup.values)

        let originalCount = contentGroups.count
        let mergedCount = mergedGroups.count
        let savedGroups = originalCount - mergedCount

        print("🚀 SHA256跨组合并完成:")
        print("  原始组数: \(originalCount)")
        print("  合并后组数: \(mergedCount)")
        print("  减少组数: \(savedGroups) (节省 \(String(format: "%.1f", Double(savedGroups) / Double(max(originalCount, 1)) * 100))%)")
        print("  执行合并操作: \(mergeCount) 次")
        print("  估算减少pHash计算: ~\(savedGroups * (savedGroups + mergedCount)) 次")

        await onProgress(
            contentGroups.count,
            "SHA256跨组合并完成，减少 \(savedGroups) 个重复组",
            contentGroups.count
        )

        return mergedGroups
    }

    // MARK: - 阶段4: 感知哈希跨组相似性检测与合并

    func stage4_PerceptualSimilarity(
        contentGroups: [ContentGroup],
        allFiles: [URL],
        dHashCache: inout [URL: UInt64],
        onProgress: @escaping ProgressCallback
    ) async throws -> [ContentGroup] {
        await onProgress(
            0,
            "开始跨组感知相似性检测...",
            contentGroups.count * contentGroups.count
        )

        print("🔍 开始pHash跨组相似性分析，检查 \(contentGroups.count) 个组...")

        var mutableContentGroups = try await stage4_1_IntraGroupSimilarity(
            contentGroups: contentGroups,
            allFiles: allFiles,
            dHashCache: &dHashCache,
            onProgress: onProgress
        )

        mutableContentGroups = try await stage4_2_CrossGroupSimilarity(
            contentGroups: mutableContentGroups,
            dHashCache: dHashCache,
            onProgress: onProgress
        )

        await onProgress(
            contentGroups.count * contentGroups.count,
            "感知相似性检测和合并完成",
            contentGroups.count * contentGroups.count
        )

        return mutableContentGroups
    }

    // MARK: - 阶段4.1: 组内相似性扩展

    func stage4_1_IntraGroupSimilarity(
        contentGroups: [ContentGroup],
        allFiles: [URL],
        dHashCache: inout [URL: UInt64],
        onProgress: @escaping ProgressCallback
    ) async throws -> [ContentGroup] {
        await onProgress(0, "正在进行组内相似性扩展...", contentGroups.count)

        var mutableContentGroups = contentGroups
        var processedFiles: Set<URL> = []
        let SIMILARITY_THRESHOLD = ScannerConfig.intraGroupSimilarityThreshold

        for group in contentGroups {
            processedFiles.formUnion(group.files)
        }

        let remainingImageFiles = allFiles.filter { file in
            !processedFiles.contains(file) && isImageFile(file)
        }

        for (groupIndex, group) in mutableContentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            let imageFiles = group.files.filter { isImageFile($0) }

            for seedImage in imageFiles {
                guard let seedPHash = dHashCache[seedImage] else { continue }

                for remainingFile in remainingImageFiles {
                    if processedFiles.contains(remainingFile) { continue }

                    if let filePHash = dHashCache[remainingFile] {
                        let similarity = hammingDistance(seedPHash, filePHash)
                        if similarity <= SIMILARITY_THRESHOLD {
                            mutableContentGroups[groupIndex].addSimilarFile(remainingFile, similarity: similarity)
                            processedFiles.insert(remainingFile)
                            print("📎 组内扩展: \(remainingFile.lastPathComponent) -> 组\(groupIndex + 1) (差异度: \(similarity))")
                        }
                    }
                }
            }

            await onProgress(
                groupIndex,
                "组内扩展 (\(groupIndex + 1)/\(contentGroups.count))...",
                contentGroups.count
            )
        }

        return mutableContentGroups
    }

    // MARK: - 阶段4.2: 高性能pHash哈希桶合并算法

    func stage4_2_CrossGroupSimilarity(
        contentGroups: [ContentGroup],
        dHashCache: [URL: UInt64],
        onProgress: @escaping ProgressCallback
    ) async throws -> [ContentGroup] {
        await onProgress(0, "正在进行高性能跨组相似性分析...", contentGroups.count)

        print("🚀 启动高性能pHash哈希桶算法，分析 \(contentGroups.count) 个组...")

        let SIMILARITY_THRESHOLD = ScannerConfig.crossGroupSimilarityThreshold

        var hashBuckets: [UInt64: [Int]] = [:]
        var groupToRepresentativeHash: [Int: UInt64] = [:]

        for (groupIndex, group) in contentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            let imageFiles = group.files.filter { isImageFile($0) }

            for imageFile in imageFiles {
                if let hash = dHashCache[imageFile] {
                    groupToRepresentativeHash[groupIndex] = hash

                    let bucketKey = hash >> 16

                    if hashBuckets[bucketKey] == nil {
                        hashBuckets[bucketKey] = []
                    }
                    hashBuckets[bucketKey]!.append(groupIndex)
                    break
                }
            }

            await onProgress(
                groupIndex + 1,
                "构建哈希桶 (\(groupIndex + 1)/\(contentGroups.count))...",
                contentGroups.count
            )

            await Task.yield()
        }

        print("📊 哈希桶统计: \(hashBuckets.count) 个桶, 平均每桶 \(Double(contentGroups.count) / Double(max(hashBuckets.count, 1))) 个组")

        let unionFind = UnionFind(size: contentGroups.count)
        var totalComparisons = 0
        var mergeCount = 0
        var processedBuckets = 0

        for (_, groupIndices) in hashBuckets {
            if Task.isCancelled { throw CancellationError() }
            if groupIndices.count < 2 { continue }

            if groupIndices.count > ScannerConfig.maxGroupsPerBucketBeforeBatching {
                print("⚠️ 哈希桶过大: \(groupIndices.count) 个组，进行分批处理避免UI卡顿")
            }

            for i in 0..<groupIndices.count {
                for j in (i + 1)..<groupIndices.count {
                    let groupA = groupIndices[i]
                    let groupB = groupIndices[j]

                    guard let hashA = groupToRepresentativeHash[groupA],
                          let hashB = groupToRepresentativeHash[groupB] else { continue }

                    let distance = hammingDistance(hashA, hashB)
                    totalComparisons += 1

                    if distance <= SIMILARITY_THRESHOLD {
                        unionFind.union(groupA, groupB)
                        mergeCount += 1
                        print("✅ 桶内合并: 组\(groupA + 1) + 组\(groupB + 1) (差异度: \(distance))")
                    }

                    if totalComparisons % 5 == 0 {
                        await onProgress(
                            min(contentGroups.count, totalComparisons * 3),
                            "桶内精确比较 (已比较 \(totalComparisons) 对)...",
                            contentGroups.count * 4
                        )
                        await Task.yield()
                    }
                }
            }

            processedBuckets += 1

            await onProgress(
                min(contentGroups.count, processedBuckets * 5),
                "桶内比较进度 (\(processedBuckets)/\(hashBuckets.count) 桶)...",
                contentGroups.count * 4
            )
            await Task.yield()
        }

        let allBucketKeys = Array(hashBuckets.keys).sorted()
        let isLargeBucketSet = hashBuckets.count > ScannerConfig.maxBucketsForCrossBucketCheck

        let effectiveBucketKeys: [UInt64]
        if isLargeBucketSet {
            let sampleCount = max(40, Int(Double(allBucketKeys.count) * 0.02))
            effectiveBucketKeys = Array(allBucketKeys.shuffled().prefix(sampleCount))
            print("⚡ 跨桶检查：桶数 \(hashBuckets.count) > \(ScannerConfig.maxBucketsForCrossBucketCheck)，随机抽样 \(sampleCount) 个桶（覆盖率 \(String(format: "%.1f", Double(sampleCount) / Double(allBucketKeys.count) * 100))%）")
        } else {
            effectiveBucketKeys = allBucketKeys
        }

        print("🔍 执行跨桶高相似性检查（检查 \(effectiveBucketKeys.count) 个桶）...")

        for i in 0..<effectiveBucketKeys.count {
            for j in (i + 1)..<effectiveBucketKeys.count {
                let keyA = effectiveBucketKeys[i]
                let keyB = effectiveBucketKeys[j]

                let bucketDistance = hammingDistance(keyA, keyB)
                if bucketDistance <= 3 {
                    let groupsA = hashBuckets[keyA]!
                    let groupsB = hashBuckets[keyB]!

                    for groupA in groupsA.prefix(2) {
                        for groupB in groupsB.prefix(2) {
                            guard let hashA = groupToRepresentativeHash[groupA],
                                  let hashB = groupToRepresentativeHash[groupB] else { continue }

                            let distance = hammingDistance(hashA, hashB)
                            totalComparisons += 1

                            if distance <= SIMILARITY_THRESHOLD {
                                unionFind.union(groupA, groupB)
                                mergeCount += 1
                                print("✅ 跨桶合并: 组\(groupA + 1) + 组\(groupB + 1) (差异度: \(distance))")
                            }
                        }
                    }
                }
            }
            if i % 50 == 0 { await Task.yield() }
        }

        var rootToMergedGroup: [Int: ContentGroup] = [:]
        var rootToMergedFilesSetPhase4: [Int: Set<URL>] = [:]

        for (originalIndex, originalGroup) in contentGroups.enumerated() {
            let root = unionFind.find(originalIndex)

            if let existingGroup = rootToMergedGroup[root] {
                var mergedGroup = existingGroup
                var mergedFilesSet = rootToMergedFilesSetPhase4[root] ?? Set(existingGroup.files)
                for file in originalGroup.files {
                    if !mergedFilesSet.contains(file) {
                        mergedGroup.files.append(file)
                        mergedFilesSet.insert(file)
                        mergedGroup.relationships[file] = originalGroup.relationships[file] ?? .perceptualSimilar(hammingDistance: SIMILARITY_THRESHOLD)
                    }
                }
                rootToMergedGroup[root] = mergedGroup
                rootToMergedFilesSetPhase4[root] = mergedFilesSet
            } else {
                rootToMergedGroup[root] = originalGroup
                rootToMergedFilesSetPhase4[root] = Set(originalGroup.files)
            }
        }

        let finalGroups = Array(rootToMergedGroup.values)
        let originalCount = contentGroups.count
        let mergedCount = finalGroups.count
        let savedGroups = originalCount - mergedCount

        print("🚀 高性能pHash合并完成:")
        print("  原始组数: \(originalCount)")
        print("  合并后组数: \(mergedCount)")
        print("  哈希桶数: \(hashBuckets.count)")
        print("  总比较次数: \(totalComparisons) (节省 \(String(format: "%.1f", (1.0 - Double(totalComparisons) / Double(max(originalCount * (originalCount - 1) / 2, 1))) * 100))%)")
        print("  执行合并: \(mergeCount) 次")
        print("  减少组数: \(savedGroups)")

        return finalGroups
    }

    // MARK: - 高性能单文件重复检测

    func detectSingleFileDuplicates(
        allFiles: [URL],
        processedFiles: Set<URL>,
        sha256Cache: inout [URL: String],
        dHashCache: inout [URL: UInt64],
        onProgress: @escaping ProgressCallback
    ) async throws -> [ContentGroup] {
        let remainingFiles = allFiles.filter { !processedFiles.contains($0) }

        guard !remainingFiles.isEmpty else { return [] }

        print("🚀 开始高性能单文件重复检测：\(remainingFiles.count) 个文件")

        let sha256Groups = try await detectSHA256Duplicates(
            files: remainingFiles,
            sha256Cache: &sha256Cache,
            onProgress: onProgress
        )
        print("📊 SHA256重复检测完成：\(sha256Groups.count) 个重复组")

        let sha256MatchedFiles = Set(sha256Groups.flatMap { $0.files })
        let filesForPHash = remainingFiles.filter { !sha256MatchedFiles.contains($0) }
        let similarGroups = try await detectSimilarFiles(
            files: filesForPHash,
            dHashCache: &dHashCache,
            onProgress: onProgress
        )
        print("📊 相似性检测完成：\(similarGroups.count) 个相似组（已排除 \(sha256MatchedFiles.count) 个SHA256精确重复文件）")

        return sha256Groups + similarGroups
    }

    // MARK: - 高性能SHA256重复检测

    func detectSHA256Duplicates(
        files: [URL],
        sha256Cache: inout [URL: String],
        onProgress: @escaping ProgressCallback
    ) async throws -> [ContentGroup] {
        var hashToFiles: [String: [URL]] = [:]
        var processedCount = 0

        for file in files {
            if Task.isCancelled { throw CancellationError() }

            let hash: String
            if let cachedHash = sha256Cache[file] {
                hash = cachedHash
            } else {
                hash = try calculateHash(for: file)
                sha256Cache[file] = hash
            }

            if hashToFiles[hash] == nil {
                hashToFiles[hash] = []
            }
            hashToFiles[hash]!.append(file)

            processedCount += 1
            await onProgress(
                processedCount,
                "SHA256重复检测 (\(processedCount)/\(files.count) 文件)...",
                files.count
            )

            if processedCount % 5 == 0 {
                await Task.yield()
            }
        }

        var duplicateGroups: [ContentGroup] = []
        for (_, fileList) in hashToFiles where fileList.count > 1 {
            let primaryFile = fileList[0]
            var group = ContentGroup(singleFile: primaryFile)

            for file in fileList.dropFirst() {
                group.addIdenticalFile(file)
            }

            duplicateGroups.append(group)
            print("🔗 发现SHA256重复组: \(fileList.count) 个文件")
        }

        return duplicateGroups
    }

    // MARK: - 高性能pHash相似性检测

    func detectSimilarFiles(
        files: [URL],
        dHashCache: inout [URL: UInt64],
        onProgress: @escaping ProgressCallback
    ) async throws -> [ContentGroup] {
        let imageFiles = files.filter { isImageFile($0) }
        guard !imageFiles.isEmpty else { return [] }

        var fileToHash: [URL: UInt64] = [:]
        var processedCount = 0

        for file in imageFiles {
            if Task.isCancelled { throw CancellationError() }

            let hash: UInt64?
            if let cachedHash = dHashCache[file] {
                hash = cachedHash
            } else {
                do {
                    hash = try calculateDHash(for: file)
                    dHashCache[file] = hash
                } catch {
                    if let hashError = error as? HashCalculationError,
                       case .imageDecodingError = hashError {
                        hash = nil
                    } else {
                        print("⚠️ 单文件相似性检测pHash失败: \(file.lastPathComponent) - \(error)")
                        hash = nil
                    }
                }
            }

            if let validHash = hash {
                fileToHash[file] = validHash
            }

            processedCount += 1
            await onProgress(
                processedCount,
                "pHash相似性检测 (\(processedCount)/\(files.count) 文件)...",
                files.count
            )

            if processedCount % 5 == 0 {
                await Task.yield()
            }
        }

        return try await applySimilarityDetection(fileToHash: fileToHash)
    }

    // MARK: - 应用相似性检测算法

    func applySimilarityDetection(fileToHash: [URL: UInt64]) async throws -> [ContentGroup] {
        let SIMILARITY_THRESHOLD = ScannerConfig.singleFileSimilarityThreshold

        var hashBuckets: [UInt64: [URL]] = [:]
        for (file, hash) in fileToHash {
            let bucketKey = hash >> 16
            if hashBuckets[bucketKey] == nil {
                hashBuckets[bucketKey] = []
            }
            hashBuckets[bucketKey]!.append(file)
        }

        let fileArray = Array(fileToHash.keys)
        let fileToIndex = Dictionary(uniqueKeysWithValues: fileArray.enumerated().map { ($1, $0) })
        let unionFind = UnionFind(size: fileArray.count)

        for (_, filesInBucket) in hashBuckets where filesInBucket.count > 1 {
            for i in 0..<filesInBucket.count {
                for j in (i + 1)..<filesInBucket.count {
                    let fileA = filesInBucket[i]
                    let fileB = filesInBucket[j]

                    guard let hashA = fileToHash[fileA],
                          let hashB = fileToHash[fileB],
                          let indexA = fileToIndex[fileA],
                          let indexB = fileToIndex[fileB] else { continue }

                    let distance = hammingDistance(hashA, hashB)
                    if distance <= SIMILARITY_THRESHOLD {
                        unionFind.union(indexA, indexB)
                    }
                }
            }
            await Task.yield()
        }

        var rootToGroup: [Int: ContentGroup] = [:]
        for (index, file) in fileArray.enumerated() {
            let root = unionFind.find(index)

            if rootToGroup[root] == nil {
                rootToGroup[root] = ContentGroup(singleFile: file)
            } else {
                let hash = fileToHash[file]!
                let rootFile = fileArray[root]
                let rootHash = fileToHash[rootFile]!
                let similarity = hammingDistance(hash, rootHash)
                rootToGroup[root]!.addSimilarFile(file, similarity: similarity)
            }
        }

        return rootToGroup.values.filter { $0.files.count > 1 }.map { $0 }
    }

    // MARK: - 阶段5: 文件大小优选和分组

    func stage5_FileSizeOptimization(
        contentGroups: [ContentGroup],
        onProgress: @escaping ProgressCallback
    ) async throws -> (duplicatePlans: [CleaningPlan], cleanPlans: [CleaningPlan]) {
        await onProgress(0, "开始文件大小优选和分组...", contentGroups.count)

        var duplicatePlans: [CleaningPlan] = []
        var cleanPlans: [CleaningPlan] = []

        for (index, group) in contentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            var plan = CleaningPlan(groupName: group.seedName)
            plan.isSuspiciousPairing = group.isSuspiciousPairing

            switch group.groupType {
            case .livePhoto:
                let heicFiles = group.files.filter { $0.pathExtension.lowercased() == "heic" }
                let movFiles = group.files.filter { $0.pathExtension.lowercased() == "mov" }

                let isDuplicateGroup = group.files.count > 2 ||
                                       heicFiles.count > 1 ||
                                       movFiles.count > 1

                if isDuplicateGroup {
                    let bestHEIC = heicFiles.max { getFileSize($0) < getFileSize($1) }
                    let bestMOV = movFiles.max { getFileSize($0) < getFileSize($1) }

                    if let bestHEIC = bestHEIC {
                        let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(bestHEIC), countStyle: .file)
                        plan.keepFile(bestHEIC, reason: "最大HEIC文件 (\(sizeStr))")
                    }
                    if let bestMOV = bestMOV {
                        let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(bestMOV), countStyle: .file)
                        plan.keepFile(bestMOV, reason: "最大MOV文件 (\(sizeStr))")
                    }

                    for file in group.files {
                        if file != bestHEIC && file != bestMOV {
                            let reason = group.getRelationship(file)
                            plan.deleteFile(file, reason: reason)
                        }
                    }

                    duplicatePlans.append(plan)
                    print("📋 Live Photo重复组: \(group.seedName) (共\(group.files.count)个文件)")

                } else {
                    for file in group.files {
                        let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(file), countStyle: .file)
                        let fileType = file.pathExtension.uppercased()
                        plan.keepFile(file, reason: "干净的\(fileType)文件 (\(sizeStr))")
                    }

                    cleanPlans.append(plan)
                    print("✅ 干净Live Photo组: \(group.seedName) (完整Live Photo对)")
                }

            case .singleFile:
                if group.files.count > 1 {
                    let bestFile = group.files.max { getFileSize($0) < getFileSize($1) }!
                    let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(bestFile), countStyle: .file)
                    plan.keepFile(bestFile, reason: "最大文件 (\(sizeStr))")

                    for file in group.files {
                        if file != bestFile {
                            let reason = group.getRelationship(file)
                            plan.deleteFile(file, reason: reason)
                        }
                    }

                    duplicatePlans.append(plan)
                    print("📋 单文件重复组: \(group.seedName) (共\(group.files.count)个文件)")
                } else {
                    for file in group.files {
                        let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(file), countStyle: .file)
                        let fileType = file.pathExtension.uppercased()
                        plan.keepFile(file, reason: "单独\(fileType)文件 (\(sizeStr))")
                    }

                    cleanPlans.append(plan)
                    print("✅ 单独文件: \(group.seedName)")
                }
            }

            await onProgress(
                index + 1,
                "正在优选文件 (\(index + 1)/\(contentGroups.count))...",
                contentGroups.count
            )
        }

        print("📊 分组统计: 重复组 \(duplicatePlans.count) 个，干净组 \(cleanPlans.count) 个")
        return (duplicatePlans: duplicatePlans, cleanPlans: cleanPlans)
    }

    // MARK: - 阶段5（引擎1）：EXIF 质量评分优选 + 链接修复检测

    func stage5_QualityOptimization(
        contentGroups: [ContentGroup],
        onProgress: @escaping ProgressCallback
    ) async throws -> (duplicatePlans: [CleaningPlan], cleanPlans: [CleaningPlan]) {
        var duplicatePlans: [CleaningPlan] = []
        var cleanPlans: [CleaningPlan] = []

        for (index, group) in contentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            var plan = CleaningPlan(groupName: group.seedName)
            plan.isSuspiciousPairing = group.isSuspiciousPairing

            switch group.groupType {
            case .livePhoto:
                let heicFiles = group.files.filter { $0.pathExtension.lowercased() == "heic" }
                let movFiles  = group.files.filter { $0.pathExtension.lowercased() == "mov" }
                let isDuplicate = group.files.count > 2 || heicFiles.count > 1 || movFiles.count > 1

                if isDuplicate {
                    let scoredHEICs: [(URL, Double)] = heicFiles.map { heic in
                        let heicDir  = heic.deletingLastPathComponent()
                        let heicBase = heic.deletingPathExtension().lastPathComponent
                        let sameDirMOV = movFiles.first {
                            $0.deletingLastPathComponent() == heicDir &&
                            $0.deletingPathExtension().lastPathComponent == heicBase
                        }
                        let score = computeQualityScore(heicURL: heic, movURL: sameDirMOV)
                        return (heic, score.totalScore)
                    }
                    guard let bestHEIC = scoredHEICs.max(by: { a, b in
                        let diff = a.1 - b.1
                        if abs(diff) > 0.5 { return diff < 0 }
                        return a.0.path.count > b.0.path.count
                    })?.0 else {
                        continue
                    }

                    plan = CleaningPlan(groupName: bestHEIC.deletingPathExtension().lastPathComponent)
                    plan.isSuspiciousPairing = group.isSuspiciousPairing

                    let bestHEICDir  = bestHEIC.deletingLastPathComponent()
                    let bestHEICBase = bestHEIC.deletingPathExtension().lastPathComponent
                    let bestMOV: URL? = {
                        if let m = movFiles.first(where: {
                            $0.deletingLastPathComponent() == bestHEICDir &&
                            $0.deletingPathExtension().lastPathComponent == bestHEICBase
                        }) { return m }
                        if let m = movFiles.first(where: {
                            $0.deletingPathExtension().lastPathComponent == bestHEICBase
                        }) { return m }
                        return movFiles.max { getFileSize($0) < getFileSize($1) }
                    }()

                    let bestScore = scoredHEICs.first { $0.0 == bestHEIC }?.1 ?? 0
                    plan.keepFile(bestHEIC, reason: "EXIF质量最佳 (得分:\(Int(bestScore)))")

                    if let mov = bestMOV {
                        let movDir  = mov.deletingLastPathComponent()
                        let movBase = mov.deletingPathExtension().lastPathComponent
                        let sameDir  = movDir  == bestHEICDir
                        let sameName = movBase == bestHEICBase

                        if sameDir && sameName {
                            let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(mov), countStyle: .file)
                            plan.keepFile(mov, reason: "配对MOV (\(sizeStr))")
                        } else {
                            let targetURL = bestHEICDir
                                .appendingPathComponent(bestHEICBase)
                                .appendingPathExtension("MOV")
                            plan.moveFile(mov, to: targetURL, reason: "修复Live Photo链接")
                        }
                    }

                    for file in group.files where file != bestHEIC && file != bestMOV {
                        plan.deleteFile(file, reason: group.getRelationship(file))
                    }
                    duplicatePlans.append(plan)

                } else {
                    if let heic = heicFiles.first, let mov = movFiles.first {
                        let sameDir  = heic.deletingLastPathComponent() == mov.deletingLastPathComponent()
                        let sameName = heic.deletingPathExtension().lastPathComponent == mov.deletingPathExtension().lastPathComponent

                        plan.keepFile(heic, reason: "完整Live Photo对")
                        if sameDir && sameName {
                            let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(mov), countStyle: .file)
                            plan.keepFile(mov, reason: "配对MOV (\(sizeStr))")
                            cleanPlans.append(plan)
                        } else {
                            let targetURL = heic.deletingLastPathComponent()
                                .appendingPathComponent(heic.deletingPathExtension().lastPathComponent)
                                .appendingPathExtension("MOV")
                            plan.moveFile(mov, to: targetURL, reason: "修复Live Photo链接")
                            duplicatePlans.append(plan)
                        }
                    } else {
                        for file in group.files {
                            let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(file), countStyle: .file)
                            plan.keepFile(file, reason: "孤立\(file.pathExtension.uppercased()) (\(sizeStr))")
                        }
                        cleanPlans.append(plan)
                    }
                }

            case .singleFile:
                if group.files.count > 1 {
                    let bestFile = group.files.max { getFileSize($0) < getFileSize($1) }!
                    let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(bestFile), countStyle: .file)
                    plan.keepFile(bestFile, reason: "最大文件 (\(sizeStr))")
                    for file in group.files where file != bestFile {
                        plan.deleteFile(file, reason: group.getRelationship(file))
                    }
                    duplicatePlans.append(plan)
                } else {
                    for file in group.files {
                        let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(file), countStyle: .file)
                        plan.keepFile(file, reason: "单独\(file.pathExtension.uppercased()) (\(sizeStr))")
                    }
                    cleanPlans.append(plan)
                }
            }

            await onProgress(
                index + 1,
                "正在评分文件 (\(index + 1)/\(contentGroups.count))...",
                contentGroups.count
            )
        }

        print("📊 分组统计: 重复/修复组 \(duplicatePlans.count) 个，干净组 \(cleanPlans.count) 个")
        return (duplicatePlans: duplicatePlans, cleanPlans: cleanPlans)
    }

    // MARK: - 阶段5（引擎2）：相似照片全部标记为保留

    func stage5_SimilarPhotosAllKeep(
        contentGroups: [ContentGroup],
        onProgress: @escaping ProgressCallback
    ) async throws -> (duplicatePlans: [CleaningPlan], cleanPlans: [CleaningPlan]) {
        var duplicatePlans: [CleaningPlan] = []
        var cleanPlans: [CleaningPlan] = []

        for (index, group) in contentGroups.enumerated() {
            if Task.isCancelled { throw CancellationError() }

            var plan = CleaningPlan(groupName: group.seedName)
            plan.isSuspiciousPairing = group.isSuspiciousPairing
            let isSimilarGroup = group.files.count > 1

            for file in group.files {
                let sizeStr = ByteCountFormatter.string(fromByteCount: getFileSize(file), countStyle: .file)
                if isSimilarGroup {
                    plan.keepFile(file, reason: "相似照片（需手动审阅）— \(sizeStr)")
                } else {
                    plan.keepFile(file, reason: "独立照片 (\(sizeStr))")
                }
            }

            if isSimilarGroup {
                duplicatePlans.append(plan)
            } else {
                cleanPlans.append(plan)
            }

            await onProgress(
                index + 1,
                "正在整理相似组 (\(index + 1)/\(contentGroups.count))...",
                contentGroups.count
            )
        }

        return (duplicatePlans: duplicatePlans, cleanPlans: cleanPlans)
    }

    // MARK: - 预计算图片感知哈希

    @discardableResult
    func precomputeImageHashes(
        allFiles: [URL],
        dHashCache: inout [URL: UInt64],
        onProgress: @escaping ProgressCallback
    ) async throws -> Int {
        let imageFiles = allFiles.filter { isImageFile($0) }
        let processorCount = ProcessInfo.processInfo.processorCount
        let batchSize = min(max(processorCount * 2, 20), 50)

        await onProgress(0, "预计算图片感知哈希...", imageFiles.count)

        var completed = 0
        var failedCount = 0
        var failedFiles: [String] = []

        for batch in imageFiles.chunked(into: batchSize) {
            if Task.isCancelled { throw CancellationError() }

            try? await withThrowingTaskGroup(of: (URL, UInt64?).self) { group in
                for imageURL in batch {
                    if Task.isCancelled { throw CancellationError() }

                    if dHashCache[imageURL] != nil {
                        completed += 1
                        continue
                    }

                    group.addTask {
                        if Task.isCancelled { throw CancellationError() }
                        do {
                            let hash = try calculateDHash(for: imageURL)
                            return (imageURL, hash)
                        } catch {
                            if let hashError = error as? HashCalculationError,
                               case .imageDecodingError = hashError {
                                return (imageURL, nil)
                            } else {
                                print("⚠️ 预计算pHash失败: \(imageURL.lastPathComponent) - \(error)")
                                return (imageURL, nil)
                            }
                        }
                    }
                }

                for try await (url, hash) in group {
                    if Task.isCancelled { throw CancellationError() }

                    if let hash = hash {
                        dHashCache[url] = hash
                    } else {
                        failedCount += 1
                        if failedFiles.count < 10 {
                            failedFiles.append(url.lastPathComponent)
                        }
                    }
                    completed += 1

                    await onProgress(
                        completed,
                        "预计算pHash (\(completed)/\(imageFiles.count))...",
                        imageFiles.count
                    )
                }
            }

            await Task.yield()
        }

        if failedCount > 0 {
            print("ℹ️ pHash 跳过统计: \(failedCount)/\(imageFiles.count) 个文件无法计算感知哈希")
            if !failedFiles.isEmpty {
                print("   示例文件: \(failedFiles.joined(separator: ", "))\(failedCount > 10 ? " 等..." : "")")
            }
            print("   原因：这些文件不会参与视觉相似度检测，但仍会通过 SHA256 检测完全重复")
        }

        return failedCount
    }
}
