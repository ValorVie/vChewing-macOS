// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

#if compiler(>=6.4)
  import Foundation

  /// 同一 id 的 rerank 列立即落盤；commit／cancel 列補上後續實際遞交結果。
  nonisolated struct D512CalibrationRecord: Codable, Sendable {
    struct Candidate: Codable, Sendable {
      let text: String
      let raw: Double
      let modelLogP: Double?
      let personalHits: Int
      let fused: Double?

      func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(raw, forKey: .raw)
        try c.encode(modelLogP, forKey: .modelLogP)
        try c.encode(personalHits, forKey: .personalHits)
        try c.encode(fused, forKey: .fused)
      }
    }

    let id: String
    var phase: String = "rerank"
    let reading: [String]
    let candidates: [Candidate]
    let defaultIndex, winnerIndex: Int
    var applied, personalConflict, pomConflict: Bool
    let weight, margin, bonus: Double
    var mode = "automatic"
    var suggested = false
    var accepted: Bool?
    var finalCommittedText: String?

    func encode(to encoder: any Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(id, forKey: .id)
      try c.encode(phase, forKey: .phase)
      try c.encode(reading, forKey: .reading)
      try c.encode(candidates, forKey: .candidates)
      try c.encode(defaultIndex, forKey: .defaultIndex)
      try c.encode(winnerIndex, forKey: .winnerIndex)
      try c.encode(applied, forKey: .applied)
      try c.encode(personalConflict, forKey: .personalConflict)
      try c.encode(pomConflict, forKey: .pomConflict)
      try c.encode(weight, forKey: .weight)
      try c.encode(margin, forKey: .margin)
      try c.encode(bonus, forKey: .bonus)
      try c.encode(mode, forKey: .mode)
      try c.encode(suggested, forKey: .suggested)
      try c.encode(accepted, forKey: .accepted)
      try c.encode(finalCommittedText, forKey: .finalCommittedText)
    }
  }

  /// 檔案只由這條序列佇列寫入；開關關閉時呼叫端不排入任何事件。
  nonisolated final class D512CalibrationLog: @unchecked Sendable {
    init(url: URL) { self.url = url }
    private let url: URL
    private let queue = DispatchQueue(label: "org.vChewing.D512CalibrationIO", qos: .utility)

    func append(_ record: D512CalibrationRecord) {
      queue.async { [self] in
        do {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.sortedKeys]
          var data = try encoder.encode(record)
          data.append(0x0A)
          try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
          if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
              throw CocoaError(.fileWriteUnknown)
            }
          }
          let file = try FileHandle(forWritingTo: url)
          defer { try? file.close() }
          try file.seekToEnd()
          try file.write(contentsOf: data)
        } catch { NSLog("vChewing D512: calibration record could not be saved.") }
      }
    }

    /// 僅供隔離測試及離線驗證使用。
    func flush() { queue.sync {} }
  }
#endif
