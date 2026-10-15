// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// The legacy closure has no inference dependency or concurrency runtime references.
#if compiler(>=6.4)
  import D512Rerank
  import Foundation
  import Homa
  import LexiconAssembly
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
          try D512ONNXScorer.verifyFiles(directory, useCache: false)
          _ = try D512Vocab(modelDirectory: directory)
          return nil
        } catch { return "i18n:D512.ModelInvalid".i18n }
      #else
        return "i18n:D512.RequiresMacOS14".i18n
      #endif
    }

    private(set) var generation: UInt64 = 0
    private(set) var context = ""
    private(set) var clientEpoch: UInt64 = 0
    var hasPin: Bool { !pins.isEmpty }
    var debounceSeconds: Double = 0.15
    var keyCommitSnapshot: (keys: [Homa.PossibleKey], text: String)?
    private(set) var lastEvaluation: Evaluation?
    var evaluationCompleted: (() -> Void)?
    var calibrationLog = D512SentenceRerank.sharedCalibrationLog
    private(set) var lastCalibrationRecord: D512CalibrationRecord?
    private var calibrationEnabled = false
    private var pendingRecords: [D512CalibrationRecord] = []

    func setCalibrationEnabled(_ enabled: Bool) {
      calibrationEnabled = enabled
      if !enabled { pendingRecords.removeAll() }
    }

    func invalidate() { generation &+= 1 }

    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
      invalidate()
      let token = generation
      DispatchQueue.main.asyncAfter(deadline: .now() + debounceSeconds) { [weak self] in
        guard let self, self.generation == token else { return }
        action()
      }
    }

    func noteCommit(_ text: String, calibrationEnabled: Bool? = nil) {
      if let calibrationEnabled { setCalibrationEnabled(calibrationEnabled) }
      context = String(String.UnicodeScalarView((context + text).unicodeScalars.suffix(D512Vocab.contextRunes)))
      finishRecords(text: text)
    }

    func leaveClient(assembler: Homa.Assembler) {
      clientEpoch &+= 1
      invalidate()
      withdraw(assembler: assembler)
      context = ""
      finishRecords(text: nil)
    }

    func clear(assembler: Homa.Assembler) {
      invalidate()
      withdraw(assembler: assembler)
      keyCommitSnapshot = nil
      finishRecords(text: nil)
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

    /// 此處僅複製值語義圖；Homa 的查詢器與感知器不會送往背景。
    func evaluate<Handler: InputHandlerProtocol>(_ handler: Handler) {
      let assembler = handler.assembler
      let defaultGrams = assembler.assembledSentence
      guard defaultGrams.reduce(0, { $0 + $1.segLength }) == assembler.length else { return }
      let fixed = handler.candidateSelectionLearning.protectedRanges(assembler: assembler)
      var personal: [FixedText] = []
      var start = 0
      for gram in defaultGrams {
        if handler.personalCandidatePreference.owns(assembler.segments[start][gram.segLength]) {
          personal.append(.init(range: start ..< start + gram.segLength, text: gram.value))
        }
        start += gram.segLength
      }
      let grid = handler.personalCandidatePreference.withWithdrawn(assembler: assembler) {
        Grid(config: assembler.config)
      }
      var pom: [FixedText] = []
      for (start, segment) in grid.assembler.segments.enumerated() {
        for (length, node) in segment where node.isOverridden && !node.isExplicitlyOverridden {
          if let value = node.value { pom.append(.init(range: start ..< start + length, text: value)) }
        }
      }
      var latest: [[String]: String] = [:]
      if handler.isCandidateRankingEnabled {
        for segment in grid.assembler.segments {
          for node in segment.values {
            for gram in node.grams {
              latest[gram.keyArray] = handler.currentLM.candidateRanking.latestValue(for: gram.keyArray)
            }
          }
        }
      }
      let token = generation
      let context = context
      let w = handler.prefs.d512RerankWeight, tau = handler.prefs.d512RerankMargin
      let b = handler.prefs.d512RerankPersonalBonus
      let keys = assembler.keys
      let completion: @MainActor @Sendable (Evaluation?) -> Void = { [weak self, weak handler] evaluation in
          guard let self else { return }
          defer { self.evaluationCompleted?() }
          guard let handler, self.generation == token,
                handler.prefs.useD512SentenceRerank, handler.session?.state.type == .ofInputting,
                handler.assembler.keys == keys,
                handler.composer.isEmpty, handler.mixedAlphanumericalBuffer.isEmpty else { return }
          if let evaluation {
            self.lastEvaluation = evaluation
            var applied = false
            if evaluation.choice != evaluation.defaultIndex {
              handler.personalCandidatePreference.withdraw(assembler: handler.assembler)
              applied = self.apply(
                evaluation.paths[evaluation.choice].grams, assembler: handler.assembler, fixedRanges: fixed
              )
              if applied {
                handler.session?.switchState(handler.generateStateOfInputting())
              } else { handler.applyPersonalCandidatePreference() }
            }
            let chosenText = evaluation.paths[applied ? evaluation.choice : evaluation.defaultIndex].text
            func conflicts(_ texts: [FixedText]) -> Bool {
              texts.contains { String(chosenText.dropFirst($0.range.lowerBound).prefix($0.range.count)) != $0.text }
            }
            let record = D512CalibrationRecord(
              id: evaluation.request.id, reading: evaluation.request.reading,
              candidates: evaluation.paths.enumerated().map { index, path in
                .init(text: path.text, raw: path.raw, modelLogP: evaluation.model?[index],
                      personalHits: path.personalHits, fused: evaluation.fused?[index])
              }, defaultIndex: evaluation.defaultIndex, winnerIndex: evaluation.winner,
              applied: applied, personalConflict: applied && conflicts(personal), pomConflict: applied && conflicts(pom),
              weight: w, margin: tau, bonus: b
            )
            self.lastCalibrationRecord = record
            if self.calibrationEnabled, handler.prefs.logD512Calibration {
              self.pendingRecords.append(record)
              self.calibrationLog.append(record)
            }
          }
      }
      worker.queue.async { [worker, latest] in
        let evaluation = worker.evaluate(
          grid: grid, defaultGrams: defaultGrams, fixed: fixed, latest: latest, context: context,
          weight: w, margin: tau, bonus: b
        )
        DispatchQueue.main.async { completion(evaluation) }
      }
    }

    nonisolated struct Path: Sendable {
      let grams: [Homa.GramInPath]
      let text: String
      let raw: Double
      let personalHits: Int

      init(grams: [Homa.GramInPath], latest: [[String]: String], wordRanges: [Range<Int>]) {
        self.grams = grams
        text = grams.map(\.value).joined()
        raw = grams.reduce(0) { $0 + $1.score }
        var start = 0, hits = 0
        for item in grams {
          let gram = item.gram, length = item.segLength
          let range = start ..< start + length
          defer { start = range.upperBound }
          guard gram.current.count == length,
                gram.keyArray.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("_") }),
                (gram.previous ?? "").isEmpty, (gram.anterior ?? "").isEmpty,
                latest[gram.keyArray] == gram.current,
                length > 1 || !wordRanges.contains(where: { $0.overlaps(range) }) else { continue }
          hits += 1
        }
        personalHits = hits
      }
    }

    nonisolated struct FixedText: Sendable {
      let range: Range<Int>
      let text: String
    }

    nonisolated struct Evaluation: Sendable {
      let request: D512Request
      let paths: [Path]
      let model: [Double]?
      let fused: [Double]?
      let defaultIndex: Int
      let winner: Int
      let choice: Int
      let weight, margin, bonus: Double
    }

    /// 複製的 Config 只含值語義節點及不可變 gram；此圖由單一 worker 獨占。
    nonisolated private final class Grid: @unchecked Sendable {
      let assembler: Homa.Assembler
      init(config: Homa.Config) { assembler = .init(gramQuerier: { _ in [] }, config: config) }
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
    private static let sharedCalibrationLog = D512CalibrationLog(url: modelDirectory
      .deletingLastPathComponent().appendingPathComponent("calibration.jsonl"))

    private func finishRecords(text: String?) {
      if calibrationEnabled {
        for var record in pendingRecords {
          record.phase = text == nil ? "cancel" : "commit"
          record.finalCommittedText = text
          calibrationLog.append(record)
        }
      }
      pendingRecords.removeAll()
    }

    /// 遞交可延後至下一個主佇列迴圈；先取出收據，避免 clear 將它記成取消。
    func takeCommitRecords() -> [D512CalibrationRecord] {
      defer { pendingRecords.removeAll() }
      return calibrationEnabled ? pendingRecords : []
    }

    func confirmCommitRecords(
      _ records: [D512CalibrationRecord], text: String?, enabled: Bool, expectedClientEpoch: UInt64
    ) {
      guard enabled else { return }
      for var record in records {
        let committed = expectedClientEpoch == clientEpoch ? text : nil
        record.phase = committed == nil ? "cancel" : "commit"
        record.finalCommittedText = committed
        calibrationLog.append(record)
      }
    }

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

      func evaluate(
        grid: Grid, defaultGrams: [Homa.GramInPath], fixed: [Range<Int>], latest: [[String]: String],
        context: String, weight: Double, margin: Double, bonus: Double
      ) -> Evaluation? {
        do {
          var wordRanges: [Range<Int>] = []
          var start = 0
          for gram in grid.assembler.assembledSentence {
            if gram.segLength > 1 { wordRanges.append(start ..< start + gram.segLength) }
            start += gram.segLength
          }
          var paths = try grid.assembler.assembleKBest(k: 8, fixedRanges: fixed).map {
            Path(grams: $0.grams, latest: latest, wordRanges: wordRanges)
          }
          let baseline = Path(grams: defaultGrams, latest: latest, wordRanges: wordRanges)
          let d: Int
          if let index = paths.firstIndex(where: { $0.text == baseline.text }) {
            d = index
            paths[index] = baseline
          } else {
            d = paths.count
            paths.append(baseline)
          }
          let request = D512Request(
            id: UUID().uuidString, context: context, reading: defaultGrams.flatMap(\.keyArray),
            candidates: paths.map {
              .init(text: $0.text, log_score: $0.raw, correction: $0.grams.contains(where: \.isReadingMismatched))
            }, engineDefault: d
          )
          let result = score(request)
          let raw = paths.map(\.raw), hits = paths.map(\.personalHits)
          let fused = D512Fusion.scores(engine: raw, model: result.scores, weight: weight,
                                        personalHits: hits, bonus: bonus)
          var winner = d
          if let fused, !fused.isEmpty {
            winner = 0
            for i in fused.indices where fused[i] > fused[winner] { winner = i }
          }
          let choice = D512Fusion.choose(engine: raw, model: result.scores, default: d, weight: weight,
                                         margin: margin, personalHits: hits, bonus: bonus)
          return .init(request: request, paths: paths, model: result.scores, fused: fused,
                       defaultIndex: d, winner: winner, choice: choice, weight: weight, margin: margin, bonus: bonus)
        } catch { return nil }
      }
    }
  }

  extension InputHandlerProtocol {
    func scheduleD512Rerank() {
      let rerank = d512SentenceRerank
      rerank.setCalibrationEnabled(prefs.logD512Calibration)
      guard prefs.useD512SentenceRerank, session?.state.type == .ofInputting,
            currentTypingMethod == .vChewingFactory, !prefs.useSCPCTypingMode,
            !prefs.cassetteEnabled, composer.isEmpty, mixedAlphanumericalBuffer.isEmpty,
            (2 ... 32).contains(assembler.length),
            assembler.assembledSentence.reduce(0, { $0 + $1.segLength }) == assembler.length,
            assembler.assembledSentence.allSatisfy({
              !$0.isReadingMismatched && $0.keyArray.allSatisfy { !$0.isEmpty && !$0.hasPrefix("_") }
            }) else { rerank.invalidate(); return }
      guard !rerank.hasPin else { return }
      rerank.schedule { [weak self] in
        guard let self else { return }
        rerank.evaluate(self)
      }
    }
  }
#endif
