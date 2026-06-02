import Foundation

/// Build-time configuration. Values are injected via Info.plist substitution
/// from xcconfig / Xcode build settings — never entered by the user at runtime.
enum AppConfig {
    /// RunPod serverless endpoint or direct pod URL.
    /// Set STRG_SERVER_URL in your xcconfig or Xcode build settings.
    static let serverURL: URL = {
        let s = Bundle.main.infoDictionary?["STRG_SERVER_URL"] as? String ?? ""
        return URL(string: s.isEmpty ? "http://localhost:8000" : s)!
    }()

    /// Bearer token for RunPod Serverless.
    /// Set STRG_API_KEY in your xcconfig or Xcode build settings.
    static let apiKey: String = {
        Bundle.main.infoDictionary?["STRG_API_KEY"] as? String ?? ""
    }()
}
