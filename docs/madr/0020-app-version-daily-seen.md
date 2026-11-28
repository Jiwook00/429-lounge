---
status: accepted
date: 2026-11-28
---

# 앱 버전과 일별 접속을 `touch_seen`에 얹어 기록한다

## 배경과 문제

릴리스 전후 변화와 리텐션을 데이터로 보고 싶은데, 회원이 어느 버전을 쓰는지와 어느 날 들어왔는지가 남지 않는다. `players.last_seen_at`은 마지막 한 번뿐이라 지난 날짜가 사라진다.

## 결정

- `touch_seen(p_app_version text default null)`로 인자를 더한다. 인자 없는 호출(옛 앱)은 기본값 null로 그대로 동작하고, null이면 저장된 버전을 지우지 않는다
- `players.app_version`: 마지막 접속 버전. 버전이 바뀌면 1분 중복 제한과 무관하게 바로 쓴다
- `player_daily_seen(player_id, day, first_seen_at, last_seen_at, app_version, seen_count)`: 회원 × KST 날짜 1행. `touch_seen`이 upsert한다. RLS만 켜고 정책이 없어 클라이언트는 읽기·쓰기 모두 못 한다 (분석은 `scripts/snapshot.py` 덤프로)
- 새 이벤트 테이블이나 클라이언트 쓰기는 만들지 않는다. 앱 버전은 앱의 `CFBundleShortVersionString`(번들 없으면 `dev`)

### 결과

- 좋은 점: RPC 하나로 끝나고 옛 앱이 깨지지 않는다
- 나쁜 점: 옛 앱(touch_seen 없음)은 일별 기록이 남지 않는다. 앱을 켠 날만 기록되고 `seen_count`는 2분 주기 호출 수라 대략치다
