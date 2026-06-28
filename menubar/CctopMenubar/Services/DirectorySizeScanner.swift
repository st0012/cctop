import Foundation

enum DirectorySizeScanner {
    static func sizeOfDirectory(atPath path: String) -> Int64? {
        let root = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
        ]
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                failed = true
                return true
            }
        ) else {
            return nil
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                failed = true
                continue
            }
            if values.isSymbolicLink == true {
                continue
            }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            total += Int64(size)
        }

        return failed ? nil : total
    }
}
