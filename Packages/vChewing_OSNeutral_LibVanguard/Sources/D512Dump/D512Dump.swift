// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import TrieKit

@main
enum D512Dump {
  static func main() {
    do {
      try run(arguments: Array(CommandLine.arguments.dropFirst()))
    } catch {
      FileHandle.standardError.write(Data("D512Dump: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func run(arguments: [String]) throws {
    if arguments == ["--help"] {
      print("Usage: D512Dump --factory <factory.txtMap> --input <cases.jsonl> --mode span|nbest [--k 1...8]\nJSONL is written to stdout; errors to stderr. Only factory CHT unigrams are loaded.")
      return
    }
    var options: [String: String] = [:]
    guard arguments.count.isMultiple(of: 2) else { throw DumpError("Options require values; see --help.") }
    for index in stride(from: 0, to: arguments.count, by: 2) {
      let key = arguments[index]
      guard ["--factory", "--input", "--mode", "--k"].contains(key), options[key] == nil else {
        throw DumpError("Unknown or repeated option: \(key)")
      }
      options[key] = arguments[index + 1]
    }
    guard let factoryPath = options["--factory"], let inputPath = options["--input"],
          let modeString = options["--mode"], let mode = DumpMode(rawValue: modeString),
          let k = Int(options["--k"] ?? "8"), (1 ... 8).contains(k) else {
      throw DumpError("Require --factory, --input, --mode span|nbest, and k in 1...8; see --help.")
    }

    // Same loading backend as LXFacade.connectFactoryDictionary, without constructing
    // LXFacade or any of its shared user-data modules. No implicit resource lookup.
    let data = try Data(contentsOf: URL(fileURLWithPath: factoryPath), options: [.mappedIfSafe])
    let trie = try VanguardTrie.TextMapTrie(data: data)
    guard trie.readingSeparator == "-", data.prefix(512).containsTypingHeader else {
      throw DumpError("Expected a TYPING factory TextMap with '-' reading separator.")
    }
    let input = try String(contentsOfFile: inputPath, encoding: .utf8)
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var seenIDs = Set<String>()
    for (lineIndex, line) in input.components(separatedBy: .newlines).enumerated() where !line.isEmpty {
      do {
        let testCase = try decoder.decode(DumpCase.self, from: Data(line.utf8))
        try testCase.validate()
        guard seenIDs.insert(testCase.id).inserted else { throw DumpError("Duplicate case id: \(testCase.id)") }
        let assembler = try makeAssembler(trie: trie, reading: testCase.reading)
        for request in try Dumper.requests(for: testCase, assembler: assembler, mode: mode, k: k) {
          FileHandle.standardOutput.write(try encoder.encode(request))
          FileHandle.standardOutput.write(Data([10]))
        }
      } catch {
        throw DumpError("input line \(lineIndex + 1): \(error)")
      }
    }
    guard !seenIDs.isEmpty else { throw DumpError("Input contains no cases.") }
  }

  // Shared by the CLI and its production-factory-supplier equivalence test.
  static func makeAssembler(trie: VanguardTrie.TextMapTrie, reading: [String]) throws -> Homa.Assembler {
    let assembler = Homa.Assembler(gramQuerier: { keys in
      let readings = keys.compactMap { $0.allValues.first }
      // LX_TrieKitImpl.swift defines .cht as raw type ID 6 in LexiconAssembly.
      let cht = VanguardTrie.Trie.EntryType(rawValue: 6)
      let nodes = trie.getNodes(keyArray: readings, filterType: cht, partiallyMatch: false, longerSegment: false)
      var grams: [Homa.Gram] = []
      for entry in nodes.flatMap(\.entries) {
        guard entry.typeID == cht, entry.value.unicodeScalars.count == readings.count,
              entry.probability.isFinite else { continue }
        // Same sign conversion as LXFacade.makeFactoryUnigrams for exact CHT lookup.
        grams.append(Homa.Gram(keyArray: readings, current: entry.value, probability: -abs(entry.probability)))
      }
      return grams
    })
    try assembler.insertKeys(reading.map { Homa.PossibleKey.singleKey($0) })
    return assembler
  }
}

private extension Data.SubSequence {
  var containsTypingHeader: Bool {
    String(decoding: self, as: UTF8.self).contains("TYPE\tTYPING\n")
  }
}
