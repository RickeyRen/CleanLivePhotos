import XCTest
import Foundation
import CryptoKit
@testable import CleanLivePhotos

// MARK: - 测试辅助工具

private func createTempFile(
    name: String,
    content: Data,
    in dir: URL
) throws -> URL {
    let fileURL = dir.appendingPathComponent(name)
    try content.write(to: fileURL)
    return fileURL
}

private func withTempDirectory(_ body: (URL) async throws -> Void) async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CleanLivePhotosTests_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try await body(tempDir)
}

// MARK: - SHA256 哈希安全测试

class SHA256SafetyTests: XCTestCase {

    func testIdenticalFilesProduceSameHash() async throws {
        try await withTempDirectory { dir in
            let content = Data("Hello, Live Photos!".utf8)
            let fileA = try createTempFile(name: "a.heic", content: content, in: dir)
            let fileB = try createTempFile(name: "b.heic", content: content, in: dir)
            let hashA = try calculateHash(for: fileA)
            let hashB = try calculateHash(for: fileB)
            XCTAssertEqual(hashA, hashB, "内容完全相同的两个文件应产生相同 SHA256")
        }
    }

    func testDifferentFilesProduceDifferentHash() async throws {
        try await withTempDirectory { dir in
            let fileA = try createTempFile(name: "a.heic", content: Data("File A content".utf8), in: dir)
            let fileB = try createTempFile(name: "b.heic", content: Data("File B content".utf8), in: dir)
            let hashA = try calculateHash(for: fileA)
            let hashB = try calculateHash(for: fileB)
            XCTAssertNotEqual(hashA, hashB, "内容不同的文件不应产生相同哈希")
        }
    }

    /// 核心安全测试：3MB 文件头尾相同、中间不同 → 必须产生不同哈希
    /// 旧代码只哈希头尾 1MB 会误判为重复（BUG），新代码哈希全文件（< 50MB）
    func testLargeFilesWithSameBoundariesButDifferentMiddleAreNotDuplicates() async throws {
        try await withTempDirectory { dir in
            let oneMB = 1024 * 1024
            let prefix = Data(repeating: 0xAA, count: oneMB)
            let suffix = Data(repeating: 0xBB, count: oneMB)

            var contentA = Data()
            contentA.append(prefix)
            contentA.append(Data(repeating: 0x11, count: oneMB))
            contentA.append(suffix)

            var contentB = Data()
            contentB.append(prefix)
            contentB.append(Data(repeating: 0x22, count: oneMB))
            contentB.append(suffix)

            XCTAssertNotEqual(contentA, contentB, "测试数据应确实不同")
            XCTAssertEqual(contentA.count, 3 * oneMB)

            let fileA = try createTempFile(name: "photo_A.heic", content: contentA, in: dir)
            let fileB = try createTempFile(name: "photo_B.heic", content: contentB, in: dir)

            let hashA = try calculateHash(for: fileA)
            let hashB = try calculateHash(for: fileB)

            XCTAssertNotEqual(hashA, hashB,
                "安全漏洞！头尾相同、中间不同的文件被哈希为相同值，会导致误删用户数据！")
        }
    }

    func testFilesWithDifferentSizesProduceDifferentHash() async throws {
        try await withTempDirectory { dir in
            let oneMB = 1024 * 1024
            let prefix = Data(repeating: 0xAA, count: oneMB)
            let suffix = Data(repeating: 0xBB, count: oneMB)

            var contentA = Data()
            contentA.append(prefix)
            contentA.append(suffix)

            var contentB = Data()
            contentB.append(prefix)
            contentB.append(Data(repeating: 0xCC, count: 100 * 1024))
            contentB.append(suffix)

            let fileA = try createTempFile(name: "small.heic", content: contentA, in: dir)
            let fileB = try createTempFile(name: "large.heic", content: contentB, in: dir)

            let hashA = try calculateHash(for: fileA)
            let hashB = try calculateHash(for: fileB)
            XCTAssertNotEqual(hashA, hashB, "大小不同的文件不应产生相同哈希")
        }
    }

    func testSmallFilesHashCorrectly() async throws {
        try await withTempDirectory { dir in
            let smallContent = Data(repeating: 0x42, count: 512 * 1024)
            let fileA = try createTempFile(name: "small_a.heic", content: smallContent, in: dir)
            let fileB = try createTempFile(name: "small_b.heic", content: smallContent, in: dir)
            let fileC = try createTempFile(name: "small_c.heic",
                                           content: Data(repeating: 0x43, count: 512 * 1024), in: dir)

            let hashA = try calculateHash(for: fileA)
            let hashB = try calculateHash(for: fileB)
            let hashC = try calculateHash(for: fileC)

            XCTAssertEqual(hashA, hashB, "相同小文件应有相同哈希")
            XCTAssertNotEqual(hashA, hashC, "不同小文件应有不同哈希")
        }
    }

