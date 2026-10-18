import Cocoa
import FlutterMacOS

/// Standard AppKit sheets keep the secure editor discoverable in native AX,
/// outside this SDK's Flutter-only accessibility child hierarchy.
final class SecureInput: NSObject, NSTextFieldDelegate {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var activeAlert: NSAlert?
  private weak var activeField: NSSecureTextField?

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    self.channel = FlutterMethodChannel(
      name: "dev.noteagent/secure-input", binaryMessenger: messenger
    )
    self.window = window
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      guard call.method == "edit" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.edit(call.arguments, result: result)
    }
  }

  private func edit(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let configuration = arguments as? [String: Any],
          let label = configuration["label"] as? String,
          let draft = configuration["text"] as? String,
          let window = window else {
      result(FlutterError(code: "secure_input_unavailable", message: "安全输入暂时不可用。", details: nil))
      return
    }
    guard activeAlert == nil, window.attachedSheet == nil else {
      result(FlutterError(code: "secure_input_busy", message: "请先关闭当前窗口。", details: nil))
      return
    }
    let alert = NSAlert()
    alert.messageText = label
    alert.informativeText = "输入内容不会显示在连接页面。取消会保留之前的输入。"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "使用此输入")
    alert.addButton(withTitle: "取消")
    alert.buttons[1].keyEquivalent = "\u{1b}"
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 28))
    field.stringValue = draft
    field.font = .systemFont(ofSize: 16)
    field.setAccessibilityLabel(label)
    field.isEditable = true
    field.isSelectable = true
    field.delegate = self
    alert.accessoryView = field
    alert.buttons[0].isEnabled = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    alert.window.initialFirstResponder = field
    activeAlert = alert
    activeField = field
    alert.beginSheetModal(for: window) { [weak self] response in
      let value = field.stringValue
      let accepted = response == .alertFirstButtonReturn &&
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      field.currentEditor()?.string = ""
      field.stringValue = ""
      field.delegate = nil
      self?.activeField = nil
      self?.activeAlert = nil
      result(accepted ? value : nil)
    }
    alert.window.makeFirstResponder(field)
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = activeField else { return }
    activeAlert?.buttons[0].isEnabled =
      !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }
}
