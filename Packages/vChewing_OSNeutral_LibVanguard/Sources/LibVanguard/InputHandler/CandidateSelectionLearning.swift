// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LexiconAssembly

/// 手選只在客體收到完整結果後學習；部分溢出結果另保護尚未遞交的尾端，不學習自動組字。
public final class CandidateSelectionLearning {
  public init() {}

  struct Receipt {
    fileprivate let fragments: [(Choice, Int)]

    func confirm(insertedUnchanged: Bool) {
      for (choice, count) in fragments {
        if !insertedUnchanged { choice.cancelled = true }
        guard choice.learnable, choice.epoch.isValid, !choice.cancelled, !choice.learned else { continue }
        choice.delivered += count
        guard choice.delivered == choice.pair.keyArray.count else { continue }
        choice.learned = true
        choice.store.recordCommittedCandidate(choice.pair, selectionOrder: choice.order)
      }
    }
  }

  func record(_ pair: Homa.CandidatePair, at cursor: Int, assembler: Homa.Assembler,
              store: LXAssembly.CandidateRankingStore, learnable: Bool = true) {
    prune(assembler: assembler)
    guard let hit = assembler.assembledSentence.findGram(at: cursor), hit.gram.asCandidatePair == pair,
          hit.range.upperBound <= assembler.length,
          let node = assembler.segments[hit.range.lowerBound][hit.range.count],
          node.currentGram?.id == hit.gram.gram.id
    else { return }
    let tokens = hit.range.compactMap { assembler.segments[$0][1]?.id }
    guard tokens.count == pair.keyArray.count else { return }
    let tokenSet = Set(tokens)
    choices.removeAll {
      guard !$0.tokens.allSatisfy({ !tokenSet.contains($0) }) else { return false }
      $0.cancelled = true
      return true
    }
    choices.append(Choice(pair: pair, nodeID: node.id, tokens: tokens, store: store,
                          learnable: learnable && learningEnabled, epoch: epoch))
  }

  func prune(assembler: Homa.Assembler) {
    choices.removeAll {
      guard range(of: $0, assembler: assembler) == nil else { return false }
      $0.cancelled = true
      return true
    }
  }

  func protectedRanges(assembler: Homa.Assembler) -> [Range<Int>] {
    var ranges = choices.compactMap { range(of: $0, assembler: assembler) }
    var start = 0
    // 刪除回補的手選殘片仍須保護，但不因此新增可學習的 Choice；只認目前組句中的存活節點。
    for gram in assembler.assembledSentence {
      let end = start + gram.segLength
      defer { start = end }
      guard gram.isExplicit, end <= assembler.length,
            let node = assembler.segments[start][gram.segLength], node.isExplicitlyOverridden,
            node.currentGram?.id == gram.gram.id else { continue }
      ranges.append(start ..< end)
    }
    return ranges
  }

  /// 只使用已在軌格內的合法後綴；這是已遞交詞的尾端保全，不是新的手選或學習來源。
  func protectOverflowSuffix(of pair: Homa.CandidatePair, after readingCount: Int,
                             assembler: Homa.Assembler, store: LXAssembly.CandidateRankingStore) -> Bool {
    let keys = Array(pair.keyArray.dropFirst(readingCount))
    let values = Array(pair.value).dropFirst(readingCount).map(String.init)
    guard !keys.isEmpty, keys.count == values.count else { return false }
    var mirror: [FIUUID: Homa.NodeOverrideStatus] = [:]
    func select(start: Int, keys: [String], value: String) -> Bool {
      guard let node = assembler.segments[start][keys.count],
            let index = node.grams.firstIndex(where: { $0.keyArray == keys && $0.current == value })
      else { return false }
      var status = node.overrideStatus
      status.currentOverrideType = .withSpecified
      status.overridingScore = 114_514
      status.isExplicitlyOverridden = false
      status.currentUnigramIndex = index
      mirror[node.id] = status
      return true
    }
    if !select(start: readingCount, keys: keys, value: values.joined()) {
      mirror.removeAll()
      for (offset, key) in keys.enumerated() {
        guard select(start: readingCount + offset, keys: [key], value: values[offset]) else { return false }
      }
    }
    record(pair, at: 0, assembler: assembler, store: store, learnable: false)
    assembler.restoreFromNodeOverrideStatusMirror(mirror)
    return true
  }

  func clear() {
    choices.forEach { $0.cancelled = true }
    overflow.forEach { $0.fragments.forEach { $0.0.cancelled = true } }
    choices.removeAll()
    overflow.removeAll()
  }

  /// 只在總開關切換時撤銷舊 epoch；正常 clear/commit 不會撤銷已抽取的有效 receipt。
  @discardableResult
  func setLearningEnabled(_ enabled: Bool) -> Bool {
    guard learningEnabled != enabled else { return false }
    learningEnabled = enabled
    epoch.isValid = false
    epoch = Epoch(isValid: enabled)
    return true
  }

  /// 必須在 overflow 的 dropKey 之前擷取證據，並保留未遞交尾端的節點身分。
  func consumePrefix(readingCount: Int, assembler: Homa.Assembler) -> Receipt {
    prune(assembler: assembler)
    var fragments: [(Choice, Int)] = []
    for choice in choices {
      guard let range = range(of: choice, assembler: assembler), range.lowerBound < readingCount else { continue }
      let count = min(range.upperBound, readingCount) - range.lowerBound
      guard count > 0 else { continue }
      fragments.append((choice, count))
      choice.tokens.removeFirst(count)
      // 部分溢出會拆掉原整詞節點；尾端改由仍存活的單讀音節點身分驗證。
      choice.nodeID = nil
    }
    choices.removeAll { $0.tokens.isEmpty }
    return Receipt(fragments: fragments)
  }

