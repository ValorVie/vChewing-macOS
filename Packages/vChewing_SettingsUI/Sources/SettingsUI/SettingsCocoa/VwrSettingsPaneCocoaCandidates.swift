// (c) 2022 and onwards The vChewing Project (MulanPSL-2.0 License).
// ====================
// This code is released under the SPDX-License-Identifier: `MulanPSL-2.0`.

import AppKit
#if compiler(>=6.4)
  import LibVanguard
#endif

// MARK: - SettingsPanesCocoa.Candidates

extension SettingsPanesCocoa {
  public final class Candidates: NSViewController {
    // MARK: Public

    override public func loadView() {
      view = body ?? .init()
      (view as? NSStackView)?.alignment = .centerX
      view.makeSimpleConstraint(.width, relation: .equal, value: windowWidth)
    }

    // MARK: Internal

    var windowWidth: CGFloat { SettingsPanesCocoa.windowWidth }
    var contentWidth: CGFloat { SettingsPanesCocoa.contentWidth }
    var innerContentWidth: CGFloat { SettingsPanesCocoa.innerContentWidth }
    var tabContainerWidth: CGFloat { SettingsPanesCocoa.tabContainerWidth }
    var contentHalfWidth: CGFloat { SettingsPanesCocoa.contentHalfWidth }

