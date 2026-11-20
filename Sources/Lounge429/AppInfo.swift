import Foundation

/// 버전, 피드백 링크 등 앱 정보
enum AppInfo {
    /// Info.plist의 버전. `swift run`이나 스냅샷처럼 번들 없이 돌면 "dev"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// 화면 표시용: "v0.2.1", 번들 없으면 "dev"
    static var versionLabel: String { version == "dev" ? "dev" : "v\(version)" }

    /// GitHub 새 이슈 화면. 버전과 macOS만 미리 채운다 (이슈는 공개라 닉네임·계정은 넣지 않는다)
    static var feedbackURL: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let body = """
        **어떤 일이 있었나요?**


        **기대한 것 / 바라는 것**


        ---
        429 Lounge \(version) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        """
        var c = URLComponents(string: "https://github.com/Jiwook00/429-lounge/issues/new")!
        c.queryItems = [
            URLQueryItem(name: "labels", value: "feedback"),
            URLQueryItem(name: "body", value: body),
        ]
        return c.url!
    }
}
