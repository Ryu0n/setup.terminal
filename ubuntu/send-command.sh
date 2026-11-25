#!/bin/bash
# SSH 로 노드에 스크립트를 전송해 root 권한으로 실행한다. (AWS SSM send-command 와 같은 역할)
#
# 사용법: ./send-command.sh [-t 초] <노드> <스크립트> [스크립트 인자...]
#   예) ./send-command.sh berry-0 commands/config-master.sh
#       ./send-command.sh berry-1 commands/config-worker.sh "$K3S_URL" "$K3S_TOKEN"
#
# - 스크립트 전체가 노드에 도착해 sha256 이 일치할 때만 실행한다. (일부만 전송된 채 실행되지 않는다)
# - 원격 stdout 은 그대로 stdout 으로(결과 캡처용), 원격 stderr 는 "[노드] " 를 붙여 stderr 로 내보낸다.
# - 종료 코드는 원격 스크립트의 종료 코드다. (124: 제한 시간 초과, 255: SSH 접속 실패)
# - 인자는 스크립트 본문에 실어 보낸다. 토큰 같은 값이 원격 명령줄(ps, sudo 로그)에 남지 않는다.
#
# 전제: cluster.env(cluster.env.example 을 복사해 작성)가 있고, 노드에 SSH 키로 접속할 수 있으며,
#       접속 계정이 비밀번호 없이 sudo 를 쓸 수 있어야 한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "사용법: $(basename "$0") [-t 초] <노드> <스크립트> [스크립트 인자...]"
}

timeout_seconds=900
while [ "$#" -gt 0 ]; do
  case "$1" in
    -t | --timeout)
      timeout_seconds="${2:-}"
      shift
      if [ "$#" -gt 0 ]; then shift; fi
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "알 수 없는 옵션: $1" >&2
      usage >&2
      exit 2
      ;;
    *) break ;;
  esac
done

case "$timeout_seconds" in
  "" | *[!0-9]*)
    echo "제한 시간은 초 단위 숫자여야 합니다: '$timeout_seconds'" >&2
    exit 2
    ;;
esac
if [ "$#" -lt 2 ]; then
  usage >&2
  exit 2
fi

node="$1"
script="$2"
shift 2

if [ ! -f "$script" ]; then
  echo "스크립트를 찾을 수 없습니다: $script" >&2
  exit 2
fi

config_file="$SCRIPT_DIR/cluster.env"
if [ ! -f "$config_file" ]; then
  echo "설정 파일이 없습니다: $config_file" >&2
  echo "같은 폴더의 cluster.env.example 을 복사해 환경에 맞게 고친 뒤 다시 실행하세요." >&2
  exit 2
fi
# shellcheck source=cluster.env.example
source "$config_file"

# 원격 셸이 값을 그대로 한 단어로 읽도록 작은따옴표로 감싼다.
shell_quote() {
  local escaped_quote="'\\''"
  printf "'%s'" "${1//\'/$escaped_quote}"
}

sha256() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi | awk '{ print $1 }'
}

# 전송 본문 = 인자를 설정하는 한 줄 + 스크립트 원문
payload="set --"
for argument in "$@"; do
  payload="$payload $(shell_quote "$argument")"
done
payload="$payload
$(cat "$script")"
payload_sha256="$(sha256 <<< "$payload")"

# 노드에서 본문을 받아 실행하는 수신부. $1: 본문의 sha256, $2: 제한 시간(초)
# 작은따옴표로 감싸 보내므로 안에서는 작은따옴표를 쓰지 않는다.
# shellcheck disable=SC2016  # 변수는 로컬이 아니라 노드에서 확장되어야 한다
receiver='
set -eu
body=$(mktemp /tmp/send-command.XXXXXX)
trap "rm -f $body" EXIT
trap "exit 129" HUP INT TERM
cat > "$body"
if ! echo "$1  $body" | sha256sum --check --status -; then
  echo "전송된 스크립트가 온전하지 않아 실행하지 않았습니다. (sha256 불일치)" >&2
  exit 97
fi
if [ "$(id -u)" -eq 0 ]; then
  timeout -k 10 "$2" bash "$body" < /dev/null
elif sudo -n true 2> /dev/null; then
  sudo -n timeout -k 10 "$2" bash "$body" < /dev/null
else
  echo "비밀번호 없는 sudo 가 필요합니다. 노드에서 sudo visudo -f /etc/sudoers.d/90-nopasswd 로 다음 줄을 추가하세요: $(id -un) ALL=(ALL) NOPASSWD:ALL" >&2
  exit 98
fi
'

ssh_options=(
  -T
  -o BatchMode=yes
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=4
  -o StrictHostKeyChecking="$SSH_STRICT_HOST_KEY_CHECKING"
)
if [ -n "$SSH_USER" ]; then ssh_options+=(-l "$SSH_USER"); fi
if [ -n "$SSH_PORT" ]; then ssh_options+=(-p "$SSH_PORT"); fi
if [ -n "$SSH_IDENTITY_FILE" ]; then ssh_options+=(-i "$SSH_IDENTITY_FILE"); fi

prefix_with_node() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    printf '[%s] %s\n' "$node" "$line"
  done
}

# stdout 은 그대로 두고 stderr 에만 접두어를 붙인다. (fd 3 = 원래 stdout)
status=0
{
  ssh "${ssh_options[@]}" -- "$node" "sh -c '$receiver' send-command $payload_sha256 $timeout_seconds" \
    <<< "$payload" 2>&1 1>&3 3>&- | prefix_with_node >&2 3>&-
} 3>&1 || status=$?

case "$status" in
  0) ;;
  124) echo "[$node] 제한 시간(${timeout_seconds}초)을 넘겨 중단했습니다: $script" >&2 ;;
  255) echo "[$node] SSH 접속에 실패했습니다. 키 인증과 cluster.env 의 노드·SSH 설정을 확인하세요." >&2 ;;
  *) echo "[$node] 실패했습니다 (종료 코드 $status): $script" >&2 ;;
esac
exit "$status"
