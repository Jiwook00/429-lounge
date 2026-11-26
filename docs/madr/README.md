# Architecture Decision Records

[MADR](https://adr.github.io/madr/) 형식. 새 결정은 `0000-template.md`를 복사해서 다음 번호로.
이미 accepted된 문서는 고치지 않고, 바뀌면 새 ADR을 쓰고 이전 문서의 status를 `superseded by`로 바꾼다.

| #                                                | 결정                                                                            | 상태     |
| ------------------------------------------------ | ------------------------------------------------------------------------------- | -------- |
| [0001](0001-swift-package-menubar-app.md)        | Xcode 프로젝트 없이 Swift Package로 메뉴바 앱 구성                              | accepted |
| [0002](0002-supabase-local-first.md)             | 백엔드는 Supabase, 개발은 로컬 Docker                                           | accepted |
| [0003](0003-server-authoritative-rpc.md)         | 게임 결과·칩은 서버 RPC에서만, 라운드는 지연 정산                               | accepted |
| [0004](0004-chip-economy-raw-tokens.md)          | 칩은 토큰 사용량 그대로 (요금제 보정 없음)                                      | accepted |
| [0005](0005-pixel-sprites-in-code.md)            | 도트 스프라이트는 코드 격자로, 폰트는 Galmuri                                   | accepted |
| [0006](0006-anonymous-auth-file-session.md)      | 익명 로그인 + 파일 세션 저장                                                    | accepted |
| [0007](0007-remote-supabase-zip-distribution.md) | 초대 회원 배포: 서울 Supabase + ad-hoc 서명 zip                                 | accepted |
| [0008](0008-lounge-presence.md)                  | 라운지 접속: "라운지에 있음" + "보는 중" 두 단계, Claude 상태, 서버 기록 전광판 | accepted |
| [0009](0009-codex-support-golden-per-tool.md)    | Codex 로그도 읽고 토큰은 합산, 황금 칩은 도구마다                               | accepted |
| [0010](0010-update-notice-min-version.md)        | 업데이트: 자동 설치 대신 앱 안 안내 + 서버 최소 버전                            | accepted |
| [0011](0011-lounge-roster-offline.md)            | 라운지 명부: 접속 중이 아닌 회원도 "오프라인 · 3시간 전"으로                    | accepted |
| [0014](0014-blackjack-comic-table.md)            | 블랙잭: 만화 5컷 테이블, 좌석별 순차 턴, 빈 자리는 AI, 무한 덱 + 홀 카드 없음   | accepted |
| [0015](0015-mini-roulette-replaces-oddeven.md)   | 미니 룰렛 0~12: 0은 무효 판, 칸을 누르면 바로 걸림, 홀짝은 은퇴                 | accepted |
| [0016](0016-sparkle-updates.md)                  | Sparkle로 앱 안에서 서명된 업데이트 설치                                        | accepted |
| [0017](0017-lounge-wall-free-pixels.md)          | 라운지 벽화: 칩과 무관한 32×32 공용 벽, 칠하기는 토큰 버킷(10개, 30초 충전)     | accepted |
| [0018](0018-429-drop-plinko.md)                  | 429 드롭: 격자 플링코 + 파친코 포켓, 서버가 경로를 정하고 환수율은 DP로         | accepted |
