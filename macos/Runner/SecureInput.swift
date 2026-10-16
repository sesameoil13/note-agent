import Cocoa
import FlutterMacOS

/// AppKit owns secure keyboard editing and password accessibility. Never use a
/// normal NSTextField plus a manually masked accessibility value for secrets.
final class SecureInputFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    SecureInputField(
      channel: FlutterMethodChannel(
        name: "dev.noteagent/secure-input/\(viewId)", binaryMessenger: messenger
      ),
      configuration: args as? [String: Any] ?? [:]
    )
  }
}

private final class SecureInputField: NSSecureTextField, NSTextFieldDelegate {
  private let channel: FlutterMethodChannel

  init(channel: FlutterMethodChannel, configuration: [String: Any]) {
    self.channel = channel
    super.init(frame: .zero)
    delegate = self
    isBordered = false
    drawsBackground = false
    focusRingType = .none
    font = .systemFont(ofSize: 16)
    textColor = NSColor(calibratedRed: 0.929, green: 0.906, blue: 0.859, alpha: 1)
    appearance = NSAppearance(named: .darkAqua)
    (cell as? NSSecureTextFieldCell)?.echosBullets = true
    apply(configuration)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "update":
        self.apply(call.arguments as? [String: Any] ?? [:])
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  required init?(coder: NSCoder) { return nil }

  private func apply(_ configuration: [String: Any]) {
    if let label = configuration["label"] as? String {
      setAccessibilityLabel(label)
    }
    if let enabled = configuration["enabled"] as? Bool {
      if !enabled, currentEditor() != nil { window?.makeFirstResponder(nil) }
      isEnabled = enabled
    }
    if let text = configuration["text"] as? String, text != stringValue {
      stringValue = text
      // Keep the secure field editor in sync when the App clears a saved Key.
      currentEditor()?.string = text
    }
  }

  func controlTextDidChange(_ notification: Notification) {
    channel.invokeMethod("changed", arguments: stringValue)
  }

  func controlTextDidBeginEditing(_ notification: Notification) {
    channel.invokeMethod("focused", arguments: true)
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    channel.invokeMethod("focused", arguments: false)
  }

  deinit {
    channel.setMethodCallHandler(nil)
    stringValue = ""
  }
}