    var body: NSView? {
      NSStackView.build(.vertical, insets: .new(all: 14)) {
        NSStackView.buildSection(width: contentWidth) {
          UserDef.kUseRearCursorMode.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kCursorPlacementAfterSelectingCandidate.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kUseDynamicCandidateWindowOrigin.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kDodgeInvalidEdgeCandidateCursorPosition.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kCandidateStateJKHLBehavior
            .renderCocoa(
              fixWidth: contentWidth,
              prefUITab: .tabCandidates
            ) { renderable in
              renderable.currentControl?.target = self
              renderable.currentControl?
                .action = #selector(self.performCandidateKeysSanityCheck(_:))
            }
          UserDef.kUseShiftQuestionToCallServiceMenu
            .renderCocoa(
              fixWidth: contentWidth,
              prefUITab: .tabCandidates
            ) { renderable in
              renderable.currentControl?.target = self
              renderable.currentControl?
                .action = #selector(self.performCandidateKeysSanityCheck(_:))
            }
        }?.boxed()
        NSStackView.buildSection(width: contentWidth) {
          UserDef.kCandidateKeys.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          ) { renderable in
            renderable.currentControl?.target = self
            renderable.currentControl?.action = #selector(self.candidateKeysDidSet(_:))
            renderable.currentControl?.alignment = .right
          }
          UserDef.kUseHorizontalCandidateList.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kCandidateListTextSize
            .renderCocoa(
              fixWidth: contentWidth,
              prefUITab: .tabCandidates
            ) { renderable in
              renderable.currentControl?.target = self
              renderable.currentControl?.action = #selector(self.candidateFontSizeDidSet(_:))
            }
          UserDef.kCandidateWindowShowOnlyOneLine.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kEnforceSingleLineCandidateWindowLayout4SCPC.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kEnableCandidateWindowAnimation.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kAlwaysExpandCandidateWindow.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kMinCellWidthForHorizontalMatrix.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kRespectClientAccentColor.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
        }?.boxed()
        NSStackView.buildSection(width: contentWidth) {
          UserDef.kShowCodePointInCandidateUI.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kShowReverseLookupInCandidateUI.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kUsePersonalCandidatePreference.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          ) { renderable in
            renderable.currentControl?.target = self
            renderable.currentControl?.action = #selector(self.personalCandidatePreferenceDidSet(_:))
          }
          #if compiler(>=6.4)
            let d512Reason = D512SentenceRerank.unavailableReason
            UserDef.kUseD512SentenceRerank.renderCocoa(
              fixWidth: contentWidth, prefUITab: .tabCandidates
            ) { renderable in
              renderable.currentControl?.isEnabled = d512Reason == nil
              renderable.currentControl?.target = self
              renderable.currentControl?.action = #selector(self.personalCandidatePreferenceDidSet(_:))
            }
            UserDef.kD512RerankMode.renderCocoa(
              fixWidth: contentWidth, prefUITab: .tabCandidates
            ) { renderable in
              self.configureD512ModeControl(renderable.currentControl)
            }
            UserDef.kD512SuggestionAcceptKey.renderCocoa(
              fixWidth: contentWidth, prefUITab: .tabCandidates
            ) { renderable in
              self.configureD512AcceptKeyControl(renderable.currentControl)
            }
            makeD512ParameterView()
            if let reason = d512Reason {
              NSTextField(wrappingLabelWithString: reason)
            }
            UserDef.kLogD512Calibration.renderCocoa(
              fixWidth: contentWidth, prefUITab: .tabCandidates
            ) { renderable in
              renderable.currentControl?.target = self
              renderable.currentControl?.action = #selector(self.personalCandidatePreferenceDidSet(_:))
            }
          #endif
          UserDef.kUseFixedCandidateOrderOnSelection.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kConsolidateContextOnCandidateSelection.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
          UserDef.kCandidateNarrationToggleType.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
        }?.boxed()
        NSStackView.buildSection(width: contentWidth) {
          UserDef.kPopupCompositionBufferTextSize.renderCocoa(
            fixWidth: contentWidth,
            prefUITab: .tabCandidates
          )
        }?.boxed()
        NSStackView.buildSection(width: contentWidth) {
          NSStackView.build(.horizontal) {
            "i18n:Menu.WhereIsIMKCandidateWindow".makeNSLabel(fixWidth: contentWidth)
            NSView()
            NSButton(
              verbatim: "...",
              target: self,
              action: #selector(whereIsIMKCandidatesWindow(_:))
            )
          }
        }?.boxed()
        NSView().makeSimpleConstraint(.height, relation: .equal, value: NSFont.systemFontSize)
      }
    }

    @IBAction
    func whereIsIMKCandidatesWindow(_: Any) {
      let window = CtlSettingsCocoa.shared?.window
      let title = "i18n:Menu.EndOfIMKCandidateWindow".i18n
      let explanation = "i18n:InfoMessage.EndOfIMKCandidatesExplanation".i18n
      window.callAlert(title: title, text: explanation)
    }

    @IBAction
    func personalCandidatePreferenceDidSet(_: NSControl) {
      SettingsUIHost.shared.syncLMPrefs()
    }

    func configureD512ModeControl(
      _ control: NSControl?, defaults: NSUserDefaultsController = .shared
    ) {
      control?.bind(
        .enabled, to: defaults,
        withKeyPath: "values.\(UserDef.kUseD512SentenceRerank.rawValue)"
      )
      control?.target = self
      control?.action = #selector(personalCandidatePreferenceDidSet(_:))
    }

    #if compiler(>=6.4)
      func configureD512ParameterControls(
        preset: NSPopUpButton, margin: NSTextField, weight: NSTextField, bonus: NSTextField,
        defaults: NSUserDefaultsController = .shared
      ) {
        d512ParameterControls = D512ParameterControls(
          preset: preset, fields: [margin, weight, bonus], defaults: defaults
        )
      }

      private var d512ParameterControls: D512ParameterControls?

      private func makeD512ParameterView() -> NSView? {
        let preset = NSPopUpButton()
        let margin = NSTextField(), weight = NSTextField(), bonus = NSTextField()
        configureD512ParameterControls(preset: preset, margin: margin, weight: weight, bonus: bonus)
        return NSStackView.build(.vertical) {
          NSStackView.build(.horizontal) {
            "i18n:D512.Preset.title".makeNSLabel()
            NSView()
            preset
          }
          for (key, field) in zip(["margin", "weight", "bonus"], [margin, weight, bonus]) {
            NSStackView.build(.horizontal) {
              "i18n:D512.Parameter.\(key)".makeNSLabel()
              NSView()
              field.makeSimpleConstraint(.width, relation: .equal, value: 100)
            }
          }
          NSTextField(wrappingLabelWithString: "i18n:D512.Preset.description".i18n)
        }
      }

      func configureD512AcceptKeyControl(
        _ control: NSControl?, defaults: NSUserDefaultsController = .shared
      ) {
        configureD512ModeControl(control, defaults: defaults)
        control?.bind(
          NSBindingName("enabled2"), to: defaults,
          withKeyPath: "values.\(UserDef.kD512RerankMode.rawValue)",
          options: [.valueTransformer: D512SuggestModeTransformer()]
        )
      }

      nonisolated private final class D512SuggestModeTransformer: ValueTransformer {
        override class func transformedValueClass() -> AnyClass { NSNumber.self }
        override func transformedValue(_ value: Any?) -> Any? { (value as? NSNumber)?.intValue == 1 }
      }
    #endif

    @IBAction
    func performCandidateKeysSanityCheck(_: NSControl) {
      // 利用該變數的 didSet 屬性自糾。
      PrefMgr.shared.candidateKeys = PrefMgr.shared.candidateKeys
    }

    @IBAction
    func candidateKeysDidSet(_ sender: NSComboBox) {
      let keys = sender.stringValue.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).lowercased().deduplicated
      // Start Error Handling.
      guard let errorResult = PrefMgr.shared.validate(candidateKeys: keys) else {
        PrefMgr.shared.candidateKeys = keys
        return
      }
      let alert = NSAlert(error: "i18n:ErrorMessage.InvalidSelectionKeys".i18n)
      alert.informativeText = errorResult
      IMEApp.buzz()
      if let window = CtlSettingsCocoa.shared?.window {
        alert.beginSheetModal(for: window) { _ in
          sender.stringValue = CandidateKey.defaultKeys
        }
      } else {
        switch alert.runModal() {
        default: sender.stringValue = CandidateKey.defaultKeys
        }
      }
    }

    @IBAction
    func candidateFontSizeDidSet(_: NSControl) {
      print("Candidate Font Size Changed to \(PrefMgr.shared.candidateListTextSize)")
      guard !(12 ... 196).contains(PrefMgr.shared.candidateListTextSize) else { return }
      PrefMgr.shared.candidateListTextSize = max(12, min(PrefMgr.shared.candidateListTextSize, 196))
    }
  }
}

