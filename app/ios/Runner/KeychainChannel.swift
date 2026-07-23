import Flutter
import UIKit
import Security

/// The shared Keychain Access Group both Runner and the NSE hold in their
/// entitlements. Keep in lockstep with NotificationService.entitlements and the
/// SecItem query in NotificationService.swift.
///
/// $(AppIdentifierPrefix) only expands inside entitlements/Info.plist files —
/// in Swift source it would compile as a literal string and match no entitled
/// group (errSecMissingEntitlement). Resolve it at runtime from the
/// AppIdentifierPrefix key in Info.plist instead, which Xcode does substitute.
var kSharedKeychainGroup: String {
  let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
  return "\(prefix)ai.radhaai.antgrid.push"
}
let kKeychainService = "ai.radhaai.antgrid.push"

/// Bridges the shared-keychain store to Dart. The APNs token used to be served
/// alongside this; `push` provides it now.
final class KeychainChannel: NSObject {
  func register(with registrar: FlutterPluginRegistrar) {
    let keychain = FlutterMethodChannel(name: "ai.radhaai.antgrid/keychain", binaryMessenger: registrar.messenger())
    keychain.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "write":
        SharedKeychainStore.write(key: args?["key"] as? String ?? "", value: args?["value"] as? String ?? "")
        result(nil)
      case "read":
        result(SharedKeychainStore.read(key: args?["key"] as? String ?? ""))
      case "delete":
        SharedKeychainStore.delete(key: args?["key"] as? String ?? "")
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// Explicit SecItem access to the shared group — deliberately NOT
/// flutter_secure_storage, so the NSE reads the exact same attributes.
enum SharedKeychainStore {
  private static func baseQuery(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: kKeychainService,
      kSecAttrAccount as String: key,
      kSecAttrAccessGroup as String: kSharedKeychainGroup,
    ]
  }
  static func write(key: String, value: String) {
    let data = Data(value.utf8)
    var q = baseQuery(key)
    SecItemDelete(q as CFDictionary)
    q[kSecValueData as String] = data
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(q as CFDictionary, nil)
  }
  static func read(key: String) -> String? {
    var q = baseQuery(key)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
          let d = out as? Data else { return nil }
    return String(data: d, encoding: .utf8)
  }
  static func delete(key: String) { SecItemDelete(baseQuery(key) as CFDictionary) }
}
