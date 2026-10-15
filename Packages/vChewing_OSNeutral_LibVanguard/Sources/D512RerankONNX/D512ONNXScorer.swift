// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import CD512ONNXRuntime
import CryptoKit
import D512Rerank
import Foundation

// onnxruntime source (checked 2026-10-15): official pod archive `pod-archive-onnxruntime-c-1.30.0.zip`
// from https://download.onnxruntime.ai, SHA-256 e6f1670c14406fd9f082bb400ab197a9b0a9646058ca6366e440642e2b54a2ea,
// declared as a binaryTarget in `Package.swift` (which records why the official SwiftPM package is not used).
// Its static library is built with minos 14.0 (`otool -l`, LC_BUILD_VERSION; the podspec also lists macOS 14),
// so everything here is `@available(macOS 14, *)` even though the package floor is macOS 12: callers on a
// macOS 12/13 deployment target must gate at compile time. Package-level platforms cannot be raised per target.

// MARK: - D512ONNXScorer

/// `D512Scoring` backed by an onnxruntime CPU session over `d512-pf512-20260926/model.onnx`.
@available(macOS 14, *)
public final class D512ONNXScorer: D512Scoring {
  public struct Failure: Error, CustomStringConvertible {
    public let description: String
  }

  /// Pinned model release; `verifyFiles` refuses anything else.
  public static let revision = "d512-pf512-20260926"
  public static let pinnedSHA256 = [
    "model.onnx": "71af1f0e77b2752cc71cbc04bf19c8e8f2e765662246f766e65a2822bab4e66e",
    "vocab.json": "556dffaffbf4c05211a846dcee55ef735cea68c5754f9bffcc6f9588124172b3",
  ]

  public let vocab: D512Vocab

  /// Verifies the pinned hashes (once per process per directory), loads the vocab, then the session.
  public init(modelDirectory: URL, intraOpThreads: Int32 = 2) throws {
    try Self.verifyFiles(modelDirectory)
    self.vocab = try D512Vocab(modelDirectory: modelDirectory)
    guard let api = OrtGetApiBase().pointee.GetApi(UInt32(ORT_API_VERSION)) else {
      throw Failure(description: "onnxruntime API version \(ORT_API_VERSION) unavailable")
    }
    self.api = api.pointee
    try check(self.api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "d512", &env))
    var options: OpaquePointer?
    try check(self.api.CreateSessionOptions(&options))
    defer { self.api.ReleaseSessionOptions(options) }
    try check(self.api.SetIntraOpNumThreads(options, intraOpThreads))
    try check(self.api.SetInterOpNumThreads(options, 1))
    let path = modelDirectory.appendingPathComponent("model.onnx").path
    try check(self.api.CreateSession(env, path, options, &session))
    try check(self.api.GetAllocatorWithDefaultOptions(&allocator)) // process-wide, never released
  }

  deinit {
    api.ReleaseSession(session)
    api.ReleaseEnv(env)
  }

  public func logProb(_ x: D512Input) throws -> Double {
    let L = Int64(x.length), n = Int64(x.targetIds.count)
    var inputs: [OpaquePointer?] = []
    var output: OpaquePointer?
    defer { (inputs + [output]).forEach { api.ReleaseValue($0) } }
    for (data, shape) in [
      (x.ids, [1, L]), (x.bases, [1, L]), (x.tones, [1, L]), (x.types, [1, L]), (x.positions, [1, L]),
    ] {
      inputs.append(try tensor(data, shape, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64))
    }
    inputs.append(try tensor(x.mask, [1, 1, L, L], ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL))
    for (data, shape) in [(x.projPos, [n]), (x.targetNode, [1, n]), (x.targetIds, [1, n])] {
      inputs.append(try tensor(data, shape, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64))
    }
    try Self.inputNames.withCStringArray { inNames in
      try ["scores"].withCStringArray { outNames in
        try check(api.Run(session, nil, inNames, inputs, inputs.count, outNames, 1, &output))
      }
    }
    var raw: UnsafeMutableRawPointer?
    try check(api.GetTensorMutableData(output, &raw))
    guard let raw else { throw Failure(description: "empty scores tensor") }
    return Double(raw.load(as: Float.self)) // NaN/±inf is rejected by `D512Vocab.modelScores`
  }

  private static let inputNames = [
    "ids", "bases", "tones", "types", "positions", "mask", "proj_pos", "target_node", "target_ids",
  ]

  /// ORT-allocated tensor (owns its buffer), filled with a copy of `values`.
  private func tensor<T>(_ values: [T], _ shape: [Int64], _ type: ONNXTensorElementDataType) throws -> OpaquePointer? {
    var value: OpaquePointer?
    try check(api.CreateTensorAsOrtValue(allocator, shape, shape.count, type, &value))
    var raw: UnsafeMutableRawPointer?
    do {
      try check(api.GetTensorMutableData(value, &raw))
    } catch {
      api.ReleaseValue(value)
      throw error
    }
    guard let raw else {
      api.ReleaseValue(value)
      throw Failure(description: "tensor without data")
    }
    values.withUnsafeBytes { raw.copyMemory(from: $0.baseAddress!, byteCount: $0.count) } // inputs are never empty
    return value
  }

  private func check(_ status: OpaquePointer?) throws { try Self.check(api, status) }

  // MARK: - Hash pinning

  nonisolated(unsafe) private static var verified: Set<String> = []
  private static let lock = NSLock()

  /// Checks `model.onnx` / `vocab.json` against the pinned SHA-256; the result is cached per process.
  public static func verifyFiles(_ dir: URL, useCache: Bool = true) throws {
    let key = dir.standardizedFileURL.resolvingSymlinksInPath().path
    lock.lock()
    defer { lock.unlock() }
    if useCache, verified.contains(key) { return }
    verified.remove(key)
    for (name, expected) in pinnedSHA256.sorted(by: { $0.key < $1.key }) {
      let actual = try sha256(dir.appendingPathComponent(name))
      guard actual == expected else {
        throw Failure(description: "\(name): SHA-256 \(actual) != pinned \(expected) (\(revision))")
      }
    }
    verified.insert(key)
  }

  static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func check(_ api: OrtApi, _ status: OpaquePointer?) throws {
    guard let status else { return }
    defer { api.ReleaseStatus(status) }
    throw Failure(description: "onnxruntime: " + (api.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown error"))
  }

  private let api: OrtApi
  private var env: OpaquePointer?
  private var session: OpaquePointer?
  private var allocator: UnsafeMutablePointer<OrtAllocator>?
}

extension [String] {
  fileprivate func withCStringArray<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> R) rethrows -> R {
    let owned = map { strdup($0) }
    defer { owned.forEach { free($0) } }
    return try owned.map { UnsafePointer($0) }.withUnsafeBufferPointer { try body($0.baseAddress!) }
  }
}
