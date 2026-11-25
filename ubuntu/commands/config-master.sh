#!/bin/bash
# k3s 서버(컨트롤 플레인)를 구성한다.
# send-command.sh 로 전송되어 마스터 노드에서 root 로 실행된다. 다시 실행해도 안전하다.
#
# 사용법: config-master.sh [K3S_VERSION]
#   K3S_VERSION  설치할 버전 (예: v1.36.6+k3s1). 비우면 stable 채널 최신
#
# 결과(stdout):
#   K3S_URL=<워커가 조인할 서버 주소>
#   K3S_TOKEN=<조인 토큰>
#   K3S_VERSION=<설치된 버전. 워커도 이 버전으로 맞춘다>
set -euo pipefail
exec 3>&1 1>&2 # fd 3 = 결과(stdout). 그 외 출력은 모두 로그(stderr)

K3S_VERSION="${1:-}"
API_PORT=6443
TOKEN_FILE=/var/lib/rancher/k3s/server/node-token
NODE_NAME="$(hostname | tr '[:upper:]' '[:lower:]')" # k3s 가 이 노드를 등록하는 이름

if [ "$(uname -s)" != "Linux" ] || [ "$(id -u)" -ne 0 ]; then
  echo "노드(Linux)에서 root 로 실행해야 합니다. send-command.sh 로 전송하세요."
  exit 1
fi
if [ -e /etc/systemd/system/k3s-agent.service ]; then
  echo "이 노드에는 k3s 에이전트가 설치되어 있습니다. k3s-agent-uninstall.sh 로 제거한 뒤 다시 실행하세요."
  exit 1
fi

# 실패하면 노드에 접속하지 않고도 원인을 볼 수 있게 서비스 로그를 남긴다.
show_service_log_on_failure() {
  if [ "$?" -ne 0 ]; then
    echo "--- k3s 서비스 로그 (마지막 20줄) ---"
    journalctl -u k3s --no-pager -n 20 || true
  fi
}
trap show_service_log_on_failure EXIT

wait_until() {
  local description=$1 limit=$2
  shift 2
  local deadline=$((SECONDS + limit))
  until "$@" > /dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "시간 초과(${limit}초): $description"
      return 1
    fi
    sleep 3
  done
}

# 이 노드의 InternalIP. 노드가 등록되어 주소가 붙기 전에는 빈 값이다.
get_node_ip() {
  k3s kubectl get node "$NODE_NAME" \
    -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' | awk '{ print $1 }'
}

node_registered() {
  [ -n "$(get_node_ip)" ]
}

echo "=== k3s 서버 설치 ==="
# CNI·kube-proxy·네트워크 정책은 Cilium 이 맡으므로 내장 기능을 끈다.
# 외부 진입은 Cloudflare Tunnel 이라 Traefik·servicelb 도 쓰지 않는다.
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
  --flannel-backend=none \
  --disable-network-policy \
  --disable-kube-proxy \
  --disable=traefik,servicelb
# 변경이 없으면 설치 스크립트가 서비스 기동을 건너뛰므로, 내려가 있던 경우를 위해 한 번 더 올린다.
systemctl start k3s

echo "=== API 서버·노드 등록 대기 ==="
wait_until "API 서버 응답" 180 k3s kubectl get --raw /readyz
wait_until "노드 등록 ($NODE_NAME)" 180 node_registered
echo "$NODE_NAME 등록됨. CNI(Cilium)를 설치하기 전까지는 NotReady 가 정상입니다."

echo "=== 컨트롤 플레인 전용 테인트 ==="
k3s kubectl taint node "$NODE_NAME" node-role.kubernetes.io/control-plane=:NoSchedule --overwrite

api_host="$(get_node_ip)"
token="$(cat "$TOKEN_FILE")"
installed_version="$(k3s --version | awk 'NR == 1 { print $3 }')"
if [ -z "$api_host" ] || [ -z "$token" ] || [ -z "$installed_version" ]; then
  echo "노드 IP·조인 토큰·설치 버전 중 확인하지 못한 값이 있습니다."
  exit 1
fi

{
  echo "K3S_URL=https://${api_host}:${API_PORT}"
  echo "K3S_TOKEN=${token}"
  echo "K3S_VERSION=${installed_version}"
} >&3
