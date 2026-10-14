// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import Testing
import TrieKit
@testable import D512Dump

struct D512DumpTests {
  private let reading = ["ㄐㄧㄚˇ", "ㄧˇ", "ㄅㄧㄥˇ"]

  private func singleWordTrie() throws -> VanguardTrie.TextMapTrie {
    let textMap = """
    #PRAGMA:VANGUARD_HOMA_LEXICON_HEADER
    VERSION\t1.1
    TYPE\tTYPING
    READING_SEPARATOR\t-
    ENTRY_COUNT\t1
    KEY_COUNT\t1
    #PRAGMA:VANGUARD_HOMA_LEXICON_VALUES
    @-2\t乙\t乙
    #PRAGMA:VANGUARD_HOMA_LEXICON_KEY_LINE_MAP
    ㄧˇ\t0\t1
    """
    return try VanguardTrie.TextMapTrie(data: Data((textMap + "\n").utf8))
  }

  private func makeAssembler() throws -> Homa.Assembler {
    let entries: [String: [(String, Double)]] = [
      "ㄐㄧㄚˇ": [("甲", -2), ("假", -3)],
      "ㄧˇ": [("乙", -2)],
      "ㄅㄧㄥˇ": [("丙", -2)],
      "ㄐㄧㄚˇ-ㄧˇ": [("甲乙", -3), ("加以", -4)],
      "ㄧˇ-ㄅㄧㄥˇ": [("乙丙", -2.5)],
      "ㄐㄧㄚˇ-ㄧˇ-ㄅㄧㄥˇ": [("甲乙丙", -5)],
    ]
    let assembler = Homa.Assembler(gramQuerier: { keys in
      let exactKeys = keys.compactMap { $0.allValues.first }
      return (entries[exactKeys.joined(separator: "-")] ?? []).map {
        Homa.Gram(keyArray: exactKeys, current: $0.0, probability: $0.1)
      }
    })
    try assembler.insertKeys(reading.map { .singleKey($0) })
    return assembler
  }

  @Test func beamKeepsBestDistinctTextsAcrossDifferentSegmentations() throws {
    let assembler = try makeAssembler()
    let original = assembler.assembledSentence
    let paths = try assembler.d512BeamPaths(k: 8)
    #expect(paths.map(\.text) == ["甲乙丙", "假乙丙", "加以丙"])
    #expect(paths.map(\.log_score) == [-4.5, -5.5, -6])
    #expect(paths.first?.segments.map(\.Word) == ["甲", "乙丙"])
    #expect(assembler.assembledSentence == original)
    #expect(assembler.mostRecentPathScore == -4.5)
    #expect(try assembler.d512BeamPaths(k: 1).count == 1)
    #expect(throws: DumpError.self) { try assembler.d512BeamPaths(k: 9) }
  }

  @Test func spansUseEnginePathLocalCandidatesAndLeftContext() throws {
    let testCase = DumpCase(id: "test", gold: "假乙丙", reading: reading, context: "前文")
    let requests = try Dumper.requests(for: testCase, assembler: makeAssembler(), mode: .span, k: 8)
    #expect(requests.map(\.span) == [[0, 1], [1, 3]])
    #expect(requests.map(\.context) == ["前文", "前文甲"])
    #expect(requests.map(\.gold) == ["假", "乙丙"])
    #expect(requests.map(\.gold_in_candidates) == [true, true])
    #expect(requests.first?.candidates.map(\.text) == ["甲", "假"])
    #expect(requests.first?.text_mode == true)
    #expect(requests.last?.text_mode == nil)
    #expect(requests.last?.candidates.first?.segments.first?.Start == 0)
    #expect(requests.last?.candidates.first?.segments.first?.End == 2)
  }

  @Test func nbestReportsWholeInputAndOracleMiss() throws {
    let testCase = DumpCase(id: "miss", gold: "賈以餅", reading: reading, context: "前文")
    let requests = try Dumper.requests(for: testCase, assembler: makeAssembler(), mode: .nbest, k: 2)
    #expect(requests.count == 1)
    #expect(requests.first?.span == [0, 3])
    #expect(requests.first?.context == "前文")
    #expect(requests.first?.candidates.map(\.text) == ["甲乙丙", "假乙丙"])
    #expect(requests.first?.gold_in_candidates == false)
  }

