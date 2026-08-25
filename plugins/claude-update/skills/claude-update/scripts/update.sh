#!/usr/bin/env bash
# Install the latest claude-code native release directly, bypassing the
# built-in updater. `claude update` puts a fixed total deadline on a ~300MB
# download, so on a slow link (corporate proxy) it fails no matter how much
# progress it made — that path is skipped entirely here. Instead: read the
# published manifest, fetch the binary with no total deadline (only a stall
# guard) and real resume, verify its SHA256, and swap the symlink the way the
# native updater would.
set -euo pipefail

RELEASES_BASE="${CLAUDE_UPDATE_RELEASES_BASE:-https://downloads.claude.ai/claude-code-releases}"
# 0 = 시도당 총 시간 제한 없음. 이 스크립트가 존재하는 이유가 "진행 중인
# 전송을 총 시간으로 끊는 것"이므로 기본값은 무제한이다. 대신 아래 정체
# 감지로 죽은 연결만 끊는다.
DOWNLOAD_MAX_TIME="${CLAUDE_UPDATE_MAX_TIME:-0}"           # seconds, per attempt (0 = unlimited)
STALL_SPEED="${CLAUDE_UPDATE_STALL_SPEED:-1024}"           # bytes/s 미만이면 정체로 본다
STALL_TIME="${CLAUDE_UPDATE_STALL_TIME:-120}"              # 그 상태가 이만큼 이어지면 시도를 끊는다
MAX_STALLS="${CLAUDE_UPDATE_RETRIES:-5}"                   # 진전 없는 시도가 연속 이만큼이면 포기
MAX_ATTEMPTS="${CLAUDE_UPDATE_MAX_ATTEMPTS:-30}"           # 폭주 방지용 총 시도 상한
RETRY_DELAY="${CLAUDE_UPDATE_RETRY_DELAY:-5}"              # seconds
CONNECT_TIMEOUT="${CLAUDE_UPDATE_CONNECT_TIMEOUT:-60}"     # seconds, 프록시 핸드셰이크까지 감안
META_MAX_TIME="${CLAUDE_UPDATE_META_MAX_TIME:-60}"         # seconds, latest/manifest.json 한 번당
META_RETRIES="${CLAUDE_UPDATE_META_RETRIES:-3}"
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

# latest 와 manifest.json 은 몇 KB 짜리지만, 느린 프록시에서는 이것도 실패한다.
# 여기서 죽으면 300MB 다운로드는 시작조차 못 하므로 재시도를 붙인다 — 작고
# 멱등한 GET 이라 처음부터 다시 받아도 손해가 없다.
fetch_meta() {
  local url="$1" out="${2:-}" attempt=0 rc=0
  while :; do
    attempt=$((attempt + 1))
    rc=0
    if [[ -n "$out" ]]; then
      curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$META_MAX_TIME" -o "$out" "$url" || rc=$?
    else
      curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$META_MAX_TIME" "$url" || rc=$?
    fi
    [[ "$rc" -eq 0 ]] && return 0
    [[ "$attempt" -ge "$META_RETRIES" ]] && return "$rc"
    echo "   요청 실패 (curl exit $rc) — ${RETRY_DELAY}초 뒤 재시도 ($attempt/$META_RETRIES)" >&2
    sleep "$RETRY_DELAY"
  done
}

# curl's own meter is a \r-overwritten single line — useless in a log file
# that gets tailed, which is how a backgrounded run is read. Print one line
# per interval instead, with the recent rate and an ETA: on a slow link the
# only question worth answering from a tail is "will this finish, and when".
watch_progress() {
  local file="$1" total="$2" start="$SECONDS"
  local prev prev_time now elapsed span delta rate size_part rate_part eta_part
  prev="$(file_size "$file")"
  prev_time="$SECONDS"
  while :; do
    sleep "$PROGRESS_INTERVAL"
    now="$(file_size "$file")"
    elapsed=$((SECONDS - start))
    span=$((SECONDS - prev_time))
    [[ "$span" -lt 1 ]] && span=1
    delta=$((now - prev))
    [[ "$delta" -lt 0 ]] && delta=0
    rate=$((delta / span))
    prev="$now"
    prev_time="$SECONDS"

    if [[ "$total" -gt 0 ]]; then
      size_part="$(printf '%3d%%  %sMB / %sMB' \
        "$((now * 100 / total))" "$((now / 1048576))" "$((total / 1048576))")"
    else
      size_part="$(printf '      %sMB' "$((now / 1048576))")"
    fi
    if [[ "$rate" -gt 0 ]]; then
      rate_part="$(printf '%d.%dMB/s' "$((rate / 1048576))" "$(((rate * 10 / 1048576) % 10))")"
    else
      rate_part='정체'
    fi
    eta_part=''
    if [[ "$total" -gt 0 && "$rate" -gt 0 && "$now" -lt "$total" ]]; then
      eta_part="$(printf '남은 ~%d분' "$((((total - now) / rate + 59) / 60))")"
    fi
    printf '   %s  %s  %s  경과 %ss\n' "$size_part" "$rate_part" "$eta_part" "$elapsed"
  done
}

