import UserNotifications
import Security

/// Shared keychain group + attributes — keep in lockstep with KeychainChannel.swift.
///
/// $(AppIdentifierPrefix) only expands inside entitlements/Info.plist files —
/// in Swift source it would compile as a literal string and match no entitled
/// group (errSecMissingEntitlement). Resolve it at runtime from the
/// AppIdentifierPrefix key in Info.plist instead, which Xcode does substitute.
private var kSharedKeychainGroup: String {
  let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
  return "\(prefix)ai.radhaai.antgrid.push"
}
private let kKeychainService = "ai.radhaai.antgrid.push"
private let kSeedAccount = "push_priv_x25519_v1"

final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttempt: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    let best = (request.content.mutableCopy() as! UNMutableNotificationContent)
    self.bestAttempt = best

    let info = request.content.userInfo
    guard let epk = info["epk"] as? String,
          let box = info["box"] as? String,
          let seed = loadSeed(),
          let json = PushCrypto.open(epkB64: epk, boxB64: box, seed: seed),
          let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      // Decrypt failed → show the generic placeholder the relay set (never leaks content).
      contentHandler(best)
      return
    }
    if let title = obj["title"] as? String, !title.isEmpty { best.title = title }
    if let body = obj["body"] as? String { best.body = body }
    contentHandler(best)
  }

  override func serviceExtensionTimeWillExpire() {
    if let h = contentHandler, let b = bestAttempt { h(b) }
  }

  private func loadSeed() -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: kKeychainService,
      kSecAttrAccount as String: kSeedAccount,
      kSecAttrAccessGroup as String: kSharedKeychainGroup,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
          let b64 = out as? Data,
          let seed = Data(base64Encoded: b64) else { return nil }
    return seed  // Task 5 stores base64(seed); decode back to 32 raw bytes.
  }
}
