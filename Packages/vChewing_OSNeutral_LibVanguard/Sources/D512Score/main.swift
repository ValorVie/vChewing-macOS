// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// Dev tool: scores dumper JSONL with `D512ONNXScorer` and compares against a `d512eval.py` report.
//
// Usage: D512Score --model-dir <dir> --requests <held-out-nbest.jsonl> --report <report-held-out-nbest.json>
//                  [--limit N] [--weight 0.5] [--margin 0.5] [--threads 2]
// Prints a JSON summary to stdout; exits 1 when a request's fallback or candidate count disagrees.

import D512Rerank
import D512RerankONNX
import Darwin
import Foundation

struct Report: Decodable {
  struct Entry: Decodable {
    let id: String
    let fallback: String?
    let task: String?
    let model: [Double]?
  }

  let per_request: [Entry]
}

func arg(_ name: String) -> String? {
  CommandLine.arguments.firstIndex(of: name).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
}

func residentMB() -> (rss: Double, footprint: Double) {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
  _ = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
  }
  return (Double(info.resident_size) / 1_048_576, Double(info.phys_footprint) / 1_048_576)
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
  let q = xs.sorted()
  return q.isEmpty ? .nan : q[min(q.count - 1, Int(p * Double(q.count)))] // same index rule as d512eval.py
}

func median(_ xs: [Double]) -> Double {
  let q = xs.sorted()
  guard !q.isEmpty else { return .nan }
  return q.count % 2 == 1 ? q[q.count / 2] : (q[q.count / 2 - 1] + q[q.count / 2]) / 2
}

func ms(since t: UInt64) -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t) / 1e6 }

guard let modelDir = arg("--model-dir"), let requestsPath = arg("--requests"), let reportPath = arg("--report") else {
  FileHandle.standardError.write(Data("usage: D512Score --model-dir <dir> --requests <jsonl> --report <json> [--limit N]\n".utf8))
  exit(2)
}
let limit = arg("--limit").flatMap(Int.init) ?? .max
let weight = arg("--weight").flatMap(Double.init) ?? 0.5
let margin = arg("--margin").flatMap(Double.init) ?? 0.5
let threads = arg("--threads").flatMap(Int32.init) ?? 2

let dec = JSONDecoder()
let requests = try String(contentsOfFile: requestsPath, encoding: .utf8).split(separator: "\n")
  .prefix(limit).map { try dec.decode(D512Request.self, from: Data($0.utf8)) }
let expected = Dictionary(
  try dec.decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: reportPath))).per_request.map { ($0.id, $0) },
  uniquingKeysWith: { a, _ in a }
)

let memBefore = residentMB()
var t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
try D512ONNXScorer.verifyFiles(URL(fileURLWithPath: modelDir))
let hashMs = ms(since: t)
t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
let scorer = try D512ONNXScorer(modelDirectory: URL(fileURLWithPath: modelDir), intraOpThreads: threads)
let sessionMs = ms(since: t) // hash already cached: vocab + session only
let memAfterSession = residentMB()

if let warm = requests.first(where: { scorer.vocab.fallbackReason($0) == nil }) {
  for _ in 0 ..< 3 { _ = try scorer.vocab.modelScores(warm, scorer: scorer) } // excluded from latency
}

var compared = 0, candidates = 0, overTolerance = 0, maxAbs = 0.0, worstID = "", winnerMismatch: [String] = []
var mismatches: [String] = [], latency8: [Double] = [], latencyAll: [Double] = []
for req in requests {
  guard let py = expected[req.id] else { mismatches.append("\(req.id): missing in report"); continue }
  guard py.task != "text" else { continue } // the harness text task is out of scope
  t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  let swift = try scorer.vocab.modelScores(req, scorer: scorer)
  let elapsed = ms(since: t)
  guard let swift, let pyModel = py.model else {
    if (swift == nil) != (py.model == nil) { mismatches.append("\(req.id): fallback swift=\(swift == nil) py=\(py.fallback ?? "nil")") }
    continue
  }
  guard swift.count == pyModel.count else { mismatches.append("\(req.id): candidate count"); continue }
  latencyAll.append(elapsed)
  if req.candidates.count == 8 { latency8.append(elapsed) }
  compared += 1
  candidates += swift.count
  for (a, b) in zip(swift, pyModel) {
    if abs(a - b) > 1e-4 { overTolerance += 1 }
    if abs(a - b) > maxAbs { (maxAbs, worstID) = (abs(a - b), req.id) }
  }
  let engine = req.candidates.map(\.log_score)
  let mine = D512Fusion.choose(engine: engine, model: swift, default: req.engineDefault, weight: weight, margin: margin)
  let theirs = D512Fusion.choose(engine: engine, model: pyModel, default: req.engineDefault, weight: weight, margin: margin)
  if mine != theirs { winnerMismatch.append(req.id) }
}
let memEnd = residentMB()

let summary: [String: Any] = [
  "requests": requests.count, "compared_requests": compared, "compared_candidates": candidates,
  "max_abs_diff": maxAbs, "max_abs_diff_request": worstID,
  "candidates_over_1e-4": overTolerance,
  "fusion": ["weight": weight, "margin": margin, "winner_mismatches": winnerMismatch.count, "ids": Array(winnerMismatch.prefix(20))],
  "fallback_or_shape_mismatches": mismatches,
  "latency_ms_8_candidates": ["n": latency8.count, "median": median(latency8), "p95": percentile(latency8, 0.95)],
  "latency_ms_all": ["n": latencyAll.count, "median": median(latencyAll), "p95": percentile(latencyAll, 0.95)],
  "hash_verify_ms": hashMs, "session_create_ms": sessionMs, "intra_op_threads": threads,
  "memory_mb": [
    "rss_before_session": memBefore.rss, "rss_after_session": memAfterSession.rss, "rss_end": memEnd.rss,
    "footprint_after_session": memAfterSession.footprint, "footprint_end": memEnd.footprint,
  ],
]
print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
exit(mismatches.isEmpty ? 0 : 1)
