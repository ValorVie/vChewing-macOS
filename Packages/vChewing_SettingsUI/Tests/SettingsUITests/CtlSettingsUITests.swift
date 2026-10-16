// (c) 2022 and onwards The vChewing Project (MulanPSL-2.0 License).
// ====================
// This code is released under the SPDX-License-Identifier: `MulanPSL-2.0`.

import AppKit
import Shared
import SwiftExtension
import Testing

@testable import SettingsUI

// MARK: - CtlSettingsUITests

/// SwiftUI 偏好設定視窗的生命週期測試：確認關閉後不留殘存 controller 與 contentView。
///
/// 原位於 MainAssembly4Darwin 的單元測試靶（該處以 `AppDelegate.shared.checkMemoryUsage()`
/// 另作主體 RAM 取樣）；移入本套件後僅保留視窗生命週期斷言——RAM 取樣屬宿主 App 的
/// 記憶體遙測，非本套件可觀測之範圍。
@Suite(.serialized)
final class CtlSettingsUITests {
  // MARK: Lifecycle

  init() {
    UserDefaults.unitTests = .init(suiteName: "org.atelierInmu.vChewing.SettingsUI.UnitTests")
    UserDefaults.pendingUnitTests = true
    UserDef.resetAll()
  }

  // MARK: Internal

  @Test
  func testSettingsWindowDoesNotLeak() throws {
    // `CtlSettingsUI` 僅在 macOS 14 及以上供應；較舊系統沒有這個視窗可測。
    guard #available(macOS 14, *) else { return }
    // 直接在同一執行緒上顯示再關閉，測試框架已在 main thread。
    CtlSettingsUI.show()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    #expect(CtlSettingsUI.shared != nil)

    CtlSettingsUI.shared?.close()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    #expect(CtlSettingsUI.shared == nil)
    // window 的 contentView 也應該已被移除。
    #expect(CtlSettingsUI.shared?.window?.contentView == nil)
  }