  func enqueueOverflow(text: String, receipts: [Receipt]) {
    guard !text.isEmpty, receipts.contains(where: { !$0.fragments.isEmpty }) else { return }
    overflow.append((text, receipts.flatMap(\.fragments)))
  }

  func takeCommit(text: String, assembler: Homa.Assembler) -> Receipt? {
    guard !choices.isEmpty || !overflow.isEmpty else { return nil }
    var remainingText = text
    var fragments: [(Choice, Int)] = []
    if let batch = overflow.first {
      overflow.removeFirst()
      if remainingText.hasPrefix(batch.text) {
        remainingText = String(remainingText.dropFirst(batch.text.count))
        fragments += batch.fragments
      } else {
        batch.fragments.forEach { $0.0.cancelled = true }
      }
    }
    let composition = assembler.assembledSentence.map(\.value).joined()
    if !composition.isEmpty, remainingText.hasPrefix(composition) {
      prune(assembler: assembler)
      fragments += choices.map { ($0, $0.tokens.count) }
      choices.removeAll()
    }
    return fragments.isEmpty ? nil : Receipt(fragments: fragments)
  }

  // ponytail: 少量待學習選取以 O(組字長度 × 選取數量) 掃描；長組字區若成為瓶頸再建立單次 ID 索引。
  private func range(of choice: Choice, assembler: Homa.Assembler) -> Range<Int>? {
    guard !choice.cancelled, let firstToken = choice.tokens.first,
          let start = assembler.segments.indices.first(where: { assembler.segments[$0][1]?.id == firstToken })
    else { return nil }
    let end = start + choice.tokens.count
    guard end <= assembler.length else { return nil }
    for (offset, token) in choice.tokens.enumerated() {
      guard assembler.segments[start + offset][1]?.id == token else { return nil }
    }
    if let nodeID = choice.nodeID {
      guard assembler.segments[start][choice.tokens.count]?.id == nodeID else { return nil }
    }
    let consumed = choice.pair.keyArray.count - choice.tokens.count
    let expectedKeys = Array(choice.pair.keyArray.dropFirst(consumed))
    let expectedValue = String(choice.pair.value.dropFirst(consumed))
    guard let slice = slice(start ..< end, assembler: assembler),
          slice.keyArray == expectedKeys, slice.value == expectedValue
    else { return nil }
    return start ..< end
  }

  /// 依讀音位置擷取目前組句；禁止以全文 contains 判定另一位置的同字。
  private func slice(_ range: Range<Int>, assembler: Homa.Assembler) -> Homa.CandidatePair? {
    var position = 0
    var keys: [String] = []
    var value = ""
    for gram in assembler.assembledSentence {
      let end = position + gram.keyArray.count
      defer { position = end }
      let lower = max(range.lowerBound, position)
      let upper = min(range.upperBound, end)
      guard lower < upper else { continue }
      if gram.isReadingMismatched {
        guard lower == position, upper == end else { return nil }
        keys += gram.keyArray
        value += gram.value
      } else {
        let offsets = (lower - position) ..< (upper - position)
        keys += gram.keyArray[offsets]
        value += Array(gram.value)[offsets].map(String.init).joined()
      }
    }
    guard keys.count == range.count else { return nil }
    return .init(keyArray: keys, value: value)
  }

  fileprivate final class Choice {
    init(pair: Homa.CandidatePair, nodeID: FIUUID, tokens: [FIUUID], store: LXAssembly.CandidateRankingStore,
         learnable: Bool, epoch: Epoch) {
      self.pair = pair
      self.nodeID = nodeID
      self.tokens = tokens
      self.store = store
      self.learnable = learnable
      self.epoch = epoch
      self.order = learnable ? store.nextSelectionOrder() : 0
    }

    let pair: Homa.CandidatePair
    let store: LXAssembly.CandidateRankingStore
    let order: UInt64
    let learnable: Bool
    let epoch: Epoch
    var nodeID: FIUUID?
    var tokens: [FIUUID]
    var delivered = 0
    var cancelled = false
    var learned = false
  }

  fileprivate final class Epoch {
    init(isValid: Bool = true) { self.isValid = isValid }
    var isValid: Bool
  }

  private var choices: [Choice] = []
  private var overflow: [(text: String, fragments: [(Choice, Int)])] = []
  private var epoch = Epoch()
  private var learningEnabled = true
}

extension InputHandlerProtocol {
  var isCandidateRankingEnabled: Bool {
    prefs.usePersonalCandidatePreference && isPersonalCandidatePreferenceModeEligible
  }

  var isPersonalCandidatePreferenceModeEligible: Bool {
    currentTypingMethod == .vChewingFactory && !prefs.useSCPCTypingMode
      && (typingMode == .bopomofoKeyblock || typingMode == .pinyinKeyblock)
      && (composer.isPinyinMode || !prefs.mixedAlphanumericalEnabled)
  }

  func isStandardRankingCandidate(_ pair: Homa.CandidatePair) -> Bool {
    !pair.keyArray.isEmpty && pair.keyArray.allSatisfy { !$0.isEmpty && !$0.hasPrefix("_") }
  }
}
