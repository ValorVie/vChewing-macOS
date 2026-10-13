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
    #expect(testHandler.assembler.assembledSentence.map(\.value).joined() == "世事")
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

  @Test("SS-PersonalPreference-021 A delivered manual word becomes preedit and Enter without opening candidates")
  func test_SS_PersonalPreference_021_DefaultWord() throws {
    prepareCandidateRankingData()
    try commitRankingValue("逝世")
    testClientProxy.clear()
    typeSentenceOrCandidates("g4g4")
    #expect(testSession.state.type == .ofInputting)
    #expect(testSession.state.displayedText == "逝世")
    #expect(testHandler.assembler.assembledSentence.map(\.value).joined() == "逝世")
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "逝世")
    #expect(rankingCount("逝世") == 1)
  }

  @Test("SS-PersonalPreference-022 Recent single characters yield to a newly formed legal word")
  func test_SS_PersonalPreference_022_SingleToWord() throws {
    prepareCandidateRankingData()
    testHandler.currentLM.injectTestData(userPhrases: {
      $0.replaceData(textData: "試 ㄕˋ -0.5\n世 ㄕˋ -1\n界 ㄐㄧㄝˋ -1\n世界 ㄕˋ-ㄐㄧㄝˋ -0.1\n")
    })
    typeSentenceOrCandidates("g4ru,4")
    #expect(testHandler.assembler.assembledSentence.map(\.value) == ["世界"])
    testSession.switchState(.ofAbortion())
    try openRankingComposition(keys: ["ㄕˋ"])
    try selectRankingValue("世")
    press(.dataEnterReturn)
    testClientProxy.clear()
    typeSentenceOrCandidates("g4")
    #expect(testSession.state.displayedText == "世")
    typeSentenceOrCandidates("ru,4")
    #expect(testSession.state.displayedText == "世界")
    #expect(testHandler.assembler.assembledSentence.map(\.value) == ["世界"])
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "世界")
  }

  @Test("SS-PersonalPreference-023 Recent complete-reading word wins over an automatic POM override")
  func test_SS_PersonalPreference_023_POMConflict() throws {
    prepareCandidateRankingData()
    try commitRankingValue("逝世")
    testClientProxy.clear()
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    typeSentenceOrCandidates("g4")
    injectPersonalPOM(value: "世事", cursor: 0)
    typeSentenceOrCandidates("g4")
    #expect(testSession.state.displayedText == "逝世")
    #expect(testHandler.assembler.assembledSentence.map(\.value).joined() == "逝世")
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "逝世")
    #expect(rankingCount("逝世") == 1)
  }

  @Test("SS-PersonalPreference-024 A current manual word survives later typing and conflicting POM")
  func test_SS_PersonalPreference_024_ManualProtection() throws {
    prepareCandidateRankingData()
    try commitRankingValue("逝世")
    testClientProxy.clear()
    typeSentenceOrCandidates("g4g4")
    _ = openCandidateWindow(cursor: 2)
    try selectRankingValue("世事")
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    injectPersonalPOM(value: "逝世", cursor: 0)
    typeSentenceOrCandidates("g4")
    #expect(testSession.state.displayedText.hasPrefix("世事"))
    #expect(testHandler.assembler.assembledSentence.first?.value == "世事")
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText.hasPrefix("世事"))
    #expect(rankingCount("世事") == 1)
    #expect(rankingCount("逝世") == 1)
  }

  @Test("SS-PersonalPreference-025 Keyboard overflow extracts preferred text before dropping its readings")
  func test_SS_PersonalPreference_025_DefaultOverflow() throws {
    prepareCandidateRankingData()
    testHandler.currentLM.injectTestData(userPhrases: {
      $0.replaceData(textData: "試 ㄕˋ -0.5\n逝 ㄕˋ -4\n世 ㄕˋ -4\n試試 ㄕˋ-ㄕˋ -1\n逝世 ㄕˋ-ㄕˋ -2\n世事 ㄕˋ-ㄕˋ -3\n")
    })
    try commitRankingValue("逝世")
    testClientProxy.clear()
    testHandler.prefs.securityHardenedCompositionBuffer = true
    for _ in 0 ..< 22 { typeSentenceOrCandidates("g4") }
    #expect(testClientProxy.committedText == "逝世")
    #expect(rankingCount("逝世") == 1)
    testSession.switchState(.ofAbortion())
  }

  @Test("SS-PersonalPreference-026 Contextual word preference must not disappear into cheaper single characters")
  func test_SS_PersonalPreference_026_ContextualBaseline() throws {
    preparePersonalGrid(singleScore: -3, wordScore: -10, contextual: true)
    typeSentenceOrCandidates("ru83g4g4")
    let initial = testHandler.assembler.assembledSentence.map(\.value)
    #expect(initial == ["甲", "試試"], "fixture path: \(initial)")
    testHandler.currentLM.candidateRanking.recordCommittedCandidate(.init(keyArray: ["ㄕˋ", "ㄕˋ"], value: "逝世"))
    testSession.switchState(testHandler.generateStateOfInputting())
    #expect(testHandler.assembler.assembledSentence.map(\.value) == ["甲", "逝世"])
    #expect(testSession.state.displayedText == "甲逝世")
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "甲逝世")
  }

  @Test("SS-PersonalPreference-027 A learned word can be selected from the grid even outside the original path")
  func test_SS_PersonalPreference_027_NonPathWord() throws {
    preparePersonalGrid(singleScore: -1, wordScore: -3, contextual: false)
    typeSentenceOrCandidates("g4g4")
    let initial = testHandler.assembler.assembledSentence.map(\.value)
    #expect(initial == ["試", "試"], "fixture path: \(initial)")
    testHandler.currentLM.candidateRanking.recordCommittedCandidate(.init(keyArray: ["ㄕˋ", "ㄕˋ"], value: "逝世"))
    testSession.switchState(testHandler.generateStateOfInputting())
    #expect(testHandler.assembler.assembledSentence.map(\.value) == ["逝世"])
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "逝世")
  }

  @Test("SS-PersonalPreference-028 Overflow preserves a learned word whose suffix has no standalone gram")
  func test_SS_PersonalPreference_028_OverflowWithoutSuffixGram() throws {
    prepareCandidateRankingData()
    try commitRankingValue("逝世")
    testClientProxy.clear()
    testHandler.prefs.securityHardenedCompositionBuffer = true
    for _ in 0 ..< 22 { typeSentenceOrCandidates("g4") }
    #expect(testClientProxy.committedText == "逝世")
    #expect(testHandler.assembler.length == 20)
    #expect(testSession.state.displayedText == String(repeating: "逝世", count: 10))
    #expect(testHandler.assembler.actualKeys == Array(repeating: "ㄕˋ", count: 20))
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == String(repeating: "逝世", count: 11))
    #expect(rankingCount("逝世") == 1)
  }

  @Test("SS-PersonalPreference-029 Recent word wins over a longer overlapping automatic POM node")
  func test_SS_PersonalPreference_029_OverlappingPOM() throws {
    prepareCandidateRankingData()
    testHandler.currentLM.injectTestData(userPhrases: {
      $0.replaceData(textData: "試 ㄕˋ -0.5\n試試 ㄕˋ-ㄕˋ -1\n逝世 ㄕˋ-ㄕˋ -2\n世事 ㄕˋ-ㄕˋ -3\n試試試 ㄕˋ-ㄕˋ-ㄕˋ -4\n")
    })
    try commitRankingValue("逝世")
    testClientProxy.clear()
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    typeSentenceOrCandidates("g4g4")
    injectPersonalPOM(value: "試試試", cursor: 1, keyArray: Array(repeating: "ㄕˋ", count: 3))
    typeSentenceOrCandidates("g4")
    #expect(testHandler.assembler.assembledSentence.map(\.value) == ["逝世", "試"])
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == "逝世試")
  }

  @Test("SS-PersonalPreference-030 The master switch defaults on and off/on retains history and readings")
  func test_SS_PersonalPreference_030_MasterSwitch() throws {
    #expect(UserDef(rawValue: "UsePersonalCandidatePreference")?.boolDefaultValue == true)
    prepareCandidateRankingData()
    try commitRankingValue("逝世")
    testClientProxy.clear()
    typeSentenceOrCandidates("g4g4")
    let cursor = testHandler.assembler.cursor
    setPersonalPreference(false)
    #expect(testSession.state.displayedText == "試試")
    #expect(testHandler.assembler.cursor == cursor)
    #expect(testHandler.assembler.actualKeys == ["ㄕˋ", "ㄕˋ"])
    #expect(testClientProxy.committedText.isEmpty)
    #expect(rankingCount("逝世") == 1)
    setPersonalPreference(true)
    #expect(testSession.state.displayedText == "逝世")
    #expect(testHandler.assembler.cursor == cursor)
    #expect(testClientProxy.committedText.isEmpty)
  }

  @Test("SS-PersonalPreference-031 Off does not learn manual choices and preserves a current manual word")
  func test_SS_PersonalPreference_031_OffLearning() throws {
    prepareCandidateRankingData()
    try commitRankingValue("逝世")
    try openRankingComposition()
    try selectRankingValue("世事")
    setPersonalPreference(false)
    #expect(testHandler.assembler.assembledSentence.map(\.value).joined() == "世事")
    press(.dataEnterReturn)
    #expect(rankingCount("世事") == 0)
    try openRankingComposition()
    #expect(rankingValues() == ["試試", "逝世", "世事"])
    try selectRankingValue("世事")
    press(.dataEnterReturn)
    #expect(rankingCount("世事") == 0)
    setPersonalPreference(true)
    try openRankingComposition()
    #expect(rankingValues().first == "逝世")
  }

  @Test("SS-PersonalPreference-032 Off/on invalidates an extracted receipt but normal clear does not")
  func test_SS_PersonalPreference_032_ReceiptEpoch() throws {
    prepareCandidateRankingData()
    try openRankingComposition()
    try selectRankingValue("世事")
    let normal = try #require(testHandler.candidateSelectionLearning.takeCommit(text: "世事", assembler: testHandler.assembler))
    testHandler.clear()
    normal.confirm(insertedUnchanged: true)
    #expect(rankingCount("世事") == 1)
    try openRankingComposition()
    try selectRankingValue("逝世")
    let stale = try #require(testHandler.candidateSelectionLearning.takeCommit(text: "逝世", assembler: testHandler.assembler))
    setPersonalPreference(false)
    setPersonalPreference(true)
    stale.confirm(insertedUnchanged: true)
    #expect(rankingCount("逝世") == 0)
    #expect(rankingCount("世事") == 1)
  }

  @Test("SS-PersonalPreference-033 Two production sessions observe the same master switch on their next input")
  func test_SS_PersonalPreference_033_TwoSessions() throws {
    prepareCandidateRankingData()
    try commitRankingValue("逝世")
    let otherClient = MockClientProxy()
    defer { withExtendedLifetime(otherClient) {} }
    let other = InputSession(preallocated: (), manuallyAssignedClientProxy: otherClient)
    let otherHandler = try #require(other.inputHandler)
    otherHandler.currentLM = testHandler.currentLM
    otherHandler.prefs = testHandler.prefs
    other.prefs = testHandler.prefs
    otherHandler.ensureKeyboardParser()
    func typeOther(_ text: String) {
      for character in text {
        for event in KBEvent.KeyEventData(chars: String(character)).asPairedEvents {
          let handled = other.handleEvent(event)
          if event.type == .keyDown { #expect(handled) }
        }
      }
    }
    UserDefaults.current.set(false, forKey: "UsePersonalCandidatePreference")
    typeSentenceOrCandidates("g4g4")
    typeOther("g4g4")
    #expect(testSession.state.displayedText == "試試")
    #expect(other.state.displayedText == "試試")
    UserDefaults.current.set(true, forKey: "UsePersonalCandidatePreference")
    testSession.switchState(.ofAbortion())
    other.switchState(.ofAbortion())
    typeSentenceOrCandidates("g4g4")
    typeOther("g4g4")
    #expect(testSession.state.displayedText == "逝世")
    #expect(other.state.displayedText == "逝世")
  }

  @Test("SS-PersonalPreference-034 Cancel and deletion invalidate manual learning while automatic words do not learn")
  func test_SS_PersonalPreference_034_CancelAndDelete() throws {
    prepareCandidateRankingData()
    typeSentenceOrCandidates("g4g4")
    #expect(testSession.state.displayedText == "試試")
    press(.dataEnterReturn)
    #expect(rankingCount("試試") == 0)
    try commitRankingValue("逝世")
    typeSentenceOrCandidates("g4g4")
    testSession.switchState(.ofAbortion())
    #expect(rankingCount("逝世") == 1)
    typeSentenceOrCandidates("g4g4")
    _ = openCandidateWindow(cursor: 2)
    try selectRankingValue("世事")
    press(.backspaceEvent)
    typeSentenceOrCandidates("g4")
    press(.dataEnterReturn)
    #expect(rankingCount("世事") == 0)
    #expect(rankingCount("逝世") == 1)
  }

  @Test("SS-PersonalPreference-035 Reading and script histories remain isolated, including normal pinyin")
  func test_SS_PersonalPreference_035_ReadingAndScriptIsolation() throws {
    prepareCandidateRankingData()
    try commitRankingValue("逝世")
    testHandler.currentLM.injectTestData(userPhrases: {
      $0.replaceData(textData: "試 ㄕˋ -0.5\n時 ㄕˊ -0.5\n試試 ㄕˋ-ㄕˋ -1\n逝世 ㄕˋ-ㄕˋ -2\n時事 ㄕˊ-ㄕˋ -1\n")
    })
    typeSentenceOrCandidates("g6g4")
    #expect(testSession.state.displayedText == "時事")
    testSession.switchState(.ofAbortion())
    testHandler.prefs.pinyinTypingEnabled = true
    testHandler.prefs.keyboardParser4Pinyin = KeyboardParser.ofHanyuPinyin.rawValue
    testHandler.ensureKeyboardParser()
    typeSentenceOrCandidates("shi4shi4")
    #expect(testSession.state.displayedText == "逝世")
    testSession.switchState(.ofAbortion())
    let traditional = testHandler.currentLM
    testHandler.currentLM = LXAssembly.LXFacade(isCHS: true)
    prepareCandidateRankingData()
    typeSentenceOrCandidates("g4g4")
    #expect(testSession.state.displayedText == "試試")
    #expect(rankingCount("逝世") == 0)
    testSession.switchState(.ofAbortion())
    testHandler.currentLM = traditional
    prepareCandidateRankingData()
    typeSentenceOrCandidates("g4g4")
    #expect(testSession.state.displayedText == "逝世")
  }

  @Test("SS-PersonalPreference-036 Window fixed-order settings do not disable single-character preedit preferences")
  func test_SS_PersonalPreference_036_FixedWindowSettings() throws {
    prepareCandidateRankingData()
    testHandler.currentLM.injectTestData(userPhrases: {
      $0.replaceData(textData: "試 ㄕˋ -0.5\n世 ㄕˋ -1\n")
    })
    try openRankingComposition(keys: ["ㄕˋ"])
    try selectRankingValue("世")
    press(.dataEnterReturn)
    testHandler.prefs.useFixedCandidateOrderOnSelection = true
    testHandler.prefs.enforceETenDOSCandidateSequence = true
    typeSentenceOrCandidates("g4")
    #expect(testSession.state.displayedText == "世")
    _ = openCandidateWindow()
    #expect(testSession.state.candidates.map(\.value) == testHandler.generateArrayOfCandidates(fixOrder: true).map(\.value))
  }

  @Test("SS-PersonalPreference-037 A POM target starting outside a manual cursor still cannot overlap the manual word")
  func test_SS_PersonalPreference_037_ManualPOMOverlap() throws {
    prepareCandidateRankingData()
    testHandler.currentLM.injectTestData(userPhrases: {
      $0.replaceData(textData: "試 ㄕˋ -0.5\n試試 ㄕˋ-ㄕˋ -1\n逝世 ㄕˋ-ㄕˋ -2\n世事 ㄕˋ-ㄕˋ -3\n試試試 ㄕˋ-ㄕˋ-ㄕˋ -4\n")
    })
    try commitRankingValue("逝世")
    typeSentenceOrCandidates("g4g4")
    _ = openCandidateWindow(cursor: 2)
    try selectRankingValue("世事")
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    injectPersonalPOM(value: "試試試", cursor: 2, keyArray: Array(repeating: "ㄕˋ", count: 3))
    typeSentenceOrCandidates("g4")
    #expect(testHandler.assembler.assembledSentence.first?.value == "世事")
    press(.dataEnterReturn)
    #expect(rankingCount("世事") == 1)
  }

  @Test("SS-PersonalPreference-038 Toggling while a window is open preserves all nine numeric snapshot choices")
  func test_SS_PersonalPreference_038_WindowSnapshot() throws {
    prepareCandidateRankingData(includeSingleTrial: false)
    testHandler.prefs.candidateKeys = "123456789"
    testHandler.currentLM.syncPrefs()
    try commitRankingValue("逝世")
    for index in 0 ..< 9 {
      try openRankingComposition()
      let snapshot = testSession.state.candidates
      try #require(snapshot.count >= 9)
      UserDefaults.current.set(false, forKey: "UsePersonalCandidatePreference")
      testSession.refreshPersonalCandidatePreference()
      #expect(testSession.state.candidates.map(\.value) == snapshot.map(\.value))
      UserDefaults.current.set(true, forKey: "UsePersonalCandidatePreference")
      testSession.refreshPersonalCandidatePreference()
      #expect(testSession.state.candidates.map(\.value) == snapshot.map(\.value))
      let cursor = testHandler.actualNodeCursorPosition
      press(KBEvent.KeyEventData(chars: String(index + 1)))
      #expect(testHandler.assembler.assembledSentence.findGram(at: cursor)?.gram.asCandidatePair ==
        Homa.CandidatePair(keyArray: snapshot[index].keyArray, value: snapshot[index].value))
      testSession.switchState(.ofAbortion())
    }
  }

  @Test("SS-PersonalPreference-039 Backspace preserves a manual remainder without learning it")
  func test_SS_PersonalPreference_039_BackspaceManualRemainder() throws {
    try checkManualRemainder(forward: false)
  }

  @Test("SS-PersonalPreference-040 ForwardDelete preserves a manual remainder without learning it")
  func test_SS_PersonalPreference_040_ForwardDeleteManualRemainder() throws {
    try checkManualRemainder(forward: true)
  }

  private func checkManualRemainder(forward: Bool) throws {
    prepareCandidateRankingData()
    testHandler.currentLM.injectTestData(userPhrases: {
      $0.replaceData(textData: "試 ㄕˋ -0.5\n世 ㄕˋ -4\n事 ㄕˋ -4\n試試 ㄕˋ-ㄕˋ -0.9\n逝世 ㄕˋ-ㄕˋ -2\n世事 ㄕˋ-ㄕˋ -3\n")
    })
    testHandler.currentLM.syncPrefs()
    let recent = Homa.CandidatePair(keyArray: ["ㄕˋ"], value: "試")
    testHandler.currentLM.candidateRanking.recordCommittedCandidate(recent)
    typeSentenceOrCandidates("g4g4")
    _ = openCandidateWindow()
    try selectRankingValue("世事")
    #expect(testSession.state.displayedText == "世事")
    testHandler.assembler.cursor = forward ? 0 : 2
    press(forward ? .deleteForwardEvent : .backspaceEvent)
    let remainder = forward ? "事" : "世"
    #expect(testSession.state.displayedText == remainder)
    #expect(testHandler.assembler.segments[0][1]?.isExplicitlyOverridden == true)
    press(.dataEnterReturn)
    #expect(testClientProxy.committedText == remainder)
    #expect(rankingCount("世事") == 0)
    #expect(testHandler.currentLM.candidateRanking.count(for: recent) == 1)
    for value in ["世", "事"] {
      #expect(testHandler.currentLM.candidateRanking.count(for: .init(keyArray: ["ㄕˋ"], value: value)) == 0)
    }
  }

  private func setPersonalPreference(_ enabled: Bool) {
    UserDefaults.current.set(enabled, forKey: "UsePersonalCandidatePreference")
    testSession.refreshPersonalCandidatePreference()
  }

  private func injectPersonalPOM(value: String, cursor: Int, keyArray: [String] = ["ㄕˋ", "ㄕˋ"]) {
    testHandler.currentLM.injectTestData(lxPerceptor: {
      var suggestion = LXAssembly.OverrideSuggestion()
      suggestion.candidates = [(keyArray: keyArray, value: value, probability: 0, previous: nil)]
      suggestion.forceHighScoreOverride = true
      suggestion.overrideCursor = cursor
      $0.testInjectedSuggestion = suggestion
    })
  }

  private func preparePersonalGrid(singleScore: Double, wordScore: Double, contextual: Bool) {
    prepareCandidateRankingData()
    testHandler.currentLM.injectTestData(userPhrases: {
      $0.replaceData(textData: "甲 ㄐㄧㄚˇ -1\n試 ㄕˋ \(singleScore)\n試試 ㄕˋ-ㄕˋ \(wordScore)\n逝世 ㄕˋ-ㄕˋ \(wordScore - 1)\n")
    })
    testHandler.assembler = Homa.Assembler(gramQuerier: { query in
      let keys = query.map(\.first)
      switch keys {
      case ["ㄐㄧㄚˇ"]: return [.init(keyArray: keys, value: "甲", score: -1)]
      case ["ㄕˋ"]: return [.init(keyArray: keys, value: "試", score: singleScore)]
      case ["ㄕˋ", "ㄕˋ"]:
        var grams = [Homa.Gram(keyArray: keys, value: "試試", score: wordScore),
                     Homa.Gram(keyArray: keys, value: "逝世", score: wordScore - 1)]
        if contextual { grams.append(.init(keyArray: keys, current: "試試", previous: "甲", probability: -1)) }
        return grams
      default: return []
      }
    })
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
    testHandler.prefs.pinyinTypingEnabled = false
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
