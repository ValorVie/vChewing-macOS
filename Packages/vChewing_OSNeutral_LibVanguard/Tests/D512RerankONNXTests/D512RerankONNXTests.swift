// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import D512Rerank
import Foundation
import Testing
@testable import D512RerankONNX

// The model is not in git. Point `D512_MODEL_DIR` at `d512-pf512-20260926`, or keep the default
// `DevLab/D512Eval/harness/models/d512-pf512-20260926` (a symlink in the eval worktrees); the model
// tests are skipped when neither exists.
private let modelDir: URL = {
  if let env = ProcessInfo.processInfo.environment["D512_MODEL_DIR"] { return URL(fileURLWithPath: env) }
  return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../DevLab/D512Eval/harness/models/d512-pf512-20260926").standardized
}()

private let hasModel = FileManager.default.fileExists(atPath: modelDir.appendingPathComponent("model.onnx").path)

private struct Fixture: Decodable {
  struct Case: Decodable {
    let id: String, context: String, reading: [String], engine_default: Int
    let candidates: [D512Request.Candidate]
    let expected_model: [Double]?
    var request: D512Request {
      D512Request(id: id, context: context, reading: reading, candidates: candidates, engineDefault: engine_default)
    }
  }

  let requests: [Case]

  static func load() throws -> [Case] {
    let url = try #require(Bundle.module.url(forResource: "held-out-fixture", withExtension: "json"))
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).requests
  }
}

struct D512RerankONNXTests {
  @Test(.enabled(if: hasModel, "D512 model not present"))
  func scoresAndFusionWinnersMatchPythonHarness() throws {
    let scorer = try D512ONNXScorer(modelDirectory: modelDir)
    let cases = try Fixture.load()
    #expect(cases.count == 7)
    for c in cases {
      let swift = try scorer.vocab.modelScores(c.request, scorer: scorer)
      guard let expected = c.expected_model else {
        #expect(swift == nil, "\(c.id) should fall back")
        continue
      }
      let got = try #require(swift, "\(c.id) unexpectedly fell back")
      #expect(got.count == expected.count)
      for (a, b) in zip(got, expected) { #expect(abs(a - b) <= 1e-4, "\(c.id): \(a) vs \(b)") }
      let engine = c.candidates.map(\.log_score)
      #expect(
        D512Fusion.choose(engine: engine, model: got, default: c.request.engineDefault, weight: 0.5, margin: 0.5)
          == D512Fusion.choose(engine: engine, model: expected, default: c.request.engineDefault, weight: 0.5, margin: 0.5)
      )
    }
  }

  @Test func hashMismatchIsRejected() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("d512-hash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("not a model".utf8).write(to: dir.appendingPathComponent("model.onnx"))
    try Data("{}".utf8).write(to: dir.appendingPathComponent("vocab.json"))
    #expect(throws: D512ONNXScorer.Failure.self) { try D512ONNXScorer.verifyFiles(dir) }
    #expect(try D512ONNXScorer.sha256(dir.appendingPathComponent("vocab.json"))
      == "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
  }
}
