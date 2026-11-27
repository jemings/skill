#!/usr/bin/env bash
# check-scan.sh - 사내 스킬 스캐너(cisco-ai-skill-scanner)를 통째로 돌려 is_safe 로 판정한다.
#
# 사용법: bash scripts/check-scan.sh <경로>...
#   경로마다 `skill-scanner scan-all <경로> --recursive --format json` 을 부른다. 경로는 플러그인
#   디렉터리, plugins/, 스킬 디렉터리 어느 것이든 되고, 그 아래의 SKILL.md 를 스캐너가 찾는다.
#   exit 0  모든 스킬이 is_safe: true (출력 없음. LOW, MEDIUM finding 은 통과다)
#   exit 1  is_safe: false 인 스킬이 있다. 그 스킬의 CRITICAL, HIGH finding 마다 stdout 에 한 줄
#           `<스킬 경로>/<file_path>:<줄>:<rule_id> <severity>` 를 낸다(스킬 경로는 지금 디렉터리 기준
#           상대 경로, 줄이 null 이면 `-`). finding 이 없는데 is_safe 가 false 면 `<스킬 경로>:-:is_safe false`.
#   exit 2  인자 오류: 인자가 없다, 경로가 없다, 경로 아래에 SKILL.md 가 하나도 없다(스캐너를 부르기 전에 본다)
#   exit 3  판정할 수 없다: 스캐너를 찾지 못했다, 실행에 실패했다, 출력이 JSON 이 아니거나 모양이 다르다,
#           출력을 읽는 perl 이 실패했다. exit 1 은 항상 출력이 있다.
#           stderr 에 이유 한 줄과, 스캐너 문제면 설치 방법을, perl 이 실패했으면 perl 과 코어 모듈
#           JSON::PP 가 필요하다는 안내를 낸다. 통과로 넘어가는 SKIP 은 없다.
#
# 스캐너 찾기: 환경 변수 SKILL_SCANNER(실행 파일 경로)가 있으면 그것만 쓰고, 없으면 PATH 의 skill-scanner.
# 스스로 설치하지 않는다(커밋 전 검사가 네트워크와 사내 프록시에 매달리지 않도록).
# 설치(설치에만 네트워크가 필요하고 스캔은 오프라인이다):
#   uv venv <dir> && uv pip install --python <dir>/bin/python cisco-ai-skill-scanner==2.3.2
#   SKILL_SCANNER=<dir>/bin/skill-scanner bash scripts/check-scan.sh plugins
#
# 버전: `--version` 이 `skill-scanner 2.3.2` 가 아니면 stderr 에 경고 한 줄을 내고 판정은 계속한다.
#
# 스캐너의 exit 코드는 판정에 쓰지 않는다. `scan` 은 unsafe 여도 exit 0 이고, 스킬이 없거나 경로가
# 틀려도 exit 1 이라 위반과 오류를 가르지 못한다. 판정은 JSON 의 is_safe 만 본다.
# is_safe 는 스캐너 2.3.2 에서 CRITICAL 또는 HIGH finding 이 없는 것이다.

export LC_ALL=C.UTF-8

EXPECTED_VERSION="skill-scanner 2.3.2"
INSTALL_HINT="설치: uv venv <dir> && uv pip install --python <dir>/bin/python cisco-ai-skill-scanner==2.3.2, 그리고 SKILL_SCANNER=<dir>/bin/skill-scanner"
JUDGE_HINT="판정에는 perl 과 코어 모듈 JSON::PP 가 필요하다(스캐너 설치 문제가 아니다)"

usage_error() { echo "check-scan: $1" >&2; exit 2; }
scanner_unusable() { echo "check-scan: 스캐너를 쓸 수 없다: $1" >&2; echo "check-scan: $INSTALL_HINT" >&2; exit 3; }

# 경계 1: 인자. 이 아래는 존재하고 SKILL.md 를 품은 경로만 본다.
[ "$#" -gt 0 ] || { echo "usage: bash scripts/check-scan.sh <path>..." >&2; exit 2; }
for p in "$@"; do
  [ -e "$p" ] || usage_error "no such path: $p"
  [ -n "$(find "$p" -name SKILL.md -not -path '*/.git/*' -print -quit)" ] || usage_error "no SKILL.md under: $p"
done

# 경계 2: 스캐너. 이 아래는 실행 가능한 스캐너 하나만 안다.
if [ -n "${SKILL_SCANNER:-}" ]; then
  scanner=$SKILL_SCANNER
  [ -x "$scanner" ] && [ -f "$scanner" ] || scanner_unusable "SKILL_SCANNER 가 실행 파일이 아니다: $scanner"
