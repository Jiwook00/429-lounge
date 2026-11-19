---
status: accepted
date: 2026-11-19
---

# Xcode 프로젝트 없이 Swift Package로 메뉴바 앱 구성

## 배경과 문제

macOS 메뉴바 앱을 만들어야 한다. 빌드·테스트를 터미널(그리고 Claude Code)에서 바로 돌릴 수 있어야 하고, 로그 파싱 같은 로직은 UI 없이 테스트하고 싶다.

## 고려 요소

- CLI만으로 빌드, 테스트, 실행
- 프로젝트 파일 diff가 사람이 읽을 수 있을 것
- 메뉴바 전용 앱(Dock 아이콘 없음) 지원

## 고려한 선택지

1. Xcode 프로젝트 (`.xcodeproj`)
2. XcodeGen / Tuist로 프로젝트 생성
3. Swift Package + `.app` 번들 스크립트

## 결정

선택: "Swift Package + 번들 스크립트". `Package.swift` 하나로 라이브러리(`LoungeCore`, `LoungeNet`), 앱, CLI, 테스트 타깃을 관리하고, `scripts/build-app.sh`가 실행 파일과 리소스 번들을 `429 Lounge.app`으로 묶는다(`LSUIElement`, ad-hoc 서명).

### 결과

- 좋은 점: `swift build`, `swift test`로 끝. 로직과 UI가 타깃 단위로 분리됨. 개발용 CLI(`lounge-bot`, `lounge-scan`)를 같은 패키지에 둘 수 있음
- 좋은 점: `--snapshot` 모드로 UI를 PNG로 렌더링해 화면 없이 확인 가능
- 나쁜 점: Xcode 프리뷰, 에셋 카탈로그, 자동 서명/공증을 못 씀. 배포할 때 서명과 공증 스크립트가 따로 필요
- 나쁜 점: `Info.plist`를 스크립트에서 직접 관리

## 선택지별 장단점

### Xcode 프로젝트

- 좋음: 프리뷰, 서명, 공증, 에셋 카탈로그
- 나쁨: `.pbxproj` diff를 읽기 어렵고 CLI 작업과 맞지 않음

### XcodeGen / Tuist

- 좋음: Xcode 기능을 쓰면서 설정은 텍스트로 관리
- 나쁨: 도구가 하나 더 늘어남. 지금 규모엔 과함. 배포 단계에서 다시 검토할 만함