  @Test("A28-P4 Cocoa presets, fields and mode changes share only the active parameters")
  func testD512ParameterControls() throws {
    let controller = NSUserDefaultsController(defaults: UserDefaults.current, initialValues: nil)
    let automatic = ["D512RerankMargin", "D512RerankWeight", "D512RerankPersonalBonus"]
    let suggest = ["D512SuggestRerankMargin", "D512SuggestRerankWeight", "D512SuggestRerankPersonalBonus"]
    func set(_ name: String, _ value: Any) { controller.setValue(value, forKeyPath: "values.\(name)") }
    func value(_ name: String) -> Double { (controller.value(forKeyPath: "values.\(name)") as? NSNumber)?.doubleValue ?? -1 }
    set("UseD512SentenceRerank", false)
    set("D512RerankMode", 1)
    for (key, number) in zip(automatic, [0.5, 0.5, 2.0]) { set(key, number) }
    for (key, number) in zip(suggest, [2.0, 0.5, 2.0]) { set(key, number) }
    let pane = SettingsPanesCocoa.Candidates()
    let preset = NSPopUpButton()
    let margin = NSTextField(), weight = NSTextField(), bonus = NSTextField()
    let fields = [margin, weight, bonus]
    let controls: [NSControl] = [preset, margin, weight, bonus]
    pane.configureD512ParameterControls(preset: preset, margin: margin, weight: weight, bonus: bonus, defaults: controller)
    #expect(controls.allSatisfy { !$0.isEnabled })
    set("UseD512SentenceRerank", true)
    #expect(controls.allSatisfy { $0.isEnabled })
    #expect(preset.numberOfItems == 4)
    #expect(preset.indexOfSelectedItem == 1)
    #expect(fields.map(\.doubleValue) == [2, 0.5, 2])
    func act(_ control: NSControl) throws {
      let action = try #require(control.action)
      _ = try #require(control.target)
      control.sendAction(action, to: control.target)
    }
    for (index, tau) in [(0, 3.0), (1, 2.0), (2, 1.0)] {
      preset.selectItem(at: index)
      try act(preset)
      #expect(suggest.map(value) == [tau, 0.5, 2])
      #expect(automatic.map(value) == [0.5, 0.5, 2])
    }
    for (index, number) in [(0, 4.5), (1, 0.7), (2, 3.0)] {
      fields[index].doubleValue = number
      try act(fields[index])
      #expect(value(suggest[index]) == number)
      #expect(preset.indexOfSelectedItem == 3)
      preset.selectItem(at: 1)
      try act(preset)
    }
    preset.selectItem(at: 3)
    try act(preset)
    #expect(suggest.map(value) == [2, 0.5, 2])
    #expect(preset.indexOfSelectedItem == 1)
    set("D512RerankMode", 0)
    #expect(fields.map(\.doubleValue) == [0.5, 0.5, 2])
    for (index, tau) in [(0, 1.0), (1, 0.5), (2, 0.2)] {
      preset.selectItem(at: index)
      try act(preset)
      #expect(automatic.map(value) == [tau, 0.5, 2])
      #expect(suggest.map(value) == [2, 0.5, 2])
    }
    // NumberFormatter handles normal editing; the action also rejects invalid pasted/programmatic values.
    for (index, field) in fields.enumerated() {
      let formatter = try #require(field.formatter as? NumberFormatter)
      #expect(formatter.minimum == 0 && formatter.maximum == 10)
      let previous = value(automatic[index])
      for invalid in [-0.1, 10.1] {
        field.doubleValue = invalid
        try act(field)
        #expect(value(automatic[index]) == previous)
        #expect(field.doubleValue == previous)
      }
      for valid in [0.0, 10.0, 0.25] {
        field.doubleValue = valid
        try act(field)
        #expect(value(automatic[index]) == valid)
        #expect(preset.indexOfSelectedItem == 3)
      }
    }
    set("D512RerankMode", 1)
    #expect(fields.map(\.doubleValue) == [2, 0.5, 2])
    #expect(preset.indexOfSelectedItem == 1)
    set("D512SuggestRerankWeight", 0.9)
    #expect(weight.doubleValue == 0.9)
    #expect(preset.indexOfSelectedItem == 3)
    set("UseD512SentenceRerank", false)
    #expect(controls.allSatisfy { !$0.isEnabled })
  }

