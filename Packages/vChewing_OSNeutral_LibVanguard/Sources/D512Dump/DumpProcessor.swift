// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa

struct DumpSummary: Encodable {
  let event = "summary"
  let mode: String
  var processed = 0
  var succeeded = 0
  var skipped = 0
  var requests = 0
  var skip_reasons: [String: Int] = [:]
}

private struct DumpSkippedCase: Encodable {
  let event = "skip"
  let id: String
  let reason: String
  let detail: String
}

extension D512Dump {
  static func process(
    input: String, mode: DumpMode, k: Int,
    makeAssembler: (DumpCase) throws -> Homa.Assembler,
    emit: (Data) -> (), diagnose: (Data) -> ()
  ) throws -> DumpSummary {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var summary = DumpSummary(mode: mode.rawValue)
    defer {
      if let data = try? encoder.encode(summary) { diagnose(data) }
    }
    var seenIDs = Set<String>()
    for (lineIndex, line) in input.components(separatedBy: .newlines).enumerated() where !line.isEmpty {
      let testCase: DumpCase
      do {
        testCase = try decoder.decode(DumpCase.self, from: Data(line.utf8))
      } catch {
        throw DumpError("input line \(lineIndex + 1): invalid JSON/schema: \(error)")
      }
      guard seenIDs.insert(testCase.id).inserted else {
        throw DumpError("input line \(lineIndex + 1): duplicate case id: \(testCase.id)")
      }
      summary.processed += 1
      do {
        try testCase.validate()
        let assembler = try makeAssembler(testCase)
        let requests = try Dumper.requests(for: testCase, assembler: assembler, mode: mode, k: k)
        // Encode the whole case before emitting any of its requests.
        let payloads = try requests.map { try encoder.encode($0) }
        payloads.forEach(emit)
        summary.succeeded += 1
        summary.requests += payloads.count
      } catch {
        let reason: String
        if let failure = error as? DumpError {
          reason = failure.code.rawValue
        } else if let engineFailure = error as? Homa.Exception,
                  case .givenKeyHasNoResults = engineFailure {
          reason = "no_factory_reading"
        } else {
          reason = "engine_error"
        }
        summary.skipped += 1
        summary.skip_reasons[reason, default: 0] += 1
        diagnose(try encoder.encode(DumpSkippedCase(id: testCase.id, reason: reason, detail: String(describing: error))))
      }
    }
    guard summary.succeeded > 0 else { throw DumpError("No cases succeeded.") }
    return summary
  }
}
