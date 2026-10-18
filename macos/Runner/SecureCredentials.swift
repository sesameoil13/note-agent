import Cocoa
import FlutterMacOS
import Security

/// Synchronous OS boundary. The adapter owns scheduling, not the Keychain implementation.
struct CredentialKeychain {
  var read: ([String: Any]) -> (OSStatus, CFTypeRef?)
  var update: ([String: Any], [String: Any]) -> OSStatus
  var add: ([String: Any]) -> OSStatus
  var delete: ([String: Any]) -> OSStatus

  static let system = CredentialKeychain(
    read: { query in
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      return (status, item)
    },
    update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
    add: { SecItemAdd($0 as CFDictionary, nil) },
    delete: { SecItemDelete($0 as CFDictionary) }
  )
}

/// Each device identity and its OpenRouter Key live in Keychain, outside the vault.
final class SecureCredentials {
  private let channel: FlutterMethodChannel
  // SecItem calls can wait on securityd/user interaction. Never run them on the
  // Flutter platform thread, or concurrently with another credential operation.
  private static let worker = DispatchQueue(label: "dev.noteagent.credentials")

  init(messenger: FlutterBinaryMessenger, keychain: CredentialKeychain = .system) {
    channel = FlutterMethodChannel(name: "dev.noteagent/credentials", binaryMessenger: messenger)
    let worker = Self.worker
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: String] ?? [:]
      let slot = args["slot"] ?? "default"
      guard slot.utf8.prefix(41).count <= 40,
            slot.range(of: "^[a-zA-Z0-9_-]{1,40}$", options: .regularExpression) != nil else {
        result(FlutterError(code: "secure_store", message: "安全存储标识无效。", details: nil)); return
      }
      let method = call.method
      guard ["read", "write", "delete"].contains(method) else {
        result(FlutterMethodNotImplemented); return
      }
      var writeData: Data?
      if method == "write" {
        guard let value = args["value"], value.utf8.prefix(16385).count <= 16384,
              let data = value.data(using: .utf8) else {
          result(Self.failure()); return
        }
        writeData = data
      }
      let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.noteagent.connection", kSecAttrAccount as String: slot]
      let data = writeData
      worker.async {
        // Completion is enqueued once, after the OS actually returns. There is
        // no synthetic timeout/cancel that could hide a later Keychain write.
        func finish(_ value: Any?) {
          DispatchQueue.main.async { result(value) }
        }
        switch method {
        case "read":
          var search = query
          search[kSecReturnData as String] = true
          search[kSecMatchLimit as String] = kSecMatchLimitOne
          let (status, item) = keychain.read(search)
          if status == errSecItemNotFound { finish(nil) }
          else if status == errSecSuccess, let data = item as? Data,
                  data.count <= 16384, let value = String(data: data, encoding: .utf8) { finish(value) }
          else { finish(Self.failure()) }
        case "write":
          guard let data = data else { finish(Self.failure()); return }
          let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
          var status = keychain.update(query, values)
          if status == errSecItemNotFound {
            status = keychain.add(query.merging(values) { _, new in new })
          }
          finish(status == errSecSuccess ? nil : Self.failure())
        default: // delete; unknown methods were rejected before scheduling.
          let status = keychain.delete(query)
          finish(status == errSecSuccess || status == errSecItemNotFound ? nil : Self.failure())
        }
      }
    }
  }
  private static func failure() -> FlutterError {
    FlutterError(code: "secure_store", message: "系统安全存储暂时不可用，请解锁设备后重试。", details: nil)
  }
}
