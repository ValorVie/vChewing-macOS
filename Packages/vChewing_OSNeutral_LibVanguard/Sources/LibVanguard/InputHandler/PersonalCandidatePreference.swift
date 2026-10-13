// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Homa
import LexiconAssembly

/// 僅持有可撤回的自動選取狀態；不改寫詞庫分數，也不產生學習事件。
public final class PersonalCandidatePreference {
  public init() {}

  private struct Pin {
    let original: Homa.NodeOverrideStatus
    let applied: Homa.NodeOverrideStatus
  }

  private var pins: [FIUUID: Pin] = [:]

  func clear() { pins.removeAll() }

  func owns(_ node: Homa.Node?) -> Bool {
    guard let node, let pin = pins[node.id] else { return false }
    return node.overrideStatus == pin.applied
  }

  func withdraw(assembler: Homa.Assembler) {
    var mirror: [FIUUID: Homa.NodeOverrideStatus] = [:]
    for segment in assembler.segments {
      for node in segment.values {
        guard let pin = pins[node.id], node.overrideStatus == pin.applied else { continue }
        mirror[node.id] = pin.original
      }
    }
    pins.removeAll()
    guard !mirror.isEmpty else { return }
    assembler.restoreFromNodeOverrideStatusMirror(mirror)
    assembler.assemble()
  }

  func apply(assembler: Homa.Assembler, store: LXAssembly.CandidateRankingStore,
             protectedRanges: [Range<Int>]) {
    withdraw(assembler: assembler)
    var mirror: [FIUUID: Homa.NodeOverrideStatus] = [:]
    var candidates: [(range: Range<Int>, node: Homa.Node, index: Int)] = []
    for (start, segment) in assembler.segments.enumerated() {
      for (length, node) in segment {
        let range = start ..< start + length
        guard range.upperBound <= assembler.length,
              !protectedRanges.contains(where: { $0.overlaps(range) }) else { continue }
        for (index, gram) in node.grams.enumerated() {
          guard gram.keyArray.count == length, gram.current.count == length,
                gram.keyArray.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("_") }),
                (gram.previous ?? "").isEmpty, (gram.anterior ?? "").isEmpty,
                store.latestValue(for: gram.keyArray) == gram.current else { continue }
          candidates.append((range, node, index))
        }
      }
    }
    candidates.sort {
      if $0.range.count != $1.range.count { return $0.range.count > $1.range.count }
      if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
      return $0.index < $1.index
    }
    var occupied = protectedRanges
    var selectedRanges: [Range<Int>] = []
    var originalWordRanges: [Range<Int>] = []
    var start = 0
    for gram in assembler.assembledSentence {
      let range = start ..< start + gram.segLength
      if gram.segLength > 1 { originalWordRanges.append(range) }
      start = range.upperBound
    }
    for candidate in candidates {
      guard !occupied.contains(where: { $0.overlaps(candidate.range) }) else { continue }
      if candidate.range.count == 1,
         originalWordRanges.contains(where: { $0.overlaps(candidate.range) }) { continue }
      let original = candidate.node.overrideStatus
      var applied = original
      applied.currentOverrideType = .withSpecified
      applied.overridingScore = 114_514
      applied.isExplicitlyOverridden = false
      applied.currentUnigramIndex = candidate.index
      pins[candidate.node.id] = Pin(original: original, applied: applied)
      mirror[candidate.node.id] = applied
      occupied.append(candidate.range)
      selectedRanges.append(candidate.range)
    }
    // 只暫降與已選偏好相交的自動強覆寫，保留原狀態供撤回；手選及無相交的 POM 不動。
    for (start, segment) in assembler.segments.enumerated() {
      for (length, node) in segment {
        let range = start ..< start + length
        guard mirror[node.id] == nil, node.currentOverrideType == .withSpecified,
              node.overridingScore > 0, !node.isExplicitlyOverridden,
              !protectedRanges.contains(where: { $0.overlaps(range) }),
              selectedRanges.contains(where: { $0.overlaps(range) }) else { continue }
        let original = node.overrideStatus
        var applied = original
        applied.overridingScore = -114_514
        pins[node.id] = Pin(original: original, applied: applied)
        mirror[node.id] = applied
      }
    }
    guard !mirror.isEmpty else { return }
    assembler.restoreFromNodeOverrideStatusMirror(mirror)
    assembler.assemble()
  }
}

extension InputHandlerProtocol {
  @discardableResult
  public func synchronizePersonalCandidatePreference() -> Bool {
    candidateSelectionLearning.setLearningEnabled(prefs.usePersonalCandidatePreference)
  }

  func applyPersonalCandidatePreference() {
    synchronizePersonalCandidatePreference()
    guard isCandidateRankingEnabled else {
      personalCandidatePreference.withdraw(assembler: assembler)
      return
    }
    personalCandidatePreference.apply(
      assembler: assembler, store: currentLM.candidateRanking,
      protectedRanges: candidateSelectionLearning.protectedRanges(assembler: assembler)
    )
  }
}
