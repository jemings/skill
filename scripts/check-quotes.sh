#!/usr/bin/env bash
# check-quotes.sh - 사내 스킬 스캐너가 따옴표 짝을 잘못 읽어 낼 오탐을 커밋 전에 찾는다.
#
# 사용법: bash scripts/check-quotes.sh <경로>...
#   따옴표가 파일 끝까지 열려 있는 셸 파일 하나당 한 줄을 `파일:줄:상태` 꼴로 낸다.
#   줄은 어긋남이 시작된 줄(마지막으로 줄 끝에서 따옴표가 닫혀 있던 줄의 다음 줄),
#   상태는 스캐너가 쓰는 이름(single / double / ansi_c)이다.
#   하나라도 있으면 exit 1, 없으면 출력 없이 exit 0, 인자가 틀리거나 못 읽으면 exit 2.
#
# 왜: cisco-ai-skill-scanner 의 주석 제거가 따옴표 상태를 줄 사이로 이어 가므로,
# "$(grep -c '..."...' ...)" 꼴의 한 줄에서 짝이 어긋나면 파일 끝까지 따옴표가 열린 채로 남고,
# 그 뒤의 한글 주석이 코드로 분석되어 HOMOGLYPH_ATTACK(HIGH) 오탐이 난다(#38).
# check-ascii.sh 는 한글을 허용하니 못 잡고, 스캐너는 설치에 네트워크가 필요하다(스캔 자체는 check-scan.sh).
#
# 규칙: cisco-ai-skill-scanner 2.3.2 skill_scanner/core/static_analysis/comment_stripping.py 의
# _strip_bash_comments 의 따옴표 상태 기계를 그대로 옮겼다. 스캐너를 올리면 이 규칙도 다시 맞춘다
# (scripts/test-check-quotes.sh 는 SCANNER_PY 로 원함수와 차분 시험을 한다).
#   - 줄은 \n 으로만 나눈다. \r 은 공백이다.
#   - 홑따옴표 안은 `\` 도 평범한 글자다. $'...'(ansi_c)와 쌍따옴표 안에서는 `\` 가 다음 글자를 가린다.
#   - $' 는 ansi_c, $" 는 double 로 연다.
#   - # 는 줄머리나 공백, ;|&()<> 바로 뒤에서만 주석이다. 주석이 시작되면 그 줄의 나머지는 읽지 않는다.
#   - `\` 가림은 줄을 넘지 않는다. 열린 따옴표만 다음 줄로 이어진다.
#
# 한계 (이슈 #47 범위 밖):
#   - 파일 끝 상태만 본다. 중간에 어긋났다가 짝수 번 뒤집혀 복구되면 못 잡는다.
#   - heredoc 을 파싱하지 않는다(스캐너와 같다). 본문의 홀수 따옴표도 어긋남으로 센다.
#   - Python isspace() 의 비ASCII 공백은 다루지 않는다(ASCII 공백과 \x1c-\x1f 만).
#   - 스캐너가 읽지 않는 파일(NUL 이 있거나 UTF-8 이 아닌 것)은 건너뛰고, 앞 BOM 은 벗기고 읽는다.
#   - 디렉터리 인자가 심볼릭 링크면 따라가지 않는다(check-ascii.sh 와 같다).
#
# 대상: 디렉터리 인자는 아래의 *.sh, *.bash(대소문자 무시)와 shebang 이 sh/bash 인 확장자 없는 파일
# (.git 은 제외). 파일 인자는 이름과 상관없이 그대로 검사한다. 이름으로 거를 수 있는 파일은 열지 않으니
# 대상이 아닌 읽기 불가 파일은 상관없고, shebang 을 봐야 하는 확장자 없는 파일이 읽기 불가면 exit 2 다.

export LC_ALL=C

if [ "$#" -eq 0 ]; then
  echo "usage: bash scripts/check-quotes.sh <path>..." >&2
  exit 2
fi
for p in "$@"; do
  if [ ! -e "$p" ]; then
    echo "check-quotes: no such path: $p" >&2
    exit 2
  fi
done

