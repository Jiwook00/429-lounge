import Testing
@testable import LoungeCore

@Suite struct JosaTests {
    @Test func picksByBatchim() {
        #expect(Josa.subject("철수") == "철수가")
        #expect(Josa.subject("도윤") == "도윤이")
        #expect(Josa.topic("민지") == "민지는")
        #expect(Josa.topic("도윤") == "도윤은")
        #expect(Josa.topic("나") == "나는")
    }

    @Test func digitsByReading() {
        #expect(Josa.subject("8") == "8이")
        #expect(Josa.subject("9") == "9가")
        #expect(Josa.subject("10") == "10이")
        #expect(Josa.pick("2", "이었지만", "였지만") == "2였지만")
    }

    @Test func nonHangulCountsAsPlain() {
        #expect(Josa.subject("danny") == "danny가")
        #expect(Josa.topic("") == "는")
    }
}