    func testUnreadableFileThrowsError() async throws {
        try await withTempDirectory { dir in
            let fileURL = dir.appendingPathComponent("nonexistent.heic")
            XCTAssertThrowsError(try calculateHash(for: fileURL)) { error in
                XCTAssertTrue(error is HashCalculationError, "应抛出 HashCalculationError，实际: \(error)")
            }
        }
    }
}

// MARK: - 汉明距离测试

class HammingDistanceTests: XCTestCase {

    func testSameHashDistanceIsZero() {
        let hash: UInt64 = 0xDEADBEEFCAFEBABE
        XCTAssertEqual(hammingDistance(hash, hash), 0)
    }

    func testOppositeHashDistanceIs64() {
        XCTAssertEqual(hammingDistance(UInt64.min, UInt64.max), 64)
        XCTAssertEqual(hammingDistance(0x0000000000000000, 0xFFFFFFFFFFFFFFFF), 64)
    }

    func testKnownDistanceCalculations() {
        XCTAssertEqual(hammingDistance(0b0000, 0b0001), 1, "最低位不同 → 距离 1")
        XCTAssertEqual(hammingDistance(0b0000, 0b0011), 2, "低 2 位不同 → 距离 2")
        XCTAssertEqual(hammingDistance(0x00, 0xFF), 8, "8 位全不同 → 距离 8")
    }

    func testDistanceIsSymmetric() {
        let a: UInt64 = 0xABCDEF0123456789
        let b: UInt64 = 0x9876543210FEDCBA
        XCTAssertEqual(hammingDistance(a, b), hammingDistance(b, a))
    }

    func testSimilarityThresholdBoundaries() {
        let base: UInt64 = 0
        let atSingleFileThreshold: UInt64 = 0x00000000000000FF
        XCTAssertEqual(hammingDistance(base, atSingleFileThreshold), 8)
        XCTAssertLessThanOrEqual(hammingDistance(base, atSingleFileThreshold),
                                 ScannerConfig.singleFileSimilarityThreshold)

        let aboveThreshold: UInt64 = 0x00000000000001FF
        XCTAssertEqual(hammingDistance(base, aboveThreshold), 9)
        XCTAssertGreaterThan(hammingDistance(base, aboveThreshold),
                             ScannerConfig.singleFileSimilarityThreshold)
    }
}

// MARK: - Union-Find 并查集测试

class UnionFindTests: XCTestCase {

    func testInitialStateEachElementIsOwnRoot() {
        let uf = UnionFind(size: 5)
        for i in 0..<5 {
            XCTAssertEqual(uf.find(i), i, "初始状态下元素 \(i) 的根应为自身")
            for j in 0..<5 where j != i {
                XCTAssertFalse(uf.connected(i, j), "初始状态下 \(i) 和 \(j) 不应连通")
            }
        }
    }

    func testUnionMakesTwoElementsConnected() {
        let uf = UnionFind(size: 5)
        uf.union(1, 3)
        XCTAssertTrue(uf.connected(1, 3))
        XCTAssertTrue(uf.connected(3, 1))
        XCTAssertFalse(uf.connected(0, 1))
    }

    func testTransitiveConnectivity() {
        let uf = UnionFind(size: 4)
        uf.union(0, 1)
        uf.union(1, 2)
        XCTAssertTrue(uf.connected(0, 2), "传递性：0-1 且 1-2 则 0-2 应连通")
        XCTAssertFalse(uf.connected(0, 3), "未参与合并的元素不应连通")
    }

    func testRepeatedUnionIsIdempotent() {
        let uf = UnionFind(size: 3)
        uf.union(0, 1)
        uf.union(0, 1)
        uf.union(1, 0)
        XCTAssertTrue(uf.connected(0, 1))
        XCTAssertFalse(uf.connected(1, 2))
    }

    func testLargeScaleMergeCorrectness() {
        let size = 100
        let uf = UnionFind(size: size)
        for i in stride(from: 0, to: size - 2, by: 2) { uf.union(i, i + 2) }
        for i in stride(from: 1, to: size - 2, by: 2) { uf.union(i, i + 2) }

        XCTAssertTrue(uf.connected(0, 98), "偶数组内应连通")
        XCTAssertTrue(uf.connected(2, 50), "偶数组内应连通")
        XCTAssertTrue(uf.connected(1, 99), "奇数组内应连通")
        XCTAssertFalse(uf.connected(0, 1), "奇偶不应连通")
    }
}

