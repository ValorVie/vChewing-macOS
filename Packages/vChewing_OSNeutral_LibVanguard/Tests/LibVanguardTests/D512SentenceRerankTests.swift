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
  }
}