# 각 항목은 `d<경로>`(디렉터리에서 찾음, 이름 거름) 나 `f<경로>`(인자로 받음)
list() {
  local p
  for p in "$@"; do
    if [ -d "$p" ]; then
      find "$p" -type f -not -path '*/.git/*' -print0 | while IFS= read -r -d '' f; do printf 'd%s\0' "$f"; done
    else
      printf 'f%s\0' "$p"
    fi
  done
}

list "$@" | sort -z |
  perl -e '
    use strict; use warnings;
    binmode(STDOUT, ":raw");
    my $found = 0;
    while (defined(my $item = do { local $/ = "\0"; scalar <STDIN> })) {
      $item =~ s/\0\z//;
      my $name = substr($item, 1);
      my $from_dir = substr($item, 0, 1) eq "d";
      # 이름으로 거를 수 있는 것은 열기 전에 거른다(대상이 아닌 파일은 못 읽어도 상관없다)
      next if $from_dir && $name !~ /\.(?:sh|bash)\z/i && $name =~ m{(?:\A|/)[^/]*\.[^/]*\z};
      my $raw = do {
        open(my $fh, "<:raw", $name) or do { print STDERR "check-quotes: cannot read: $name\n"; exit 2 };
        local $/; my $r = <$fh>; close $fh; defined $r ? $r : ""
      };
      # 스캐너의 read_text_strict 처럼: NUL 이나 비UTF-8 은 binary 라 건너뛰고, 앞 BOM 은 벗긴다
      next if index($raw, "\0") >= 0;
      # Python utf-8 은 noncharacter(U+FFFE, U+FFFF, U+FDD0..) 를 받으니 Encode 대신 RFC 3629 바이트 꼴로 본다
      next unless $raw =~ /\A(?:[\x00-\x7F]|[\xC2-\xDF][\x80-\xBF]|\xE0[\xA0-\xBF][\x80-\xBF]|[\xE1-\xEC\xEE\xEF][\x80-\xBF]{2}|\xED[\x80-\x9F][\x80-\xBF]|\xF0[\x90-\xBF][\x80-\xBF]{2}|[\xF1-\xF3][\x80-\xBF]{3}|\xF4[\x80-\x8F][\x80-\xBF]{2})*+\z/;
      $raw =~ s/\A\xEF\xBB\xBF//;
      if ($from_dir && $name !~ /\.(?:sh|bash)\z/i) {
        next unless $raw =~ m{\A\#![ \t]*(?:\S*/)?(?:env[ \t]+(?:-\S+[ \t]+)*)?(?:ba)?sh(?:\s|\z)};
      }
      my ($q, $at, $esc, $opened, $n) = ("", 1, 0, 1, 0);
      my $ws = qr/[ \t\n\r\f\x0b\x1c-\x1f]/;
      for my $line (split /\n/, $raw, -1) {
        $n++;
        my ($i, $len, $comment) = (0, length $line, 0);
        $esc = 0;
        while ($i < $len) {
          my $c = substr($line, $i, 1);
          if ($esc) { $esc = 0; $at = 0; $i++; next }
          if ($q eq "single") { $q = "" if $c eq "\x27"; $i++; next }
          if ($q eq "ansi_c") { if ($c eq "\\") { $esc = 1 } elsif ($c eq "\x27") { $q = "" } $i++; next }
          if ($q eq "double") { if ($c eq "\\") { $esc = 1 } elsif ($c eq "\"") { $q = "" } $i++; next }
          if ($c eq "\\") { $esc = 1; $i++; next }
          if ($c eq "\$" && $i + 1 < $len && substr($line, $i + 1, 1) =~ /\A[\x27"]\z/) {
            $q = substr($line, $i + 1, 1) eq "\x27" ? "ansi_c" : "double"; $at = 0; $i += 2; next;
          }
          if ($c eq "\x27") { $q = "single"; $at = 0; $i++; next }
          if ($c eq "\"") { $q = "double"; $at = 0; $i++; next }
          if ($c eq "#" && $at) { $comment = 1; last }
          $at = ($c =~ $ws || $c =~ /[;|&()<>]/) ? 1 : 0;
          $i++;
        }
        $at = 1 if $comment || ($q eq "" && !$esc);
        $opened = $n + 1 if $q eq "";
      }
      if ($q ne "") { $found++; print $name, ":", $opened, ":", $q, "\n" }
    }
    exit($found ? 1 : 0);
  '