// MARK: - SHA256 重复检测逻辑测试

class SHA256DuplicateDetectionTests: XCTestCase {

    func testIdenticalFilesDetectedAsDuplicates() throws {
        let content = Data("Duplicate file content for testing".utf8)
        let hashA = try contentHash(content)
        let hashB = try contentHash(content)
        XCTAssertEqual(hashA, hashB, "相同内容应产生相同哈希")
    }

    func testDifferentFilesNotFalselyDetectedAsDuplicates() throws {
        let contentA = Data("Photo from Monday, content A, unique data 1234567890".utf8)
        let contentB = Data("Photo from Tuesday, content B, unique data 0987654321".utf8)
        let hashA = try contentHash(contentA)
        let hashB = try contentHash(contentB)
        XCTAssertNotEqual(hashA, hashB, "不同内容的文件不应被误识别为重复")
    }

    func testLargeFileFalsePositivePrevention() async throws {
        try await withTempDirectory { dir in
            let oneMB = 1024 * 1024
            let prefix = Data(repeating: 0xAA, count: oneMB)
            let suffix = Data(repeating: 0xBB, count: oneMB)

            var contentA = Data()
            contentA.append(prefix)
            contentA.append(Data(repeating: 0x11, count: oneMB))
            contentA.append(suffix)

            var contentB = Data()
            contentB.append(prefix)
            contentB.append(Data(repeating: 0x22, count: oneMB))
            contentB.append(suffix)

            let fileA = try createTempFile(name: "photo_a.heic", content: contentA, in: dir)
            let fileB = try createTempFile(name: "photo_b.heic", content: contentB, in: dir)

            let hashA = try calculateHash(for: fileA)
            let hashB = try calculateHash(for: fileB)
            XCTAssertNotEqual(hashA, hashB,
                "3MB 文件（头尾相同、中间不同）应被识别为不同文件，否则会误删用户数据！")
        }
    }

    func testHashIsDeterministic() async throws {
        try await withTempDirectory { dir in
            let content = Data(repeating: 0x42, count: 100 * 1024)
            let file = try createTempFile(name: "deterministic.heic", content: content, in: dir)
            let hash1 = try calculateHash(for: file)
            let hash2 = try calculateHash(for: file)
            let hash3 = try calculateHash(for: file)
            XCTAssertEqual(hash1, hash2)
            XCTAssertEqual(hash2, hash3)
        }
    }

    private func contentHash(_ data: Data) throws -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}

// MARK: - ScannerConfig 阈值一致性测试

class ScannerConfigTests: XCTestCase {

    func testThresholdHierarchyIsCorrect() {
        let single = ScannerConfig.singleFileSimilarityThreshold
        let crossGroup = ScannerConfig.crossGroupSimilarityThreshold
        let intraGroup = ScannerConfig.intraGroupSimilarityThreshold
        XCTAssertLessThanOrEqual(single, crossGroup, "单文件阈值应 ≤ 跨组阈值（单文件更严格）")
        XCTAssertLessThanOrEqual(crossGroup, intraGroup, "跨组阈值应 ≤ 组内阈值（跨组更严格）")
    }

    func testThresholdsAreInValidRange() {
        XCTAssertGreaterThanOrEqual(ScannerConfig.singleFileSimilarityThreshold, 0)
        XCTAssertLessThanOrEqual(ScannerConfig.singleFileSimilarityThreshold, 64)
        XCTAssertGreaterThanOrEqual(ScannerConfig.crossGroupSimilarityThreshold, 0)
        XCTAssertLessThanOrEqual(ScannerConfig.crossGroupSimilarityThreshold, 64)
        XCTAssertGreaterThanOrEqual(ScannerConfig.intraGroupSimilarityThreshold, 0)
        XCTAssertLessThanOrEqual(ScannerConfig.intraGroupSimilarityThreshold, 64)
    }

    func testThresholdsAreNotTooPermissive() {
        XCTAssertLessThanOrEqual(ScannerConfig.intraGroupSimilarityThreshold, 20,
            "组内阈值过高会导致不相关照片被误归为同一组")
        XCTAssertLessThanOrEqual(ScannerConfig.singleFileSimilarityThreshold, 15,
            "单文件阈值过高会导致不同照片被误判为重复并删除")
    }
}

// MARK: - 文件系统安全测试（防误删核心测试）

class FileSafetyTests: XCTestCase {

