// (c) 2026 and onwards The vChewing Project (MulanPSL-2.0 License).
// ====================
// This code is released under the SPDX-License-Identifier: `MulanPSL-2.0`.

/// 兩種校正模式共用的檔位資料；自訂只反映三值，不另存偏好。
public enum D512RerankPreset: Int, CaseIterable, Sendable {
  case conservative, balanced, aggressive, custom

  public struct Parameters: Sendable, Equatable {
    public let weight: Double
    public let margin: Double
    public let bonus: Double
  }

  public func parameters(suggestMode: Bool) -> Parameters? {
    let margin: Double
    switch self {
    case .conservative: margin = suggestMode ? 3 : 1
    case .balanced: margin = suggestMode ? 2 : 0.5
    case .aggressive: margin = suggestMode ? 1 : 0.2
    case .custom: return nil
    }
    return .init(weight: 0.5, margin: margin, bonus: 2)
  }

  public static func matching(weight: Double, margin: Double, bonus: Double, suggestMode: Bool) -> Self {
    allCases.first { preset in
      guard let values = preset.parameters(suggestMode: suggestMode) else { return false }
      return abs(weight - values.weight) <= 1e-6
        && abs(margin - values.margin) <= 1e-6
        && abs(bonus - values.bonus) <= 1e-6
    } ?? .custom
  }
}
