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

// `@available` sits on each test: swift-testing rejects it on the suite type.
struct D512RerankONNXTests {
  @available(macOS 14, *)
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

  /// Runs the built `D512Score` on the fixture against a report whose expected scores are shifted by `bias`.
  private func scoreExitCode(
    bias: Double, extraArgs: [String] = [], onlyFallbacks: Bool = false, stdout: FileHandle = .nullDevice
  ) throws -> Int32 {
    let cases = try Fixture.load().filter { !onlyFallbacks || $0.expected_model == nil }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("d512-score-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let requests = try cases.map { c -> String in
      let obj: [String: Any] = [
        "id": c.id, "context": c.context, "reading": c.reading, "engine_default": c.engine_default,
        "candidates": c.candidates.map { ["text": $0.text, "log_score": $0.log_score] },
      ]
      return String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }
    try requests.joined(separator: "\n").write(to: dir.appendingPathComponent("r.jsonl"), atomically: true, encoding: .utf8)
    let perRequest: [[String: Any]] = cases.map { c in
      guard let model = c.expected_model else { return ["id": c.id, "fallback": "oov", "task": NSNull(), "model": NSNull()] }
      return ["id": c.id, "task": "phonetic", "model": model.enumerated().map { $0 == 1 ? $1 + bias : $1 }]
    }
    try JSONSerialization.data(withJSONObject: ["per_request": perRequest]).write(to: dir.appendingPathComponent("p.json"))
    let process = Process()
    // The D512Score binary sits in the products dir, an ancestor of this target's resource bundle
    // (which may itself be copied into `<tests>.xctest/Contents/Resources`).
    let binary = sequence(first: Bundle.module.bundleURL.deletingLastPathComponent()) {
      $0.path == "/" ? nil : $0.deletingLastPathComponent()
    }.map { $0.appendingPathComponent("D512Score") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    process.executableURL = try #require(binary, "D512Score binary not found")
    process.arguments = [
      "--model-dir", modelDir.path, "--requests", dir.appendingPathComponent("r.jsonl").path,
      "--report", dir.appendingPathComponent("p.json").path,
    ] + extraArgs
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  @available(macOS 14, *)
  @Test(.enabled(if: hasModel, "D512 model not present"))
  func scoreToolExitCodeGatesEquivalence() throws {
    #expect(try scoreExitCode(bias: 0) == 0)
    #expect(try scoreExitCode(bias: 1e-3) == 1) // over the default 1e-4
    #expect(try scoreExitCode(bias: 1e-3, extraArgs: ["--tolerance", "1e-2"]) == 0)
    #expect(try scoreExitCode(bias: 100, extraArgs: ["--tolerance", "1e9"]) == 1) // fusion winners flip
    // Nothing scored (all fallbacks): still prints a summary (null latencies, no NaN abort) and fails.
    let pipe = Pipe()
    #expect(try scoreExitCode(bias: 0, onlyFallbacks: true, stdout: pipe.fileHandleForWriting) == 1)
    try pipe.fileHandleForWriting.close()
    let summary = try JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile()) as? [String: Any]
    #expect(summary?["compared_requests"] as? Int == 0)
    #expect((summary?["latency_ms_all"] as? [String: Any])?["median"] is NSNull)
  }

  @available(macOS 14, *)
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
