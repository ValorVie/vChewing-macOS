// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import Testing
@testable import LexiconAssembly

@Suite(.serialized)
struct CandidateRankingStoreTests {
  private let pairs = ["試試", "逝世", "世事"].map {
    Homa.CandidatePair(keyArray: ["ㄕˋ", "ㄕˋ"], value: $0)
  }

  @Test("Recent choice wins, counts do not decay, and ties retain the original order")
  func recentAndFrequency() {
    let store = LXAssembly.CandidateRankingStore()
    #expect(store.ranked(pairs) == pairs)
    for pair in pairs {
      store.recordCommittedCandidate(pair)
      #expect(store.ranked(pairs).first == pair)
    }
    #expect(store.ranked(pairs) == [pairs[2], pairs[0], pairs[1]])
    let weighted = LXAssembly.CandidateRankingStore()
    for _ in 0 ..< 10 { weighted.recordCommittedCandidate(pairs[0]) }
    for _ in 0 ..< 5 { weighted.recordCommittedCandidate(pairs[1]) }
    weighted.recordCommittedCandidate(pairs[2])
    #expect(weighted.ranked(pairs) == [pairs[2], pairs[0], pairs[1]])
    weighted.recordCommittedCandidate(pairs[0])
    #expect(weighted.ranked(pairs) == [pairs[0], pairs[1], pairs[2]])
    #expect(pairs.map { weighted.count(for: $0) } == [11, 5, 1])
  }

  @Test("Reading groups keep their slots, absent latest is not reinserted, and ETen can fix single characters")
  func groupsAndMissingLatest() {
    let store = LXAssembly.CandidateRankingStore()
    let other = Homa.CandidatePair(keyArray: ["ㄕˊ", "ㄕˊ"], value: "時時")
    let single = Homa.CandidatePair(keyArray: ["ㄕˋ"], value: "是")
    let otherSingle = Homa.CandidatePair(keyArray: ["ㄕˋ"], value: "事")
    store.recordCommittedCandidate(pairs[1])
    store.recordCommittedCandidate(pairs[2])
    store.recordCommittedCandidate(otherSingle)
    #expect(store.ranked([pairs[0], other, pairs[1], pairs[2], single, otherSingle]) ==
      [pairs[2], other, pairs[1], pairs[0], otherSingle, single])
    #expect(store.ranked([pairs[0], pairs[1]]) == [pairs[1], pairs[0]])
    #expect(store.ranked([single, otherSingle], includingSingleCharacters: false) == [single, otherSingle])
  }

  @Test("Recency follows manual selection order even when receipts arrive in reverse order")
  func delayedReceipts() {
    let store = LXAssembly.CandidateRankingStore()
    let earlier = store.nextSelectionOrder()
    let later = store.nextSelectionOrder()
    store.recordCommittedCandidate(pairs[1], selectionOrder: later)
    store.recordCommittedCandidate(pairs[2], selectionOrder: earlier)
    #expect(store.ranked(pairs) == [pairs[1], pairs[2], pairs[0]])
  }

  @Test("Restart preserves counts and latest, and corrupt or unknown-version files are left intact")
  func persistence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("ranking.json")
    let store = LXAssembly.CandidateRankingStore(dataURL: url)
    store.recordCommittedCandidate(pairs[2])
    store.flushPendingWrites()
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -31 * 86400)],
                                         ofItemAtPath: url.path)
    let restarted = LXAssembly.CandidateRankingStore(dataURL: url)
    restarted.flushPendingWrites()
    #expect(restarted.ranked(pairs) == [pairs[2], pairs[0], pairs[1]])
    #expect(restarted.count(for: pairs[2]) == 1)
    for invalid in [Data("broken".utf8), Data("{\"version\":999,\"groups\":[]}".utf8)] {
      try invalid.write(to: url, options: .atomic)
      let damaged = LXAssembly.CandidateRankingStore(dataURL: url)
      damaged.flushPendingWrites()
      damaged.recordCommittedCandidate(pairs[0])
      damaged.flushPendingWrites()
      #expect(try Data(contentsOf: url) == invalid)
    }
  }

  @Test("An I/O failure retains the old snapshot and memory can be saved again after recovery")
  func saveFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let retained = root.appendingPathExtension("retained")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: retained)
    }
    let url = root.appendingPathComponent("ranking.json")
    let store = LXAssembly.CandidateRankingStore(dataURL: url)
    store.recordCommittedCandidate(pairs[0])
    store.flushPendingWrites()
    let original = try Data(contentsOf: url)
    try FileManager.default.moveItem(at: root, to: retained)
    try Data("blocked directory".utf8).write(to: root)
    store.recordCommittedCandidate(pairs[1])
    store.flushPendingWrites()
    #expect(try Data(contentsOf: retained.appendingPathComponent("ranking.json")) == original)
    #expect(store.count(for: pairs[1]) == 1)
    try FileManager.default.removeItem(at: root)
    try FileManager.default.moveItem(at: retained, to: root)
    store.recordCommittedCandidate(pairs[2])
    store.flushPendingWrites()
    let reloaded = LXAssembly.CandidateRankingStore(dataURL: url)
    reloaded.flushPendingWrites()
    #expect(pairs.map { reloaded.count(for: $0) } == [1, 1, 1])
  }

  @Test("The first save creates its injected parent directory in the I/O queue")
  func firstSaveCreatesParent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("new-folder/ranking.json")
    let store = LXAssembly.CandidateRankingStore(dataURL: url)
    store.recordCommittedCandidate(pairs[0])
    store.flushPendingWrites()
    #expect(FileManager.default.fileExists(atPath: url.path))
  }
}
