// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Testing

@testable import Homa

extension HomaTestsRoot {
  struct HomaTests_KBest {
    @Test("K-best preserves the engine path and both override score modes")
    func preservesEnginePathWithOverrides() throws {
      for type: Homa.Node.OverrideType in [.withSpecified, .withTopGramScore] {
        for explicit in [false, true] {
          let assembler = try fixture()
          try assembler.overrideCandidate(
            .init(keyArray: ["a"], value: "假"), at: 0, type: type,
            isExplicitlyOverridden: explicit
          )
          let expected = assembler.assemble()
          let expectedScore = assembler.mostRecentPathScore
          #expect(expectedScore == (type == .withSpecified ? 114_511.5 : -4.5))
          let mirror = assembler.createNodeOverrideStatusMirror()
          let candidates = assembler.fetchCandidates(filter: .all)
          for k in [1, 8] {
            let paths = try assembler.assembleKBest(k: k)
            #expect(paths.first?.grams == expected)
            #expect(paths.first?.score == expectedScore)
            #expect(paths.first?.rawUnigramLogScore == -5.5)
            #expect(paths.first?.grams.first?.isExplicit == (explicit && type == .withSpecified))
            #expect(assembler.createNodeOverrideStatusMirror() == mirror)
            #expect(assembler.fetchCandidates(filter: .all) == candidates)
            #expect(assembler.assembledSentence == expected)
            #expect(assembler.mostRecentPathScore == expectedScore)
          }
        }
      }
    }

    @Test("K-best equals small exhaustive unigram, override and bigram fixtures")
    func equalsExhaustiveEnumeration() throws {
      var fixtures: [Homa.Assembler] = []
      for count in 1 ... 6 {
        let keys = (0 ..< count).map { "k\($0)" }
        let assembler = Homa.Assembler(gramQuerier: { query in
          let exact = query.map(\.first)
          guard let first = exact.first, let start = keys.firstIndex(of: first),
                exact.count <= 3 else { return [] }
          let text = exact.map { $0.uppercased() }.joined()
          let score = -Double(17 * exact.count + start + 1) / 8
          return [
            .init(keyArray: exact, current: text, probability: score),
            .init(keyArray: exact, current: text.lowercased(), probability: score - 0.25),
          ]
        })
        for key in keys { try assembler.insertKey(key) }
        fixtures.append(assembler)
      }
      let overridden = try fixture()
      try overridden.overrideCandidate(.init(keyArray: ["a"], value: "假"), at: 0, type: .withSpecified)
      fixtures.append(overridden)
      let contextual = try fixture()
      contextual.withNode(at: 1, segLength: 1) { node in
        node.syncingGrams(from: node.grams + [
          .init(keyArray: ["b"], current: "乙", previous: "甲", probability: -0.25),
        ])
      }
      fixtures.append(contextual)
      for assembler in fixtures {
        _ = assembler.assemble()
        let baseline = assembler.assemble()
        let all = exhaustive(assembler)
        for k in 1 ... 8 {
          let expected = [baseline.values.joined()] + all.map(\.text).filter { $0 != baseline.values.joined() }
          let actual = try assembler.assembleKBest(k: k)
          #expect(actual.map(\.text) == Array(expected.prefix(k)))
          #expect(actual.first?.grams == baseline)
          #expect(actual.count <= k)
          #expect(Set(actual.map(\.text)).count == actual.count)
          for path in actual {
            #expect(path.score == all.first { $0.text == path.text }?.score)
            #expect(path.rawUnigramLogScore == path.grams.reduce(0) { $0 + $1.gram.probability })
          }
        }
      }
    }

