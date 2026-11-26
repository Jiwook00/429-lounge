#!/bin/sh
# 저장소의 git 훅(scripts/git-hooks)을 쓰도록 한 번 설정한다. 클론마다 한 번 실행
set -e
cd "$(git rev-parse --show-toplevel)"
chmod +x scripts/git-hooks/*
git config core.hooksPath scripts/git-hooks
echo "git 훅 설치: $(git config core.hooksPath) (pre-commit: Markdown 표 정렬)"
