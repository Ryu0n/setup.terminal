#!/bin/bash
# Cilium CNI 를 설치한다. (kube-proxy 대체 + Hubble)
# send-command.sh 로 전송되어 마스터 노드에서 root 로 실행된다. 다시 실행해도 안전하다.
# 설치만 하고 끝낸다. 파드가 다 뜰 때까지의 대기·검증은 get-nodes.sh, verify-cilium.sh 가 맡는다.
#
# 사용법: config-cilium.sh <API_HOST> <API_PORT> [CILIUM_VERSION]
#   API_HOST, API_PORT  모든 노드에서 닿는 API 서버 주소. kube-proxy 가 없어 Cilium 이 직접 붙는다
#   CILIUM_VERSION      차트 버전 (예: 1.20.5). 비우면 최신
set -euo pipefail
exec 1>&2 # 결과 없음. 모든 출력은 로그(stderr)

if [ "$#" -lt 2 ]; then
  echo "사용법: config-cilium.sh <API_HOST> <API_PORT> [CILIUM_VERSION]"
  exit 2
fi
API_HOST="$1"
API_PORT="$2"
CILIUM_VERSION="${3:-}"
POD_CIDR=10.42.0.0/16 # k3s 기본 cluster-cidr
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

if [ "$(uname -s)" != "Linux" ] || [ "$(id -u)" -ne 0 ]; then
  echo "노드(Linux)에서 root 로 실행해야 합니다. send-command.sh 로 전송하세요."
  exit 1
fi
if [ ! -f "$KUBECONFIG" ]; then
  echo "k3s 서버가 설치된 노드(마스터)에서 실행해야 합니다. ($KUBECONFIG 없음)"
  exit 1
fi

download_dir="$(mktemp -d)"
trap 'rm -rf "$download_dir"' EXIT

echo "=== helm 설치 ==="
if command -v helm > /dev/null 2>&1; then
  echo "helm 이 이미 설치되어 있습니다. ($(helm version --short))"
else
  # 설치 스크립트를 끝까지 받은 뒤에 실행한다.
  curl -fsSL -o "$download_dir/get-helm" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
  bash "$download_dir/get-helm"
fi

echo "=== cilium CLI 설치 ==="
if command -v cilium > /dev/null 2>&1; then
  echo "cilium CLI 가 이미 설치되어 있습니다."
else
  cli_version="$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
  case "$(uname -m)" in
    aarch64 | arm64) cli_archive="cilium-linux-arm64.tar.gz" ;;
    *) cli_archive="cilium-linux-amd64.tar.gz" ;;
  esac
  (
    cd "$download_dir"
    curl -fsSL --remote-name-all \
      "https://github.com/cilium/cilium-cli/releases/download/${cli_version}/${cli_archive}"{,.sha256sum}
    sha256sum --check "${cli_archive}.sha256sum"
    tar xzf "$cli_archive" -C /usr/local/bin
  )
fi

echo "=== Cilium 설치 ==="
helm repo add cilium https://helm.cilium.io --force-update
helm repo update cilium

release_options=(
  --namespace kube-system
  --set kubeProxyReplacement=true
  --set k8sServiceHost="$API_HOST"
  --set k8sServicePort="$API_PORT"
  --set hubble.relay.enabled=true
  --set hubble.ui.enabled=true
  # Istio ambient 를 나중에 얹기 위한 값. kube-proxy 를 대체하는 구성에서는 둘 다 필요하다.
  --set cni.exclusive=false
  --set socketLB.hostNamespaceOnly=true
  # k3s 가 쓰는 파드 대역에 맞춘다. (기본값 10.0.0.0/8 은 서비스 대역 10.43.0.0/16 과 겹친다)
  --set "ipam.operator.clusterPoolIPv4PodCIDRList={$POD_CIDR}"
)
if [ -n "$CILIUM_VERSION" ]; then
  release_options+=(--version "$CILIUM_VERSION")
fi
helm upgrade --install cilium cilium/cilium "${release_options[@]}"

echo "Cilium 릴리스를 적용했습니다. 노드가 Ready 가 되기까지 이미지 풀 시간이 걸립니다."