    @Test("Boundary ties survive pruning before a suffix reverses text order")
    func retainsBoundaryTies() throws {
      let assembler = Homa.Assembler(gramQuerier: { query in
        let keys = query.map(\.first)
        switch keys {
        case ["a"]:
          return ["a", "aa", "aaa"].map { .init(keyArray: keys, current: $0, probability: -1) }
        case ["z"]:
          return [.init(keyArray: keys, current: "z", probability: -1)]
        default:
          return []
        }
      })
      for key in ["a", "z"] { try assembler.insertKey(key) }
      #expect(try assembler.assembleKBest(k: 2).map(\.text) == ["az", "aaaz"])

      // k=2 時只容許八個同分前綴；第九個的語境加分不得繞過 4k 上限。
      let capped = Homa.Assembler(gramQuerier: { query in
        let keys = query.map(\.first)
        switch keys {
        case ["a"]:
          return (0 ..< 9).map { .init(keyArray: keys, current: "a\($0)", probability: -1) }
        case ["z"]:
          return [
            .init(keyArray: keys, current: "z", probability: -1),
            .init(keyArray: keys, current: "boosted", previous: "a8", probability: 10),
          ]
        default:
          return []
        }
      })
      for key in ["a", "z"] { try capped.insertKey(key) }
      #expect(try capped.assembleKBest(k: 2).map(\.text) == ["a0z", "a1z"])
    }

    @Test("K-best deduplicates text across segmentations and retains macros")
    func deduplicatesText() throws {
      let assembler = try fixture()
      let paths = try assembler.assembleKBest(k: 8)
      #expect(paths.map(\.text) == ["甲乙丙", "假乙丙", "加以丙", "長巨集文字乙丙"])
      #expect(paths.map(\.score) == [-4.5, -5.5, -6, -10.5])
      #expect(paths.first?.grams.values == ["甲", "乙丙"])
    }

    @Test("Fixed ranges preserve the whole intersected gram and its boundaries")
    func respectsFixedRanges() throws {
      let assembler = try fixture()
      let baseline = assembler.assemble()
      #expect(baseline.values == ["甲", "乙丙"])
      let paths = try assembler.assembleKBest(k: 8, fixedRanges: [2 ..< 3])
      #expect(paths.map(\.text) == ["甲乙丙", "假乙丙", "長巨集文字乙丙"])
      #expect(paths.allSatisfy { $0.grams.last == baseline.last })
      #expect(paths.allSatisfy { $0.grams.map(\.segLength) == [1, 2] })
      #expect(try assembler.assembleKBest(k: 8, fixedRanges: [-2 ..< 1, 1 ..< 3]).map(\.grams) == [baseline])
      #expect(try assembler.assembleKBest(k: 8, fixedRanges: [3 ..< 3, 8 ..< 9]).count == 4)
    }

    @Test("Fixed coordinates use lattice spans when gram key counts differ")
    func respectsLatticeCoordinates() throws {
      let longGram = Homa.Gram(keyArray: ["a", "extra"], current: "詞", probability: -1)
      let tail = Homa.Gram(keyArray: ["b"], current: "尾", probability: -1)
      let assembler = Homa.Assembler(gramQuerier: { _ in [] }, config: .init(
        keys: [.singleKey("a"), .singleKey("b")],
        segments: [
          [1: .init(keyArray: ["a"], grams: [longGram, .init(keyArray: ["a"], current: "替", probability: -2)])],
          [1: .init(keyArray: ["b"], grams: [tail, .init(keyArray: ["b"], current: "末", probability: -2)])],
        ]
      ))
      let baseline = assembler.assemble()
      let paths = try assembler.assembleKBest(k: 8, fixedRanges: [1 ..< 2])
      #expect(paths.first?.grams == baseline)
      #expect(paths.map(\.text) == ["詞尾", "替尾"])
      #expect(paths.allSatisfy { $0.grams.last?.gram == tail })
    }

