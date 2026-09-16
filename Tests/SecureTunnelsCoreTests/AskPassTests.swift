import XCTest
@testable import SecureTunnelsCore

final class AskPassTests: XCTestCase {
  private let payload = AskPassPayload(passphrase: "key-secret", password: "login-secret")

  func testPassphrasePrompt() {
    XCTAssertEqual(AskPassResponder.answer(prompt: "Enter passphrase for key '/Users/me/.ssh/id_ed25519': ", payload: payload), "key-secret")
  }

  func testPasswordPrompt() {
    XCTAssertEqual(AskPassResponder.answer(prompt: "ec2-user@203.0.113.10's password: ", payload: payload), "login-secret")
  }

  func testHostKeyConfirmation() {
    XCTAssertEqual(AskPassResponder.answer(prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ", payload: payload), "yes")
  }

  func testMissingSecretReturnsNil() {
    XCTAssertNil(AskPassResponder.answer(prompt: "Enter passphrase for key: ", payload: AskPassPayload(passphrase: "", password: nil)))
    XCTAssertNil(AskPassResponder.answer(prompt: "Something unexpected", payload: payload))
  }
}
