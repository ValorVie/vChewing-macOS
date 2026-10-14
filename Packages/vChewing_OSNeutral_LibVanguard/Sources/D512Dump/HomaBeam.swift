// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Homa

// This extension belongs only to the offline executable, not to the Homa module.
extension Homa.Assembler {
  func d512BeamPaths(k: Int) throws -> [DumpCandidate] {
    guard (1 ... 8).contains(k) else { throw DumpError("k must be in 1...8.") }
    guard !isEmpty else { throw DumpError("Cannot enumerate an empty lattice.") }
    var beams = [[DumpCandidate]](repeating: [], count: length + 1)
    beams[0] = [.init(text: "", log_score: 0, segments: [])]

    // With independent unigram edge weights and aligned text, keeping k distinct prefixes
    // at each endpoint preserves the k best distinct complete texts within this lattice.
    for start in 0 ..< length {
      for spanLength in segments[start].keys.sorted() {
        guard let node = segments[start][spanLength], !node.isOverridden else {
          throw DumpError("Beam enumeration supports factory-only, unmodified nodes.")
        }
        guard node.grams.allSatisfy(\.isUnigram) else {
          throw DumpError("Beam enumeration supports unigram scores only.")
        }
        let end = start + spanLength
        guard end <= length else { continue }
        var expanded = beams[end]
        for prefix in beams[start] {
          for gram in node.grams where gram.current.unicodeScalars.count == spanLength {
            expanded.append(.init(
              text: prefix.text + gram.current, log_score: prefix.log_score + gram.probability,
              segments: prefix.segments + [.init(Start: start, End: end, Word: gram.current)]
            ))
          }
        }
        beams[end] = bestDistinct(expanded, limit: k)
      }
    }

    let engineDefault = DumpCandidate.from(assembledSentence, score: mostRecentPathScore)
    guard engineDefault.text.unicodeScalars.count == length,
          let first = beams[length].first,
          first.log_score <= engineDefault.log_score else {
      throw DumpError("Beam scores disagree with the factory-only Homa best path.")
    }
    // Homa's existing tie choice is authoritative. Preserve its segmentation as well.
    return [engineDefault] + bestDistinct(beams[length].filter { $0.text != engineDefault.text }, limit: k - 1)
  }
}

private func bestDistinct(_ candidates: [DumpCandidate], limit: Int) -> [DumpCandidate] {
  guard limit > 0 else { return [] }
  var seen = Set<String>()
  return Array(candidates.sorted {
    if $0.log_score != $1.log_score { return $0.log_score > $1.log_score }
    return $0.text < $1.text
  }.filter { seen.insert($0.text).inserted }.prefix(limit))
}