else
  scanner=$(command -v skill-scanner) || scanner_unusable "PATH 에 skill-scanner 가 없다"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

version=$("$scanner" --version 2>"$TMP/err") || scanner_unusable "--version 이 실패했다: $scanner"
[ "$version" = "$EXPECTED_VERSION" ] ||
  echo "check-scan: 경고: 스캐너 버전이 다르다: [$version], 기대 [$EXPECTED_VERSION]" >&2

# 경계 3: 스캐너 출력. JSON 의 모양을 한 번 검사해 판정(0/1)이나 사용 불가(3)로만 바꾼다.
# 판정 쪽은 검사를 마친 구조만 읽는다.
judge() {
  perl -e '
    use strict; use warnings;
    # die 의 exit 코드는 $! 를 따라 1 이 될 수 있다. 판정(0/1)과 사용 불가(3)를 거치지 않은 끝은 모두 4 로 바꾼다.
    our $decided;
    END { $? = 4 unless $decided }
    use Cwd (); use B (); use JSON::PP;
    sub is_json_string { my $f = B::svref_2object(\$_[0])->FLAGS; return ($f & B::SVp_POK) && !($f & (B::SVp_IOK | B::SVp_NOK)) }
    sub is_json_integer { my $f = B::svref_2object(\$_[0])->FLAGS; return ($f & B::SVp_IOK) && !($f & B::SVp_POK) && $_[0] >= 0 }
    binmode(STDOUT, ":utf8");
    sub decide { $decided = 1; exit $_[0] }
    sub bad { print STDERR "check-scan: 스캐너를 쓸 수 없다: $_[0]\n"; decide(3) }
    my $raw = do { local $/; <STDIN> };
    bad("출력이 비어 있다") unless defined $raw && $raw =~ /\S/;
    my $doc = eval { JSON::PP->new->utf8->decode($raw) };
    bad("출력이 JSON 이 아니다") unless defined $doc;
    bad("최상위가 객체가 아니다") unless ref $doc eq "HASH";
    bad("results 가 배열이 아니다") unless ref $doc->{results} eq "ARRAY";
    my $cwd = Cwd::getcwd();
    my $unsafe = 0;
    for my $r (@{ $doc->{results} }) {
      bad("결과가 객체가 아니다") unless ref $r eq "HASH";
      bad("is_safe 가 불리언이 아니다") unless JSON::PP::is_bool($r->{is_safe});
      bad("skill_path 가 문자열이 아니다") unless defined $r->{skill_path} && !ref $r->{skill_path} && is_json_string($r->{skill_path});
      bad("findings 가 배열이 아니다") unless ref $r->{findings} eq "ARRAY";
      for my $f (@{ $r->{findings} }) {
        bad("finding 이 객체가 아니다") unless ref $f eq "HASH";
        for my $k (qw(rule_id severity)) {
          bad("finding.$k 가 문자열이 아니다") unless defined $f->{$k} && !ref $f->{$k} && is_json_string($f->{$k});
        }
        bad("finding.file_path 가 문자열이 아니다") if defined $f->{file_path} && (ref $f->{file_path} || !is_json_string($f->{file_path}));
        bad("finding.line_number 가 정수가 아니다")
          if defined $f->{line_number} && (ref $f->{line_number} || !is_json_integer($f->{line_number}));
      }
      next if $r->{is_safe};
      $unsafe = 1;
      my $skill = $r->{skill_path};
      $skill = "." if $skill eq $cwd;
      $skill =~ s{\A\Q$cwd\E/}{};
      my @blocking = grep { $_->{severity} =~ /\A(?:CRITICAL|HIGH)\z/ } @{ $r->{findings} };
      print "$skill:-:is_safe false\n" unless @blocking;
      for my $f (@blocking) {
        my $where = defined $f->{file_path} ? "$skill/$f->{file_path}" : $skill;
        my $line = defined $f->{line_number} ? $f->{line_number} : "-";
        print "$where:$line:$f->{rule_id} $f->{severity}\n";
      }
    }
    decide($unsafe ? 1 : 0);
  '
}

status=0
for p in "$@"; do
  # 스캐너 exit 코드는 일부러 버린다(머리 주석)
  "$scanner" scan-all "$p" --recursive --format json >"$TMP/out" 2>"$TMP/err" || true
  judge <"$TMP/out"
  rc=$?
  case $rc in
    0) ;;
    1) status=1 ;;
    3) echo "check-scan: $INSTALL_HINT" >&2; exit 3 ;;
    *) echo "check-scan: 스캐너 출력을 판정하지 못했다(JSON 을 읽는 perl 이 exit $rc 로 실패): $p" >&2
       echo "check-scan: $JUDGE_HINT" >&2; exit 3 ;;
  esac
done
exit "$status"
