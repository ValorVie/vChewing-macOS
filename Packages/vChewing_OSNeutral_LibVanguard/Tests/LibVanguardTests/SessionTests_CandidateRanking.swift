// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import Shared
import Testing
@testable import LexiconAssembly
@testable import LibVanguard

extension LibVanguardTestsRoot.InputHandlerTests.Session {
  @Test("SS-CandidateRanking-001 A manual choice is learned only after real client insertion")
  func test_SS_CandidateRanking_001_ManualCommit() throws {
    prepareCandidateRankingData()
    try openRankingComposition()
    let initial = rankingValues()
    #expect(initial == ["試試", "逝世", "世事"])
    let index = try #require(testSession.state.candidates.firstIndex { $0.value == "世事" })
    testSession.candidatePairSelectionConfirmed(at: index)
    #expect(testClientProxy.committedText.isEmpty)
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "世事")
    try openRankingComposition()
    #expect(rankingValues() == ["世事", "試試", "逝世"])
    #expect(testHandler.assembler.assembledSentence.map(\.value).joined() == "試試")
  }

  @Test("SS-CandidateRanking-002 Node identities survive shifts but not deletion and reinsertion")
  func test_SS_CandidateRanking_002_NodeIdentity() throws {
    prepareCandidateRankingData()
    try openRankingComposition()
    let assembler = testHandler.assembler
    let original = try #require(assembler.segments[0][2]?.id)
    let firstToken = try #require(assembler.segments[0][1]?.id)
    assembler.cursor = 0
    try assembler.insertKeys([Homa.PossibleKey.singleKey("ㄕˋ")])
    #expect(assembler.segments[1][2]?.id == original)
    #expect(assembler.segments[1][1]?.id == firstToken)
    assembler.cursor = 1
    try assembler.dropKey(direction: .rear)
    #expect(assembler.segments[0][2]?.id == original)
    assembler.cursor = 1
    try assembler.dropKey(direction: .rear)
    assembler.cursor = 0
    try assembler.insertKeys([Homa.PossibleKey.singleKey("ㄕˋ")])
    #expect(assembler.segments[0][2]?.id != original)
    #expect(assembler.segments[0][1]?.id != firstToken)
  }

  @Test("SS-CandidateRanking-003 Replacing A with B learns only B; cancellation and preview do not learn")
  func test_SS_CandidateRanking_003_ReplaceAndCancel() throws {
    prepareCandidateRankingData()
    try openRankingComposition()
    try selectRankingValue("逝世")
    _ = openCandidateWindow(cursor: 2)
    try selectRankingValue("世事")
    press(.dataEnterReturn)
    #expect(rankingCount("逝世") == 0)
    #expect(rankingCount("世事") == 1)
    try openRankingComposition()
    try selectRankingValue("逝世")
    testSession.switchState(.ofAbortion())
    #expect(rankingCount("逝世") == 0)
    try openRankingComposition()
    highlightNextCandidate()
    testSession.switchState(.ofAbortion())
    #expect(rankingCount("逝世") == 0)
  }

  @Test("SS-CandidateRanking-004 Deleting a choice then retyping the same word does not resurrect it")
  func test_SS_CandidateRanking_004_DeleteAndRetype() throws {
    prepareCandidateRankingData()
    try openRankingComposition()
    try selectRankingValue("試試")
    testHandler.assembler.cursor = 2
    press(.backspaceEvent)
    typeSentenceOrCandidates("g4")
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "試試")
    #expect(rankingCount("試試") == 0)
  }

  @Test("SS-CandidateRanking-005 Same-reading positions stay distinct and latest follows selection order")
  func test_SS_CandidateRanking_005_PositionsAndOrder() throws {
    prepareCandidateRankingData()
    try openRankingComposition(keys: Array(repeating: "ㄕˋ", count: 4))
    try selectRankingValue("世事")
    _ = openCandidateWindow(cursor: 2)
    try selectRankingValue("逝世")
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "逝世世事")
    #expect(rankingCount("逝世") == 1)
    #expect(rankingCount("世事") == 1)
    try openRankingComposition()
    #expect(rankingValues() == ["逝世", "世事", "試試"])
  }

  @Test("SS-CandidateRanking-006 Changed output, missing client, empty commit and duplicate commit do not learn")
  func test_SS_CandidateRanking_006_CommitEvidence() throws {
    prepareCandidateRankingData()
    try openRankingComposition()
    try selectRankingValue("世事")
    SessionHost.shared.kanjiConversionIfRequired = { _ in "不同輸出" }
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "不同輸出")
    #expect(rankingCount("世事") == 0)
    SessionHost.shared.kanjiConversionIfRequired = { $0 }
    try openRankingComposition()
    try selectRankingValue("世事")
    let address = testSession.inputControllerAssignedAddr
    testSession.inputControllerAssignedAddr = nil
    testSession.switchState(.ofCommitting(textToCommit: "世事"))
    #expect(rankingCount("世事") == 0)
    testSession.inputControllerAssignedAddr = address
    try openRankingComposition()
    try selectRankingValue("世事")
    testSession.commit(text: "", clearDisplayBeforeCommit: false)
    #expect(rankingCount("世事") == 0)
    press(.dataEnterReturn)
    testSession.commit(text: "世事", clearDisplayBeforeCommit: false)
    #expect(rankingCount("世事") == 1)
  }

  @Test("SS-CandidateRanking-007 PCB commits whole choices, but a split choice waits for its entire tail")
  func test_SS_CandidateRanking_007_Overflow() throws {
    prepareCandidateRankingData()
    testHandler.prefs.securityHardenedCompositionBuffer = true
    try openRankingComposition()
    try selectRankingValue("世事")
    try appendRankingReadings(20)
    #expect(testHandler.assembler.length == 22)
    #expect(!testHandler.assembler.assembledSentence.isEmpty)
    #expect(testHandler.session === testSession)
    #expect(testSession.clientMitigationLevel >= 2)
    let whole = testHandler.commitOverflownComposition
    #expect(whole == "世事")
    var inputting = testHandler.generateStateOfInputting()
    inputting.textToCommit = whole
    testSession.switchState(inputting)
    #expect(rankingCount("世事") == 1)
    testSession.switchState(.ofAbortion())
    #expect(rankingCount("世事") == 1)

    try openRankingComposition()
    try selectRankingValue("逝世")
    try appendRankingReadings(19)
    let prefix = testHandler.commitOverflownComposition
    #expect(prefix == "逝")
    inputting = testHandler.generateStateOfInputting()
    inputting.textToCommit = prefix
    testSession.switchState(inputting)
    #expect(rankingCount("逝世") == 0)
    try testHandler.assembler.insertKeys([Homa.PossibleKey.singleKey("ㄕˋ")])
    let suffix = testHandler.commitOverflownComposition
    #expect(suffix == "世")
    inputting = testHandler.generateStateOfInputting()
    inputting.textToCommit = suffix
    testSession.switchState(inputting)
    #expect(rankingCount("逝世") == 1)
    testSession.switchState(inputting)
    #expect(rankingCount("逝世") == 1)
  }

  @Test("SS-CandidateRanking-008 Aborting a partially inserted choice does not learn its missing tail")
  func test_SS_CandidateRanking_008_OverflowCancellation() throws {
    prepareCandidateRankingData()
    testHandler.prefs.securityHardenedCompositionBuffer = true
    try openRankingComposition()
    try selectRankingValue("世事")
    try appendRankingReadings(19)
    let prefix = testHandler.commitOverflownComposition
    var inputting = testHandler.generateStateOfInputting()
    inputting.textToCommit = prefix
    testSession.switchState(inputting)
    testSession.switchState(.ofAbortion())
    #expect(testClientProxy.committedText == "世")
    #expect(rankingCount("世事") == 0)
  }

  @Test("SS-CandidateRanking-009 The contract sequence and 10/5/1 counts use real manual commits")
  func test_SS_CandidateRanking_009_Contract() throws {
    prepareCandidateRankingData()
    for value in ["試試", "逝世", "世事"] {
      try commitRankingValue(value)
      try openRankingComposition()
      #expect(rankingValues().first == value)
    }
    #expect(rankingValues() == ["世事", "試試", "逝世"])
    testHandler.currentLM = LXAssembly.LXFacade(isCHS: false)
    prepareCandidateRankingData()
    for _ in 0 ..< 10 { try commitRankingValue("試試") }
    for _ in 0 ..< 5 { try commitRankingValue("逝世") }
    try commitRankingValue("世事")
    try openRankingComposition()
    #expect(rankingValues() == ["世事", "試試", "逝世"])
    try commitRankingValue("試試")
    try openRankingComposition()
    #expect(rankingValues() == ["試試", "逝世", "世事"])
    #expect(["試試", "逝世", "世事"].map(rankingCount) == [11, 5, 1])
  }

  @Test("SS-CandidateRanking-010 Single characters learn; fixed, ETen, SCPC and Furious gates retain upstream order")
  func test_SS_CandidateRanking_010_ModeGates() throws {
    prepareCandidateRankingData()
    try openRankingComposition(keys: ["ㄕˋ"])
    try selectRankingValue("市")
    press(.dataEnterReturn)
    let single = Homa.CandidatePair(keyArray: ["ㄕˋ"], value: "市")
    #expect(testHandler.currentLM.candidateRanking.count(for: single) == 1)
    try openRankingComposition(keys: ["ㄕˋ"])
    #expect(testSession.state.candidates.first?.value == "市")
    testHandler.prefs.enforceETenDOSCandidateSequence = true
    let fixedSingles = testHandler.generateArrayOfCandidates(fixOrder: true).map(\.value)
    #expect(testHandler.generateArrayOfCandidates(fixOrder: false).map(\.value) == fixedSingles)
    testHandler.currentLM.candidateRanking.recordCommittedCandidate(.init(keyArray: ["ㄕˋ", "ㄕˋ"], value: "世事"))
    try openRankingComposition()
    #expect(rankingValues().first == "世事")
    testHandler.prefs.useFixedCandidateOrderOnSelection = true
    #expect(testHandler.generateArrayOfCandidates(fixOrder: false).filter { $0.keyArray.count == 2 }.map(\.value) ==
      ["試試", "逝世", "世事"])
    testHandler.prefs.useFixedCandidateOrderOnSelection = false
    #expect(testHandler.generateArrayOfCandidates(fixOrder: true).filter { $0.keyArray.count == 2 }.map(\.value) ==
      ["試試", "逝世", "世事"])
    testHandler.prefs.furiousTypingEnabled4Zhuyin = true
    #expect(testHandler.generateArrayOfCandidates(fixOrder: false).filter { $0.keyArray.count == 2 }.map(\.value) ==
      ["試試", "逝世", "世事"])
    testHandler.prefs.furiousTypingEnabled4Zhuyin = false
    testHandler.prefs.furiousTypingEnabled4Pinyin = true
    #expect(testHandler.generateArrayOfCandidates(fixOrder: false).first?.value == "世事")
    testHandler.prefs.furiousTypingEnabled4Pinyin = false
    testHandler.prefs.cassetteEnabled = true
    #expect(testHandler.generateArrayOfCandidates(fixOrder: false).filter { $0.keyArray.count == 2 }.map(\.value) ==
      ["試試", "逝世", "世事"])
    testHandler.prefs.cassetteEnabled = false
    testHandler.prefs.useSCPCTypingMode = true
    try openRankingComposition(keys: ["ㄕˋ"])
    try selectRankingValue("市")
    #expect(testHandler.currentLM.candidateRanking.count(for: single) == 1)
  }

  @Test("SS-CandidateRanking-011 Numeric keys follow the displayed snapshot even after history changes")
  func test_SS_CandidateRanking_011_NumericSnapshot() throws {
    prepareCandidateRankingData(includeSingleTrial: false)
    testHandler.prefs.candidateKeys = "123456789"
    testHandler.currentLM.syncPrefs()
    for index in 0 ..< 9 {
      try openRankingComposition()
      let candidates = testSession.state.candidates.map { Homa.CandidatePair(keyArray: $0.keyArray, value: $0.value) }
      try #require(candidates.count >= 9)
      testHandler.currentLM.candidateRanking.recordCommittedCandidate(
        .init(keyArray: ["ㄕˋ", "ㄕˋ"], value: index.isMultiple(of: 2) ? "世事" : "逝世")
      )
      #expect(testSession.state.candidates.map { Homa.CandidatePair(keyArray: $0.keyArray, value: $0.value) } == candidates)
      let selected = candidates[index]
      let originalCursor = testHandler.assembler.cursor
      let originalAnchor = testHandler.actualNodeCursorPosition
      press(KBEvent.KeyEventData(chars: String(index + 1)))
      let actual = testHandler.assembler.assembledSentence.map(\.asCandidatePair)
      #expect(testHandler.assembler.assembledSentence.findGram(at: originalAnchor)?.gram.asCandidatePair == selected,
              "key \(index + 1); cursor \(originalCursor) -> \(testHandler.assembler.cursor); anchor \(originalAnchor); path \(actual)")
      testSession.switchState(.ofAbortion())
    }
  }

  @Test("SS-CandidateRanking-012 Actual keyboard overflow learns the whole choice exactly once")
  func test_SS_CandidateRanking_012_KeyboardOverflow() throws {
    prepareCandidateRankingData()
    testHandler.prefs.securityHardenedCompositionBuffer = true
    try openRankingComposition()
    try selectRankingValue("世事")
    testHandler.assembler.cursor = testHandler.assembler.length
    for _ in 0 ..< 20 { typeSentenceOrCandidates("g4") }
    #expect(testClientProxy.committedText == "世事")
    #expect(rankingCount("世事") == 1)
    #expect(rankingCount("試試") == 0)
    testSession.switchState(.ofAbortion())
    #expect(rankingCount("世事") == 1)
  }

  @Test("SS-CandidateRanking-013 Shared facades and restart keep simplified and traditional histories separate")
  func test_SS_CandidateRanking_013_SharedFacades() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let originalURLProvider = SessionHost.shared.candidateRankingDataURL
    defer {
      SessionHost.shared.candidateRankingDataURL = originalURLProvider
      Shared.InputMode.resetLexiconCache(forUnitTests: true)
      try? FileManager.default.removeItem(at: root)
    }
    SessionHost.shared.candidateRankingDataURL = { root.appendingPathComponent($0.rawValue + ".json") }
    Shared.InputMode.resetLexiconCache(forUnitTests: true)
    let traditional = Shared.InputMode.imeModeCHT.lexicon
    let otherSessionModel = Shared.InputMode.imeModeCHT.lexicon
    let simplified = Shared.InputMode.imeModeCHS.lexicon
    #expect(traditional === otherSessionModel)
    let pair = Homa.CandidatePair(keyArray: ["ㄕˋ", "ㄕˋ"], value: "世事")
    traditional.candidateRanking.recordCommittedCandidate(pair)
    traditional.candidateRanking.flushPendingWrites()
    simplified.candidateRanking.flushPendingWrites()
    #expect(otherSessionModel.candidateRanking.count(for: pair) == 1)
    #expect(simplified.candidateRanking.count(for: pair) == 0)
    Shared.InputMode.resetLexiconCache(forUnitTests: true)
    let reloaded = Shared.InputMode.imeModeCHT.lexicon
    reloaded.candidateRanking.flushPendingWrites()
    Shared.InputMode.imeModeCHS.lexicon.candidateRanking.flushPendingWrites()
    #expect(reloaded.candidateRanking.count(for: pair) == 1)
  }

  @Test("SS-CandidateRanking-014 POM preferences and suggestions cannot replace the new model's latest choice")
  func test_SS_CandidateRanking_014_POMIndependence() throws {
    prepareCandidateRankingData()
    testHandler.currentLM.candidateRanking.recordCommittedCandidate(.init(keyArray: ["ㄕˋ", "ㄕˋ"], value: "世事"))
    testHandler.currentLM.injectTestData(lxPerceptor: {
      var suggestion = LXAssembly.OverrideSuggestion()
      suggestion.candidates = [(keyArray: ["ㄕˋ", "ㄕˋ"], value: "逝世", probability: 0, previous: nil)]
      $0.testInjectedSuggestion = suggestion
    })
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    try openRankingComposition()
    let sentence = testHandler.assembler.assembledSentence
    #expect(rankingValues().first == "世事")
    _ = testHandler.generateArrayOfCandidates(fixOrder: false)
    #expect(testHandler.assembler.assembledSentence == sentence)
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
    #expect(testHandler.generateArrayOfCandidates(fixOrder: false).first?.value == "世事")
  }

  @Test("SS-CandidateRanking-015 A longer prefix-match gram cannot borrow a different node's span")
  func test_SS_CandidateRanking_015_PrefixSpan() throws {
    prepareCandidateRankingData()
    let keys = Array(repeating: "ㄕˋ", count: 4)
    testHandler.assembler = Homa.Assembler(gramQuerier: { query in
      switch query.count {
      case 1: return [Homa.Gram(keyArray: ["ㄕˋ"], value: "試", score: -10)]
      case 2: return [Homa.Gram(keyArray: keys, value: "甲乙丙丁", score: -1)]
      case 4: return [Homa.Gram(keyArray: keys, value: "戊己庚辛", score: -100)]
      default: return []
      }
    })
    try appendRankingReadings(4)
    testHandler.assembler.cursor = 2
    testSession.switchState(testHandler.generateStateOfInputting())
    _ = openCandidateWindow()
    try selectRankingValue("甲乙丙丁")
    press(.dataEnterReturn)
    #expect(!testClientProxy.committedText.isEmpty)
    #expect(testHandler.currentLM.candidateRanking.count(for: .init(keyArray: keys, value: "甲乙丙丁")) == 0)
  }

  @Test("SS-CandidateRanking-016 POM learning can remain enabled or be cleared without changing the new history")
  func test_SS_CandidateRanking_016_POMLearning() throws {
    prepareCandidateRankingData()
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    try commitRankingValue("世事")
    #expect(rankingCount("世事") == 1)
    testHandler.currentLM.clearPOMData()
    #expect(rankingCount("世事") == 1)
    try openRankingComposition()
    #expect(rankingValues().first == "世事")
  }

  @Test("SS-CandidateRanking-017 Tab learns its selected word only when the real client receives it")
  func test_SS_CandidateRanking_017_Tab() throws {
    try prepareRankingRevolution()
    press(.tabEvent)
    #expect(testHandler.assembler.assembledSentence.map(\.value).joined() == "逝世")
    #expect(rankingCount("逝世") == 0)
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "逝世")
    #expect(rankingCount("逝世") == 1)
    try openRankingComposition()
    #expect(rankingValues().first == "逝世")
  }

  @Test("SS-CandidateRanking-018 Shift+Tab replaces an earlier pending window choice")
  func test_SS_CandidateRanking_018_ShiftTab() throws {
    prepareCandidateRankingData(includeSingleTrial: false)
    testHandler.currentLM.syncPrefs()
    try openRankingComposition()
    try selectRankingValue("世事")
    var reverse = KBEvent.KeyEventData.tabEvent
    reverse.flags = [.shift]
    press(reverse)
    #expect(testHandler.assembler.assembledSentence.map(\.value).joined() == "逝世")
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "逝世")
    #expect(rankingCount("世事") == 0)
    #expect(rankingCount("逝世") == 1)
  }

  @Test("SS-CandidateRanking-019 Repeated Tab learns only the final choice; abort and failed Tab do not learn")
  func test_SS_CandidateRanking_019_RepeatedTab() throws {
    try prepareRankingRevolution()
    press(.tabEvent)
    press(.tabEvent)
    #expect(testHandler.assembler.assembledSentence.map(\.value).joined() == "世事")
    #expect(rankingCount("逝世") == 0)
    #expect(rankingCount("世事") == 0)
    press(.dataEnterReturn)
    #expect(rankingCount("逝世") == 0)
    #expect(rankingCount("世事") == 1)
    try openRankingComposition()
    testSession.switchState(testHandler.generateStateOfInputting())
    press(.tabEvent)
    testSession.switchState(.ofAbortion())
    #expect(rankingCount("逝世") == 0)
    press(.tabEvent, shouldHandle: false)
    #expect(rankingCount("世事") == 1)
  }

  @Test("SS-CandidateRanking-020 A programmatic revolve without a manual event does not learn")
  func test_SS_CandidateRanking_020_AutomaticRevolve() throws {
    try prepareRankingRevolution()
    #expect(testHandler.revolveCandidate(reverseOrder: false))
    #expect(testHandler.assembler.assembledSentence.map(\.value).joined() == "逝世")
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "逝世")
    #expect(rankingCount("逝世") == 0)
  }

  private func prepareRankingRevolution() throws {
    prepareCandidateRankingData(includeSingleTrial: false)
    testHandler.currentLM.syncPrefs()
    try openRankingComposition()
    testSession.switchState(testHandler.generateStateOfInputting())
  }

  private func commitRankingValue(_ value: String) throws {
    testClientProxy.clear()
    try openRankingComposition()
    try selectRankingValue(value)
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == value)
  }

  private func selectRankingValue(_ value: String) throws {
    let index = try #require(testSession.state.candidates.firstIndex { $0.value == value })
    testSession.candidatePairSelectionConfirmed(at: index)
  }

  private func appendRankingReadings(_ count: Int) throws {
    testHandler.assembler.cursor = testHandler.assembler.length
    for _ in 0 ..< count {
      try testHandler.assembler.insertKeys([Homa.PossibleKey.singleKey("ㄕˋ")])
    }
  }

  private func rankingCount(_ value: String) -> UInt64 {
    testHandler.currentLM.candidateRanking.count(for: .init(keyArray: ["ㄕˋ", "ㄕˋ"], value: value))
  }

  private func prepareCandidateRankingData(includeSingleTrial: Bool = true) {
    testSession.prefs = testHandler.prefs
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.useFixedCandidateOrderOnSelection = false
    testHandler.prefs.enforceETenDOSCandidateSequence = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
    testHandler.prefs.furiousTypingEnabled4Pinyin = false
    testHandler.prefs.furiousTypingEnabled4Zhuyin = false
    testHandler.prefs.useRearCursorMode = false
    testHandler.prefs.phraseReplacementEnabled = false
    testHandler.prefs.dodgeInvalidEdgeCandidateCursorPosition = false
    testHandler.prefs.keyboardParser = KeyboardParser.ofStandard.rawValue
    testHandler.ensureKeyboardParser()
    testHandler.currentLM.injectTestData(userPhrases: {
      let single = includeSingleTrial ? "試 ㄕˋ -0.5\n" : ""
      $0.replaceData(textData: single + "試試 ㄕˋ-ㄕˋ -1\n逝世 ㄕˋ-ㄕˋ -2\n世事 ㄕˋ-ㄕˋ -3\n")
    })
  }

  private func openRankingComposition(keys: [String] = ["ㄕˋ", "ㄕˋ"]) throws {
    testSession.switchState(.ofAbortion())
    try testHandler.assembler.insertKeys(keys.map { Homa.PossibleKey.singleKey($0) })
    testHandler.assembler.cursor = keys.count
    testSession.switchState(testHandler.generateStateOfInputting())
    _ = openCandidateWindow()
  }

  private func rankingValues() -> [String] {
    testSession.state.candidates.filter { $0.keyArray == ["ㄕˋ", "ㄕˋ"] }.map(\.value)
  }
}
