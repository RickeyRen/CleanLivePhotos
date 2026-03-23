import Foundation

// MARK: - Union-Find数据结构（用于高效组合并）

/// Union-Find数据结构，用于高效的组合并操作
class UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(size: Int) {
        parent = Array(0..<size)
        rank = Array(repeating: 0, count: size)
    }

    /// 查找根节点（带路径压缩）
    func find(_ x: Int) -> Int {
        if parent[x] != x {
            parent[x] = find(parent[x]) // 路径压缩
        }
        return parent[x]
    }

    /// 合并两个集合（按秩合并）
    func union(_ x: Int, _ y: Int) {
        let rootX = find(x)
        let rootY = find(y)

        if rootX != rootY {
            // 按秩合并，保持树的平衡
            if rank[rootX] < rank[rootY] {
                parent[rootX] = rootY
            } else if rank[rootX] > rank[rootY] {
                parent[rootY] = rootX
            } else {
                parent[rootY] = rootX
                rank[rootX] += 1
            }
        }
    }

    /// 判断两个元素是否在同一个集合中
    func connected(_ x: Int, _ y: Int) -> Bool {
        return find(x) == find(y)
    }
}
