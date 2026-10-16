// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import SwiftExtension

extension LXAssembly {
  /// 個人選字統計；與 POM 分開保存，不修改詞庫的持久分數。
  public final class CandidateRankingStore: @unchecked Sendable {
    public init(dataURL: URL? = nil) {
      self.dataURL = dataURL
      guard let dataURL else { return }
      state.withLock { $0.loading = true }
      ioQueue.async { [self] in
        var groups: [[String]: Group] = [:]
        var writable = true
        if FileManager.default.fileExists(atPath: dataURL.path) {
          do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: dataURL))
            guard snapshot.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            for group in snapshot.groups {
              guard !group.keyArray.isEmpty, group.keyArray.allSatisfy({ !$0.isEmpty }),
                    !group.counts.isEmpty, group.counts.values.allSatisfy({ $0 > 0 }),
                    group.counts.keys.allSatisfy({ !$0.isEmpty }), group.counts[group.latest] != nil,
                    groups[group.keyArray] == nil
              else { throw CocoaError(.fileReadCorruptFile) }
              groups[group.keyArray] = group
            }
          } catch {
            // 未能讀懂原檔時禁止覆寫；日誌不含讀音、詞值或檔案內容。
            writable = false
            NSLog("vChewing candidate ranking: data could not be loaded; original file retained.")
          }
        }
        state.withLock {
          $0.groups = groups
          $0.latestOrders.removeAll()
          for (pair, order) in $0.pending { $0.record(pair, order: order) }
          $0.pending.removeAll()
          $0.loading = false
          $0.writable = writable
        }
      }
    }

    /// 序號在手動選取時取得，讓分批或非同步遞交仍遵循選取先後。
    public func nextSelectionOrder() -> UInt64 {
      state.withLock {
        $0.selectionOrder += 1
        return $0.selectionOrder
      }
    }

    public func recordCommittedCandidate(_ pair: Homa.CandidatePair, selectionOrder: UInt64? = nil) {
      guard !pair.keyArray.isEmpty, pair.keyArray.allSatisfy({ !$0.isEmpty }), !pair.value.isEmpty else { return }
      let order = selectionOrder ?? nextSelectionOrder()
      state.withLock {
        if $0.loading { $0.pending.append((pair, order)) }
        $0.record(pair, order: order)
      }
      guard let dataURL else { return }
      ioQueue.async { [self] in
        let snapshot = state.withLockRead { current -> Snapshot? in
          guard current.writable else { return nil }
          return Snapshot(version: 1, groups: Array(current.groups.values))
        }
        guard let snapshot else { return }
        do {
          try FileManager.default.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
          let data = try JSONEncoder().encode(snapshot)
          try data.write(to: dataURL, options: .atomic)
        } catch {
          NSLog("vChewing candidate ranking: data could not be saved; original file retained.")
        }
      }
    }

    public func count(for pair: Homa.CandidatePair) -> UInt64 {
      state.withLockRead { $0.groups[pair.keyArray]?.counts[pair.value] ?? 0 }
    }

    public func latestValue(for keyArray: [String]) -> String? {
      state.withLockRead { $0.groups[keyArray]?.latest }
    }

    /// 只在完全相同 keyArray 的原有槽位間交換；沒有歷史的群組完全不動。
    public func ranked(
      _ candidates: [Homa.CandidatePair],
      includingSingleCharacters: Bool = true
    ) -> [Homa.CandidatePair] {
      let groups = state.withLockRead { $0.groups }
      guard !groups.isEmpty else { return candidates }
      var result = candidates
      let slots = Dictionary(grouping: candidates.indices, by: { candidates[$0].keyArray })
      for (keyArray, indices) in slots {
        guard includingSingleCharacters || keyArray.count > 1, let group = groups[keyArray] else { continue }
        let sorted = indices.stableSort { left, right in
          let lhs = candidates[left].value
          let rhs = candidates[right].value
          if (lhs == group.latest) != (rhs == group.latest) { return lhs == group.latest }
          return (group.counts[lhs] ?? 0) > (group.counts[rhs] ?? 0)
        }
        for (slot, source) in zip(indices, sorted) { result[slot] = candidates[source] }
      }
      return result
    }

    /// 終止應用或離線驗證時等待已排入的 I/O；按鍵與候選查詢不得呼叫。
    public func flushPendingWrites() { ioQueue.sync {} }

    #if compiler(>=6.2)
      nonisolated private struct Group: Codable, Sendable {
        var keyArray: [String]
        var latest: String
        var counts: [String: UInt64]
      }

      nonisolated private struct Snapshot: Codable, Sendable {
        let version: Int
        let groups: [Group]
      }
    #else
      private struct Group: Codable, Sendable {
        var keyArray: [String]
        var latest: String
        var counts: [String: UInt64]
      }

      private struct Snapshot: Codable, Sendable {
        let version: Int
        let groups: [Group]
      }
    #endif

    private struct State {
      var groups: [[String]: Group] = [:]
      var latestOrders: [[String]: UInt64] = [:]
      var selectionOrder: UInt64 = 0
      var pending: [(Homa.CandidatePair, UInt64)] = []
      var loading = false
      var writable = true

      nonisolated mutating func record(_ pair: Homa.CandidatePair, order: UInt64) {
        var group = groups[pair.keyArray] ?? Group(keyArray: pair.keyArray, latest: pair.value, counts: [:])
        let oldCount = group.counts[pair.value] ?? 0
        group.counts[pair.value] = oldCount == UInt64.max ? oldCount : oldCount + 1
        if order >= (latestOrders[pair.keyArray] ?? 0) {
          group.latest = pair.value
          latestOrders[pair.keyArray] = order
        }
        groups[pair.keyArray] = group
      }
    }

    private let dataURL: URL?
    private let state = NSMutex(State())
    private let ioQueue = DispatchQueue(label: "org.vChewing.candidateRankingIO")
  }
}
