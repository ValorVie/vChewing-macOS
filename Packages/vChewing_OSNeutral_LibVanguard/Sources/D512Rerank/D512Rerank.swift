// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// OS-neutral half of the D512 reranker: request model, vocab, tensor assembly and fusion.
// Port of `DevLab/D512Eval/harness/d512eval.py` (phonetic task only; no text mode).
// Inference lives behind `D512Scoring` (macOS: `D512RerankONNX`).

// MARK: - D512Request

/// One sentence-level k-best request, as written by `D512Dump` (extra fields are ignored).
public struct D512Request: Decodable, Sendable {
  public struct Candidate: Decodable, Sendable {
    public struct Segment: Decodable, Sendable {
      public let Correction: Bool?
      public init(correction: Bool) { Correction = correction }
    }

    public let text: String
    public let log_score: Double
    public let segments: [Segment]?

    public init(text: String, log_score: Double, correction: Bool = false) {
      self.text = text
      self.log_score = log_score
      self.segments = correction ? [.init(correction: true)] : nil
    }
  }

  public let id: String
  public let context: String
  public let reading: [String]
  public let candidates: [Candidate]
  /// Candidate 0 is the engine default unless the dumper says otherwise.
  public var engineDefault: Int { engine_default ?? 0 }

  public init(id: String, context: String, reading: [String], candidates: [Candidate], engineDefault: Int = 0) {
    self.id = id
    self.context = context
    self.reading = reading
    self.candidates = candidates
    self.engine_default = engineDefault
  }

  private let engine_default: Int?
}

// MARK: - D512Input

/// Feeds for one `model.onnx` run (batch 1); `mask` is the flattened L×L lower triangle.
public struct D512Input: Equatable, Sendable {
  public var ids, bases, tones, types, positions: [Int64]
  public var mask: [Bool]
  public var projPos, targetNode, targetIds: [Int64]
  public var length: Int { ids.count }
}

// MARK: - D512RerankError

public enum D512RerankError: Error, Equatable, Sendable {
  /// The model returned NaN/±inf for a candidate; the whole request must keep the engine default.
  case nonFiniteScore(requestID: String, candidate: Int, value: Double)
  /// No candidates, or `engine_default` out of range: there is no safe index to return.
  case invalidRequest(requestID: String)
}

// MARK: - D512Scoring

public protocol D512Scoring {
  /// Model log-probability (natural log) of the candidate encoded in `input`.
  func logProb(_ input: D512Input) throws -> Double
}

// MARK: - D512Vocab

public struct D512Vocab: Sendable {
  public enum Fallback: String, Sendable {
    case outOfLimits = "out_of_limits", oov, correction, badReading = "bad_reading"
  }

  public static let minSyllables = 2
  public static let maxSyllables = 32
  public static let maxCandidates = 16
  public static let contextRunes = 64

  private static let tones: [Unicode.Scalar: Int64] = ["ˊ": 2, "ˇ": 3, "ˋ": 4, "˙": 5] // no mark = 1st tone

  public init(characters: [String], bases: [String], neutralTolerantLast: Set<String>) {
    // Ids 0–7 are specials (4 = UNK); characters start at 8, bases at 2.
    self.chars = Dictionary(
      characters.enumerated().compactMap { i, c in c.unicodeScalars.first.map { ($0, Int64(i + 8)) } },
      uniquingKeysWith: { _, b in b } // last wins, as Python's dict comprehension
    )
    self.bases = Dictionary(bases.enumerated().map { ($1, Int64($0 + 2)) }, uniquingKeysWith: { _, b in b })
    self.neutral = neutralTolerantLast
  }

  /// Reads `vocab.json` and the neutral-tone list from `manifest.json` in `modelDirectory`.
  public init(modelDirectory: URL) throws {
    struct Vocab: Decodable { let characters, bases: [String] }
    struct Manifest: Decodable { let neutral_tolerant_last: [String]? }
    let dec = JSONDecoder()
    let vocab = try dec.decode(Vocab.self, from: Data(contentsOf: modelDirectory.appendingPathComponent("vocab.json")))
    let manifest = try dec.decode(
      Manifest.self, from: Data(contentsOf: modelDirectory.appendingPathComponent("manifest.json"))
    )
    self.init(
      characters: vocab.characters, bases: vocab.bases,
      neutralTolerantLast: Set(manifest.neutral_tolerant_last ?? [])
    )
  }

  /// Whole-case fallbacks (keep the engine default, do not run the model).
  /// Unlike the harness, 1-syllable requests always fall back: its text task is out of scope here.
  public func fallbackReason(_ req: D512Request) -> Fallback? {
    let n = req.reading.count
    guard (Self.minSyllables ... Self.maxSyllables).contains(n),
          (1 ... Self.maxCandidates).contains(req.candidates.count),
          req.candidates.indices.contains(req.engineDefault),
          req.candidates.allSatisfy({ $0.text.unicodeScalars.count == n })
    else { return .outOfLimits }
    if req.candidates.contains(where: { $0.text.unicodeScalars.contains { chars[$0] == nil } }) { return .oov }
    if req.candidates.contains(where: { $0.segments?.contains { $0.Correction == true } == true }) {
      return .correction
    }
    if req.reading.contains(where: { syllable($0) == nil }) { return .badReading }
    return nil
  }

