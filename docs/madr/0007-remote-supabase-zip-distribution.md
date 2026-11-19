---
status: accepted
date: 2026-11-20
---

# 초대 회원 배포: 서울 Supabase + ad-hoc 서명 zip

## 배경과 문제

로컬 Docker로만 돌던 라운지를 초대한 회원들과 실제로 같이 써 보려면 원격 백엔드와 앱 배포 방법이 필요하다. 아직 공개 여부를 정하기 전이라 비용과 운영 부담은 최소로 하고 싶다. ([ADR-0002](0002-supabase-local-first.md)에서 미뤄 둔 결정)

## 고려 요소

- 회원 대부분이 한국: Realtime 베팅과 슬롯 SPIN 지연
- 비용 0에 가깝게, 서버 프로세스 운영 없음
- 회원은 Claude Code를 쓰는 개발자: 터미널 한 줄 정도는 괜찮음
- 앱이 서버 주소를 환경변수 없이 알아야 함 (Finder로 띄운 앱엔 셸 환경변수가 없다)

## 고려한 선택지

1. 앱 배포: 소스 빌드 / **ad-hoc 서명 zip** / Developer ID 서명 + 공증
2. 서버 주소 주입: 환경변수 / **Info.plist(`LoungeServer`)** / 앱 안 설정 화면

## 결정

선택: "Supabase Free 프로젝트 `429-lounge`(hi@dwook.co 조직, Northeast Asia Seoul) + `scripts/build-app.sh --dist`로 만든 유니버설 zip".

- 원격 주소와 publishable 키는 `LoungeConfig.remote`에 코드로 둔다. 쓰기는 RPC와 RLS로만 열려 있어서 공개돼도 된다
- 어느 서버를 쓸지는 빌드 시 Info.plist `LoungeServer`로 정한다. 환경변수(`LOUNGE_SERVER`, `LOUNGE_SUPABASE_URL/KEY`)가 있으면 그게 우선
- 회원은 zip을 풀고 `xattr -dr com.apple.quarantine`으로 Gatekeeper 격리를 푼다
- 스키마는 `supabase db push`로 반영. 원격 Auth 설정(익명 로그인 켜기)은 대시보드에서. `config push`는 로컬 `config.toml`의 개발용 값까지 덮어써서 쓰지 않는다

### 결과

- 좋은 점: 비용 0, 회원은 zip 하나로 시작. 로컬 개발 흐름은 그대로 (`--remote` 없이 빌드하면 로컬)
- 나쁜 점: Gatekeeper 우회 안내가 필요하고, 자동 업데이트가 없다. 새 버전은 zip을 다시 보낸다
- 나쁜 점: Free 플랜은 7일 동안 요청이 없으면 일시정지된다
- 나쁜 점: 마이그레이션이 바로 운영 DB에 들어간다. `db push --dry-run`으로 먼저 확인
- 나중에: 공개하면 Developer ID 서명 + 공증, Sparkle 같은 업데이트 채널. 그때 새 ADR

## 선택지별 장단점

### 소스 빌드

- 좋음: Gatekeeper 문제가 없음, 회원이 코드를 볼 수 있음
- 나쁨: Xcode(Swift 6)가 필요하고 빌드에 몇 분 걸림

### Developer ID + 공증

- 좋음: 더블클릭으로 끝
- 나쁨: 연 $99, 공증 파이프라인. 초대 단계엔 과함

### 앱 안 서버 설정 화면

- 좋음: 빌드 하나로 로컬/원격 전환
- 나쁨: 회원에겐 필요 없는 UI. 개발자는 환경변수로 충분
