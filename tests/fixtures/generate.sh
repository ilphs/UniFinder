#!/usr/bin/env bash
# 성능 검증용 대량 파일 fixture 생성 (구현계획서 T8)
#
# 사용법:
#   tests/fixtures/generate.sh [출력디렉토리]
#
# 생성물:
#   <출력디렉토리>/perf-10k   — 10,000 항목 (파일 9,500 + 폴더 500)
#   <출력디렉토리>/perf-100k  — 100,000 항목 (파일 95,000 + 폴더 5,000)
#
# 주의: 파괴적 작업이므로 반드시 임시 디렉토리 하위에서만 실행한다.
set -euo pipefail

OUT_ROOT="${1:-${TMPDIR:-/tmp}/UniFinderFixtures}"

case "$OUT_ROOT" in
  /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) ;;
  *)
    echo "거부: 출력 경로는 임시 디렉토리 하위여야 합니다 (받은 값: $OUT_ROOT)" >&2
    exit 1
    ;;
esac

EXTENSIONS=(txt swift md png jpg pdf json log csv zip)

generate() {
  local dir="$1"
  local total="$2"
  local folders="$3"
  local files=$((total - folders))

  if [ -d "$dir" ]; then
    echo "이미 존재하여 건너뜀: $dir ($(ls -U "$dir" | wc -l | tr -d ' ')개)"
    return
  fi

  echo "생성 중: $dir (파일 ${files}, 폴더 ${folders})"
  mkdir -p "$dir"

  # 폴더
  python3 - "$dir" "$folders" <<'PY'
import os, sys
base, count = sys.argv[1], int(sys.argv[2])
for i in range(count):
    os.makedirs(os.path.join(base, "folder_%06d" % i), exist_ok=True)
PY

  # 파일 (내용 크기를 항목마다 다르게 해 크기 정렬도 의미 있게)
  python3 - "$dir" "$files" "${EXTENSIONS[*]}" <<'PY'
import os, sys
base, count, exts = sys.argv[1], int(sys.argv[2]), sys.argv[3].split()
for i in range(count):
    ext = exts[i % len(exts)]
    path = os.path.join(base, "item_%06d.%s" % (i, ext))
    with open(path, "wb") as f:
        f.write(b"A" * (i % 4096))
PY

  # 한글/이모지/긴 이름 엣지 케이스 (수동 체크리스트 6번용)
  touch "$dir/한글_파일이름.txt"
  touch "$dir/여행📸사진🌊.txt"
  python3 -c "import sys,os; open(os.path.join(sys.argv[1], 'a'*251 + '.txt'), 'w').close()" "$dir"

  echo "완료: $dir — $(ls -U "$dir" | wc -l | tr -d ' ')개"
}

mkdir -p "$OUT_ROOT"
generate "$OUT_ROOT/perf-10k" 10000 500
generate "$OUT_ROOT/perf-100k" 100000 5000

echo
echo "fixture 루트: $OUT_ROOT"
echo "삭제: rm -rf \"$OUT_ROOT\""
