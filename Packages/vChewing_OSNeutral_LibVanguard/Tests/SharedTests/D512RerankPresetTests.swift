// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Shared
import Testing

@Suite("A28-P1 D512 parameter presets")
struct D512RerankPresetTests {
  @Test func presetsRoundTripForBothModes() throws {
    for (suggest, margins) in [(true, [3.0, 2.0, 1.0]), (false, [1.0, 0.5, 0.2])] {
      for (preset, margin) in zip(
        [D512RerankPreset.conservative, .balanced, .aggressive], margins
      ) {
        let values = try #require(preset.parameters(suggestMode: suggest))
        #expect(values.weight == 0.5)
        #expect(values.margin == margin)
        #expect(values.bonus == 2)
        #expect(D512RerankPreset.matching(
          weight: 0.5, margin: margin, bonus: 2, suggestMode: suggest
        ) == preset)
      }
      #expect(D512RerankPreset.custom.parameters(suggestMode: suggest) == nil)
    }
  }

  @Test func eachParameterCanMakeAPresetCustom() {
    for suggest in [true, false] {
      let margin = suggest ? 2.0 : 0.5
      for (weight, tau, bonus) in [(0.6, margin, 2.0), (0.5, margin + 0.1, 2.0), (0.5, margin, 2.1)] {
        #expect(D512RerankPreset.matching(
          weight: weight, margin: tau, bonus: bonus, suggestMode: suggest
        ) == .custom)
      }
    }
    #expect(D512RerankPreset.matching(weight: .nan, margin: 0.5, bonus: 2, suggestMode: false) == .custom)
    #expect(D512RerankPreset.matching(weight: 0.5, margin: .infinity, bonus: 2, suggestMode: false) == .custom)
  }

  @Test func floatingPointWritebackRetainsPreset() throws {
    let data = try JSONEncoder().encode(0.2)
    let margin = try JSONDecoder().decode(Double.self, from: data)
    #expect(D512RerankPreset.matching(
      weight: 0.5 + 1e-10, margin: margin + 1e-10, bonus: 2 - 1e-10, suggestMode: false
    ) == .aggressive)
  }
}