    func testUniqueFilesAreNeverMarkedForDeletion() async throws {
        try await withTempDirectory { dir in
            let fileA = try createTempFile(name: "unique_a.heic",
                content: Data("Unique A - this is special content 111".utf8), in: dir)
            let fileB = try createTempFile(name: "unique_b.heic",
                content: Data("Unique B - completely different 222".utf8), in: dir)
            let fileC = try createTempFile(name: "unique_c.heic",
                content: Data("Unique C - another different file 333".utf8), in: dir)

            let hashA = try calculateHash(for: fileA)
            let hashB = try calculateHash(for: fileB)
            let hashC = try calculateHash(for: fileC)

            XCTAssertNotEqual(hashA, hashB)
            XCTAssertNotEqual(hashB, hashC)
            XCTAssertNotEqual(hashA, hashC)

            let hashToFiles: [String: [URL]] = [hashA: [fileA], hashB: [fileB], hashC: [fileC]]
            let duplicateGroups = hashToFiles.filter { $0.value.count > 1 }
            XCTAssertTrue(duplicateGroups.isEmpty, "三个唯一文件不应形成任何重复组")
        }
    }

    func testSHA256DuplicateDetectionOnlyFlagsRealDuplicates() async throws {
        try await withTempDirectory { dir in
            let duplicateContent = Data("This file has been copied!".utf8)
            let uniqueContent = Data("This file is unique and should never be deleted!".utf8)

            let dup1 = try createTempFile(name: "dup1.heic", content: duplicateContent, in: dir)
            let dup2 = try createTempFile(name: "dup2.heic", content: duplicateContent, in: dir)
            let unique = try createTempFile(name: "unique.heic", content: uniqueContent, in: dir)

            let hashDup1 = try calculateHash(for: dup1)
            let hashDup2 = try calculateHash(for: dup2)
            let hashUnique = try calculateHash(for: unique)

            XCTAssertEqual(hashDup1, hashDup2, "重复文件应有相同哈希")
            XCTAssertNotEqual(hashDup1, hashUnique, "唯一文件不应与重复文件有相同哈希")

            var hashToFiles: [String: [URL]] = [:]
            for (file, hash) in [(dup1, hashDup1), (dup2, hashDup2), (unique, hashUnique)] {
                hashToFiles[hash, default: []].append(file)
            }

            let duplicateGroups = hashToFiles.filter { $0.value.count > 1 }
            let uniqueGroups = hashToFiles.filter { $0.value.count == 1 }

            XCTAssertEqual(duplicateGroups.count, 1, "应检测到 1 个重复组")
            XCTAssertEqual(uniqueGroups.count, 1, "应有 1 个唯一文件组")

            let allFilesInDuplicateGroups = duplicateGroups.values.flatMap { $0 }
            XCTAssertFalse(allFilesInDuplicateGroups.contains(unique), "唯一文件不应出现在任何重复组中！")
        }
    }

    func testCleaningPlanAlwaysKeepsAtLeastOneFile() {
        var plan = CleaningPlan(groupName: "test_group")
        let urls = (1...5).map { URL(fileURLWithPath: "/test/file\($0).heic") }

        plan.keepFile(urls[4], reason: "最大文件")
        for i in 0..<4 { plan.deleteFile(urls[i], reason: "较小的重复文件") }

        XCTAssertEqual(plan.filesToKeep.count, 1, "应保留恰好 1 个文件")
        XCTAssertEqual(plan.filesToDelete.count, 4, "应删除 4 个重复文件")
        XCTAssertFalse(plan.filesToKeep.isEmpty, "清理计划必须至少保留一个文件")
        XCTAssertTrue(plan.filesToKeep.contains(urls[4]), "应保留 index 4 的文件")
        for i in 0..<4 {
            XCTAssertFalse(plan.filesToKeep.contains(urls[i]), "较小文件 \(i) 不应被保留")
        }
    }

    func testCleaningPlanOperationsAreCorrect() {
        var plan = CleaningPlan(groupName: "test")
        let keepURL = URL(fileURLWithPath: "/keep/file.heic")
        let deleteURL = URL(fileURLWithPath: "/delete/file.heic")

        plan.keepFile(keepURL, reason: "保留原因")
        plan.deleteFile(deleteURL, reason: "删除原因")

        XCTAssertTrue(plan.filesToKeep.contains(keepURL))
        XCTAssertTrue(plan.filesToDelete.contains(deleteURL))
        XCTAssertFalse(plan.filesToDelete.contains(keepURL))
        XCTAssertFalse(plan.filesToKeep.contains(deleteURL))
    }
}

