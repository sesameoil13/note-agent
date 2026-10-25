import Cocoa
import FlutterMacOS
import Security

// Uses the real platform channel codec/handler; only the OS Keychain and the
// binary transport normally supplied by the engine are substituted. No OS item
// or GUI is opened by this executable.
final class ProbeMessenger: NSObject, FlutterBinaryMessenger {
  var incoming: FlutterBinaryMessageHandler?
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply: FlutterBinaryReply?) {}
  func setMessageHandlerOnChannel(_ channel: String,
      binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    precondition(channel == "dev.noteagent/credentials")
    incoming = handler
    return 1
  }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
  func call(_ method: String, _ arguments: [String: String], reply: @escaping (Any?) -> Void) {
    let codec = FlutterStandardMethodCodec.sharedInstance()
    incoming!(codec.encode(FlutterMethodCall(methodName: method, arguments: arguments))) { data in
      reply(data.map { codec.decodeEnvelope($0) } ?? nil)
    }
  }
}

@main struct CredentialChannelProbe {
  static func main() {
    let messenger = ProbeMessenger()
    let releaseRead = DispatchSemaphore(value: 0)
    let readEntered = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var stored: Data? = Data("fixture-before".utf8)
    var active = 0, maxActive = 0
    var calls: [String] = []
    var responses: [String] = []
    var failures: [String] = []
    let heartbeat = DispatchSemaphore(value: 0)
    var heartbeatWhileBlocked = false
    func expect(_ condition: Bool, _ message: String) {
      if !condition { lock.lock(); failures.append(message); lock.unlock() }
    }
    func enter(_ operation: String) {
      lock.lock(); active += 1; maxActive = max(active, maxActive); calls.append(operation); lock.unlock()
    }
    func leave() { lock.lock(); active -= 1; lock.unlock() }
    let fakeOS = CredentialKeychain(
      read: { query in
        enter("read"); defer { leave() }
        expect(query[kSecAttrService as String] as? String == "dev.noteagent.connection", "service retained")
        expect(query[kSecAttrAccount as String] as? String == "fixture", "slot retained")
        readEntered.signal()
        releaseRead.wait()
        return (errSecSuccess, stored as CFTypeRef?)
      },
      update: { _, values in
        enter("write"); defer { leave() }
        expect(values[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, "device-only accessibility retained")
        stored = values[kSecValueData as String] as? Data
        return errSecSuccess
      },
      add: { _ in fatalError("existing fixture should update") },
      delete: { _ in enter("delete"); defer { leave() }; stored = nil; return errSecSuccess }
    )
    let adapter = SecureCredentials(messenger: messenger, keychain: fakeOS)
    func response(_ name: String, value: Any?) {
      expect(Thread.isMainThread, "\(name) callback must use main thread")
      responses.append(name)
      if name == "read" { expect(value as? String == "fixture-before", "read returns stored value before queued write") }
      else { expect(value == nil, "\(name) succeeds") }
    }
    // A release from another thread prevents the deliberately broken synchronous
    // adapter from hanging this executable. This is a test deadline, not a
    // production Keychain timeout or cancellation policy.
    DispatchQueue.global().async {
      _ = readEntered.wait(timeout: .now() + 1)
      let responsive = heartbeat.wait(timeout: .now() + 0.5) == .success
      lock.lock(); heartbeatWhileBlocked = responsive; lock.unlock()
      releaseRead.signal()
    }
    DispatchQueue.main.async { heartbeat.signal() }
    messenger.call("read", ["slot": "fixture"]) { response("read", value: $0) }
    messenger.call("write", ["slot": "fixture", "value": "fixture-after"]) { response("write", value: $0) }
    messenger.call("delete", ["slot": "fixture"]) { response("delete", value: $0) }
    let deadline = Date().addingTimeInterval(2)
    while responses.count < 3, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    lock.lock(); let responsive = heartbeatWhileBlocked; lock.unlock()
    expect(responsive, "main heartbeat stalled behind blocked Keychain read")
    expect(responses == ["read", "write", "delete"], "each request completes exactly once in submission order")
    lock.lock(); let observedCalls = calls, observedMax = maxActive; lock.unlock()
    expect(observedCalls == ["read", "write", "delete"] && observedMax == 1, "Keychain work is serialized")
    expect(stored == nil, "queued deletion follows write")
    // Keep the adapter/channel alive until all encoded replies are observed.
    withExtendedLifetime(adapter) {}
    // Errors and bounded argument rejection must also reply once on main;
    // rejected requests must never reach the OS (especially a late write).
    var osCalls = 0
    let unavailable = CredentialKeychain(
      read: { _ in osCalls += 1; return (errSecInteractionNotAllowed, nil) },
      update: { _, _ in osCalls += 1; return errSecInteractionNotAllowed },
      add: { _ in osCalls += 1; return errSecInteractionNotAllowed },
      delete: { _ in osCalls += 1; return errSecInteractionNotAllowed }
    )
    let errorAdapter = SecureCredentials(messenger: messenger, keychain: unavailable)
    var errorReplies = 0
    for method in ["read", "write", "delete"] {
      messenger.call(method, ["slot": "fixture", "value": "fixture"]) { value in
        expect(Thread.isMainThread, "failure callback must use main thread")
        expect((value as? FlutterError)?.code == "secure_store", "OS refusal remains a secure-store error")
        errorReplies += 1
      }
    }
    messenger.call("write", ["slot": "fixture", "value": String(repeating: "x", count: 16385)]) { value in
      expect((value as? FlutterError)?.code == "secure_store", "oversized write rejected")
      errorReplies += 1
    }
    messenger.call("delete", ["slot": "bad/slot"]) { value in
      expect((value as? FlutterError)?.code == "secure_store", "invalid slot rejected")
      errorReplies += 1
    }
    let errorDeadline = Date().addingTimeInterval(2)
    while errorReplies < 5, Date() < errorDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    // Allow queued replies to drain so duplicate callbacks are observable.
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    expect(errorReplies == 5 && osCalls == 3, "each error replies once; invalid requests never reach OS")
    withExtendedLifetime(errorAdapter) {}
    lock.lock(); let resultFailures = failures; lock.unlock()
    if !resultFailures.isEmpty {
      resultFailures.forEach { print("FAIL: \($0)") }; exit(1)
    }
    print("PASS: blocked Keychain read leaves main responsive; read/write/delete serialize and reply once on main")
  }
}
