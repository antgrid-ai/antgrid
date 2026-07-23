import UserNotifications
import XCTest

// Exercises the NSE's didReceive end to end: seed the shared keychain, hand it a
// request shaped exactly like the relay's APNs payload, and assert the delivered
// content. PushCryptoTests covers the KDF against the cross-language vector; this
// covers the part that only fails in the extension — keychain lookup, top-level
// epk/box extraction, and the decrypt-or-placeholder branch.
//
// NotificationService.swift is compiled into this target rather than imported,
// for the same reason PushCrypto.swift is: @testable import of an app-extension
// module does not survive a clean build reliably.
final class NotificationServiceTests: XCTestCase {
  // Recomputed rather than shared: NotificationService.swift scopes these
  // privately. Both run in this process against the same Bundle.main, so the
  // group string agrees by construction — which is the point, since a mismatch
  // between writer and reader is exactly the bug this would catch on device.
  private var sharedGroup: String {
    let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
    return "\(prefix)ai.radhaai.antgrid.push"
  }
  private let service = "ai.radhaai.antgrid.push"
  private let account = "push_priv_x25519_v1"

  private func loadVector() throws -> [String: String] {
    let url = try XCTUnwrap(
      Bundle(for: type(of: self)).url(forResource: "push_vector", withExtension: "json"),
      "push_vector.json missing from the test bundle"
    )
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
    )
  }

  /// Mirrors SharedKeychainStore.write: the value is stored as base64 *text*,
  /// which loadSeed() then base64-decodes back to the 32 raw bytes.
  private func seedKeychain(_ seedB64: String) throws {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: sharedGroup,
    ]
    SecItemDelete(q as CFDictionary)
    q[kSecValueData as String] = Data(seedB64.utf8)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(q as CFDictionary, nil)
    try XCTSkipUnless(
      status == errSecSuccess,
      "cannot write the shared keychain group here (OSStatus \(status)); needs the entitled host"
    )
  }

  private func clearKeychain() {
    SecItemDelete([
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: sharedGroup,
    ] as CFDictionary)
  }

  /// Builds the request the relay actually produces: generic placeholder in aps,
  /// epk/box spread at the TOP level of userInfo (see ApnsSender.send).
  private func request(epk: String, box: String) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = "Antgrid"
    content.body = "New activity"
    content.userInfo = ["epk": epk, "box": box]
    return UNNotificationRequest(identifier: "test", content: content, trigger: nil)
  }

  private func deliver(_ req: UNNotificationRequest) throws -> UNNotificationContent {
    let done = expectation(description: "contentHandler")
    var delivered: UNNotificationContent?
    NotificationService().didReceive(req) { content in
      delivered = content
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return try XCTUnwrap(delivered)
  }

  func testDecryptedPayloadReplacesPlaceholder() throws {
    let vector = try loadVector()
    try seedKeychain(vector["recipientPrivSeed"]!)
    defer { clearKeychain() }

    let content = try deliver(request(epk: vector["epk"]!, box: vector["box"]!))

    XCTAssertEqual(content.title, "Task complete")
    XCTAssertEqual(content.body, "done")
  }

  /// The security-critical branch: anything that fails to decrypt must fall back
  /// to the relay's placeholder, never surface ciphertext or an empty alert.
  func testTamperedBoxKeepsPlaceholder() throws {
    let vector = try loadVector()
    try seedKeychain(vector["recipientPrivSeed"]!)
    defer { clearKeychain() }

    var raw = try XCTUnwrap(Data(base64Encoded: vector["box"]!))
    raw[raw.count - 1] ^= 0xff

    let content = try deliver(
      request(epk: vector["epk"]!, box: raw.base64EncodedString())
    )

    XCTAssertEqual(content.title, "Antgrid")
    XCTAssertEqual(content.body, "New activity")
  }

  func testMissingSeedKeepsPlaceholder() throws {
    let vector = try loadVector()
    clearKeychain()

    let content = try deliver(request(epk: vector["epk"]!, box: vector["box"]!))

    XCTAssertEqual(content.title, "Antgrid")
    XCTAssertEqual(content.body, "New activity")
  }
}