  @Test func spanRejectsAnOverriddenDefaultBelowAnotherCandidate() throws {
    let assembler = try makeAssembler()
    try assembler.overrideCandidate(
      .init(keyArray: [reading[0]], value: "假"), at: 0, type: .withTopGramScore
    )
    #expect(assembler.assembledSentence.first?.value == "假")
    let testCase = DumpCase(id: "invalid-default", gold: "甲乙丙", reading: reading, context: "")
    #expect(throws: DumpError.self) {
      try Dumper.requests(for: testCase, assembler: assembler, mode: .span, k: 8)
    }
  }

  @Test func validationRejectsWrongTonePositionAndLength() throws {
    try DumpCase(id: "tones", gold: "天地人了啊", reading: ["ㄊㄧㄢ", "ㄉㄧˋ", "ㄖㄣˊ", "ㄌㄜ˙", "ㄚˇ"], context: "").validate()
    for bad in ["˙ㄌㄜ", "ㄌㄜ1", "ㄌㄜ ", "ㄧㄐㄚˇ", "ㄚˊˋ"] {
      #expect(throws: DumpError.self) {
        try DumpCase(id: "bad", gold: "甲乙", reading: [bad, "ㄧˇ"], context: "").validate()
      }
    }
    #expect(throws: DumpError.self) {
      try DumpCase(id: "bad", gold: "甲", reading: reading, context: "").validate()
    }
  }

  @Test func loaderCoversInputsBeyondTheIncrementalWindow() throws {
    let trie = try singleWordTrie()
    for length in [11, 32] {
      let reading = [String](repeating: "ㄧˇ", count: length)
      let assembler = try D512Dump.makeAssembler(trie: trie, reading: reading)
      print("coverage diagnostic: input=\(length), path=\(assembler.assembledSentence.totalKeyCount), empty segment positions=\(assembler.segments.indices.filter { assembler.segments[$0].isEmpty })")
      #expect(assembler.assembledSentence.totalKeyCount == length)
      #expect(assembler.assembledSentence.values.joined() == String(repeating: "乙", count: length))
    }
  }

  @Test func oneFailedCaseDoesNotInvalidateOtherCases() throws {
    let input = """
    {"id":"before","gold":"甲乙丙","reading":["ㄐㄧㄚˇ","ㄧˇ","ㄅㄧㄥˇ"],"context":""}
    {"id":"bad","gold":"甲乙","reading":["bad-reading","ㄧˇ"],"context":""}
    {"id":"after","gold":"甲乙丙","reading":["ㄐㄧㄚˇ","ㄧˇ","ㄅㄧㄥˇ"],"context":""}
    """
    var output: [Data] = []
    var diagnostics: [Data] = []
    let summary = try D512Dump.process(
      input: input, mode: .span, k: 8, makeAssembler: { _ in try makeAssembler() },
      emit: { output.append($0) }, diagnose: { diagnostics.append($0) }
    )
    let rows = try output.map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
    #expect(rows.compactMap { $0["id"] as? String } == ["before", "before", "after", "after"])
    #expect(summary.processed == 3 && summary.succeeded == 2 && summary.skipped == 1 && summary.requests == 4)
    let skippedData = try #require(diagnostics.first)
    let skipped = try #require(JSONSerialization.jsonObject(with: skippedData) as? [String: Any])
    #expect(skipped["id"] as? String == "bad")
    #expect(skipped["reason"] as? String == "invalid_reading")
    let totalsData = try #require(diagnostics.last)
    let totals = try #require(JSONSerialization.jsonObject(with: totalsData) as? [String: Any])
    #expect(totals["event"] as? String == "summary")
    #expect(totals["skipped"] as? Int == 1)
  }

  @Test func malformedJSONRemainsFatalEvenAfterOneSuccessfulCase() throws {
    let input = """
    {"id":"before","gold":"甲乙丙","reading":["ㄐㄧㄚˇ","ㄧˇ","ㄅㄧㄥˇ"],"context":""}
    not JSON
    {"id":"after","gold":"甲乙丙","reading":["ㄐㄧㄚˇ","ㄧˇ","ㄅㄧㄥˇ"],"context":""}
    """
    var output: [Data] = []
    var diagnostics: [Data] = []
    #expect(throws: DumpError.self) {
      try D512Dump.process(input: input, mode: .span, k: 8, makeAssembler: { _ in try makeAssembler() },
                           emit: { output.append($0) }, diagnose: { diagnostics.append($0) })
    }
    #expect(output.count == 2)
    let data = try #require(diagnostics.last)
    let totals = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(totals["succeeded"] as? Int == 1)
    #expect(totals["skipped"] as? Int == 0)
  }

  @Test func zeroSuccessfulCasesRemainFatal() throws {
    let input = #"{"id":"bad","gold":"甲乙","reading":["bad-reading","ㄧˇ"],"context":""}"#
    var output: [Data] = []
    var diagnostics: [Data] = []
    #expect(throws: DumpError.self) {
      try D512Dump.process(input: input, mode: .nbest, k: 8, makeAssembler: { _ in try makeAssembler() },
                           emit: { output.append($0) }, diagnose: { diagnostics.append($0) })
    }
    #expect(output.isEmpty)
    let data = try #require(diagnostics.last)
    let totals = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(totals["succeeded"] as? Int == 0)
    #expect(totals["skipped"] as? Int == 1)
  }
}
