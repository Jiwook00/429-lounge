/// 한국어 조사: 앞 글자에 받침이 있으면 `batchim`, 없으면 `plain` ("철수가" / "도윤이", "민지는" / "도윤은").
/// 숫자는 읽는 소리로 (8이 · 9가). 그 밖(영문 닉네임 등)은 받침 없는 쪽으로 본다
public enum Josa {
    public static func pick(_ word: String, _ batchim: String, _ plain: String) -> String {
        word + (hasBatchim(word) ? batchim : plain)
    }

    static func hasBatchim(_ word: String) -> Bool {
        guard let last = word.unicodeScalars.last else { return false }
        if (0xAC00...0xD7A3).contains(last.value) { return (last.value - 0xAC00) % 28 != 0 }
        // 영 일 이 삼 사 오 육 칠 팔 구
        if let d = Int(String(last)), (0...9).contains(d) { return [0, 1, 3, 6, 7, 8].contains(d) }
        return false
    }

    /// 은/는
    public static func topic(_ word: String) -> String { pick(word, "은", "는") }
    /// 이/가
    public static func subject(_ word: String) -> String { pick(word, "이", "가") }
}
