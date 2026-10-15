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
#if canImport(D512RerankONNX)
  import D512RerankONNX
#endif

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
    var pomSaves = 0
    testHandler.pomSaveCallback = { pomSaves += 1 }
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "世事")
    #expect(store.count(for: pair) == count)
    #expect(writtenUserPhrases.isEmpty)
    #expect(pomSaves == 0)
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

  @Test("SS-D512-004 Calibration is opt-in and records scores plus actual insertion")
  func test_SS_D512_004_Calibration() async throws {
    prepareD512Fixture()
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("calibration.jsonl")
    let log = D512CalibrationLog(url: url)
    testHandler.d512SentenceRerank.calibrationLog = log
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    log.flush()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    testSession.switchState(.ofAbortion())
    testHandler.prefs.logD512Calibration = true
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    log.flush()
    let before = try String(contentsOf: url, encoding: .utf8)
    let first = try #require(before.split(separator: "\n").first)
    let json = try #require(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
    #expect(json["finalCommittedText"] is NSNull)
    let candidates = try #require(json["candidates"] as? [[String: Any]])
    #expect(candidates.allSatisfy { Set(["text", "raw", "modelLogP", "personalHits", "fused"]).isSubset(of: Set($0.keys)) })
    press(.dataEnterReturn)
    log.flush()
    let records = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(D512CalibrationRecord.self, from: Data($0.utf8))
    }
    #expect(records.count == 2)
    #expect(records[0].phase == "rerank" && records[1].phase == "commit")
    #expect(records[0].id == records[1].id)
    #expect(records[1].finalCommittedText == "世事")
    #expect(records[1].applied)
    #expect(!records[1].personalConflict && !records[1].pomConflict)
  }

  @Test("SS-D512-005 Personal bonus determines whether the model can replace a personal pin", arguments: [2.0, 8.0])
  func test_SS_D512_005_PersonalBonus(_ bonus: Double) async throws {
    prepareD512Fixture()
    testHandler.prefs.d512RerankPersonalBonus = bonus
    let store = testHandler.currentLM.candidateRanking
    store.recordCommittedCandidate(.init(keyArray: ["ㄕˋ", "ㄕˋ"], value: "逝世"))
    typeSentenceOrCandidates("g4g4")
    #expect(testSession.state.displayedText == "逝世")
    await waitForD512()
    let evaluation = try #require(testHandler.d512SentenceRerank.lastEvaluation)
    #expect(evaluation.paths[evaluation.defaultIndex].personalHits == 1)
    #expect(testSession.state.displayedText == (bonus == 2 ? "世事" : "逝世"))
    #expect(testHandler.d512SentenceRerank.lastCalibrationRecord?.personalConflict == (bonus == 2))
    if bonus == 8 {
      #expect(testHandler.personalCandidatePreference.owns(testHandler.assembler.segments[0][2]))
    }
    testHandler.prefs.useD512SentenceRerank = false
    testSession.refreshD512SentenceRerank()
    #expect(testSession.state.displayedText == "逝世")
    #expect(testHandler.personalCandidatePreference.owns(testHandler.assembler.segments[0][2]))
    press(.dataEnterReturn)
    #expect(store.count(for: .init(keyArray: ["ㄕˋ", "ㄕˋ"], value: "逝世")) == 1)
  }

  @Test("SS-D512-006 Default outside k-best is appended and scored")
  func test_SS_D512_006_AppendedDefault() async throws {
    prepareD512Fixture()
    let words = ["試試", "甲乙", "丙丁", "戊己", "庚辛", "壬癸", "子丑", "寅卯", "逝世"]
    let characters = Array(Set(words.joined().map(String.init))).sorted()
    testHandler.currentLM.injectTestData(userPhrases: {
      $0.replaceData(textData: "試 ㄕˋ -30\n" + words.enumerated().map {
        "\($0.element) ㄕˋ-ㄕˋ -\($0.offset + 1)"
      }.joined(separator: "\n") + "\n")
    })
    testHandler.prefs.d512RerankPersonalBonus = 30
    testHandler.currentLM.candidateRanking.recordCommittedCandidate(.init(keyArray: ["ㄕˋ", "ㄕˋ"], value: "逝世"))
    struct Constant: D512Scoring { func logProb(_ input: D512Input) throws -> Double { -1 } }
    testHandler.d512SentenceRerank = D512SentenceRerank(
      scorer: Constant(), vocab: .init(characters: characters, bases: ["ㄕ"], neutralTolerantLast: [])
    )
    testHandler.d512SentenceRerank.debounceSeconds = 0.01
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    let evaluation = try #require(testHandler.d512SentenceRerank.lastEvaluation)
    #expect(evaluation.paths.count == 9)
    #expect(evaluation.defaultIndex == 8)
    #expect(evaluation.paths[8].text == "逝世")
    #expect(evaluation.model?.count == 9)
    #expect(evaluation.fused?[8] == 20.5)
    #expect(testSession.state.displayedText == "逝世")
  }

  @Test("SS-D512-007 Manual ranges survive winning changes in the remaining sentence")
  func test_SS_D512_007_ManualProtection() async throws {
    prepareD512Fixture()
    typeSentenceOrCandidates("g4g4g4g4")
    _ = openCandidateWindow(cursor: 2)
    let index = try #require(testSession.state.candidates.firstIndex { $0.value == "逝世" })
    testSession.candidatePairSelectionConfirmed(at: index)
    let manual = testHandler.assembler.segments[0][2]?.overrideStatus
    await waitForD512()
    let evaluation = try #require(testHandler.d512SentenceRerank.lastEvaluation)
    #expect(evaluation.paths.allSatisfy { $0.text.hasPrefix("逝世") })
    #expect(testHandler.assembler.segments[0][2]?.overrideStatus == manual)
    #expect(testHandler.assembler.assembledSentence.first?.isExplicit == true)
    #expect(testSession.state.displayedText == "逝世世事")
  }

  @Test("SS-D512-008 Results from a previous generation are discarded")
  func test_SS_D512_008_StaleResult() async {
    prepareD512Fixture()
    typeSentenceOrCandidates("g4g4")
    await withCheckedContinuation { continuation in
      let rerank = testHandler.d512SentenceRerank
      rerank.evaluationCompleted = {
        rerank.evaluationCompleted = nil
        continuation.resume()
      }
      rerank.evaluate(testHandler)
      press(.backspaceEvent)
    }
    #expect(testHandler.assembler.length == 1)
    #expect(testHandler.d512SentenceRerank.lastEvaluation == nil)
    #expect(!testHandler.d512SentenceRerank.hasPin)
    #expect(testSession.state.displayedText == "試")
  }

  @Test("SS-D512-009 Next key and Escape withdraw pins")
  func test_SS_D512_009_WithdrawAndEscape() async {
    prepareD512Fixture()
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    #expect(testHandler.d512SentenceRerank.hasPin)
    testHandler.prefs.useD512SentenceRerank = false
    press(.dataArrowHome)
    #expect(!testHandler.d512SentenceRerank.hasPin)
    #expect(testSession.state.displayedText == "試試")
    testHandler.prefs.useD512SentenceRerank = true
    press(.dataArrowEnd)
    await waitForD512()
    #expect(testHandler.d512SentenceRerank.hasPin)
    testHandler.prefs.escToCleanInputBuffer = true
    press(.escEvent)
    #expect(testHandler.assembler.isEmpty)
    #expect(!testHandler.d512SentenceRerank.hasPin)
  }

  @Test("SS-D512-010 Context uses actual insertions and clears on client change or loss of focus")
  func test_SS_D512_010_ContextLifecycle() async throws {
    prepareD512Fixture()
    testSession.commit(text: String(repeating: "甲", count: 70) + "乙")
    #expect(testHandler.d512SentenceRerank.context == String(repeating: "甲", count: 63) + "乙")
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    #expect(testHandler.d512SentenceRerank.lastEvaluation?.request.context == String(repeating: "甲", count: 63) + "乙")
    testSession.updateClientProxyObjectIdentifier(MockClientProxy())
    #expect(testHandler.d512SentenceRerank.context.isEmpty)
    #expect(!testHandler.d512SentenceRerank.hasPin)
    testSession.commit(text: "上下文")
    testSession.performServerDeactivation()
    #expect(testHandler.d512SentenceRerank.context.isEmpty)
  }

  @Test("SS-D512-011 POM overrides remain in the search graph and conflicts are reported")
  func test_SS_D512_011_POMConflict() async throws {
    prepareD512Fixture()
    struct OverrideScorer: D512Scoring {
      func logProb(_ input: D512Input) throws -> Double { input.targetIds == [2, 2] ? 100 : -10 }
    }
    try testHandler.assembler.insertKeys([.singleKey("ㄕˋ"), .singleKey("ㄕˋ")])
    try testHandler.assembler.overrideCandidate(
      .init(keyArray: ["ㄕˋ", "ㄕˋ"], value: "逝世"), at: 0, type: .withSpecified,
      isExplicitlyOverridden: false
    )
    testHandler.assembler.assemble()
    let original = testHandler.assembler.segments[0][2]?.overrideStatus
    let base = ["試", "逝", "世", "事"]
    let extra = Set(testHandler.assembler.segments.flatMap { $0.values }.flatMap(\.grams)
      .flatMap { $0.current.map(String.init) }).subtracting(base).sorted()
    testHandler.d512SentenceRerank = D512SentenceRerank(
      scorer: OverrideScorer(), vocab: .init(characters: base + extra, bases: ["ㄕ"], neutralTolerantLast: [])
    )
    testHandler.d512SentenceRerank.debounceSeconds = 0.01
    testSession.switchState(testHandler.generateStateOfInputting())
    await waitForD512()
    let evaluation = try #require(testHandler.d512SentenceRerank.lastEvaluation)
    #expect(evaluation.paths[evaluation.defaultIndex].text == "逝世")
    // 同節點的其他詞不會展開；模型可繞過軟固定的 POM，沿兩個單字節點走。
    #expect(!evaluation.paths.contains { $0.text == "世事" })
    #expect(testSession.state.displayedText == "試試", "paths=\(evaluation.paths.map(\.text)), model=\(String(describing: evaluation.model))")
    #expect(testHandler.d512SentenceRerank.lastCalibrationRecord?.pomConflict == true)
    #expect(testHandler.d512SentenceRerank.lastCalibrationRecord?.personalConflict == false)
    testHandler.d512SentenceRerank.withdraw(assembler: testHandler.assembler)
    #expect(testHandler.assembler.segments[0][2]?.overrideStatus == original)
  }

  #if canImport(D512RerankONNX)
    @available(macOS 14, *)
    @Test("SS-D512-020 Real sessions export twenty cases for the independent Python harness",
          .enabled(if: ProcessInfo.processInfo.environment["D512_A23_CASES"] != nil,
                   "D512_A23_CASES not supplied"))
    func test_SS_D512_020_RealSessionSample() async throws {
      struct Case: Decodable { let id, context, gold: String; let reading: [String] }
      let env = ProcessInfo.processInfo.environment
      let caseURL = URL(fileURLWithPath: try #require(env["D512_A23_CASES"]))
      let factoryURL = URL(fileURLWithPath: try #require(env["D512_A23_FACTORY"]))
      let modelURL = URL(fileURLWithPath: try #require(env["D512_MODEL_DIR"]))
      let cases = try String(contentsOf: caseURL, encoding: .utf8).split(separator: "\n").map {
        try JSONDecoder().decode(Case.self, from: Data($0.utf8))
      }
      #expect(cases.count == 20)
      prepareD512Fixture()
      testHandler.prefs.usePersonalCandidatePreference = false
      #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(
        textMapData: try String(contentsOf: factoryURL, encoding: .utf8)
      ))
      testHandler.currentLM.injectTestData(userPhrases: { $0.replaceData(textData: "") })
      let scorer = try D512ONNXScorer(modelDirectory: modelURL)
      testHandler.d512SentenceRerank = D512SentenceRerank(scorer: scorer, vocab: scorer.vocab)
      testHandler.d512SentenceRerank.debounceSeconds = 0.01
      var output: [String] = []
      for c in cases {
        testSession.switchState(.ofAbortion())
        testHandler.d512SentenceRerank.leaveClient(assembler: testHandler.assembler)
        testSession.commit(text: c.context)
        testClientProxy.clear()
        for key in c.reading { try testHandler.assembler.insertKeys([.singleKey(key)]) }
        testSession.switchState(testHandler.generateStateOfInputting())
        await waitForD512()
        let evaluation = try #require(testHandler.d512SentenceRerank.lastEvaluation)
        let visible = testSession.state.displayedText
        press(.dataEnterReturn)
        #expect(testClientProxy.committedText == visible, "\(c.id): actual insertion differs")
        #expect(visible == evaluation.paths[evaluation.choice].text, "\(c.id): chosen path differs")
        let row: [String: Any] = [
          "id": c.id, "context": evaluation.request.context, "reading": evaluation.request.reading,
          "gold": c.gold, "engine_default": evaluation.defaultIndex,
          "candidates": evaluation.paths.map { ["text": $0.text, "log_score": $0.raw] as [String: Any] },
          "swift_model": evaluation.model.map { $0 as Any } ?? NSNull(),
          "swift_choice": evaluation.choice, "committed": testClientProxy.committedText,
        ]
        output.append(String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self))
      }
      try (output.joined(separator: "\n") + "\n").write(
        to: caseURL.deletingLastPathComponent().appendingPathComponent("a23-session20-results.jsonl"),
        atomically: true, encoding: .utf8
      )
    }
  #endif

  private struct D512FakeScorer: D512Scoring {
    func logProb(_ input: D512Input) throws -> Double {
      input.targetIds.suffix(2) == [4, 5] ? 0 : -10
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
