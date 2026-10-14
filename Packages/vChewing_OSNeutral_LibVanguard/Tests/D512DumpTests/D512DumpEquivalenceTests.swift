// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LexiconAssembly
import Testing
import TrieKit
@testable import D512Dump

@MainActor
struct D512DumpEquivalenceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["D512_FACTORY_TEXTMAP"] != nil &&
    ProcessInfo.processInfo.environment["D512_DUMPER_CASES"] != nil))
  func standaloneMatchesProductionFactorySupplier() throws {
    let environment = ProcessInfo.processInfo.environment
    let factoryPath = try #require(environment["D512_FACTORY_TEXTMAP"])
    let casesPath = try #require(environment["D512_DUMPER_CASES"])
    let data = try Data(contentsOf: URL(fileURLWithPath: factoryPath), options: [.mappedIfSafe])
    let standaloneTrie = try VanguardTrie.TextMapTrie(data: data)
    let textMap = try #require(String(data: data, encoding: .utf8))
    try #require(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: textMap))
    defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }
    // This production supplier reads LXFacade.factoryTrie without constructing LXFacade,
    // whose instance initializer would create PrefMgr/UserDefaults. CHT is isCHS=false.
    let supplier = LXAssembly.LXFactoryGramSupplier()
    let input = try String(contentsOfFile: casesPath, encoding: .utf8)
    let cases = try input.split(whereSeparator: \.isNewline).map {
      try JSONDecoder().decode(DumpCase.self, from: Data($0.utf8))
    }
    try #require(!cases.isEmpty, "Factory equivalence requires at least one case")
    var comparisons: [CaseComparison] = []
    var totalSpans = 0
    var totalCandidates = 0
    var totalPrefixes = 0
    for testCase in cases {
      try testCase.validate()
      let standalone = try D512Dump.makeAssembler(trie: standaloneTrie, reading: testCase.reading)
      let reference = Homa.Assembler(gramQuerier: { keys in
        supplier.queryGrams(
          keys.map(\.first), filterType: .cht, partiallyMatch: false,
          partiallyMatchedKeysPostHandler: nil
        )
      })
      // Feed the production supplier incrementally and compare the standalone loader
      // after every completed syllable, including inputs longer than maxSegLength.
      var prefixesEqual = true
      for (index, syllable) in testCase.reading.enumerated() {
        try reference.insertKey(syllable)
        let prefix = try D512Dump.makeAssembler(
          trie: standaloneTrie, reading: Array(testCase.reading.prefix(index + 1))
        )
        let equal = prefix.assembledSentence == reference.assembledSentence &&
          prefix.mostRecentPathScore == reference.mostRecentPathScore &&
          prefix.assembledSentence.totalKeyCount == index + 1
        #expect(equal, "\(testCase.id) after \(index + 1) syllables: standalone=\(prefix.assembledSentence.values) / \(prefix.mostRecentPathScore), reference=\(reference.assembledSentence.values) / \(reference.mostRecentPathScore)")
        prefixesEqual = prefixesEqual && equal
        totalPrefixes += 1
      }
      try #require(standalone.assembledSentence.totalKeyCount == testCase.reading.count,
                   "\(testCase.id): standalone path does not cover the complete reading")
      try #require(reference.assembledSentence.totalKeyCount == testCase.reading.count,
                   "\(testCase.id): reference path does not cover the complete reading")
      let pathEqual = standalone.assembledSentence == reference.assembledSentence
      let scoreEqual = standalone.mostRecentPathScore == reference.mostRecentPathScore
      #expect(pathEqual, "\(testCase.id): standalone=\(standalone.assembledSentence.values), reference=\(reference.assembledSentence.values)")
      #expect(scoreEqual, "\(testCase.id): standalone score=\(standalone.mostRecentPathScore), reference score=\(reference.mostRecentPathScore)")
      var spanComparisons: [SpanComparison] = []
      var start = 0
      for gram in reference.assembledSentence {
        let directCandidates = standalone.fetchCandidates(at: start, filter: .beginAt)
        let referenceCandidates = reference.fetchCandidates(at: start, filter: .beginAt)
        // CandidatePairWeighted equality compares reading, text and exact Double weight;
        // array equality also verifies the complete candidate order, before the <=16 cap.
        let equal = directCandidates == referenceCandidates
        #expect(equal, "\(testCase.id) at \(start): candidate text/order/score differs")
        let eligible = referenceCandidates.filter {
          $0.pair.keyArray == gram.keyArray && $0.pair.value.unicodeScalars.count == gram.segLength
        }
        spanComparisons.append(.init(
          span: [start, start + gram.segLength], full_fetch_equal: equal,
          full_candidate_count: referenceCandidates.count, eligible_candidate_count: eligible.count,
          differences: equal ? [] : ["standalone=\(directCandidates)", "reference=\(referenceCandidates)"]
        ))
        start += gram.segLength
        totalSpans += 1
        totalCandidates += referenceCandidates.count
      }
      comparisons.append(.init(
        id: testCase.id, assembled_equal: pathEqual, score_equal: scoreEqual,
        prefixes_equal: prefixesEqual, standalone_assembled: standalone.assembledSentence.values,
        standalone_log_score: standalone.mostRecentPathScore,
        assembled: reference.assembledSentence.values, log_score: reference.mostRecentPathScore,
        spans: spanComparisons
      ))
    }
    let allEqual = comparisons.allSatisfy {
      $0.assembled_equal && $0.score_equal && $0.prefixes_equal && $0.spans.allSatisfy(\.full_fetch_equal)
    }
    if let reportPath = environment["D512_EQUIVALENCE_REPORT"] {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      let report = EquivalenceReport(
        reference: "LXFacade.connectToTestFactoryDictionary + LXFactoryGramSupplier(.cht / isCHS=false)",
        reference_input: "incremental insertKey per syllable; complete path coverage required",
        baseline: "factory-only CHT pure unigram; no POM/personal candidate learning",
        factory_bytes: data.count, total_cases: cases.count, total_spans: totalSpans,
        total_candidates_compared: totalCandidates, total_prefixes_compared: totalPrefixes,
        all_equal: allEqual, cases: comparisons
      )
      var output = try encoder.encode(report)
      output.append(10)
      try output.write(to: URL(fileURLWithPath: reportPath))
    }
    print("Factory equivalence: \(cases.count) cases, \(totalSpans) spans, \(totalCandidates) ordered candidates, \(totalPrefixes) prefixes compared; all_equal=\(allEqual)")
  }

  private struct SpanComparison: Encodable {
    let span: [Int]
    let full_fetch_equal: Bool
    let full_candidate_count: Int
    let eligible_candidate_count: Int
    let differences: [String]
  }

  private struct CaseComparison: Encodable {
    let id: String
    let assembled_equal: Bool
    let score_equal: Bool
    let prefixes_equal: Bool
    let standalone_assembled: [String]
    let standalone_log_score: Double
    let assembled: [String]
    let log_score: Double
    let spans: [SpanComparison]
  }

  private struct EquivalenceReport: Encodable {
    let reference: String
    let reference_input: String
    let baseline: String
    let factory_bytes: Int
    let total_cases: Int
    let total_spans: Int
    let total_candidates_compared: Int
    let total_prefixes_compared: Int
    let all_equal: Bool
    let cases: [CaseComparison]
  }
}
