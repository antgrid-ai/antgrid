import XCTest

// PushCrypto.swift is a member of this target as well as the NSE, rather than
// imported: @testable import of an app-extension module does not survive a
// clean build reliably, and the NSE deliberately owns its own copy of the crypto.
//
// The fixture is the same push_vector.json the Dart and Node tests open. It is
// referenced in place from packages/antgrid_relay_client/test/fixtures/, not
// copied, because a copy that drifts would make this test pass while the wire
// format has already diverged — the one failure this test exists to catch.
final class PushCryptoTests: XCTestCase {
  private func loadVector() throws -> [String: String] {
    let url = try XCTUnwrap(
      Bundle(for: type(of: self)).url(forResource: "push_vector", withExtension: "json"),
      "push_vector.json missing from the test bundle"
    )
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
    )
  }

  func testOpensNodeSealedVector() throws {
    let vector = try loadVector()
    let seed = try XCTUnwrap(Data(base64Encoded: vector["recipientPrivSeed"]!))
    let plaintext = PushCrypto.open(epkB64: vector["epk"]!, boxB64: vector["box"]!, seed: seed)
    XCTAssertEqual(plaintext, vector["plaintext"]!)
  }

  func testTamperedBoxReturnsNil() throws {
    let vector = try loadVector()
    let seed = try XCTUnwrap(Data(base64Encoded: vector["recipientPrivSeed"]!))
    var raw = try XCTUnwrap(Data(base64Encoded: vector["box"]!))
    raw[raw.count - 1] ^= 0xff  // flip a tag byte

    let plaintext = PushCrypto.open(
      epkB64: vector["epk"]!, boxB64: raw.base64EncodedString(), seed: seed
    )
    XCTAssertNil(plaintext)
  }
}