// MARK: - 去重逻辑完整性测试

class DeduplicationIntegrityTests: XCTestCase {

    func testSHA256DuplicatesExcludedFromPHashGroups() async throws {
        try await withTempDirectory { dir in
            let duplicateContent = Data("Exact duplicate content 1234567890".utf8)
            let uniqueContent = Data("Unique file content ABCDEFGHIJKLMN".utf8)

            let dup1 = try createTempFile(name: "dup1.heic", content: duplicateContent, in: dir)
            let dup2 = try createTempFile(name: "dup2.heic", content: duplicateContent, in: dir)
            let unique = try createTempFile(name: "unique.heic", content: uniqueContent, in: dir)

            let allFiles = [dup1, dup2, unique]
            var hashToFiles: [String: [URL]] = [:]
            for file in allFiles {
                let hash = try calculateHash(for: file)
                hashToFiles[hash, default: []].append(file)
            }
            let sha256DuplicateFiles = Set(hashToFiles.filter { $0.value.count > 1 }.values.flatMap { $0 })
            let filesForPHash = allFiles.filter { !sha256DuplicateFiles.contains($0) }

            XCTAssertTrue(sha256DuplicateFiles.contains(dup1), "dup1 应被 SHA256 检测到")
            XCTAssertTrue(sha256DuplicateFiles.contains(dup2), "dup2 应被 SHA256 检测到")
            XCTAssertFalse(sha256DuplicateFiles.contains(unique), "unique 不应出现在 SHA256 重复集合中")
            XCTAssertFalse(filesForPHash.contains(dup1), "SHA256 重复文件 dup1 不应进入 pHash 检测")
            XCTAssertFalse(filesForPHash.contains(dup2), "SHA256 重复文件 dup2 不应进入 pHash 检测")
            XCTAssertTrue(filesForPHash.contains(unique), "唯一文件 unique 应进入 pHash 检测")
        }
    }

    func testFileCannotBeBothKeptAndDeleted() {
        var plan = CleaningPlan(groupName: "mutex_test")
        let fileURL = URL(fileURLWithPath: "/test/photo.heic")

        plan.keepFile(fileURL, reason: "初始保留")
        plan.deleteFile(fileURL, reason: "改为删除")

        XCTAssertNotNil(plan.actions[fileURL], "文件应有操作记录")
        let inKeep = plan.filesToKeep.contains(fileURL)
        let inDelete = plan.filesToDelete.contains(fileURL)
        XCTAssertFalse(inKeep && inDelete, "文件不应同时在保留和删除列表中")
    }

    func testDuplicateGroupAlwaysKeepsOneBestFile() {
        let urls = [
            URL(fileURLWithPath: "/test/small.heic"),
            URL(fileURLWithPath: "/test/large.heic"),
        ]
        let fileSizes: [URL: Int64] = [urls[0]: 1024, urls[1]: 4096]
        let bestFile = urls.max { fileSizes[$0, default: 0] < fileSizes[$1, default: 0] }

        var plan = CleaningPlan(groupName: "size_test")
        if let best = bestFile {
            plan.keepFile(best, reason: "最大文件")
            for url in urls where url != best {
                plan.deleteFile(url, reason: "较小的重复")
            }
        }

        XCTAssertFalse(plan.filesToKeep.isEmpty, "至少保留一个文件")
        XCTAssertTrue(plan.filesToKeep.contains(urls[1]), "应保留大文件")
        XCTAssertTrue(plan.filesToDelete.contains(urls[0]), "应删除小文件")
    }
}

// MARK: - 边界情况测试

class EdgeCaseTests: XCTestCase {

    func testEmptyFileListHandledGracefully() {
        let uf = UnionFind(size: 0)
        _ = uf // 确认初始化不崩溃
    }

    func testSingleElementUnionFind() {
        let uf = UnionFind(size: 1)
        XCTAssertEqual(uf.find(0), 0)
    }

    func testHammingDistanceWithZeroHash() {
        XCTAssertEqual(hammingDistance(0, 0), 0)
        XCTAssertEqual(hammingDistance(0, 1), 1)
        XCTAssertEqual(hammingDistance(0, UInt64.max), 64)
    }

    func testHashBucketThresholdsAreSane() {
        XCTAssertGreaterThan(ScannerConfig.maxGroupsPerBucketBeforeBatching, 0)
        XCTAssertGreaterThan(ScannerConfig.maxBucketsForCrossBucketCheck, 0)
        XCTAssertGreaterThanOrEqual(ScannerConfig.maxGroupsPerBucketBeforeBatching, 10)
    }
}