    @Test("Context scoring remains local to each path and never writes nodes")
    func contextScoringIsReadOnly() throws {
      let entries: [String: [Homa.Gram]] = [
        "a": [.init(keyArray: ["a"], current: "甲", probability: -1),
              .init(keyArray: ["a"], current: "假", probability: -2)],
        "b": [.init(keyArray: ["b"], current: "乙", probability: -1)],
        "c": [.init(keyArray: ["c"], current: "丙", probability: -5),
              .init(keyArray: ["c"], current: "丙", previous: "乙", anterior: "假", probability: -0.25)],
      ]
      let assembler = Homa.Assembler(gramQuerier: { entries[$0.map(\.first).joined()] ?? [] })
      for key in ["a", "b", "c"] { try assembler.insertKey(key) }
      let expected = assembler.assemble()
      let expectedConfig = assembler.config
      let paths = try assembler.assembleKBest(k: 8)
      #expect(paths.first?.grams == expected)
      #expect(paths.first?.score == -7)
      #expect(paths.first?.rawUnigramLogScore == expected.reduce(0) { $0 + $1.gram.probability })
      #expect(paths.first { $0.text == "假乙丙" }?.score == -3.25)
      #expect(assembler.config == expectedConfig)
    }

    @Test("A single beam merges equal prefix text across contextual histories")
    func mergesContextHistories() throws {
      let entries: [String: [Homa.Gram]] = [
        "a": [.init(keyArray: ["a"], current: "A", probability: -2)],
        "b": [.init(keyArray: ["b"], current: "B", probability: -2)],
        "ab": [.init(keyArray: ["a", "b"], current: "AB", probability: -1)],
        "c": [.init(keyArray: ["c"], current: "C", probability: -10),
              .init(keyArray: ["c"], current: "Z", previous: "B", anterior: "A", probability: -0.25)],
      ]
      let assembler = Homa.Assembler(gramQuerier: { entries[$0.map(\.first).joined()] ?? [] })
      for key in ["a", "b", "c"] { try assembler.insertKey(key) }
      let paths = try assembler.assembleKBest(k: 8)
      #expect(paths.map(\.text) == ["ABC"])
      #expect(paths.first?.grams.values == ["AB", "C"])
    }

    @Test("Candidate zero captures a fresh contextual assembly exactly")
    func capturesFreshContextualAssembly() throws {
      // PathFinder 先擷取輸出 gram，再評分並更新節點；此處刻意不預先暖機。
      let config = Homa.Config(
        keys: [.singleKey("a"), .singleKey("b")],
        segments: [
          [1: .init(keyArray: ["a"], grams: [.init(keyArray: ["a"], current: "甲", probability: -1)])],
          [1: .init(keyArray: ["b"], grams: [
            .init(keyArray: ["b"], current: "乙", probability: -5),
            .init(keyArray: ["b"], current: "異", previous: "甲", probability: -0.25),
          ])],
        ]
      )
      for k in [1, 8] {
        let reference = Homa.Assembler(gramQuerier: { _ in [] }, config: config)
        let assembler = Homa.Assembler(gramQuerier: { _ in
          Issue.record("K-best must not requery the language model")
          return []
        }, perceptor: { _ in Issue.record("K-best must not invoke the perceptor") }, config: config)
        let expected = reference.assemble()
        #expect(expected.values == ["甲", "乙"])
        let paths = try assembler.assembleKBest(k: k)
        #expect(paths.first?.grams == expected)
        #expect(paths.first?.score == reference.mostRecentPathScore)
        #expect(paths.first?.score == -1.25)
        #expect(paths.first?.rawUnigramLogScore == -6)
        #expect(assembler.config == reference.config)
      }
    }

    @Test("Demoted overrides keep their DP score and raw gram probability separate")
    func respectsDemotedOverrides() throws {
      let assembler = try fixture()
      assembler.withNode(at: 0, segLength: 2) { node in
        node.overrideStatus = .init(
          overridingScore: -20, currentOverrideType: .withSpecified,
          isExplicitlyOverridden: true, currentUnigramIndex: 1
        )
      }
      let baseline = assembler.assemble()
      let mirror = assembler.createNodeOverrideStatusMirror()
      let paths = try assembler.assembleKBest(k: 8)
      #expect(paths.first?.grams == baseline)
      let demoted = try #require(paths.first { $0.text == "加以丙" })
      #expect(demoted.score == -22)
      #expect(demoted.rawUnigramLogScore == -6)
      #expect(demoted.grams.first?.isExplicit == true)
      #expect(assembler.createNodeOverrideStatusMirror() == mirror)
    }

