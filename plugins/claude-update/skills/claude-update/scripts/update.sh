#!/usr/bin/env bash
# Recover `claude update` when the native auto-updater's internal download
# deadline is too short for the current network (e.g. a slow corporate
# proxy). Tries the normal update first; on failure, downloads the release
# binary directly with a long timeout, verifies its checksum against the
# published manifest, and swaps it into place the same way the native
# updater would.
set -euo pipefail

RELEASES_BASE="https://downloads.claude.ai/claude-code-releases"
DOWNLOAD_MAX_TIME="${CLAUDE_UPDATE_MAX_TIME:-900}" # seconds

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
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

claude_bin="$(command -v claude || true)"
if [[ -z "$claude_bin" ]]; then
  echo "claude 실행 파일을 PATH에서 찾을 수 없습니다." >&2
  exit 1
fi

current_version="$(claude --version 2>/dev/null | awk '{print $1}')"
install_method="$(claude doctor 2>/dev/null | awk -F': ' '/Config install method/{print $2}')"

if [[ "$install_method" != "native" ]]; then
  echo "네이티브 설치가 아닙니다 (install method: ${install_method:-unknown})." >&2
  echo "npm/homebrew 등 다른 방식으로 설치했다면 해당 패키지 매니저로 갱신하세요." >&2
  exit 1
fi

if [[ ! -L "$claude_bin" ]]; then
  echo "claude 실행 파일이 심링크가 아닙니다 ($claude_bin)." >&2
  echo "이 스크립트는 공식 네이티브 설치 구조(symlink -> versions/<version>)를 가정합니다 — 안전을 위해 중단합니다." >&2
  exit 1
fi

versions_dir="$(dirname "$(readlink -f "$claude_bin")")"

echo "현재 버전: $current_version (native, $versions_dir)"
echo
echo "1) claude update 로 정상 경로부터 시도합니다..."
if claude update; then
  echo "claude update 성공."
  exit 0
fi

echo
echo "claude update 실패 — 수동 설치로 전환합니다."
echo

latest_version="$(curl -fsS --max-time 15 "$RELEASES_BASE/latest")"
echo "최신 버전: $latest_version"

if [[ "$latest_version" == "$current_version" ]]; then
  echo "이미 최신 버전입니다 ($current_version) — claude update 실패 원인이 다운로드 타임아웃이 아닐 수 있습니다." >&2
  echo "위에 출력된 원본 에러 메시지를 확인하세요." >&2
  exit 1
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
trap 'rm -f "$manifest" "${tmp_bin:-}"' EXIT

curl -fsS --max-time 15 -o "$manifest" "$RELEASES_BASE/$latest_version/manifest.json"

checksum="$(manifest_field "$manifest" "$plat" checksum)"
size="$(manifest_field "$manifest" "$plat" size)"
binary_name="$(manifest_field "$manifest" "$plat" binary)"

if [[ -z "$checksum" ]]; then
  echo "manifest.json 에서 $plat 항목을 찾지 못했습니다." >&2
  exit 1
fi

echo "대상: $latest_version / $plat, 크기 $((size / 1024 / 1024))MB"
echo
echo "2) 다운로드 중 (최대 ${DOWNLOAD_MAX_TIME}초 대기)..."

tmp_bin="$(mktemp)"
curl -o "$tmp_bin" --max-time "$DOWNLOAD_MAX_TIME" --retry 3 --retry-delay 5 \
  "$RELEASES_BASE/$latest_version/$plat/$binary_name"

actual_checksum="$(sha256_of "$tmp_bin")"
if [[ "$actual_checksum" != "$checksum" ]]; then
  echo "체크섬 불일치! 기대값=$checksum 실제값=$actual_checksum" >&2
  echo "다운로드가 손상되었을 수 있습니다 — 설치를 중단합니다." >&2
  exit 1
fi
echo "체크섬 확인됨 ($actual_checksum)."

dest="$versions_dir/$latest_version"
cp "$tmp_bin" "$dest"
chmod +x "$dest"
ln -sf "$dest" "$claude_bin"

echo
echo "3) 설치 완료:"
claude --version
