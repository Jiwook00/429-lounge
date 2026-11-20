import LoungeCore
import Testing

@Suite struct AppVersionTests {
    @Test func parses() {
        #expect(AppVersion("0.3.0")?.description == "0.3.0")
        #expect(AppVersion("v1.2")?.description == "1.2.0")
        #expect(AppVersion("dev") == nil)
        #expect(AppVersion("1.x.0") == nil)
        #expect(AppVersion("1.2.3.4") == nil)
        #expect(AppVersion("") == nil)
    }

    @Test func compares() {
        #expect(AppVersion("0.10.0")! > AppVersion("0.9.9")!)
        #expect(AppVersion("1.0")! == AppVersion("v1.0.0")!)
    }

    @Test func update() {
        let v = { AppVersion($0)! }
        // 최신이면 안내 없음
        #expect(AppUpdate.check(current: v("0.3.0"), latest: v("0.3.0"), minimum: v("0.2.0")) == nil)
        // 새 릴리스
        #expect(AppUpdate.check(current: v("0.3.0"), latest: v("0.4.0"), minimum: nil)
                == AppUpdate(current: v("0.3.0"), target: v("0.4.0"), required: false))
        // 최소 버전 미달: 릴리스 확인이 실패해도 막는다
        #expect(AppUpdate.check(current: v("0.3.0"), latest: nil, minimum: v("0.4.0"))
                == AppUpdate(current: v("0.3.0"), target: v("0.4.0"), required: true))
        #expect(AppUpdate.check(current: v("0.3.0"), latest: v("0.5.0"), minimum: v("0.4.0"))
                == AppUpdate(current: v("0.3.0"), target: v("0.5.0"), required: true))
        // 개발 실행은 안내하지 않는다
        #expect(AppUpdate.check(current: nil, latest: v("9.0.0"), minimum: v("9.0.0")) == nil)
    }
}
