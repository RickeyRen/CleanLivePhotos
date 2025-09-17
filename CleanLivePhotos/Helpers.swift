import Foundation

// MARK: - Helper Extensions

extension URL {
    var fileSize: Int64? {
        let values = try? resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
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