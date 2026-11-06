import Foundation

/// One typing mistake that turns the intended word into what was typed.
public enum EditOp: Hashable, Sendable {
    case substitute(intended: Character, typed: Character)
    case omit(Character, doubled: Bool)
    case insert(Character, nearNeighbor: Bool, doubled: Bool)
    case transpose(Character, Character)

    /// Stable key used to count how often you make this exact mistake.
    public var key: String {
        switch self {
        case let .substitute(intended, typed): return "s:\(intended)\(typed)"
        case let .omit(c, _): return "o:\(c)"
        case let .insert(c, _, _): return "i:\(c)"
        case let .transpose(a, b): return "t:\(a)\(b)"
        }
    }

    /// Per-character probability of this mistake before any personal data.
    public var prior: Double {
        switch self {
        case let .substitute(intended, typed): return Keyboard.isAdjacent(intended, typed) ? 0.003 : 0.0001
        case let .omit(_, doubled): return doubled ? 0.004 : 0.0015
        case let .insert(_, near, doubled): return doubled ? 0.003 : (near ? 0.002 : 0.0002)
        case .transpose: return 0.004
        }
    }
}

public enum EditDistance {
    /// Edits turning `intended` into `typed` (optimal string alignment), or nil when more than `maxEdits` apart.
    public static func align(intended a: [Character], typed b: [Character], maxEdits: Int = 2) -> [EditOp]? {
        let n = a.count, m = b.count
        guard abs(n - m) <= maxEdits else { return nil }
        let w = m + 1
        var d = [Int](repeating: 0, count: (n + 1) * w)
        for j in 0...m { d[j] = j }
        for i in stride(from: 1, through: n, by: 1) {
            d[i * w] = i
            var rowMin = i
            for j in stride(from: 1, through: m, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = min(d[(i - 1) * w + j] + 1, d[i * w + j - 1] + 1, d[(i - 1) * w + j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    v = min(v, d[(i - 2) * w + j - 2] + 1)
                }
                d[i * w + j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > maxEdits { return nil }
        }
        guard d[n * w + m] <= maxEdits else { return nil }

        var ops: [EditOp] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            let cur = d[i * w + j]
            if i > 0, j > 0, a[i - 1] == b[j - 1], cur == d[(i - 1) * w + j - 1] {
                i -= 1; j -= 1
            } else if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1], cur == d[(i - 2) * w + j - 2] + 1 {
                ops.append(.transpose(a[i - 2], a[i - 1]))
                i -= 2; j -= 2
            } else if i > 0, j > 0, cur == d[(i - 1) * w + j - 1] + 1 {
                ops.append(.substitute(intended: a[i - 1], typed: b[j - 1]))
                i -= 1; j -= 1
            } else if i > 0, cur == d[(i - 1) * w + j] + 1 {
                let doubled = (i > 1 && a[i - 2] == a[i - 1]) || (i < n && a[i] == a[i - 1])
                ops.append(.omit(a[i - 1], doubled: doubled))
                i -= 1
            } else {
                guard j > 0 else { break }
                let c = b[j - 1]
                let neighbors = [j > 1 ? b[j - 2] : nil, j < m ? b[j] : nil].compactMap { $0 }
                ops.append(.insert(
                    c,
                    nearNeighbor: neighbors.contains { Keyboard.isAdjacent($0, c) },
                    doubled: neighbors.contains(c)
                ))
                j -= 1
            }
        }
        return ops
    }
}
