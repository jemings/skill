#!/usr/bin/env bash
# Install the latest claude-code native release directly, bypassing the
# built-in updater. `claude update` puts a fixed total deadline on a ~300MB
# download, so on a slow link (corporate proxy) it fails no matter how much
# progress it made — that path is skipped entirely here. Instead: read the
# published manifest, fetch the binary with a generous timeout and resume,
# verify its SHA256, and swap the symlink the way the native updater would.
set -euo pipefail

RELEASES_BASE="${CLAUDE_UPDATE_RELEASES_BASE:-https://downloads.claude.ai/claude-code-releases}"
DOWNLOAD_MAX_TIME="${CLAUDE_UPDATE_MAX_TIME:-900}"       # seconds, per attempt
PROGRESS_INTERVAL="${CLAUDE_UPDATE_PROGRESS_INTERVAL:-30}" # seconds
CACHE_DIR="${CLAUDE_UPDATE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-update}"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_size() {
  stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0
}

# Pulls one field ("checksum" | "size" | "binary") out of the platform
# block for $plat in manifest.json, without depending on jq.
manifest_field() {
  local manifest_file="$1" plat="$2" field="$3"
  awk -v key="\"$plat\": {" '
    $0 ~ key { flag=1; next }
    flag && /}/ { exit }
    flag { print }
  ' "$manifest_file" | grep -oE "\"$field\": *\"?[^\",}]+\"?" | sed -E 's/^"[^"]+": *"?([^",}]+)"?$/\1/'
}

# curl's own meter is a \r-overwritten single line — useless in a log file
# that gets tailed, which is how a backgrounded run is read. Print one line
# per interval instead.
watch_progress() {
  local file="$1" total="$2" start="$SECONDS" now pct
  while :; do
    sleep "$PROGRESS_INTERVAL"
    now="$(file_size "$file")"
    if [[ "$total" -gt 0 ]]; then pct=$((now * 100 / total)); else pct=0; fi
    printf '   %3d%%  %sMB / %sMB  경과 %ss\n' \
      "$pct" "$((now / 1048576))" "$((total / 1048576))" "$((SECONDS - start))"
  done
}

claude_bin="$(command -v claude || true)"
if [[ -z "$claude_bin" ]]; then
  echo "claude 실행 파일을 PATH에서 찾을 수 없습니다." >&2
  exit 1
fi

if [[ ! -L "$claude_bin" ]]; then
  echo "claude 실행 파일이 심링크가 아닙니다 ($claude_bin)." >&2
  echo "이 스크립트는 공식 네이티브 설치 구조(symlink -> versions/<version>)를 가정합니다 — 안전을 위해 중단합니다." >&2
  exit 1
fi

target="$(readlink -f "$claude_bin")"
versions_dir="$(dirname "$target")"
current_version="$(basename "$target")"

# 네이티브 레이아웃이면 여기서 확인이 끝난다. 아닐 때만 (느린) claude doctor 로
# 되물어, 레이아웃이 바뀐 네이티브 설치와 npm/homebrew 설치를 구분한다.
if [[ "$(basename "$versions_dir")" != "versions" ]]; then
  install_method="$(claude doctor 2>/dev/null | awk -F': ' '/Config install method/{print $2}')"
  if [[ "$install_method" != "native" ]]; then
    echo "네이티브 설치가 아닙니다 (install method: ${install_method:-unknown}, $target)." >&2
    echo "npm/homebrew 등 다른 방식으로 설치했다면 해당 패키지 매니저로 갱신하세요." >&2
    exit 1
  fi
  current_version="$(claude --version 2>/dev/null | awk '{print $1}')"
fi

echo "현재 버전: $current_version (native, $versions_dir)"
echo
echo "1) 최신 버전 확인..."

latest_version="$(curl -fsS --max-time 15 "$RELEASES_BASE/latest")"
echo "최신 버전: $latest_version"

if [[ "$latest_version" == "$current_version" && "${CLAUDE_UPDATE_FORCE:-}" != "1" ]]; then
  echo "이미 최신 버전입니다 — 할 일이 없습니다."
  echo "(같은 버전을 다시 설치하려면 CLAUDE_UPDATE_FORCE=1)"
  exit 0
fi

os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
Linux)
  case "$arch" in
  x86_64) plat=linux-x64 ;;
  aarch64 | arm64) plat=linux-arm64 ;;
  *)
    echo "지원하지 않는 arch: $arch" >&2
    exit 1
    ;;
  esac
  if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
    plat="${plat}-musl"
  fi
  ;;
