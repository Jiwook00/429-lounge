import Foundation
import LoungeCore

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

// MARK: - 업데이트 (ADR-0010)

extension AppInfo {
    static let repo = "https://github.com/Jiwook00/429-lounge"
    /// 설치 스크립트가 업데이트도 한다 (앱을 끄고 덮어쓴 뒤 다시 켠다)
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/Jiwook00/429-lounge/main/scripts/install.sh | bash"

    static func releaseURL(_ version: AppVersion) -> URL {
        URL(string: "\(repo)/releases/tag/v\(version)")!
    }

    /// 최신 릴리스 태그. `/releases/latest`가 302로 `/releases/tag/vX.Y.Z`를 알려준다
    /// (API와 달리 비인증 요청 한도가 없다). 리다이렉트는 따라가지 않고 Location만 본다
    static func latestRelease() async -> AppVersion? {
        var req = URLRequest(url: URL(string: "\(repo)/releases/latest")!)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 15
        guard let (_, res) = try? await URLSession.shared.data(for: req, delegate: NoRedirect()),
              let location = (res as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let tag = location.split(separator: "/").last
        else { return nil }
        return AppVersion(String(tag))
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