  /// Model log-probs per candidate, or nil when the request falls back.
  /// Neutral-tone rule (as the harness): a neutral-tolerant last syllable written without `˙`
  /// is also scored as `˙`, keeping the max.
  /// Throws `D512RerankError.nonFiniteScore` when any model output is NaN/±inf.
  public func modelScores(_ req: D512Request, scorer: some D512Scoring) throws -> [Double]? {
    guard fallbackReason(req) == nil else { return nil }
    let sounds = req.reading.compactMap(syllable)
    var neutralSounds: [(Int64, Int64)]?
    if let last = req.reading.last.flatMap(Self.splitTone), last.tone != 5, neutral.contains(last.base),
       let b = bases[last.base] {
      neutralSounds = sounds.dropLast() + [(b, 5)]
    }
    return try req.candidates.enumerated().map { i, cand in
      let finite = { (s: Double) throws -> Double in
        guard s.isFinite else { throw D512RerankError.nonFiniteScore(requestID: req.id, candidate: i, value: s) }
        return s
      }
      var s = try finite(scorer.logProb(encode(context: req.context, sounds: sounds, candidate: cand.text)))
      if let alt = neutralSounds {
        s = max(s, try finite(scorer.logProb(encode(context: req.context, sounds: alt, candidate: cand.text))))
      }
      return s
    }
  }

  /// Fused pick for one request. Any scoring error (fallback-worthy model output, inference failure)
  /// keeps the engine default for the whole request and is returned alongside, never swallowed.
  /// `choice` is nil only for an invalid request (no candidates / default out of range).
  public func rerank(
    _ req: D512Request, scorer: some D512Scoring, weight: Double, margin: Double,
    personalHits: [Int]? = nil, bonus: Double = 0
  )
    -> (choice: Int?, error: (any Error)?) {
    guard req.candidates.indices.contains(req.engineDefault) else {
      return (nil, D512RerankError.invalidRequest(requestID: req.id))
    }
    do {
      let model = try modelScores(req, scorer: scorer)
      let engine = req.candidates.map(\.log_score)
      return (D512Fusion.choose(
        engine: engine, model: model, default: req.engineDefault, weight: weight, margin: margin,
        personalHits: personalHits, bonus: bonus
      ), nil)
    } catch {
      return (req.engineDefault, error)
    }
  }

  /// `[BOS] context [SEP] reading×k [OUT] candidate[:-1]`, verbatim port of the harness `_run`.
  func encode(context: String, sounds: [(base: Int64, tone: Int64)], candidate: String) -> D512Input {
    let head = [1] + context.unicodeScalars.suffix(Self.contextRunes).map { chars[$0] ?? 4 } + [2]
    let cand = candidate.unicodeScalars.map { chars[$0]! } // fallbackReason rejected OOV
    let h = head.count, k = sounds.count, n = cand.count
    let out = h + k
    let L = out + n
    let zeros = { (c: Int) in [Int64](repeating: 0, count: c) }
    var mask = [Bool](repeating: false, count: L * L)
    for r in 0 ..< L { for c in 0 ... r { mask[r * L + c] = true } }
    return D512Input(
      ids: head + zeros(k) + [3] + cand.dropLast(),
      bases: zeros(h) + sounds.map(\.base) + zeros(n),
      tones: zeros(h) + sounds.map(\.tone) + zeros(n),
      types: zeros(h) + [Int64](repeating: 1, count: k) + [0] + [Int64](repeating: 2, count: n - 1),
      positions: (0 ..< Int64(L)).map { $0 },
      mask: mask,
      projPos: (Int64(out) ..< Int64(L)).map { $0 },
      targetNode: (0 ..< Int64(n)).map { $0 },
      targetIds: cand.map { $0 - 6 }
    )
  }

  func syllable(_ s: String) -> (base: Int64, tone: Int64)? {
    guard let split = Self.splitTone(s) else { return nil }
    return bases[split.base].map { ($0, split.tone) }
  }

  /// `"ㄇㄚˇ"` → `("ㄇㄚ", 3)`; no mark = 1st tone; nil for an empty string.
  private static func splitTone(_ s: String) -> (base: String, tone: Int64)? {
    guard let mark = s.unicodeScalars.last else { return nil }
    guard let tone = tones[mark] else { return (s, 1) }
    return (String(String.UnicodeScalarView(s.unicodeScalars.dropLast())), tone)
  }

  private let chars: [Unicode.Scalar: Int64]
  private let bases: [String: Int64]
  private let neutral: Set<String>
}

// MARK: - D512Fusion

public enum D512Fusion {
  /// `fused = raw + w × model + b × personalHits`; nil means the whole request must fall back.
  public static func scores(
    engine: [Double], model: [Double]?, weight w: Double, personalHits: [Int]? = nil, bonus b: Double = 0
  ) -> [Double]? {
    guard let model, model.count == engine.count, w.isFinite, b.isFinite else { return nil }
    let hits = personalHits ?? [Int](repeating: 0, count: engine.count)
    guard hits.count == engine.count, hits.allSatisfy({ $0 >= 0 }),
          engine.allSatisfy(\.isFinite), model.allSatisfy(\.isFinite) else { return nil }
    let fused = engine.indices.map { engine[$0] + w * model[$0] + b * Double(hits[$0]) }
    return fused.allSatisfy(\.isFinite) ? fused : nil
  }

  /// A non-default candidate wins only by a strict margin `> τ`.
  /// Ties on the max pick the lowest index, as Python's `max`. `model == nil`, mismatched lengths,
  /// an out-of-range default or any non-finite fused score keep the default.
  public static func choose(
    engine: [Double], model: [Double]?, default d: Int, weight w: Double, margin tau: Double,
    personalHits: [Int]? = nil, bonus b: Double = 0
  )
    -> Int {
    guard engine.indices.contains(d), tau.isFinite,
          let fused = scores(engine: engine, model: model, weight: w, personalHits: personalHits, bonus: b)
    else { return d }
    var best = 0
    for i in fused.indices where fused[i] > fused[best] { best = i }
    return best != d && fused[best] - fused[d] > tau ? best : d
  }
}
