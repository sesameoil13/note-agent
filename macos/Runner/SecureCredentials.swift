import Cocoa
import FlutterMacOS
import Security

/// Each device identity and its OpenRouter Key live in Keychain, outside the vault.
final class SecureCredentials {
  private let channel: FlutterMethodChannel
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.noteagent/credentials", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: String] ?? [:]
      let slot = args["slot"] ?? "default"
      guard slot.range(of: "^[a-zA-Z0-9_-]{1,40}$", options: .regularExpression) != nil else {
        result(FlutterError(code: "secure_store", message: "安全存储标识无效。", details: nil)); return
      }
      let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.noteagent.connection", kSecAttrAccount as String: slot]
      switch call.method {
      case "read":
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { result(nil) }
        else if status == errSecSuccess, let data = item as? Data,
                let value = String(data: data, encoding: .utf8) { result(value) }
        else { result(Self.failure()) }
      case "write":
        guard let value = args["value"], let data = value.data(using: .utf8), data.count <= 16384 else {
          result(Self.failure()); return
        }
        let values: [String: Any] = [kSecValueData as String: data,
          kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
          status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        result(status == errSecSuccess ? nil : Self.failure())
      case "delete":
        let status = SecItemDelete(query as CFDictionary)
        result(status == errSecSuccess || status == errSecItemNotFound ? nil : Self.failure())
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  private static func failure() -> FlutterError {
    FlutterError(code: "secure_store", message: "系统安全存储暂时不可用，请解锁设备后重试。", details: nil)
  }
}
