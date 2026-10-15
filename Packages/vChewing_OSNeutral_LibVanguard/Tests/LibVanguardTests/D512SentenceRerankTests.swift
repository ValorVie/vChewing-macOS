// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import D512Rerank
import Foundation
import Homa
import Shared
import Testing
@testable import LibVanguard

extension LibVanguardTestsRoot {
  @Suite("D512SentenceRerank")
  struct D512SentenceRerankTests {
    @Test func pinsRestoreOriginalStatusesAndRespectLaterManualChanges() throws {
      let assembler = Homa.Assembler(gramQuerier: { keys in
        let values = keys.count == 2 ? ["試試", "世事"] : ["試"]
        return values.enumerated().map {
          Homa.Gram(keyArray: keys.map { $0.allValues[0] }, current: $0.element,
                    probability: -Double($0.offset + 1))
        }
      })
      try assembler.insertKeys([.singleKey("ㄕˋ"), .singleKey("ㄕˋ")])
      let paths = try assembler.assembleKBest(k: 8)
      let original = try #require(assembler.segments[0][2]?.overrideStatus)
      let rerank = D512SentenceRerank()
      #expect(rerank.apply(paths[1].grams, assembler: assembler, fixedRanges: []))
      #expect(assembler.assembledSentence.map(\.value) == ["世事"])
      #expect(assembler.assembledSentence.allSatisfy { !$0.isExplicit })
      rerank.withdraw(assembler: assembler)
      #expect(assembler.segments[0][2]?.overrideStatus == original)
      #expect(assembler.assembledSentence.map(\.value) == ["試試"])
      #expect(rerank.apply(paths[1].grams, assembler: assembler, fixedRanges: []))
      try assembler.overrideCandidate(
        Homa.CandidatePair(keyArray: ["ㄕˋ", "ㄕˋ"], value: "試試"), at: 0,
        type: .withSpecified, isExplicitlyOverridden: true
      )
      let manual = assembler.segments[0][2]?.overrideStatus
      rerank.withdraw(assembler: assembler)
      #expect(assembler.segments[0][2]?.overrideStatus == manual)
    }

    @Test func contextAndGenerationRemainSessionLocal() {
      let first = D512SentenceRerank(), second = D512SentenceRerank()
      first.noteCommit(String(repeating: "甲", count: 80) + "乙")
      #expect(first.context == String(repeating: "甲", count: 63) + "乙")
      #expect(second.context.isEmpty)
      first.clear(assembler: .init(gramQuerier: { _ in [] }))
      #expect(first.context.unicodeScalars.count == 64)
      #expect(first.generation == 1)
      first.leaveClient(assembler: .init(gramQuerier: { _ in [] }))
      #expect(first.context.isEmpty)
      #expect(first.generation == 2)
      #expect(UserDef.kUseD512SentenceRerank.boolDefaultValue == false)
      #expect(UserDef.kD512RerankPersonalBonus.doubleDefaultValue == 2)
      #expect(second.debounceSeconds == 0.15)
    }

    @Test func injectedScorerRunsThroughBackgroundWorker() async {
      struct Scorer: D512Scoring {
        func logProb(_ input: D512Input) throws -> Double {
          #expect(!Thread.isMainThread)
          return -Double(input.targetIds.count)
        }
      }
      let vocab = D512Vocab(characters: ["試"], bases: ["ㄕ"], neutralTolerantLast: [])
      let rerank = D512SentenceRerank(scorer: Scorer(), vocab: vocab)
      let request = D512Request(
        id: "test", context: "", reading: ["ㄕˋ", "ㄕˋ"], candidates: [.init(text: "試試", log_score: -1)]
      )
      let result = await withCheckedContinuation { continuation in
        rerank.score(request) { continuation.resume(returning: $0) }
      }
      #expect(result.scores == [-2])
      #expect(result.error == nil)
    }

    @Test func personalHitsRejectContextIncompleteKeysAndSplitWords() {
      func path(_ keys: [String], _ text: String, previous: String? = nil,
                words: [Range<Int>] = []) -> D512SentenceRerank.Path {
        let gram = Homa.Gram(keyArray: keys, current: text, previous: previous, probability: -1)
        return .init(grams: [.init(gram: gram, isExplicit: false)], latest: [keys: text], wordRanges: words)
      }
      #expect(path(["ㄕˋ", "ㄕˋ"], "世事").personalHits == 1)
      #expect(path(["ㄕˋ"], "世", words: [0 ..< 2]).personalHits == 0)
      #expect(path(["ㄕˋ"], "世", previous: "前").personalHits == 0)
      #expect(path(["_punctuation"], "。").personalHits == 0)
      #expect(path([""], "世").personalHits == 0)
      #expect(path(["ㄕˋ"], "世事").personalHits == 0)
    }

    @Test func missingAndHashMismatchedModelsAreUnavailable() throws {
      let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
      #expect(D512SentenceRerank.unavailableReason(at: directory) != nil)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for name in ["model.onnx", "vocab.json", "manifest.json"] {
        try Data("invalid".utf8).write(to: directory.appendingPathComponent(name))
      }
      #expect(D512SentenceRerank.unavailableReason(at: directory) != nil)
    }

    @Test func delayedCalibrationReceiptCannotCommitAcrossClients() throws {
      let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".jsonl")
      let rerank = D512SentenceRerank()
      rerank.calibrationLog = D512CalibrationLog(url: url)
      let record = D512CalibrationRecord(
        id: "receipt", reading: ["ㄕˋ", "ㄕˋ"], candidates: [], defaultIndex: 0, winnerIndex: 0,
        applied: false, personalConflict: false, pomConflict: false, weight: 0.5, margin: 0.5, bonus: 2
      )
      let epoch = rerank.clientEpoch
      rerank.leaveClient(assembler: .init(gramQuerier: { _ in [] }))
      rerank.confirmCommitRecords([record], text: "世事", enabled: true, expectedClientEpoch: epoch)
      rerank.calibrationLog.flush()
      let data = try Data(contentsOf: url).dropLast()
      let result = try JSONDecoder().decode(D512CalibrationRecord.self, from: Data(data))
      #expect(result.phase == "cancel")
      #expect(result.finalCommittedText == nil)
    }
  }
}