# 한 번의 curl 호출. curl 자체 --retry 는 쓰지 않는다 — 재시도할 때 -C - 의
# 이어받기 지점을 다시 계산하지 않아서 이미 받은 300MB를 버리고 0부터
# 다시 받는다(출력 파일도 잘린다). 재시도는 아래 루프가 하고, 매 시도가
# 새 curl 이므로 그때마다 부분 파일 크기에서 이어받는다.
download_attempt() {
  local url="$1" rc=0
  local -a args=(
    -fL --no-progress-meter -C - -o "$part"
    --connect-timeout "$CONNECT_TIMEOUT"
    --speed-limit "$STALL_SPEED" --speed-time "$STALL_TIME"
  )
  [[ "$DOWNLOAD_MAX_TIME" -gt 0 ]] && args+=(--max-time "$DOWNLOAD_MAX_TIME")
  curl "${args[@]}" "$url" || rc=$?
  return "$rc"
}

# 정체된 시도만 재시도 횟수를 소모한다 — 느린 프록시에서 끊겼다 이어받기를
# 반복하며 조금씩 전진하는 것은 실패가 아니라 정상 경로다.
download_to_part() {
  local url="$1" attempt=0 stalled=0 rc=0 before after
  watch_progress "$part" "$size" &
  watcher=$!
  while :; do
    attempt=$((attempt + 1))
    before="$(file_size "$part")"
    [[ "$before" -gt 0 ]] && resumed=1
    rc=0
    download_attempt "$url" || rc=$?
    [[ "$rc" -eq 0 ]] && break

    after="$(file_size "$part")"
    if [[ "$rc" -eq 33 ]]; then
      echo "   서버가 이어받기(Range)를 거부했습니다 — 처음부터 다시 받습니다."
      rm -f "$part"
      after=0
    fi

    if [[ "$after" -gt "$before" ]]; then
      stalled=0
      echo "   시도 $attempt 끊김 (curl exit $rc) — $((after / 1048576))MB 지점까지 받았습니다. 이어받아 재시도합니다."
    else
      stalled=$((stalled + 1))
      echo "   시도 $attempt 실패 (curl exit $rc) — 진전 없음 ($stalled/$MAX_STALLS)."
      [[ "$stalled" -ge "$MAX_STALLS" ]] && break
    fi
    if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
      echo "   총 시도 상한($MAX_ATTEMPTS)에 도달했습니다."
      break
    fi
    sleep "$RETRY_DELAY"
  done
  { kill "$watcher" && wait "$watcher"; } 2>/dev/null || true
  watcher=""
  return "$rc"
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

latest_version="$(fetch_meta "$RELEASES_BASE/latest")"
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
resumed=0 # 어느 시도든 0이 아닌 지점에서 이어받았으면 1
trap 'rm -f "$manifest"; [[ -n "$watcher" ]] && kill "$watcher" 2>/dev/null; true' EXIT

fetch_meta "$RELEASES_BASE/$latest_version/manifest.json" "$manifest"

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
url="$RELEASES_BASE/$latest_version/$plat/$binary_name"

if [[ "$DOWNLOAD_MAX_TIME" -gt 0 ]]; then
  attempt_limit="최대 ${DOWNLOAD_MAX_TIME}초/시도"
else
  attempt_limit="시간 제한 없음, ${STALL_TIME}초 정체 시 재시도"
fi
echo "2) 다운로드 ($attempt_limit, ${PROGRESS_INTERVAL}초마다 진행률)..."

have=0
[[ -f "$part" ]] && have="$(file_size "$part")"
# 크기를 알면 완전한지 먼저 보고, 모르면 남아 있는 조각의 체크섬을 그냥
# 대조한다 — 완성된 파일에 -C - 로 이어받기를 걸면 416 으로 실패한다.
if [[ "$have" -gt 0 ]] && [[ "$size" -eq 0 || "$have" -ge "$size" ]]; then
  if [[ "$(sha256_of "$part")" == "$checksum" ]]; then
    echo "   캐시에 완전한 파일이 있습니다 — 다운로드를 건너뜁니다."
    have=-1
  elif [[ "$size" -gt 0 ]]; then
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
  rc=0
  download_to_part "$url" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "다운로드 실패 (curl exit $rc)." >&2
    echo "받은 부분은 $part 에 남겨 뒀습니다 — 다시 실행하면 이어받습니다." >&2
    exit "$rc"
  fi
fi

echo
echo "3) 체크섬 검증..."
actual_checksum="$(sha256_of "$part")"
# 이어받은 파일이 틀렸다면 앞부분(이전 실행분·Range 를 무시한 프록시 응답)이
# 의심스럽다. 사용자에게 300MB 재다운로드를 수동으로 시키지 말고 여기서
# 한 번은 처음부터 다시 받아 본다.
if [[ "$actual_checksum" != "$checksum" && "$resumed" -eq 1 ]]; then
  echo "   체크섬 불일치 — 이어받은 조각이 손상된 것으로 보입니다. 처음부터 다시 받습니다."
  rm -f "$part"
  resumed=0
  rc=0
  download_to_part "$url" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "다운로드 실패 (curl exit $rc)." >&2
    exit "$rc"
  fi
  actual_checksum="$(sha256_of "$part")"
fi
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