Darwin)
  case "$arch" in
  x86_64) plat=darwin-x64 ;;
  arm64) plat=darwin-arm64 ;;
  *)
    echo "지원하지 않는 arch: $arch" >&2
    exit 1
    ;;
  esac
  ;;
*)
  echo "지원하지 않는 OS: $os (Windows는 이 스크립트로 처리하지 않습니다)" >&2
  exit 1
  ;;
esac
echo "플랫폼: $plat"

manifest="$(mktemp)"
watcher=""
trap 'rm -f "$manifest"; [[ -n "$watcher" ]] && kill "$watcher" 2>/dev/null; true' EXIT

curl -fsS --max-time 15 -o "$manifest" "$RELEASES_BASE/$latest_version/manifest.json"

# `|| true` — 필드가 없으면 grep 이 1을 내고 set -e 가 조용히 죽인다.
# 아래 안내 메시지까지 살아서 도달하게 한다.
checksum="$(manifest_field "$manifest" "$plat" checksum || true)"
size="$(manifest_field "$manifest" "$plat" size || true)"
binary_name="$(manifest_field "$manifest" "$plat" binary || true)"

if [[ -z "$checksum" || -z "$binary_name" ]]; then
  echo "manifest.json 에서 $plat 항목을 찾지 못했습니다." >&2
  exit 1
fi
[[ -n "$size" ]] || size=0

echo "대상: $latest_version / $plat, 크기 $((size / 1024 / 1024))MB"
echo

# 중단된 다운로드는 캐시에 남겨 두고 다음 실행에서 이어받는다 — 프록시가
# 끊길 때마다 300MB를 처음부터 다시 받지 않기 위해서다.
mkdir -p "$CACHE_DIR"
part="$CACHE_DIR/$latest_version-$plat"

echo "2) 다운로드 (최대 ${DOWNLOAD_MAX_TIME}초/시도, ${PROGRESS_INTERVAL}초마다 진행률)..."
have=0
[[ -f "$part" ]] && have="$(file_size "$part")"
if [[ "$have" -gt 0 && "$size" -gt 0 && "$have" -ge "$size" ]]; then
  if [[ "$(sha256_of "$part")" == "$checksum" ]]; then
    echo "   캐시에 완전한 파일이 있습니다 — 다운로드를 건너뜁니다."
    have=-1
  else
    echo "   캐시 파일 체크섬이 맞지 않아 삭제하고 새로 받습니다."
    rm -f "$part"
    have=0
  fi
fi

if [[ "$have" -ge 0 ]]; then
  if [[ "$have" -gt 0 && "$size" -gt 0 ]]; then
    echo "   이어받기: $((have / 1048576))MB ($((have * 100 / size))%) 지점부터"
  elif [[ "$have" -gt 0 ]]; then
    echo "   이어받기: $((have / 1048576))MB 지점부터"
  fi
  watch_progress "$part" "$size" &
  watcher=$!
  rc=0
  curl -fL --no-progress-meter -C - -o "$part" \
    --max-time "$DOWNLOAD_MAX_TIME" \
    --speed-limit 1024 --speed-time 120 \
    --retry 5 --retry-delay 5 \
    "$RELEASES_BASE/$latest_version/$plat/$binary_name" || rc=$?
  { kill "$watcher" && wait "$watcher"; } 2>/dev/null || true
  watcher=""
  if [[ "$rc" -ne 0 ]]; then
    echo "다운로드 실패 (curl exit $rc)." >&2
    echo "받은 부분은 $part 에 남겨 뒀습니다 — 다시 실행하면 이어받습니다." >&2
    exit "$rc"
  fi
fi

echo
echo "3) 체크섬 검증..."
actual_checksum="$(sha256_of "$part")"
if [[ "$actual_checksum" != "$checksum" ]]; then
  echo "체크섬 불일치! 기대값=$checksum 실제값=$actual_checksum" >&2
  echo "손상된 파일을 삭제합니다 ($part) — 다시 실행하면 새로 받습니다." >&2
  rm -f "$part"
  exit 1
fi
echo "   확인됨 ($actual_checksum)."

echo
echo "4) 설치..."
dest="$versions_dir/$latest_version"
staged="$versions_dir/.$latest_version.incoming.$$"
cp "$part" "$staged"
chmod +x "$staged"
mv -f "$staged" "$dest"
ln -sfn "$dest" "$claude_bin"
rm -f "$part"

echo "   $claude_bin -> $dest"
echo
echo "완료: $(claude --version)"
echo "(실행 중인 세션은 계속 이전 버전이며, 새로 띄우는 claude 부터 적용됩니다.)"
