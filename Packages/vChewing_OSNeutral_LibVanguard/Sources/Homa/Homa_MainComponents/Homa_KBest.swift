// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

extension Homa {
  public enum KBestError: Error {
    case invalidLimit
  }

  /// 完整路徑快照；分數與文字均不依賴後續的節點狀態。
  public struct KBestPath: Sendable {
    // MARK: Lifecycle

    init(grams: [GramInPath], score: Double) {
      self.grams = grams
      self.score = score
      self.text = grams.values.joined()
      self.rawUnigramLogScore = grams.reduce(0) { $0 + $1.gram.probability }
    }

    init(prefix: Self, gram: GramInPath, edgeScore: Double) {
      self.grams = prefix.grams + [gram]
      self.score = prefix.score + edgeScore
      self.text = prefix.text + gram.value
      self.rawUnigramLogScore = prefix.rawUnigramLogScore + gram.gram.probability
    }

    // MARK: Public

    public let grams: [GramInPath]
    /// 包含節點覆寫權重及適用語境權重的 DP 總分。
    public let score: Double
    /// 沿路各 `gram.probability` 之和，完全不含覆寫權重。
    /// 若原路徑本身帶有語境 gram，亦原樣取該 gram 的 probability。
    public let rawUnigramLogScore: Double
    public let text: String
  }
}

extension Homa.Assembler {
  /// 先正式組句，再唯讀列舉至多 k 條文字互異的完整路徑。
  ///
  /// 第 0 條原樣保留本次 `assemble()` 的文字、分段、明確覆寫標記與 DP 分數；
  /// 其餘路徑依分數遞減排列，同分時依文字排序。正式組句採一維 DP，故在帶語境的
  /// 格位中，第 0 條不保證高於其餘路徑。搜尋不呼叫供應器、感知器或修改既有節點。
  /// 非覆寫節點展開各 gram（語境 gram 須符合路徑前驅）；覆寫節點僅使用當前 gram，
  /// 依 PathFinder 相同的 `getScore` 計分，但允許其他分段繞過未受保護的節點。
  /// - Parameters:
  ///   - k: 1...8；超出範圍時拋出 `Homa.KBestError.invalidLimit`，且不組句。
  ///   - fixedRanges: 格位座標的半開區間。凡與區間相交的第 0 條路徑 gram，
  ///     在所有路徑中均須保留同一 gram 及其完整格位幅節；空區間與圖外位置不生效。
  /// - Returns: 空圖或無完整路徑時為空陣列；否則包含第 0 條的至多 k 條路徑。
  public func assembleKBest(k: Int, fixedRanges: [Range<Int>] = []) throws -> [Homa.KBestPath] {
    guard (1 ... 8).contains(k) else { throw Homa.KBestError.invalidLimit }
    let original = assemble()
    guard !original.isEmpty, mostRecentPathScore > Double(Int32.min) else { return [] }

    // 不能以 gram.keyArray.count 推算位置：前綴匹配可能在短幅節中存放更長的 gram。
    var start = 0
    var fixed: [KBestFixedGram] = []
    for gram in original {
      guard start < segments.count,
            let span = segments[start].first(where: { entry in
              entry.value.grams.contains { $0.id == gram.gram.id }
            })?.key else { return [] }
      let range = start ..< (start + span)
      if fixedRanges.contains(where: { !$0.isEmpty && $0.overlaps(range) }) {
        fixed.append(.init(range: range, gram: gram))
      }
      start += span
    }
    guard start == length else { return [] }
    let first = Homa.KBestPath(grams: original, score: mostRecentPathScore)
    guard k > 1 else { return [first] }

    // 語境會讓相同文字、不同分段的前綴具有不同的後續分數，因此須分開保留前驅二位。
    // 純 unigram 圖不需要語境分桶，每個終點只保留 k 個相異文字即可。
    let hasContext = segments.contains { $0.values.contains { $0.grams.contains { !$0.isUnigram } } }
    var beams = [[KBestContext: [Homa.KBestPath]]](repeating: [:], count: length + 1)
    beams[0][.init()] = [.init(grams: [], score: 0)]
    for position in 0 ..< length {
      let prefixes = beams[position].values.flatMap { kBestDistinct($0, limit: k) }
      beams[position] = [:]
      guard !prefixes.isEmpty else { continue }
      for span in segments[position].keys.sorted() where span > 0 && position + span <= length {
        guard let node = segments[position][span] else { continue }
        let range = position ..< (position + span)
        let constraints = fixed.filter { $0.range.overlaps(range) }
        for prefix in prefixes {
          let previous = prefix.grams.last?.value ?? ""
          let anterior = prefix.grams.dropLast().last?.value ?? ""
          for edge in kBestEdges(node, previous: previous, anterior: anterior) {
            guard constraints.allSatisfy({ $0.range == range && $0.gram == edge.gram }) else { continue }
            let path = Homa.KBestPath(prefix: prefix, gram: edge.gram, edgeScore: edge.score)
            let context = hasContext ? KBestContext(previous: edge.gram.value, anterior: previous) : .init()
            beams[range.upperBound][context, default: []].append(path)
          }
        }
      }
    }
    let others = beams[length].values.flatMap { $0 }.filter { $0.text != first.text }
    return [first] + kBestDistinct(others, limit: k - 1)
  }
}

// MARK: - Private

private struct KBestFixedGram {
  let range: Range<Int>
  let gram: Homa.GramInPath
}

private struct KBestContext: Hashable {
  var previous: String = ""
  var anterior: String = ""
}

private func kBestEdges(
  _ node: Homa.Node, previous: String, anterior: String
) -> [(gram: Homa.GramInPath, score: Double)] {
  if node.isOverridden {
    guard let gram = node.currentGram else { return [] }
    var copy = node
    let score = copy.getScore(previous: previous, anterior: anterior)
    return [(gram: .init(gram: gram, isExplicit: node.isExplicitlyOverridden), score: score)]
  }
  // 與 PathFinder 相同，單元圖使用 probability；語境加分只在前驅符合時可用。
  // 展開次佳 gram 是 k-best 專屬操作，不改動 PathFinder 的 currentGram 選取。
  return node.grams.compactMap { gram in
    if !gram.isUnigram {
      guard !previous.isEmpty, gram.previous == previous,
            gram.anterior == nil || (!anterior.isEmpty && gram.anterior == anterior) else { return nil }
    }
    return (.init(gram: gram, isExplicit: false), gram.probability)
  }
}

private func kBestDistinct(_ paths: [Homa.KBestPath], limit: Int) -> [Homa.KBestPath] {
  var seen = Set<String>()
  return Array(paths.sorted {
    $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score
  }.filter { seen.insert($0.text).inserted }.prefix(limit))
}
