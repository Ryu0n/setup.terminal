#!/bin/bash
# k3s 에이전트(워커)를 구성해 클러스터에 조인시킨다.
# send-command.sh 로 전송되어 워커 노드에서 root 로 실행된다. 다시 실행해도 안전하다.
#
# 사용법: config-worker.sh <K3S_URL> <K3S_TOKEN> [K3S_VERSION]
#   config-master.sh 의 결과 값을 그대로 넘긴다. K3S_VERSION 을 비우면 stable 채널 최신
set -euo pipefail
exec 1>&2 # 결과 없음. 모든 출력은 로그(stderr)

if [ "$#" -lt 2 ]; then
  echo "사용법: config-worker.sh <K3S_URL> <K3S_TOKEN> [K3S_VERSION]"
  exit 2
fi
K3S_URL="$1"
K3S_TOKEN="$2"
K3S_VERSION="${3:-}"

if [ "$(uname -s)" != "Linux" ] || [ "$(id -u)" -ne 0 ]; then
  echo "노드(Linux)에서 root 로 실행해야 합니다. send-command.sh 로 전송하세요."
  exit 1
fi
if [ -e /etc/systemd/system/k3s.service ]; then
  echo "이 노드에는 k3s 서버가 설치되어 있습니다. k3s-uninstall.sh 로 제거한 뒤 다시 실행하세요."
  exit 1
fi

# 실패하면 노드에 접속하지 않고도 원인을 볼 수 있게 서비스 로그를 남긴다.
show_service_log_on_failure() {
  if [ "$?" -ne 0 ]; then
    echo "--- k3s-agent 서비스 로그 (마지막 20줄) ---"
    journalctl -u k3s-agent --no-pager -n 20 || true
  fi
}
trap show_service_log_on_failure EXIT

echo "=== k3s 서버 접속 확인 ==="
# 서버에 닿지 않으면 에이전트가 끝없이 재시도해 설치가 멈춰 있게 되므로 먼저 확인한다.
if ! curl -ks --max-time 10 -o /dev/null "$K3S_URL/ping"; then
  echo "k3s 서버에 접속할 수 없습니다: $K3S_URL"
  exit 1
fi

echo "=== k3s 에이전트 설치 ==="
curl -sfL https://get.k3s.io \
  | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" INSTALL_K3S_VERSION="$K3S_VERSION" sh -
# 변경이 없으면 설치 스크립트가 서비스 기동을 건너뛰므로, 내려가 있던 경우를 위해 한 번 더 올린다.
systemctl start k3s-agent

echo "k3s 에이전트가 떴습니다. 클러스터 등록 여부는 마스터에서 확인합니다. (get-nodes.sh)"
