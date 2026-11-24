#!/usr/bin/env bash
# mutate.sh -- 변이 하나를 걸고 시험을 돌린 뒤 되돌린다(agent-dispatch 적대적 리뷰, 검수). 던져 둘 사본(temp-tree.sh) 안에서 돌린다.
#
#   mutate.sh --file F --from TEXT --to TEXT [--no-baseline] -- <시험 명령...>
#   mutate.sh --file F --from-file A --to-file B [--no-baseline] -- <시험 명령...>
#
#   F 안에서 TEXT 가 글자 그대로 정확히 한 번 나와야 한다(0번이나 2번 이상이면 exit 2). 여러 줄이면 --from-file/--to-file.
#   먼저 변이 없이 시험을 돌려 초록인지 본다(--no-baseline 이면 건너뛴다). 빨강이면 변이가 아무것도 증명하지 못하므로 exit 2.
#   그다음 변이를 걸어 돌리고, 끝나면(중단돼도) 원래 파일로 되돌린다.
#
# 출력(마지막 줄): "KILLED rc=<시험의 exit>" exit 0 / "SURVIVED" exit 1 / 오류는 stderr 에 내고 exit 2.
# 시험 출력은 stderr 로 흘린다. 변이가 언어 문법을 깨면 시험이 그 때문에 빨개지니, 변이 뒤의 파일이 유효한지는 부르는 쪽이 본다.
# 헤더 규칙: 도움말(-h)은 2행부터 첫 비주석 줄 직전까지 낸다.
# 필요한 것: bash, perl.
set -uo pipefail

die() { echo "mutate: $*" >&2; exit 2; }
usage() { awk 'NR >= 2 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; }

file='' from='' to='' have_from=0 have_to=0 baseline=1
while [ $# -gt 0 ]; do
  case $1 in
    --file) file=${2:-}; shift 2 ;;
    --from) from=${2-}; have_from=1; shift 2 ;;
    --to) to=${2-}; have_to=1; shift 2 ;;
    --from-file) [ -f "${2:-}" ] || die "--from-file 이 없다"; from=$(cat "$2"; printf x); from=${from%x}; have_from=1; shift 2 ;;
    --to-file) [ -f "${2:-}" ] || die "--to-file 이 없다"; to=$(cat "$2"; printf x); to=${to%x}; have_to=1; shift 2 ;;
    --no-baseline) baseline=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) die "모르는 인자: $1" ;;
  esac
done
[ -f "$file" ] || die "--file 이 없다: '$file'"
[ "$have_from" = 1 ] && [ -n "$from" ] || die "--from(또는 --from-file)을 줘라"
[ "$have_to" = 1 ] || die "--to(또는 --to-file)를 줘라"
[ "$from" != "$to" ] || die "--from 과 --to 가 같다"
[ $# -gt 0 ] || die "-- 뒤에 시험 명령을 줘라"

n=$(FROM=$from perl -0777 -ne '$c = () = /\Q$ENV{FROM}\E/g; print $c' "$file") || die "perl 이 실패했다"
[ "$n" = 1 ] || die "$file 에서 --from 이 $n 번 나온다(정확히 한 번이어야 한다)"

if [ "$baseline" = 1 ]; then
  "$@" >&2 || die "변이 전 시험이 이미 빨갛다(exit $?) -- 변이가 아무것도 증명하지 못한다"
fi

backup=$(mktemp)
cp -p "$file" "$backup"
trap 'cp -p "$backup" "$file"; rm -f "$backup"' EXIT INT TERM
FROM=$from TO=$to perl -0777 -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$backup" > "$file" || die "변이를 쓰지 못했다"
cmp -s "$backup" "$file" && die "변이가 파일을 바꾸지 않았다"

"$@" >&2
rc=$?
if [ "$rc" != 0 ]; then echo "KILLED rc=$rc"; exit 0; fi
echo "SURVIVED"; exit 1