    @Test("Empty and disconnected lattices return no incomplete paths")
    func noIncompletePaths() throws {
      let empty = Homa.Assembler(gramQuerier: { _ in [] })
      #expect(try empty.assembleKBest(k: 8).isEmpty)
      let assembler = try fixture()
      assembler.segments[0] = [:]
      #expect(try assembler.assembleKBest(k: 8).isEmpty)
    }

    @Test("K-best rejects limits outside 1...8 without changing state")
    func rejectsInvalidLimits() throws {
      let assembler = try fixture()
      let config = assembler.config
      for k in [Int.min, -1, 0, 9, Int.max] {
        #expect(throws: Homa.KBestError.invalidLimit) { try assembler.assembleKBest(k: k) }
        #expect(assembler.config == config)
      }
    }

    @Test("Measure k=8 at 8, 16 and 32 syllables without a timing gate")
    func measureKBest() throws {
      for count in [8, 16, 32] {
        let assembler = Homa.Assembler(gramQuerier: { query in
          let keys = query.map(\.first)
          guard keys.count <= 6 else { return [] }
          return (0 ..< 4).map { index in
            .init(keyArray: keys, current: keys.joined() + "\(index)", probability: -Double(keys.count + index))
          }
        })
        for index in 0 ..< count { try assembler.insertKey("音\(index)") }
        for _ in 0 ..< 5 { _ = try assembler.assembleKBest(k: 8) }
        var samples: [Double] = []
        for _ in 0 ..< 50 {
          let start = Date.timeIntervalSinceReferenceDate
          let paths = try assembler.assembleKBest(k: 8)
          samples.append((Date.timeIntervalSinceReferenceDate - start) * 1_000)
          #expect(paths.count == 8)
        }
        samples.sort()
        print(
          "KBest k=8 syllables=\(count) samples=50 mean_ms=\(samples.reduce(0, +) / 50) "
            + "median_ms=\(samples[25]) p95_ms=\(samples[47]) max_ms=\(samples[49])"
        )
      }
    }

    private func fixture() throws -> Homa.Assembler {
      let entries: [String: [(String, Double)]] = [
        "a": [("甲", -2), ("假", -3), ("長巨集文字", -8)],
        "b": [("乙", -2)], "c": [("丙", -2)],
        "ab": [("甲乙", -3), ("加以", -4)],
        "bc": [("乙丙", -2.5)], "abc": [("甲乙丙", -5)],
      ]
      let assembler = Homa.Assembler(gramQuerier: { query in
        let keys = query.map(\.first)
        return (entries[keys.joined()] ?? []).map { .init(keyArray: keys, current: $0.0, probability: $0.1) }
      })
      for key in ["a", "b", "c"] { try assembler.insertKey(key) }
      return assembler
    }

    /// 不剪枝、展開所有路徑後才合併相同文字，作為小圖的獨立 oracle。
    private func exhaustive(_ assembler: Homa.Assembler) -> [(text: String, score: Double)] {
      var best: [String: Double] = [:]
      func visit(_ start: Int, _ text: String, _ score: Double, _ previous: String, _ anterior: String) {
        if start == assembler.length {
          best[text] = max(best[text] ?? -.infinity, score)
          return
        }
        for (length, node) in assembler.segments[start] {
          if node.isOverridden {
            guard let gram = node.currentGram else { continue }
            var copy = node
            visit(start + length, text + gram.current,
                  score + copy.getScore(previous: previous, anterior: anterior), gram.current, previous)
            continue
          }
          for gram in node.grams {
            if !gram.isUnigram {
              guard !previous.isEmpty, gram.previous == previous,
                    gram.anterior == nil || (!anterior.isEmpty && gram.anterior == anterior) else { continue }
            }
            visit(start + length, text + gram.current, score + gram.probability, gram.current, previous)
          }
        }
      }
      visit(0, "", 0, "", "")
      return best.map { (text: $0.key, score: $0.value) }.sorted {
        $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score
      }
    }
  }
}
