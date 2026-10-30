#!/usr/bin/env bash
# check-ascii.sh - 경로 아래 파일에서 한글을 뺀 non-ASCII 문자를 찾는다.
#
# 사용법: bash scripts/check-ascii.sh <경로>...
#   non-ASCII 문자 하나당 한 줄을 `파일:줄:문자 U+XXXX` 꼴로 낸다.
#   하나라도 있으면 exit 1, 없으면 출력 없이 exit 0, 인자가 틀리면 exit 2.
#
# 한글(U+1100-11FF, U+3130-318F, U+AC00-D7A3)은 허용한다. 바이트가 아니라
# 코드포인트 단위로 세며, 부르는 쪽의 로케일에 결과가 기대지 않도록 고정한다.
# 잘못된 UTF-8 바이트는 U+FFFD 로 보고한다.

export LC_ALL=C.UTF-8

if [ "$#" -eq 0 ]; then
  echo "usage: bash scripts/check-ascii.sh <path>..." >&2
  exit 2
fi
for p in "$@"; do
  if [ ! -e "$p" ]; then
    echo "check-ascii: no such path: $p" >&2
    exit 2
  fi
done

find "$@" -type f -not -path '*/.git/*' -print0 | LC_ALL=C sort -z |
  perl -e '
    use strict; use warnings; use Encode ();
    binmode(STDOUT, ":raw");
    my $found = 0;
    while (defined(my $name = do { local $/ = "\0"; scalar <STDIN> })) {
      $name =~ s/\0\z//;
      open(my $fh, "<:raw", $name) or do { print STDERR "check-ascii: cannot read: $name\n"; exit 2 };
      my $n = 0;
      while (my $raw = <$fh>) {
        $n++;
        next unless $raw =~ /[^\x00-\x7F]/;
        my $s = Encode::decode("UTF-8", $raw, Encode::FB_DEFAULT);
        for my $c (split //, $s) {
          my $o = ord $c;
          next if $o < 0x80;
          next if ($o >= 0x1100 && $o <= 0x11FF) || ($o >= 0x3130 && $o <= 0x318F)
               || ($o >= 0xAC00 && $o <= 0xD7A3);
          $found++;
          print $name, ":", $n, ":", Encode::encode("UTF-8", $c), sprintf(" U+%04X\n", $o);
        }
      }
      close $fh;
    }
    exit($found ? 1 : 0);
  '
