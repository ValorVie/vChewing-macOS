// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Testing
@testable import D512Rerank

// Expected feeds/scores were captured from `d512eval.py` (`Scorer._run`/`score`) with the same
// tiny vocab and a stub session returning `L + 0.25 × Σtones`.
struct D512RerankTests {
  private let vocab = D512Vocab(
    characters: ["你", "好", "嗎", "我"], bases: ["ㄋㄧ", "ㄏㄠ", "ㄇㄚ"], neutralTolerantLast: ["ㄇㄚ"]
  )

  private struct Recorder: D512Scoring {
    final class Box { var inputs: [D512Input] = [] }
    let box = Box()
    func logProb(_ input: D512Input) throws -> Double {
      box.inputs.append(input)
      return Double(input.length) + 0.25 * Double(input.tones.reduce(0, +))
    }
  }

  private func request(_ context: String, _ reading: [String], _ texts: [String]) -> D512Request {
    D512Request(id: "t", context: context, reading: reading, candidates: texts.map { .init(text: $0, log_score: 0) })
  }

  @Test func encodingMatchesHarnessFeeds() throws {
    let rec = Recorder()
    let scores = try vocab.modelScores(request("我？", ["ㄋㄧˇ", "ㄏㄠˇ"], ["你好"]), scorer: rec)
    #expect(scores == [9.5])
    let x = try #require(rec.box.inputs.first)
    #expect(rec.box.inputs.count == 1)
    #expect(x.ids == [1, 11, 4, 2, 0, 0, 3, 8])
    #expect(x.bases == [0, 0, 0, 0, 2, 3, 0, 0])
    #expect(x.tones == [0, 0, 0, 0, 3, 3, 0, 0])
    #expect(x.types == [0, 0, 0, 0, 1, 1, 0, 2])
    #expect(x.positions == Array(0 ... 7))
    #expect((0 ..< 8).map { r in x.mask[(r * 8) ..< (r * 8 + 8)].filter { $0 }.count } == Array(1 ... 8))
    #expect(x.mask[1] == false && x.mask[8] == true)
    #expect(x.projPos == [6, 7])
    #expect(x.targetNode == [0, 1])
    #expect(x.targetIds == [2, 3])
  }

  @Test func neutralTolerantLastSyllableKeepsTheMax() throws {
    let rec = Recorder()
    #expect(try vocab.modelScores(request("我", ["ㄋㄧ", "ㄇㄚ"], ["你嗎"]), scorer: rec) == [8.5])
    #expect(rec.box.inputs.map(\.tones) == [[0, 0, 0, 1, 1, 0, 0], [0, 0, 0, 1, 5, 0, 0]])
    let already = Recorder()
    _ = try vocab.modelScores(request("我", ["ㄋㄧ", "ㄇㄚ˙"], ["你嗎"]), scorer: already)
    #expect(already.box.inputs.count == 1)
  }

  @Test func contextKeepsLast64ScalarsAndUnknownIsUNK() throws {
    let rec = Recorder()
    _ = try vocab.modelScores(request(String(repeating: "好", count: 70) + "？", ["ㄋㄧ", "ㄏㄠ"], ["你好"]), scorer: rec)
    let ids = try #require(rec.box.inputs.first).ids
    #expect(ids.count == 1 + 64 + 1 + 2 + 1 + 1)
    #expect(ids[1 ... 64].filter { $0 == 9 }.count == 63 && ids[64] == 4)
  }

  @Test func fallbacks() throws {
    #expect(vocab.fallbackReason(request("", ["ㄋㄧ"], ["你"])) == .outOfLimits)
    #expect(vocab.fallbackReason(request("", Array(repeating: "ㄋㄧ", count: 33), [String(repeating: "你", count: 33)])) == .outOfLimits)
    #expect(vocab.fallbackReason(request("", ["ㄋㄧ", "ㄏㄠ"], (0 ..< 17).map { _ in "你好" })) == .outOfLimits)
    #expect(vocab.fallbackReason(request("", ["ㄋㄧ", "ㄏㄠ"], ["你他"])) == .oov)
    #expect(vocab.fallbackReason(request("", ["ㄋㄧ", "ㄒㄧ"], ["你好"])) == .badReading)
    #expect(vocab.fallbackReason(request("", ["ㄋㄧ", "ㄏㄠ"], ["你好"])) == nil)
    #expect(try vocab.modelScores(request("", ["ㄋㄧ", "ㄏㄠ"], ["你他"]), scorer: Recorder()) == nil)
    #expect(vocab.fallbackReason(request("", ["ㄋㄧ", "ㄏㄠ"], ["你好嗎"])) == .outOfLimits)
    let badDefault = D512Request(
      id: "t", context: "", reading: ["ㄋㄧ", "ㄏㄠ"], candidates: [.init(text: "你好", log_score: 0)], engineDefault: 1
    )
    #expect(vocab.fallbackReason(badDefault) == .outOfLimits)
    let corrected = try JSONDecoder().decode(D512Request.self, from: Data("""
    {"id":"t","context":"","reading":["ㄋㄧ","ㄏㄠ"],
     "candidates":[{"text":"你好","log_score":0,"segments":[{"Correction":true}]}]}
    """.utf8))
    #expect(vocab.fallbackReason(corrected) == .correction)
  }

