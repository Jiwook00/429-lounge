---
status: accepted
date: 2026-11-19
---

# 백엔드는 Supabase, 개발은 로컬 Docker

## 배경과 문제

회원들이 같은 테이블에서 실시간으로 베팅하려면 서버가 필요하다. 인증, DB, 실시간 동기화가 필요하고, 1인 개발이라 운영 부담은 최소여야 한다. 프로토타입 단계에서는 원격 호스팅 환경도 아직 정하지 않았다.

## 고려 요소

- 실시간 동기화(베팅, 착석자)와 서버 측 로직
- 서버 프로세스를 직접 운영하지 않을 것
- 개발 단계에서 특정 원격 환경에 묶이지 않을 것

## 고려한 선택지

1. Supabase (원격 프로젝트에서 바로 개발)
2. Supabase (로컬 Docker로 개발, 나중에 원격 배포)
3. 직접 만든 Go WebSocket 서버
4. Firebase

## 결정

선택: "Supabase, 로컬 Docker 개발". `supabase start`로 DB, Auth, REST, Realtime만 띄운다(Studio, Storage, Edge Runtime 등은 Docker 메모리 4GB 제약 때문에 끔). 스키마와 서버 로직은 `supabase/migrations/`에 SQL로 두고, 원격으로 옮길 땐 같은 마이그레이션을 적용하고 `LOUNGE_SUPABASE_URL` / `LOUNGE_SUPABASE_KEY`만 바꾼다.

### 결과

- 좋은 점: Postgres 함수 + RLS + Realtime으로 서버 프로세스 없이 게임 로직 구현. 원격 환경 없이도 개발 진행
- 좋은 점: `supabase db reset`으로 언제든 깨끗한 상태에서 마이그레이션 전체를 검증
- 나쁜 점: 실제 회원들이 쓰려면 원격 프로젝트가 필요. 호스팅 환경은 배포 단계에서 결정
- 나쁜 점: 로컬 스택이 Docker 리소스를 계속 씀 (`supabase stop`)

## 선택지별 장단점

### 원격 Supabase에서 바로 개발

- 좋음: 처음부터 여러 기기에서 함께 테스트 가능
- 나쁨: 리전, 플랜 같은 호스팅 결정을 먼저 해야 하고, 스키마를 바꿀 때마다 원격 DB에 바로 반영됨

### Go WebSocket 서버

- 좋음: 게임 루프를 서버 타이머로 정확하게 제어. 익숙한 스택
- 나쁨: 인증, 영속성, 배포, 모니터링을 전부 직접. 프로토타입엔 과함

### Firebase

- 좋음: 실시간 DB가 성숙함
- 나쁨: 서버 측 정산을 하려면 Cloud Functions 필요. SQL로 규칙을 표현하기 어려움
