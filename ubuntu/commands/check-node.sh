#!/bin/bash
# 노드가 k3s 를 올릴 수 있는 상태인지 점검한다. 아무것도 변경하지 않는다.
# send-command.sh 로 전송되어 노드에서 root 로 실행된다.
#
# 사용법: check-node.sh
# 결과(stdout): NODE_NAME=<클러스터에 등록될 노드 이름>
set -euo pipefail
exec 3>&1 1>&2 # fd 3 = 결과(stdout). 그 외 출력은 모두 로그(stderr)

failures=0
fail() {
  echo "점검 실패: $*"
  failures=$((failures + 1))
}

uname -srm

if [ "$(uname -s)" != "Linux" ] || [ "$(id -u)" -ne 0 ]; then
  fail "노드(Linux)에서 root 로 실행해야 합니다. send-command.sh 로 전송하세요."
fi

if ! command -v curl > /dev/null 2>&1; then
  fail "curl 이 없습니다. (apt-get install -y curl)"
fi

# k3s 는 메모리 cgroup 이 꺼져 있으면 뜨지 못한다. 라즈베리파이는 기본값이 꺼짐이다. (노션 Phase 0)
if ! grep -qsw memory /sys/fs/cgroup/cgroup.controllers \
  && [ "$(awk '$1 == "memory" { print $4 }' /proc/cgroups 2> /dev/null)" != "1" ]; then
  fail "메모리 cgroup 이 꺼져 있습니다. config-cgroup.sh 로 커널 인자를 추가하고 재부팅해야 합니다. (재부팅 후에도 그대로라면 고친 cmdline.txt 가 실제 부팅에 쓰이는 파일인지 확인)"
fi

if command -v ufw > /dev/null 2>&1; then
  ufw_status="$(ufw status 2> /dev/null || true)"
  case "$ufw_status" in
    "Status: active"*) echo "경고: ufw 가 켜져 있습니다. 노드 간 통신이 막히면 조인·CNI 구성이 실패합니다. (k3s 권장: ufw disable)" ;;
  esac
fi

if [ "$failures" -gt 0 ]; then
  exit 1
fi

# k3s 는 호스트명을 소문자로 바꿔 노드 이름으로 쓴다.
echo "NODE_NAME=$(hostname | tr '[:upper:]' '[:lower:]')" >&3