  @Test func neutralRuleStripsAnExplicitToneMark() throws {
    let rec = Recorder()
    // Harness: L=7, tones [3,3] → 7 + 1.5; neutral variant [3,5] → 7 + 2.
    #expect(try vocab.modelScores(request("我", ["ㄋㄧˇ", "ㄇㄚˇ"], ["你嗎"]), scorer: rec) == [9])
    #expect(rec.box.inputs.map { Array($0.tones.suffix(4)) } == [[3, 3, 0, 0], [3, 5, 0, 0]])
    #expect(rec.box.inputs[1].bases == rec.box.inputs[0].bases)
  }

  /// Returns `bad` for candidate "你嗎" (last target id 4), -1 otherwise.
  private struct Injected: D512Scoring {
    let bad: Double
    func logProb(_ input: D512Input) throws -> Double { input.targetIds.last == 4 ? bad : -1 }
  }

  @Test(arguments: [Double.nan, .infinity])
  func nonFiniteModelScoreKeepsEngineDefaultAndReportsIt(bad: Double) throws {
    let req = D512Request(
      id: "nf", context: "", reading: ["ㄋㄧ", "ㄏㄠ"],
      candidates: [.init(text: "你好", log_score: -1), .init(text: "你嗎", log_score: -1.5)]
    )
    #expect {
      try vocab.modelScores(req, scorer: Injected(bad: bad))
    } throws: { error in
      guard case let .nonFiniteScore(id, candidate, value) = error as? D512RerankError else { return false }
      return id == "nf" && candidate == 1 && (value.isNaN ? bad.isNaN : value == bad)
    }
    let (choice, error) = vocab.rerank(req, scorer: Injected(bad: bad), weight: 0.5, margin: 0.5)
    #expect(choice == 0)
    #expect(error is D512RerankError)
    #expect(vocab.rerank(req, scorer: Injected(bad: -1), weight: 0.5, margin: 0.5).error == nil)
  }

  @Test(arguments: [Double.nan, .infinity])
  func fusionKeepsDefaultOnNonFiniteInput(bad: Double) {
    #expect(D512Fusion.choose(engine: [0, -1], model: [0, bad], default: 0, weight: 0.5, margin: 0.5) == 0)
    #expect(D512Fusion.choose(engine: [0, bad], model: [0, 0], default: 0, weight: 0.5, margin: 0.5) == 0)
    #expect(D512Fusion.choose(engine: [0, -1], model: [0], default: 0, weight: 0.5, margin: 0.5) == 0)
  }

  @Test func fusionNeedsStrictMarginAndPrefersLowestIndexOnTies() {
    let engine = [-1.0, -1.2, -3.0]
    // fused = [-2, -1.2, -2]: candidate 1 leads by 0.8.
    #expect(D512Fusion.choose(engine: engine, model: [-2, -0, -2], default: 0, weight: 0.5, margin: 0.5) == 1)
    #expect(D512Fusion.choose(engine: engine, model: [-2, -0, -2], default: 0, weight: 0.5, margin: 0.8) == 0)
    #expect(D512Fusion.choose(engine: engine, model: [-2, -0, 8], default: 0, weight: 0, margin: 0) == 0)
    #expect(D512Fusion.choose(engine: [-1, -1], model: [0, 0], default: 1, weight: 1, margin: -1) == 0)
    #expect(D512Fusion.choose(engine: engine, model: nil, default: 0, weight: 8, margin: 0) == 0)
  }
}
