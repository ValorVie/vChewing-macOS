// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// The legacy closure has no inference dependency or concurrency runtime references.
#if compiler(>=6.4)
  import D512Rerank
  import Foundation
  import Homa
  #if canImport(D512RerankONNX)
    import D512RerankONNX
  #endif

  /// 每個 session 的可撤回 pin、世代與前文；ORT 僅在序列背景佇列使用。
  public final class D512SentenceRerank {
    public init() { worker = Self.defaultWorker }

    /// 測試注入，不載入磁碟模型。注入後 scorer 的所有呼叫均由 worker 獨占。
    init(scorer: any D512Scoring, vocab: D512Vocab) {
      worker = Worker(scorer: scorer, vocab: vocab)
    }

    public static var modelDirectory: URL {
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      return support.appendingPathComponent("vChewing/D512/d512-pf512-20260926", isDirectory: true)
    }

    public static var unavailableReason: String? { unavailableReason(at: modelDirectory) }

    static func unavailableReason(at directory: URL) -> String? {
      #if canImport(D512RerankONNX)
        guard #available(macOS 14, *) else { return "i18n:D512.RequiresMacOS14".i18n }
        guard ["model.onnx", "vocab.json", "manifest.json"].allSatisfy({
          FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) else { return "i18n:D512.ModelMissing".i18n }
        do {
          try D512ONNXScorer.verifyFiles(directory)
          _ = try D512Vocab(modelDirectory: directory)
          return nil
        } catch { return "i18n:D512.ModelInvalid".i18n }
      #else
        return "i18n:D512.RequiresMacOS14".i18n
      #endif
    }

    private(set) var generation: UInt64 = 0
    private(set) var context = ""
    var hasPin: Bool { !pins.isEmpty }
    var debounceSeconds: Double = 0.15

    func invalidate() { generation &+= 1 }

    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
      invalidate()
      let token = generation
      DispatchQueue.main.asyncAfter(deadline: .now() + debounceSeconds) { [weak self] in
        guard let self, self.generation == token else { return }
        action()
      }
    }

    func noteCommit(_ text: String) {
      context = String(String.UnicodeScalarView((context + text).unicodeScalars.suffix(D512Vocab.contextRunes)))
    }

    func leaveClient(assembler: Homa.Assembler) {
      invalidate()
      withdraw(assembler: assembler)
      context = ""
    }

    func clear(assembler: Homa.Assembler) {
      invalidate()
      withdraw(assembler: assembler)
    }

    func owns(_ node: Homa.Node?) -> Bool {
      guard let node, let pin = pins[node.id] else { return false }
      return node.overrideStatus == pin.applied
    }

    func withdraw(assembler: Homa.Assembler) {
      var mirror: [FIUUID: Homa.NodeOverrideStatus] = [:]
      for segment in assembler.segments {
        for node in segment.values {
          guard let pin = pins[node.id], node.overrideStatus == pin.applied else { continue }
          mirror[node.id] = pin.original
        }
      }
      pins.removeAll()
      guard !mirror.isEmpty else { return }
      assembler.restoreFromNodeOverrideStatusMirror(mirror)
      assembler.assemble()
    }

    /// 先核對整條路徑，再一次寫回；手選節點與格位保持原狀。
    @discardableResult
    func apply(_ grams: [Homa.GramInPath], assembler: Homa.Assembler, fixedRanges: [Range<Int>]) -> Bool {
      var selected: [(Homa.Node, Int)] = []
      var start = 0
      for gram in grams {
        let length = gram.segLength
        guard start < assembler.segments.count, let node = assembler.segments[start][length],
              let index = node.grams.firstIndex(where: { $0.id == gram.gram.id }) else { return false }
        let range = start ..< start + length
        if !fixedRanges.contains(where: { $0.overlaps(range) }) { selected.append((node, index)) }
        start += length
      }
      guard start == assembler.length else { return false }
      var mirror: [FIUUID: Homa.NodeOverrideStatus] = [:]
      for (node, index) in selected {
        let original = node.overrideStatus
        var applied = original
        applied.currentOverrideType = .withSpecified
        applied.overridingScore = 114_514
        applied.isExplicitlyOverridden = false
        applied.currentUnigramIndex = index
        pins[node.id] = Pin(original: original, applied: applied)
        mirror[node.id] = applied
      }
      // 跨分段 POM 強覆寫可能與贏家相交；暫降而非刪除，撤回時復原。
      for (start, segment) in assembler.segments.enumerated() {
        for (length, node) in segment {
          guard mirror[node.id] == nil, node.currentOverrideType == .withSpecified,
                node.overridingScore > 0, !node.isExplicitlyOverridden,
                !fixedRanges.contains(where: { $0.overlaps(start ..< start + length) }) else { continue }
          let original = node.overrideStatus
          var applied = original
          applied.overridingScore = -114_514
          pins[node.id] = Pin(original: original, applied: applied)
          mirror[node.id] = applied
        }
      }
      assembler.restoreFromNodeOverrideStatusMirror(mirror)
      assembler.assemble()
      guard assembler.assembledSentence.map(\.value).joined() == grams.map(\.value).joined() else {
        withdraw(assembler: assembler)
        return false
      }
      return true
    }

    func score(_ request: D512Request, completion: @escaping @MainActor @Sendable (ModelResult) -> Void) {
      worker.queue.async { [worker] in
        let result = worker.score(request)
        DispatchQueue.main.async { completion(result) }
      }
    }

    nonisolated struct ModelResult: Sendable {
      let scores: [Double]?
      let error: String?
    }

    private struct Pin {
      let original: Homa.NodeOverrideStatus
      let applied: Homa.NodeOverrideStatus
    }

    private var pins: [FIUUID: Pin] = [:]
    private let worker: Worker
    private static let defaultWorker = Worker()

    /// `@unchecked` 限於佇列持有者；scorer、vocab 都只在 queue 內存取。
    nonisolated private final class Worker: @unchecked Sendable {
      let queue = DispatchQueue(label: "org.vChewing.D512Scoring", qos: .userInitiated)
      private var scorer: (any D512Scoring)?
      private var vocab: D512Vocab?

      init(scorer: (any D512Scoring)? = nil, vocab: D512Vocab? = nil) {
        self.scorer = scorer
        self.vocab = vocab
      }

      func score(_ request: D512Request) -> ModelResult {
        do {
          if scorer == nil {
            #if canImport(D512RerankONNX)
              guard #available(macOS 14, *) else {
                return .init(scores: nil, error: "macOS 14 required")
              }
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
              let directory = support.appendingPathComponent("vChewing/D512/d512-pf512-20260926")
              let loaded = try D512ONNXScorer(modelDirectory: directory)
              scorer = loaded
              vocab = loaded.vocab
            #else
              return .init(scores: nil, error: "macOS 14 required")
            #endif
          }
          guard let scorer, let vocab else { return .init(scores: nil, error: "scorer unavailable") }
          return .init(scores: try vocab.modelScores(request, scorer: scorer), error: nil)
        } catch { return .init(scores: nil, error: String(describing: error)) }
      }
    }
  }
#endif
