import AuthenticationServices
import Flutter
import UIKit

/// Runs an OAuth round trip in ASWebAuthenticationSession, the in-app browser
/// Apple provides for sign-in. App Review rejects handing sign-in off to
/// Safari (guideline 4), which is what the other platforms do.
///
/// Resolves `authenticate` to the callback URL the flow ended on, or to nil
/// when the user closed the sheet. The session intercepts the callback scheme
/// itself, so the callback never reaches the app as a deep link as well.
final class WebAuthChannel: NSObject, ASWebAuthenticationPresentationContextProviding {
  private weak var registrar: FlutterPluginRegistrar?
  private var session: ASWebAuthenticationSession?

  func register(with registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    let channel = FlutterMethodChannel(name: "ai.radhaai.antgrid/web_auth", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "authenticate" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any]
      guard let self,
            let url = URL(string: args?["url"] as? String ?? ""),
            let scheme = args?["callbackScheme"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "url and callbackScheme are required", details: nil))
        return
      }
      self.authenticate(url: url, callbackScheme: scheme, result: result)
    }
  }

  private func authenticate(url: URL, callbackScheme: String, result: @escaping FlutterResult) {
    // One sheet at a time. Cancelling answers the earlier caller with nil
    // through its own completion handler.
    session?.cancel()
    var started: ASWebAuthenticationSession?
    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
      DispatchQueue.main.async {
        if let self, self.session === started { self.session = nil }
        if let error {
          if case ASWebAuthenticationSessionError.canceledLogin = error {
            result(nil)
          } else {
            result(FlutterError(code: "FAILED", message: error.localizedDescription, details: nil))
          }
          return
        }
        result(callback?.absoluteString)
      }
    }
    started = session
    session.presentationContextProvider = self
    self.session = session
    if !session.start() {
      self.session = nil
      result(FlutterError(code: "UNAVAILABLE", message: "The sign-in sheet could not be shown", details: nil))
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    if let window = registrar?.viewController?.view.window { return window }
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
  }
}
