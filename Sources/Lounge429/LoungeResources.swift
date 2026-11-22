import Foundation

enum LoungeResources {
    static let bundle: Bundle = {
        // 배포 앱에는 SwiftPM 리소스 번들이 Contents/Resources 안에 들어간다.
        if let url = Bundle.main.url(forResource: "429Lounge_Lounge429", withExtension: "bundle"),
           let resources = Bundle(url: url) {
            return resources
        }
        return Bundle.module
    }()
}
