#!/bin/bash
# CI: 명령을 최대 3번 해 본다 (빌드 도구가 받아 오는 저장소가 가끔 403 · 시간 초과를 내서 빌드가 통째로 실패하는 것을 줄인다)
# 사용법: bash tool/retry.sh flutter build apk --release ...
for i in 1 2 3; do
  "$@" && exit 0
  echo "::warning::실패 ($i/3): $*"
  [ "$i" -lt 3 ] && sleep $((i * 40))
done
exit 1
