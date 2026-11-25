#!/bin/bash
# Cilium 이 정상인지 검증한다.
# send-command.sh 로 전송되어 마스터 노드에서 root 로 실행된다.
#
# 사용법: verify-cilium.sh [--connectivity-test]
#   --connectivity-test  cilium connectivity test 까지 수행한다.
#                        (테스트용 네임스페이스와 파드를 만들며 파이에서 10분쯤 걸린다)
set -euo pipefail
exec 1>&2 # 결과 없음. 모든 출력은 로그(stderr)

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== Cilium 상태 ==="
cilium status --wait --wait-duration 10m --interactive=false

echo "=== 노드 ==="
k3s kubectl get nodes -o wide

if [ "${1:-}" = "--connectivity-test" ]; then
  echo "=== 연결성 테스트 ==="
  cilium connectivity test
fi
