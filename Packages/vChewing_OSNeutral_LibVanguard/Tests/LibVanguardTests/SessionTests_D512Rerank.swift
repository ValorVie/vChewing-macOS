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

  @Test("SS-D512-012 A swallowed function key refreshes the withdrawn pin and restarts debounce")
  func test_SS_D512_012_FunctionKey() async {
    prepareD512Fixture()
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    press(.functionKeyEvent(.kF1))
    let visible = testSession.state.displayedText
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == visible)
    prepareD512Fixture()
    typeSentenceOrCandidates("g4g4")
    press(.functionKeyEvent(.kF1))
    await waitForD512()
    #expect(testSession.state.displayedText == "世事")
  }

  @Test("SS-D512-R1-001 Client exits preserve displayed commits without refilling cleared context",
        arguments: ["deactivate_other", "deactivate_current", "session", "client"], [0.5, 100.0])
  func test_SS_D512_R1_001_ClientExit(_ boundary: String, _ margin: Double) async {
    prepareD512Fixture()
    testHandler.prefs.d512RerankMargin = margin
    InputSession.current = ["deactivate_current", "session"].contains(boundary) ? testSession : nil
    defer { InputSession.current = nil }
    testSession.commit(text: "前文")
    testClientProxy.clear()
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    let visible = testSession.state.displayedText
    #expect(visible == (margin == 0.5 ? "世事" : "試試"))
    #expect(testHandler.d512SentenceRerank.context == "前文")
    switch boundary {
    case "deactivate_other":
      testSession.performServerDeactivation()
    case "deactivate_current":
      testSession.performServerDeactivation()
      #expect(testSession.state.displayedText == visible)
      #expect(testHandler.d512SentenceRerank.context.isEmpty)
      testSession.commitComposition()
    case "session":
      InputSession.current = nil
      #expect(testHandler.d512SentenceRerank.context.isEmpty)
      // 切 session 後緊接停用，第二次 leaveClient 不得蓋掉第一次保存的畫面句。
      testSession.performServerDeactivation()
    default:
      testSession.updateClientProxyObjectIdentifier(MockClientProxy())
      #expect(testHandler.d512SentenceRerank.context.isEmpty)
      testSession.commitComposition()
    }
    #expect(testClientProxy.committedText == visible)
    #expect(testHandler.d512SentenceRerank.context.isEmpty)
    #expect(!testHandler.d512SentenceRerank.hasPin)
  }

  @Test("SS-D512-R1-002 Disabled reranking does not collect committed context")
  func test_SS_D512_R1_002_DisabledContext() {
    prepareD512Fixture()
    testHandler.prefs.useD512SentenceRerank = false
    testSession.commit(text: "關閉期間的文字")
    #expect(testHandler.d512SentenceRerank.context.isEmpty)
  }

  @Test("SS-D512-R1-003 Shift Enter derives associates from the displayed final segment")
  func test_SS_D512_R1_003_Associates() async {
    prepareD512Fixture()
    testHandler.prefs.associatedPhrasesEnabled = true
    testHandler.currentLM.injectTestData(associates: {
      $0.replaceData(textData: "試試 看\n世事 難料\n")
    })
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    let visible = testSession.state.displayedText
    press(.shiftEnterEvent)
    #expect(testClientProxy.committedText == visible)
    #expect(testSession.state.candidates.contains { $0.value == "難料" })
    #expect(!testSession.state.candidates.contains { $0.value == "看" })
  }

  @Test("SS-D512-R2-001 Read-only queries preserve the displayed commit across client exits",
        arguments: ["current", "session", "client"])
  func test_SS_D512_R2_001_ComposedStringBeforeCommit(_ boundary: String) async {
    prepareD512Fixture()
    InputSession.current = testSession
    defer { InputSession.current = nil }
    testSession.commit(text: "前文")
    testClientProxy.clear()
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    let visible = testSession.state.displayedText
    #expect(visible == "世事")
    let rerank = testHandler.d512SentenceRerank
    let oldEpoch = rerank.clientEpoch
    switch boundary {
    case "current": testSession.performServerDeactivation()
    case "session": InputSession.current = nil
    default: testSession.updateClientProxyObjectIdentifier(MockClientProxy())
    }
    #expect(rerank.keyCommitSnapshot?.text == visible)
    #expect(rerank.pendingCommitClientEpoch == oldEpoch)
    // 只產生狀態、沒有重繪的呼叫者也必須保留待送資料。
    _ = testHandler.generateStateOfInputting(sansReading: true)
    #expect(rerank.keyCommitSnapshot?.text == visible)
    #expect(rerank.pendingCommitClientEpoch == oldEpoch)
    let queried = testSession.composedString() as? String
    #expect(queried == visible)
    #expect(testSession.state.displayedText == visible)
    #expect(rerank.keyCommitSnapshot?.text == visible)
    #expect(rerank.pendingCommitClientEpoch == oldEpoch)
    testSession.commitComposition()
    #expect(testClientProxy.committedText == visible)
    #expect(rerank.context.isEmpty)
    #expect(rerank.keyCommitSnapshot == nil)
    #expect(rerank.pendingCommitClientEpoch == nil)
  }

  @Test("SS-D512-R2-002 Settings redraw replaces the pending displayed commit without a key event",
        arguments: ["d512", "personal"])
  func test_SS_D512_R2_002_SettingsRedraw(_ setting: String) async {
    prepareD512Fixture()
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    #expect(testSession.state.displayedText == "世事")
    testSession.updateClientProxyObjectIdentifier(MockClientProxy())
    let rerank = testHandler.d512SentenceRerank
    #expect(rerank.keyCommitSnapshot != nil)
    #expect(rerank.pendingCommitClientEpoch != nil)
    testHandler.prefs.useD512SentenceRerank = false
    if setting == "d512" {
      testSession.refreshD512SentenceRerank()
    } else {
      testHandler.prefs.usePersonalCandidatePreference = false
      testSession.refreshPersonalCandidatePreference()
    }
    let redrawn = testSession.state.displayedText
    #expect(redrawn == "試試")
    #expect(rerank.keyCommitSnapshot == nil)
    #expect(rerank.pendingCommitClientEpoch == nil)
    #expect(testSession.composedString() as? String == redrawn)
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == redrawn)
    #expect(rerank.context.isEmpty)
    #expect(rerank.keyCommitSnapshot == nil)
    #expect(rerank.pendingCommitClientEpoch == nil)
  }

  @Test("SS-D512-R2-003 Snapshot queries apply kanji conversion only when both lengths match")
  func test_SS_D512_R2_003_ConvertedSnapshot() async {
    prepareD512Fixture()
    let originalConversion = SessionHost.shared.kanjiConversionIfRequired
    defer { SessionHost.shared.kanjiConversionIfRequired = originalConversion }
    let sameLengthConversion: (String) -> String = {
      $0.replacingOccurrences(of: "世", with: "丗")
    }
    SessionHost.shared.kanjiConversionIfRequired = sameLengthConversion
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    #expect(testSession.state.displayedText == "世事")
    #expect(IMEStateParsed(testSession.state).displayedTextConverted == "丗事")
    testSession.updateClientProxyObjectIdentifier(MockClientProxy())
    #expect(testSession.composedString() as? String == "丗事")
    // 字元數相同、UTF-16 長度不同的轉換也不能改動組字查詢。
    SessionHost.shared.kanjiConversionIfRequired = {
      $0.replacingOccurrences(of: "世", with: "😀")
    }
    #expect(testSession.composedString() as? String == "世事")
    // UTF-16 長度相同、字元數不同也須保留原文。
    SessionHost.shared.kanjiConversionIfRequired = {
      $0.replacingOccurrences(of: "世事", with: "😀")
    }
    #expect(testSession.composedString() as? String == "世事")
    SessionHost.shared.kanjiConversionIfRequired = sameLengthConversion
    testSession.commitComposition()
    #expect(testClientProxy.committedText == "丗事")
    #expect(testHandler.d512SentenceRerank.context.isEmpty)
    #expect(testHandler.d512SentenceRerank.keyCommitSnapshot == nil)
    #expect(testHandler.d512SentenceRerank.pendingCommitClientEpoch == nil)
  }

  @Test("SS-D512-A25-S1 Suggestion preserves the default and only shows changed text", arguments: [2, 4])
  func test_SS_D512_A25_S1_Suggest(_ readings: Int) async throws {
    let url = prepareD512SuggestFixture()
    typeSentenceOrCandidates(readings == 2 ? "g4g4" : "g4g4g4g4")
    let cursor = testHandler.assembler.cursor
    await waitForD512()
    #expect(testSession.state.displayedText == (readings == 2 ? "試試" : "試試試試"))
    #expect(testHandler.assembler.cursor == cursor)
    #expect(!testHandler.d512SentenceRerank.hasPin)
    #expect(testStatusUI.isShown)
    #expect(testStatusUI.shownTooltip == "⇥ 世事")
    #expect(testHandler.d512SentenceRerank.pendingSuggestion != nil)
    let row = try #require(d512CalibrationRows(url).first)
    #expect(row["mode"] as? String == "suggest")
    #expect(row["suggested"] as? Bool == true)
    #expect(row["applied"] as? Bool == false)
  }

  @Test("SS-D512-A25-S2 The configured key accepts changed nodes as manual selections",
        arguments: [2, 4], [0, 1, 2])
  func test_SS_D512_A25_S2_Accept(_ readings: Int, _ acceptKey: Int) async throws {
    let url = prepareD512SuggestFixture()
    testHandler.prefs.d512SuggestionAcceptKey = acceptKey
    typeSentenceOrCandidates(readings == 2 ? "g4g4" : "g4g4g4g4")
    await waitForD512()
    let before = testHandler.assembler.assembledSentence
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    let pomGeneration = LXAssembly.LXFacade.pomGeneration
    var pomSaves = 0
    testHandler.pomSaveCallback = { pomSaves += 1 }
    let pair = Homa.CandidatePair(keyArray: ["ㄕˋ", "ㄕˋ"], value: "世事")
    let store = testHandler.currentLM.candidateRanking
    let count = store.count(for: pair)
    let unchangedPair = Homa.CandidatePair(keyArray: ["ㄕˋ", "ㄕˋ"], value: "試試")
    let unchangedCount = store.count(for: unchangedPair)
    let winner = readings == 2 ? "世事" : "試試世事"
    let start = readings - 2
    testHandler.furiousTrail = ["shi"]
    press(d512AcceptEvent(acceptKey))
    #expect(testHandler.furiousTrail.isEmpty)
    #expect(testSession.state.displayedText == winner)
    #expect(!testStatusUI.isShown)
    #expect(testHandler.d512SentenceRerank.pendingSuggestion == nil)
    #expect(testHandler.candidateSelectionLearning.protectedRanges(assembler: testHandler.assembler).contains(start ..< readings))
    #expect(store.count(for: pair) == count)
    #expect(pomSaves == 1)
    #expect(LXAssembly.LXFacade.pomGeneration == pomGeneration + 1)
    #expect(testHandler.currentLM.fetchPOMSuggestion(
      assembledResult: before, cursor: start, timestamp: Date().timeIntervalSince1970
    ).candidates.contains { $0.value == "世事" })
    // 下一鍵撤回 D512 pin，已接受的手選仍須保留至實際送出才學習。
    press(.dataArrowHome)
    #expect(!testHandler.d512SentenceRerank.hasPin)
    #expect(testSession.state.displayedText == winner)
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == winner)
    #expect(store.count(for: pair) == count + 1)
    #expect(store.count(for: unchangedPair) == unchangedCount)
    let row = try #require(d512CalibrationRows(url).last)
    #expect(row["phase"] as? String == "commit")
    #expect(row["accepted"] as? Bool == true)
  }

  @Test("SS-D512-A25-S3 Ignoring a suggestion does not learn", arguments: ["typing", "enter", "escape"])
  func test_SS_D512_A25_S3_Ignore(_ action: String) async throws {
    let url = prepareD512SuggestFixture()
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    var pomSaves = 0
    testHandler.pomSaveCallback = { pomSaves += 1 }
    let pair = Homa.CandidatePair(keyArray: ["ㄕˋ", "ㄕˋ"], value: "世事")
    let count = testHandler.currentLM.candidateRanking.count(for: pair)
    switch action {
    case "typing":
      typeSentenceOrCandidates("g4")
      #expect(testSession.state.displayedText == "試試試")
      press(.dataEnterReturn)
    case "enter": press(.dataEnterReturn)
    default:
      testHandler.prefs.escToCleanInputBuffer = true
      press(.escEvent)
    }
    #expect(!testStatusUI.isShown)
    #expect(testHandler.d512SentenceRerank.pendingSuggestion == nil)
    #expect(testClientProxy.committedText == (action == "escape" ? "" : action == "typing" ? "試試試" : "試試"))
    #expect(testHandler.currentLM.candidateRanking.count(for: pair) == count)
    #expect(testHandler.candidateSelectionLearning.protectedRanges(assembler: testHandler.assembler).isEmpty)
    #expect(pomSaves == 0)
    let row = try #require(d512CalibrationRows(url).last)
    #expect(row["accepted"] as? Bool == false)
  }

  @Test("SS-D512-A25-S4 Tab without a suggestion follows the selected acceptance key",
        arguments: [0, 1], [0, 1, 2])
  func test_SS_D512_A25_S4_Revolve(_ mode: Int, _ acceptKey: Int) async throws {
    let url = prepareD512SuggestFixture(mode: mode)
    testHandler.prefs.d512SuggestionAcceptKey = acceptKey
    #expect(UserDef(rawValue: "D512RerankMode")?.intDefaultValue == 0)
    testHandler.prefs.d512RerankMargin = 100
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    #expect(testSession.state.displayedText == "試試")
    press(.tabEvent)
    let expected = mode == 1 && acceptKey == 0 ? "試試" : "逝世"
    #expect(testSession.state.displayedText == expected)
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == expected)
    let row = try #require(d512CalibrationRows(url).last)
    #expect(row["mode"] as? String == (mode == 0 ? "automatic" : "suggest"))
    #expect(row["accepted"] is NSNull || (mode == 1 && row["accepted"] as? Bool == false))
  }

  @Test("SS-D512-A25-S5 Client exits and settings discard suggestions", arguments: ["current", "session", "client", "refresh", "off"])
  func test_SS_D512_A25_S5_Discard(_ boundary: String) async throws {
    let url = prepareD512SuggestFixture()
    InputSession.current = testSession
    defer { InputSession.current = nil }
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    var pomSaves = 0
    testHandler.pomSaveCallback = { pomSaves += 1 }
    switch boundary {
    case "current": testSession.performServerDeactivation()
    case "session": InputSession.current = nil
    case "client": testSession.updateClientProxyObjectIdentifier(MockClientProxy())
    case "off":
      testHandler.prefs.useD512SentenceRerank = false
      testSession.refreshD512SentenceRerank()
    default: testSession.refreshD512SentenceRerank()
    }
    #expect(!testStatusUI.isShown)
    #expect(testHandler.d512SentenceRerank.pendingSuggestion == nil)
    #expect(!testHandler.d512SentenceRerank.hasPin)
    #expect(testSession.state.displayedText == "試試")
    testSession.commitComposition()
    #expect(testClientProxy.committedText == "試試")
    #expect(pomSaves == 0)
    let row = try #require(d512CalibrationRows(url).last)
    #expect(row["accepted"] as? Bool == false)
  }

  @Test("SS-D512-A25-R1-001 Accepted words replace overlapping POM pins and learn on commit",
        arguments: [true, false], [true, false])
  func test_SS_D512_A25_R1_001_MergeAcrossPOMPins(_ moveFirst: Bool, _ observePOM: Bool) async throws {
    let url = prepareD512SuggestFixture()
    typeSentenceOrCandidates("g4g4")
    let assembler = testHandler.assembler
    for position in 0 ..< 2 {
      try assembler.overrideCandidate(
        .init(keyArray: ["ㄕˋ"], value: "試"), at: position, type: .withSpecified,
        isExplicitlyOverridden: false
      )
    }
    assembler.assemble()
    #expect(assembler.assembledSentence.map(\.value) == ["試", "試"])
    testSession.switchState(testHandler.generateStateOfInputting())
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = observePOM
    await waitForD512()
    #expect(testHandler.d512SentenceRerank.pendingSuggestion?.text == "世事")
    let pair = Homa.CandidatePair(keyArray: ["ㄕˋ", "ㄕˋ"], value: "世事")
    let store = testHandler.currentLM.candidateRanking
    let count = store.count(for: pair)
    var pomSaves = 0
    testHandler.pomSaveCallback = { pomSaves += 1 }
    press(.tabEvent)
    #expect(testSession.state.displayedText == "世事")
    #expect(!testHandler.d512SentenceRerank.hasPin)
    #expect(pomSaves == (observePOM ? 1 : 0))
    if moveFirst { press(.dataArrowHome) }
    #expect(testSession.state.displayedText == "世事")
    #expect(assembler.assembledSentence.map(\.value) == ["世事"])
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "世事")
    #expect(store.count(for: pair) == count + 1)
    #expect(pomSaves == (observePOM ? 1 : 0))
    let row = try #require(d512CalibrationRows(url).last)
    #expect(row["phase"] as? String == "commit")
    #expect(row["accepted"] as? Bool == true)
  }

  @Test("SS-D512-A25-R1-002 Split suggestions accept atomically", arguments: [false, true])
  func test_SS_D512_A25_R1_002_SplitChanges(_ missingTail: Bool) async throws {
    let url = prepareD512SuggestFixture()
    testHandler.prefs.d512RerankWeight = 3
    let assembler = Homa.Assembler(gramQuerier: { query in
      let keys = query.map(\.first)
      if keys.count == 2 { return [.init(keyArray: keys, current: "試試", probability: -1)] }
      guard keys.count == 1 else { return [] }
      return [Homa.Gram(keyArray: keys, current: "試", probability: -4),
              .init(keyArray: keys, current: "世", probability: -5),
              .init(keyArray: keys, current: "事", probability: -6)]
    })
    try assembler.insertKeys([.singleKey("ㄕˋ"), .singleKey("ㄕˋ")])
    testHandler.assembler = assembler
    testSession.switchState(testHandler.generateStateOfInputting())
    await waitForD512()
    #expect(testHandler.d512SentenceRerank.pendingSuggestion?.changes.map { $0.gram.value } == ["世", "事"])
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    var pomSaves = 0
    testHandler.pomSaveCallback = { pomSaves += 1 }
    let pairs = ["世", "事"].map { Homa.CandidatePair(keyArray: ["ㄕˋ"], value: $0) }
    let store = testHandler.currentLM.candidateRanking
    let counts = pairs.map { store.count(for: $0) }
    if missingTail {
      // 同鍵圖中缺少第二個勝者節點，第一個試套也必須還原，不能留下部分接受。
      var config = assembler.config
      config.segments[1].removeValue(forKey: 1)
      let incomplete = Homa.Assembler(gramQuerier: { _ in [] }, config: config)
      testHandler.assembler = incomplete
      let original = incomplete.createNodeOverrideStatusMirror()
      #expect(!testHandler.d512SentenceRerank.acceptSuggestion(testHandler))
      #expect(incomplete.createNodeOverrideStatusMirror() == original)
      #expect(incomplete.assembledSentence.map(\.value) == ["試試"])
      #expect(!testHandler.d512SentenceRerank.hasPin)
      #expect(testHandler.d512SentenceRerank.lastCalibrationRecord?.accepted == false)
      #expect(testHandler.candidateSelectionLearning.protectedRanges(assembler: incomplete).isEmpty)
      #expect(pomSaves == 0)
      for (index, pair) in pairs.enumerated() { #expect(store.count(for: pair) == counts[index]) }
      return
    }
    press(.tabEvent)
    #expect(testSession.state.displayedText == "世事")
    #expect(!testHandler.d512SentenceRerank.hasPin)
    #expect(pomSaves == 2)
    press(.dataArrowHome)
    #expect(testSession.state.displayedText == "世事")
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "世事")
    for (index, pair) in pairs.enumerated() { #expect(store.count(for: pair) == counts[index] + 1) }
    #expect(pomSaves == 2)
    #expect(try d512CalibrationRows(url).last?["accepted"] as? Bool == true)
  }

  @Test("SS-D512-A25-R2-001 Repeated readings accept the exact suggested node",
        arguments: [(2, false), (3, false), (3, true)])
  func test_SS_D512_A25_R2_001_NodeAnchor(_ configuration: (Int, Bool)) async throws {
    let (length, tail) = configuration
    let url = prepareD512SuggestFixture()
    struct Favor: D512Scoring {
      let desired: [Int64]
      func logProb(_ input: D512Input) throws -> Double { input.targetIds == desired ? 0 : -100 }
    }
    let word = length == 2 ? "世事" : "世事時"
    let expected = tail ? "試" + word : word + "試"
    let ids: [Int64] = length == 2 ? [3, 4] : [3, 4, 5]
    let log = testHandler.d512SentenceRerank.calibrationLog
    testHandler.d512SentenceRerank = D512SentenceRerank(
      scorer: Favor(desired: tail ? [2] + ids : ids + [2]),
      vocab: .init(characters: ["試", "世", "事", "時"], bases: ["ㄕ"], neutralTolerantLast: [])
    )
    testHandler.d512SentenceRerank.calibrationLog = log
    testHandler.d512SentenceRerank.debounceSeconds = 0.01
    let assembler = Homa.Assembler(gramQuerier: { query in
      let keys = query.map(\.first)
      if keys.count == 1 { return [.init(keyArray: keys, current: "試", probability: -4)] }
      guard keys.count == length else { return [] }
      return [.init(keyArray: keys, current: String(repeating: "試", count: length), probability: -1),
              .init(keyArray: keys, current: word, probability: -3)]
    })
    try assembler.insertKeys(Array(repeating: .singleKey("ㄕˋ"), count: length + 1))
    testHandler.assembler = assembler
    testSession.switchState(testHandler.generateStateOfInputting())
    await waitForD512()
    let suggestion = try #require(testHandler.d512SentenceRerank.pendingSuggestion)
    #expect(suggestion.grams.map(\.value).joined() == expected)
    #expect(suggestion.changes.map(\.start) == (tail ? [1] : [0, length]))
    let expectedPOMSaves = tail ? 1 : 2
    let pair = Homa.CandidatePair(keyArray: Array(repeating: "ㄕˋ", count: length), value: word)
    let store = testHandler.currentLM.candidateRanking
    let count = store.count(for: pair)
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    var pomSaves = 0
    testHandler.pomSaveCallback = { pomSaves += 1 }
    press(.tabEvent)
    #expect(testSession.state.displayedText == expected)
    #expect(assembler.assembledSentence.map(\.value).joined() == expected)
    #expect(testHandler.d512SentenceRerank.lastCalibrationRecord?.accepted == true)
    #expect(!testHandler.d512SentenceRerank.hasPin)
    #expect(pomSaves == expectedPOMSaves)
    #expect(store.count(for: pair) == count)
    press(.dataArrowHome)
    #expect(testSession.state.displayedText == expected)
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == expected)
    #expect(store.count(for: pair) == count + 1)
    #expect(pomSaves == expectedPOMSaves)
    let row = try #require(d512CalibrationRows(url).last)
    #expect(row["phase"] as? String == "commit")
    #expect(row["accepted"] as? Bool == true)
  }

  @Test("SS-D512-A26-K1 Dedicated Tab preserves composition; Shift and candidate Tab keep their behavior",
        arguments: ["none", "failed", "shift", "candidates"])
  func test_SS_D512_A26_K1_Tab(_ action: String) async throws {
    _ = prepareD512SuggestFixture()
    if action != "failed" { testHandler.prefs.d512RerankMargin = 100 }
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    if action == "failed" {
      _ = try #require(testHandler.d512SentenceRerank.pendingSuggestion)
      try protectD512DefaultForFailedAcceptance()
    }
    let mirror = testHandler.assembler.createNodeOverrideStatusMirror()
    let cursor = testHandler.assembler.cursor
    if action == "candidates" {
      press(.dataArrowDown)
      #expect(testSession.state.type == .ofCandidates)
      syncCandidateControllerCount()
      press(.tabEvent)
      #expect(testSession.state.type == .ofCandidates)
      #expect(testSession.state.displayedText == "逝世")
    } else if action == "shift" {
      try testHandler.assembler.overrideCandidate(
        .init(keyArray: ["ㄕˋ", "ㄕˋ"], value: "世事"), atSegment: 0, segLength: 2,
        isExplicitlyOverridden: true, perceptionHandler: { _ in }
      )
      testSession.switchState(testHandler.generateStateOfInputting())
      var tab = KBEvent.KeyEventData.tabEvent
      tab.flags = [.shift]
      press(tab)
      #expect(testSession.state.displayedText == "逝世")
    } else {
      press(.tabEvent)
      #expect(testSession.state.displayedText == "試試")
      #expect(testHandler.assembler.cursor == cursor)
      #expect(testHandler.assembler.createNodeOverrideStatusMirror() == mirror)
      #expect(testHandler.d512SentenceRerank.pendingSuggestion == nil)
      #expect(testHandler.d512SentenceRerank.lastCalibrationRecord?.accepted == false)
    }
    #expect(testClientProxy.committedText.isEmpty)
  }

  @Test("SS-D512-A26-K2 Ctrl Tab is dedicated; plain and modified Tab keep their behavior",
        arguments: ["none", "failed", "plain", "modified"])
  func test_SS_D512_A26_K2_ControlTab(_ action: String) async throws {
    _ = prepareD512SuggestFixture()
    testHandler.prefs.d512SuggestionAcceptKey = 1
    if action == "none" { testHandler.prefs.d512RerankMargin = 100 }
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    if action == "failed" { try protectD512DefaultForFailedAcceptance() }
    let mirror = testHandler.assembler.createNodeOverrideStatusMirror()
    let cursor = testHandler.assembler.cursor
    var tab = d512AcceptEvent(1)
    if action == "plain" { tab.flags = [] }
    if action == "modified" { tab.flags = [.control, .option] }
    press(tab)
    #expect(testSession.state.displayedText == (action == "plain" || action == "modified" ? "逝世" : "試試"))
    #expect(testClientProxy.committedText.isEmpty)
    #expect(testHandler.d512SentenceRerank.pendingSuggestion == nil)
    #expect(testHandler.d512SentenceRerank.lastCalibrationRecord?.accepted == false)
    if action == "none" || action == "failed" {
      #expect(testHandler.assembler.cursor == cursor)
      #expect(testHandler.assembler.createNodeOverrideStatusMirror() == mirror)
      #expect(testHandler.candidateSelectionLearning.protectedRanges(assembler: testHandler.assembler).isEmpty == (action == "none"))
    }
  }

  @Test("SS-D512-A26-K3 Forward accepts only at the sentence end in either orientation",
        arguments: [false, true], ["suggestion", "middle", "none"])
  func test_SS_D512_A26_K3_Forward(_ vertical: Bool, _ action: String) async throws {
    let url = prepareD512SuggestFixture()
    testHandler.prefs.d512SuggestionAcceptKey = 2
    testClientProxy.textOrientation = vertical ? 0 : 1
    testSession.updateVerticalTypingStatus()
    if action == "none" { testHandler.prefs.d512RerankMargin = 100 }
    typeSentenceOrCandidates("g4g4")
    if action == "middle" {
      testHandler.assembler.cursor = 1
      testSession.switchState(testHandler.generateStateOfInputting())
    }
    await waitForD512()
    #expect((testHandler.d512SentenceRerank.pendingSuggestion != nil) == (action != "none"))
    let pair = Homa.CandidatePair(keyArray: ["ㄕˋ", "ㄕˋ"], value: "世事")
    let store = testHandler.currentLM.candidateRanking
    let count = store.count(for: pair)
    var pomSaves = 0
    testHandler.pomSaveCallback = { pomSaves += 1 }
    let errors = recordedErrors.count
    press(d512AcceptEvent(2, vertical: vertical))
    let expected = action == "suggestion" ? "世事" : "試試"
    #expect(testSession.state.displayedText == expected)
    #expect(testHandler.assembler.cursor == 2)
    #expect(testHandler.d512SentenceRerank.pendingSuggestion == nil)
    #expect(!testHandler.d512SentenceRerank.hasPin)
    #expect(store.count(for: pair) == count)
    #expect(pomSaves == 0)
    if action == "none" {
      #expect(recordedErrors.count == errors + 1)
      #expect(recordedErrors.last == "A96AAD58")
    }
    if action == "middle" {
      #expect(testHandler.candidateSelectionLearning.protectedRanges(assembler: testHandler.assembler).isEmpty)
    }
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == expected)
    #expect(store.count(for: pair) == count + (action == "suggestion" ? 1 : 0))
    #expect(try d512CalibrationRows(url).last?["accepted"] as? Bool == (action == "suggestion"))
  }

  @Test("SS-D512-A26-K4 Automatic and disabled reranking preserve Tab revolution",
        arguments: [0, 1, 2], [true, false])
  func test_SS_D512_A26_K4_Automatic(_ acceptKey: Int, _ enabled: Bool) async throws {
    _ = prepareD512SuggestFixture(mode: enabled ? 0 : 1)
    testHandler.prefs.d512SuggestionAcceptKey = acceptKey
    testHandler.prefs.d512RerankMargin = 100
    typeSentenceOrCandidates("g4g4")
    await waitForD512()
    testHandler.prefs.useD512SentenceRerank = enabled
    press(.tabEvent)
    #expect(testSession.state.displayedText == "逝世")
    #expect(testClientProxy.committedText.isEmpty)
  }

  private func d512AcceptEvent(_ acceptKey: Int, vertical: Bool = false) -> KBEvent.KeyEventData {
    if acceptKey == 2 { return vertical ? .dataArrowDown : .dataArrowRight }
    var tab = KBEvent.KeyEventData.tabEvent
    if acceptKey == 1 { tab.flags = [.control] }
    return tab
  }

  private func protectD512DefaultForFailedAcceptance() throws {
    try testHandler.assembler.overrideCandidate(
      .init(keyArray: ["ㄕˋ", "ㄕˋ"], value: "試試"), atSegment: 0, segLength: 2,
      isExplicitlyOverridden: true, perceptionHandler: { _ in }
    )
  }

  private func prepareD512SuggestFixture(mode: Int = 1) -> URL {
    prepareD512Fixture()
    testUI.currentSessionID = testSession.id
    testUI.tooltipUI = testStatusUI
    UserDefaults.current.set(mode, forKey: "D512RerankMode")
    testHandler.prefs.logD512Calibration = true
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("calibration.jsonl")
    testHandler.d512SentenceRerank.calibrationLog = D512CalibrationLog(url: url)
    return url
  }

  private func d512CalibrationRows(_ url: URL) throws -> [[String: Any]] {
    testHandler.d512SentenceRerank.calibrationLog.flush()
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
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
    final class Completion { var finished = false }
    await withCheckedContinuation { continuation in
      let completion = Completion()
      let rerank = testHandler.d512SentenceRerank
      rerank.evaluationCompleted = {
        guard !completion.finished else { return }
        completion.finished = true
        rerank.evaluationCompleted = nil
        continuation.resume()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        guard !completion.finished else { return }
        Issue.record("D512 evaluation timed out")
        completion.finished = true
        rerank.evaluationCompleted = nil
        continuation.resume()
      }
    }
  }
}