// `#Preview` 是 SwiftUI 的巨集，展開需要 6.2 以上的巨集外掛（`@available` 擋不住展開）；
// 5.10 側編不到它，故整段圈進 compiler condition。
#if compiler(>=6.2)
  @available(macOS 14.0, *)
  #Preview(traits: .fixedLayout(width: 600, height: 768)) {
    SettingsPanesCocoa.Candidates()
  }
#endif

#if compiler(>=6.4)
  /// NSUserDefaultsController 的 KVO 讓模式切換與外部偏好更新同步反映於同一組欄位。
  @MainActor
  private final class D512ParameterControls: NSObject {
    init(preset: NSPopUpButton, fields: [NSTextField], defaults: NSUserDefaultsController) {
      self.preset = preset
      self.fields = fields
      self.defaults = defaults
      super.init()
      preset.addItems(withTitles: D512RerankPreset.allCases.map {
        "i18n:D512.Preset.option.\($0.rawValue)".i18n
      })
      preset.target = self
      preset.action = #selector(presetDidSet(_:))
      preset.setAccessibilityLabel("i18n:D512.Preset.title".i18n)
      for (field, name) in zip(fields, ["margin", "weight", "bonus"]) {
        field.setAccessibilityLabel("i18n:D512.Parameter.\(name)".i18n)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximum = 10
        // 17 significant digits round-trip a Double; the fractional limit also covers subnormal values.
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 17
        formatter.maximumFractionDigits = 340
        field.formatter = formatter
        field.alignment = .right
        field.cell?.sendsActionOnEndEditing = true
        field.target = self
        field.action = #selector(parameterDidSet(_:))
      }
      for control in ([preset] as [NSControl]) + fields {
        control.bind(.enabled, to: defaults, withKeyPath: "values.\(UserDef.kUseD512SentenceRerank.rawValue)")
      }
      for key in observedKeys {
        defaults.addObserver(self, forKeyPath: "values.\(key)", options: .new, context: nil)
      }
      refresh()
    }

    isolated deinit {
      for key in observedKeys { defaults.removeObserver(self, forKeyPath: "values.\(key)") }
    }

    private let preset: NSPopUpButton
    private let fields: [NSTextField]
    private let defaults: NSUserDefaultsController
    private let automatic: [UserDef] = [.kD512RerankMargin, .kD512RerankWeight, .kD512RerankPersonalBonus]
    private let suggest: [UserDef] = [.kD512SuggestRerankMargin, .kD512SuggestRerankWeight, .kD512SuggestRerankPersonalBonus]

    private var observedKeys: [String] { [UserDef.kD512RerankMode.rawValue] + (automatic + suggest).map(\.rawValue) }
    private var suggestMode: Bool { (defaults.value(forKeyPath: "values.\(UserDef.kD512RerankMode.rawValue)") as? NSNumber)?.intValue == 1 }
    private var keys: [UserDef] { suggestMode ? suggest : automatic }

    private func refresh() {
      let values = keys.map { key in
        (defaults.value(forKeyPath: "values.\(key.rawValue)") as? NSNumber)?.doubleValue ?? key.doubleDefaultValue
      }
      for (field, value) in zip(fields, values) { field.doubleValue = value }
      preset.selectItem(at: D512RerankPreset.matching(
        weight: values[1], margin: values[0], bonus: values[2], suggestMode: suggestMode
      ).rawValue)
    }

    nonisolated override func observeValue(
      forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
      context: UnsafeMutableRawPointer?
    ) {
      // 這個 controller 與所有 AppKit 控制項都在 main actor 使用。
      MainActor.assumeIsolated { refresh() }
    }

    @objc private func presetDidSet(_: NSPopUpButton) {
      guard preset.isEnabled,
            let selection = D512RerankPreset(rawValue: preset.indexOfSelectedItem),
            let values = selection.parameters(suggestMode: suggestMode) else {
        refresh()
        return
      }
      let activeKeys = keys
      for (key, value) in zip(activeKeys, [values.margin, values.weight, values.bonus]) {
        defaults.setValue(value, forKeyPath: "values.\(key.rawValue)")
      }
      SettingsUIHost.shared.syncLMPrefs()
    }

    @objc private func parameterDidSet(_ sender: NSTextField) {
      guard sender.isEnabled, let index = fields.firstIndex(of: sender),
            let number = sender.objectValue as? NSNumber,
            number.doubleValue.isFinite, (0 ... 10).contains(number.doubleValue) else {
        refresh()
        return
      }
      defaults.setValue(number, forKeyPath: "values.\(keys[index].rawValue)")
      SettingsUIHost.shared.syncLMPrefs()
    }
  }
#endif
