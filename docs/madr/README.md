# Architecture Decision Records

[MADR](https://adr.github.io/madr/) 형식. 새 결정은 `0000-template.md`를 복사해서 다음 번호로.
이미 accepted된 문서는 고치지 않고, 바뀌면 새 ADR을 쓰고 이전 문서의 status를 `superseded by`로 바꾼다.

| #                                                | 결정                                               | 상태     |
| ------------------------------------------------ | -------------------------------------------------- | -------- |
| [0001](0001-swift-package-menubar-app.md)        | Xcode 프로젝트 없이 Swift Package로 메뉴바 앱 구성 | accepted |
| [0002](0002-supabase-local-first.md)             | 백엔드는 Supabase, 개발은 로컬 Docker              | accepted |
| [0003](0003-server-authoritative-rpc.md)         | 게임 결과·칩은 서버 RPC에서만, 라운드는 지연 정산  | accepted |
| [0004](0004-chip-economy-raw-tokens.md)          | 칩은 토큰 사용량 그대로 (요금제 보정 없음)         | accepted |
| [0005](0005-pixel-sprites-in-code.md)            | 도트 스프라이트는 코드 격자로, 폰트는 Galmuri      | accepted |
| [0006](0006-anonymous-auth-file-session.md)      | 익명 로그인 + 파일 세션 저장                       | accepted |
| [0007](0007-remote-supabase-zip-distribution.md) | 초대 회원 배포: 서울 Supabase + ad-hoc 서명 zip    | accepted |
| [0008](0008-lounge-presence.md) | 라운지 접속: "라운지에 있음" + "보는 중" 두 단계, Claude 상태, 서버 기록 전광판 | accepted |