  @Test("A28-Fix1 Cocoa field-editor commits and focus changes preserve full precision",
        arguments: [false, true])
  func testD512ParameterEditingPreservesPrecision(_ losesFocus: Bool) throws {
    _ = NSApplication.shared
    let defaults = NSUserDefaultsController(defaults: UserDefaults.current, initialValues: nil)
    defaults.setValue(true, forKeyPath: "values.UseD512SentenceRerank")
    let pane = SettingsPanesCocoa.Candidates()
    let fields = [NSTextField(), NSTextField(), NSTextField()]
    let preset = NSPopUpButton()
    pane.configureD512ParameterControls(
      preset: preset, margin: fields[0], weight: fields[1], bonus: fields[2], defaults: defaults
    )
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let other = NSTextField(frame: NSRect(x: 20, y: 10, width: 180, height: 24))
    window.contentView?.addSubview(other)
    for (index, field) in fields.enumerated() {
      field.frame = NSRect(x: 20, y: 50 + index * 40, width: 180, height: 24)
      window.contentView?.addSubview(field)
    }
    defer { window.endEditing(for: nil); window.close() }
    let inputs: [(String, Double)] = [
      ("0.123456789", 0.123456789), ("0.0000001", 0.0000001),
      ("9.9999999", 9.9999999), ("0.12345678901234567", 0.12345678901234567),
    ]
    for mode in [0, 1] {
      defaults.setValue(mode, forKeyPath: "values.D512RerankMode")
      let keys = mode == 1
        ? ["D512SuggestRerankMargin", "D512SuggestRerankWeight", "D512SuggestRerankPersonalBonus"]
        : ["D512RerankMargin", "D512RerankWeight", "D512RerankPersonalBonus"]
      for locale in ["en_US", "de_DE"] {
        for (field, key) in zip(fields, keys) {
          let formatter = try #require(field.formatter as? NumberFormatter)
          formatter.locale = Locale(identifier: locale)
          for (input, expected) in inputs {
            defaults.setValue(2.0, forKeyPath: "values.\(key)")
            field.selectText(nil)
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.string = input.replacingOccurrences(of: ".", with: formatter.decimalSeparator)
            if losesFocus {
              #expect(window.makeFirstResponder(other))
            } else {
              editor.insertNewline(nil)
            }
            #expect(UserDefaults.current.double(forKey: key) == expected,
                    "\(locale) \(key) input=\(input) blur=\(losesFocus)")
            // A later action without an edit must preserve the original stored number too.
            defaults.setValue(expected, forKeyPath: "values.\(key)")
            let action = try #require(field.action)
            field.sendAction(action, to: field.target)
            #expect(UserDefaults.current.double(forKey: key) == expected)
            window.endEditing(for: field)
          }
        }
      }
    }
  }

  @Test("A28-Fix1 Invalid numeric text never changes a parameter")
  func testD512ParameterInvalidTextIsRejected() throws {
    let defaults = NSUserDefaultsController(defaults: UserDefaults.current, initialValues: nil)
    defaults.setValue(true, forKeyPath: "values.UseD512SentenceRerank")
    defaults.setValue(1, forKeyPath: "values.D512RerankMode")
    let pane = SettingsPanesCocoa.Candidates()
    let fields = [NSTextField(), NSTextField(), NSTextField()]
    pane.configureD512ParameterControls(
      preset: NSPopUpButton(), margin: fields[0], weight: fields[1], bonus: fields[2], defaults: defaults
    )
    for (field, key) in zip(fields, ["D512SuggestRerankMargin", "D512SuggestRerankWeight", "D512SuggestRerankPersonalBonus"]) {
      let formatter = try #require(field.formatter as? NumberFormatter)
      formatter.locale = Locale(identifier: "en_US")
      defaults.setValue(0.25, forKeyPath: "values.\(key)")
      for input in ["-0.1", "10.0000004", "11", "", "NaN", "2abc", "1.2.3"] {
        field.stringValue = input
        let action = try #require(field.action)
        field.sendAction(action, to: field.target)
        #expect(UserDefaults.current.double(forKey: key) == 0.25, "Rejected: \(input)")
      }
    }
  }

  @Test("SS-D512-A25-S6 The mode control follows the master switch")
  func testD512ModeRequiresMasterSwitch() throws {
    _ = try #require(UserDef(rawValue: "D512RerankMode"))
    let controller = NSUserDefaultsController(defaults: UserDefaults.current, initialValues: nil)
    let keyPath = "values.UseD512SentenceRerank"
    controller.setValue(false, forKeyPath: keyPath)
    let pane = SettingsPanesCocoa.Candidates()
    let control = NSPopUpButton()
    pane.configureD512ModeControl(control, defaults: controller)
    #expect(!control.isEnabled)
    controller.setValue(true, forKeyPath: keyPath)
    #expect(control.isEnabled)
  }

  @Test("SS-D512-A26-K5 The acceptance key control requires enabled suggestion mode")
  func testD512AcceptKeyRequiresSuggestMode() throws {
    _ = try #require(UserDef(rawValue: "D512SuggestionAcceptKey"))
    let controller = NSUserDefaultsController(defaults: UserDefaults.current, initialValues: nil)
    let master = "values.UseD512SentenceRerank"
    let mode = "values.D512RerankMode"
    controller.setValue(false, forKeyPath: master)
    controller.setValue(1, forKeyPath: mode)
    let pane = SettingsPanesCocoa.Candidates()
    let control = NSPopUpButton()
    pane.configureD512AcceptKeyControl(control, defaults: controller)
    #expect(!control.isEnabled)
    controller.setValue(true, forKeyPath: master)
    controller.setValue(0, forKeyPath: mode)
    #expect(!control.isEnabled)
    controller.setValue(1, forKeyPath: mode)
    #expect(control.isEnabled)
    controller.setValue(false, forKeyPath: master)
    #expect(!control.isEnabled)
  }
}
