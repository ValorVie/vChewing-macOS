// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import D512Rerank
import Foundation
import Homa
import Shared
import Testing
@testable import LibVanguard
@testable import LexiconAssembly

extension LibVanguardTestsRoot.InputHandlerTests.Session {
  @Test("SS-D512-001 Disabled switch preserves composition")
  func test_SS_D512_001_Disabled() async throws {
    prepareD512Fixture()
    testHandler.prefs.useD512SentenceRerank = false
    typeSentenceOrCandidates("g4g4")
    try await Task.sleep(nanoseconds: 180_000_000)
    #expect(testSession.state.displayedText == "試試")
    #expect(testHandler.d512SentenceRerank.lastEvaluation == nil)
    #expect(!testHandler.d512SentenceRerank.hasPin)
  }

  @Test("SS-D512-002 Winner applies after debounce and Enter commits without learning")
  func test_SS_D512_002_WinnerAndCommit() async {
    prepareD512Fixture()
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    #expect(testSession.state.displayedText == "世事")
    #expect(testHandler.assembler.assembledSentence.allSatisfy { !$0.isExplicit })
    let pair = Homa.CandidatePair(keyArray: ["ㄕˋ", "ㄕˋ"], value: "世事")
    let store = testHandler.currentLM.candidateRanking
    let count = store.count(for: pair)
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "世事")
    #expect(store.count(for: pair) == count)
    #expect(writtenUserPhrases.isEmpty)
    #expect(!testHandler.d512SentenceRerank.hasPin)
    #expect(testHandler.d512SentenceRerank.context == "世事")
  }

  @Test("SS-D512-003 Margin retains displayed default")
  func test_SS_D512_003_Margin() async {
    prepareD512Fixture()
    testHandler.prefs.d512RerankMargin = 100
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    #expect(testSession.state.displayedText == "試試")
    #expect(!testHandler.d512SentenceRerank.hasPin)
  }

  private struct D512FakeScorer: D512Scoring {
    func logProb(_ input: D512Input) throws -> Double {
      input.targetIds == [4, 5] ? 0 : -10
    }
  }

  func prepareD512Fixture() {
    testSession.switchState(.ofAbortion())
    testHandler.prefs.useD512SentenceRerank = true
    testHandler.prefs.usePersonalCandidatePreference = true
    testHandler.prefs.d512RerankWeight = 0.5
    testHandler.prefs.d512RerankMargin = 0.5
    testHandler.prefs.d512RerankPersonalBonus = 2
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
    testHandler.prefs.associatedPhrasesEnabled = false
    testHandler.prefs.enforceETenDOSCandidateSequence = false
    testHandler.prefs.phraseReplacementEnabled = false
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.useRearCursorMode = false
    testHandler.prefs.mixedAlphanumericalEnabled = false
    testHandler.prefs.keyboardParser = 0
    testHandler.currentLM.injectTestData(userPhrases: {
      $0.replaceData(textData: "試 ㄕˋ -4\n試試 ㄕˋ-ㄕˋ -1\n逝世 ㄕˋ-ㄕˋ -2\n世事 ㄕˋ-ㄕˋ -3\n")
    })
    testHandler.d512SentenceRerank = D512SentenceRerank(
      scorer: D512FakeScorer(), vocab: D512Vocab(
        characters: ["試", "逝", "世", "事"], bases: ["ㄕ"], neutralTolerantLast: []
      )
    )
    testHandler.d512SentenceRerank.debounceSeconds = 0.01
    testHandler.ensureKeyboardParser()
  }

  func waitForD512() async {
    await withCheckedContinuation { continuation in
      testHandler.d512SentenceRerank.evaluationCompleted = {
        self.testHandler.d512SentenceRerank.evaluationCompleted = nil
        continuation.resume()
      }
    }
  }
}
