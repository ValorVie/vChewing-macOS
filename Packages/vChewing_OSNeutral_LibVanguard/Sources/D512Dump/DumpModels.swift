// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import Tekkon

struct DumpError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

enum DumpMode: String { case span, nbest }

struct DumpCase: Decodable {
  let id: String
  let gold: String
  let reading: [String]
  let context: String

  func validate() throws {
    guard !id.isEmpty, (2 ... 32).contains(reading.count), gold.unicodeScalars.count == reading.count else {
      throw DumpError("\(id): id must be nonempty; reading must have 2–32 syllables, one gold character per syllable.")
    }
    for syllable in reading {
      var composer = Tekkon.Composer()
      let valid = !syllable.isEmpty && syllable.unicodeScalars.allSatisfy {
        $0 != " " && composer.receiveKey(fromPhonabet: $0)
      }
      guard valid, composer.isPronounceable, composer.getComposition() == syllable else {
        throw DumpError("\(id): invalid Tekkon reading '\(syllable)' (tone must be at the right; first tone has no mark).")
      }
    }
  }
}

struct DumpSegment: Encodable, Equatable {
  let Start: Int
  let End: Int
  let Word: String
  let Partial = false
  let Correction = false
}

struct DumpCandidate: Encodable {
  let text: String
  let log_score: Double
  let segments: [DumpSegment]

  static func from(_ grams: [Homa.GramInPath], score: Double) -> Self {
    var offset = 0
    let segments = grams.map { item in
      defer { offset += item.segLength }
      return DumpSegment(Start: offset, End: offset + item.segLength, Word: item.value)
    }
    return .init(text: grams.values.joined(), log_score: score, segments: segments)
  }
}

struct DumpRequest: Encodable {
  let id: String
  let mode: String
  let span: [Int]
  let context: String
  let reading: [String]
  let candidates: [DumpCandidate]
  let engine_default = 0
  let gold: String
  let gold_in_candidates: Bool
  let score_scale = "log10 (not ln); baseline=factory-only CHT pure unigram, no POM/personal candidate learning (weaker than personalized daily engine); weights rounded upstream to 3 decimals, positive values negated; span=same-node gram score, nbest=sum of gram scores; candidate 0 is maximum; no bigram/trigram, backoff or override weighting"
  let text_mode: Bool?
}

enum Dumper {
  static func requests(for testCase: DumpCase, assembler: Homa.Assembler, mode: DumpMode, k: Int) throws -> [DumpRequest] {
    try testCase.validate()
    let best = assembler.assembledSentence
    guard best.totalKeyCount == testCase.reading.count,
          best.allSatisfy({ $0.value.unicodeScalars.count == $0.segLength }) else {
      throw DumpError("\(testCase.id): engine path does not cover reading with one character per syllable.")
    }
    if mode == .nbest {
      let candidates = try assembler.d512BeamPaths(k: k)
      return [try request(for: testCase, mode: mode, start: 0, end: testCase.reading.count,
                      context: testCase.context, candidates: candidates)]
    }
    var offset = 0
    var leftText = ""
    return try best.map { item in
      let length = item.segLength
      let alternatives = assembler.fetchCandidates(at: offset, filter: .beginAt).filter {
        $0.pair.keyArray == item.keyArray && $0.pair.value.unicodeScalars.count == length
      }
      // Keep the actual best-path gram first, even when another gram has an equal score.
      var candidates = [DumpCandidate.from([item], score: item.score)]
      var seen: Set<String> = [item.value]
      for candidate in alternatives where candidates.count < 16 {
        guard seen.insert(candidate.pair.value).inserted else { continue }
        candidates.append(.init(
          text: candidate.pair.value, log_score: candidate.weight,
          segments: [.init(Start: 0, End: length, Word: candidate.pair.value)]
        ))
      }
      let output = try request(for: testCase, mode: mode, start: offset, end: offset + length,
                           context: testCase.context + leftText, candidates: candidates)
      offset += length
      leftText += item.value
      return output
    }
  }

  private static func request(for testCase: DumpCase, mode: DumpMode, start: Int, end: Int,
                              context: String, candidates: [DumpCandidate]) throws -> DumpRequest {
    guard let engineDefault = candidates.first,
          candidates.allSatisfy({ $0.log_score.isFinite && engineDefault.log_score >= $0.log_score }) else {
      throw DumpError("\(testCase.id) [\(start),\(end)): candidate 0 must have the maximum finite log_score.")
    }
    let gold = String(String.UnicodeScalarView(Array(testCase.gold.unicodeScalars)[start ..< end]))
    return .init(
      id: testCase.id, mode: mode.rawValue, span: [start, end], context: context,
      reading: Array(testCase.reading[start ..< end]), candidates: candidates,
      gold: gold, gold_in_candidates: candidates.contains { $0.text == gold },
      text_mode: mode == .span && end - start == 1 ? true : nil
    )
  }
}
