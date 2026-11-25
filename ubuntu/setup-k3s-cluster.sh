#!/bin/bash
# 홈랩 노드들에 k3s + Cilium 클러스터를 구성한다.
#
#   [1/7] 노드 준비          모든 노드     commands/config-cgroup.sh  메모리 cgroup. 꺼져 있던 노드만 재부팅한다
#   [2/7] 사전 점검          모든 노드     commands/check-node.sh
#   [3/7] 마스터 구성        마스터        commands/config-master.sh  -> K3S_URL, K3S_TOKEN, K3S_VERSION
#   [4/7] 워커 구성          워커 (병렬)   commands/config-worker.sh  <- K3S_URL, K3S_TOKEN, K3S_VERSION
#   [5/7] 노드 등록 대기     마스터 폴링   commands/get-nodes.sh
#   [6/7] Cilium 설치        마스터        commands/config-cilium.sh
#   [7/7] Ready 대기·검증    마스터 폴링   commands/get-nodes.sh, commands/verify-cilium.sh
#
# 노드·SSH·버전은 cluster.env 에서 설정한다. (cluster.env.example 을 복사해 만들며 git 에는 올리지 않는다)
# 중간에 실패하면 원인을 고친 뒤 처음부터 다시 실행하면 된다.
#
# 사용법: ./setup-k3s-cluster.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMANDS_DIR="$SCRIPT_DIR/commands"
CONFIG_FILE="$SCRIPT_DIR/cluster.env"

if [ "$#" -gt 0 ]; then
  echo "사용법: $(basename "$0")   (인자 없음. 설정은 cluster.env 또는 환경변수로 한다)"
  case "$1" in
    -h | --help) exit 0 ;;
    *) exit 2 ;;
  esac
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "설정 파일이 없습니다: $CONFIG_FILE"
  echo "같은 폴더의 cluster.env.example 을 복사해 환경에 맞게 고친 뒤 다시 실행하세요."
  exit 1
fi
# shellcheck source=cluster.env.example
source "$CONFIG_FILE"

read -r -a WORKERS <<< "$WORKER_NODES"
if [ "${#WORKERS[@]}" -eq 0 ]; then
  echo "워커 노드가 없습니다. cluster.env 의 WORKER_NODES 를 확인하세요."
  exit 1
fi
NODES=("$MASTER_NODE" "${WORKERS[@]}")

send_command() {
  "$SCRIPT_DIR/send-command.sh" "$@"
}

# "KEY=VALUE" 줄로 이루어진 명령 결과에서 KEY 의 값을 꺼낸다.
result_value() {
  sed -n "s/^$1=//p" <<< "$2" | tail -n 1
}

# get-nodes.sh 결과에서 노드가 원하는 상태(registered | ready)인지 확인한다.
node_is() {
  local state=$1 name=$2 nodes=$3
  case "$state" in
    registered) awk -v name="$name" '$1 == name { found = 1 } END { exit !found }' <<< "$nodes" ;;
    ready) awk -v name="$name" '$1 == name && $2 == "True" { found = 1 } END { exit !found }' <<< "$nodes" ;;
  esac
}

# 모든 노드가 원하는 상태가 될 때까지 마스터에 주기적으로 물어본다.
wait_for_nodes() {
  local state=$1 limit=$2
  local deadline=$((SECONDS + limit))
  local nodes name pending label
  case "$state" in
    registered) label="등록" ;;
    ready) label="Ready" ;;
  esac
  while true; do
    # 조회에 실패하면(API 서버 재시작 등) 이번 차례는 모두 대기 중으로 본다.
    nodes="$(send_command -t 30 "$MASTER_NODE" "$COMMANDS_DIR/get-nodes.sh" 2> /dev/null || true)"
    pending=""
    for name in "${NODE_NAMES[@]}"; do
      if ! node_is "$state" "$name" "$nodes"; then
        pending="$pending $name"
      fi
    done
    if [ -z "$pending" ]; then
      echo "모든 노드 $label 완료: ${NODE_NAMES[*]}"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "시간 초과(${limit}초). $label 대기 중이던 노드:$pending"
      send_command -t 30 "$MASTER_NODE" "$COMMANDS_DIR/get-nodes.sh" || true # 현재 상태나 조회 오류를 그대로 보여준다
      return 1
    fi
    echo "$label 대기 중:$pending"
    sleep "$POLL_INTERVAL"
  done
}

# 재부팅한 노드들이 다시 올라와 사전 점검(메모리 cgroup 포함)을 통과할 때까지 기다린다.
# 재부팅 전에는 메모리 cgroup 이 꺼져 있어 점검에 실패하므로, 내려가기 전의 노드를 완료로 착각하지 않는다.
wait_for_reboot() {
  local limit=$1
  shift
  local deadline=$((SECONDS + limit))
  local node pending
  while true; do
    pending=""
    for node in "$@"; do
      if ! send_command -t 30 "$node" "$COMMANDS_DIR/check-node.sh" > /dev/null 2>&1; then
        pending="$pending $node"
      fi
    done
    if [ -z "$pending" ]; then
      echo "재부팅 완료: $*"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "시간 초과(${limit}초). 재부팅 후 준비되지 않은 노드:$pending"
      for node in $pending; do
        send_command -t 30 "$node" "$COMMANDS_DIR/check-node.sh" > /dev/null || true # 원인을 그대로 보여준다
      done
      return 1
    fi
    echo "재부팅 대기 중:$pending"
    sleep "$POLL_INTERVAL"
  done
}

echo "=== [1/7] 노드 준비: 메모리 cgroup (${NODES[*]}) ==="
failed_nodes=""
manual_reboot_nodes=""
rebooting_nodes=()
for node in "${NODES[@]}"; do
  state=""
  if result="$(send_command -t 60 "$node" "$COMMANDS_DIR/config-cgroup.sh" "$AUTO_REBOOT")"; then
    state="$(result_value CGROUP "$result")"
  fi
  case "$state" in
    enabled) ;;
    reboot-scheduled) rebooting_nodes+=("$node") ;;
    reboot-required) manual_reboot_nodes="$manual_reboot_nodes $node" ;;
    *) failed_nodes="$failed_nodes $node" ;;
  esac
done
if [ -n "$failed_nodes" ]; then
  echo "노드 준비에 실패한 노드:$failed_nodes"
  exit 1
fi
if [ -n "$manual_reboot_nodes" ]; then
  echo "재부팅해야 메모리 cgroup 이 켜지는 노드:$manual_reboot_nodes"
  echo "AUTO_REBOOT 가 true 가 아니라서 재부팅하지 않았습니다. 직접 재부팅한 뒤 다시 실행하세요."
  exit 1
fi
if [ "${#rebooting_nodes[@]}" -gt 0 ]; then
  echo "메모리 cgroup 을 켜려고 재부팅하는 노드: ${rebooting_nodes[*]}"
  wait_for_reboot "$NODE_REBOOT_TIMEOUT" "${rebooting_nodes[@]}"
fi

echo "=== [2/7] 사전 점검 (${NODES[*]}) ==="
NODE_NAMES=()
failed_nodes=""
for node in "${NODES[@]}"; do
  name=""
  if result="$(send_command -t 60 "$node" "$COMMANDS_DIR/check-node.sh")"; then
    name="$(result_value NODE_NAME "$result")"
  fi
  if [ -n "$name" ]; then
    NODE_NAMES+=("$name")
  else
    failed_nodes="$failed_nodes $node"
  fi
done
if [ -n "$failed_nodes" ]; then
  echo "사전 점검을 통과하지 못한 노드:$failed_nodes"
  exit 1
fi
duplicated_names="$(printf '%s\n' "${NODE_NAMES[@]}" | sort | uniq -d | tr '\n' ' ')"
if [ -n "$duplicated_names" ]; then
  echo "호스트명이 겹칩니다. k3s 는 노드마다 고유한 호스트명이 필요합니다: $duplicated_names"
  exit 1
fi

echo "=== [3/7] 마스터 노드 구성 ($MASTER_NODE) ==="
master_result="$(send_command "$MASTER_NODE" "$COMMANDS_DIR/config-master.sh" "$K3S_VERSION")"
K3S_URL="$(result_value K3S_URL "$master_result")"
K3S_TOKEN="$(result_value K3S_TOKEN "$master_result")"
K3S_VERSION="$(result_value K3S_VERSION "$master_result")"
if [ -z "$K3S_URL" ] || [ -z "$K3S_TOKEN" ] || [ -z "$K3S_VERSION" ]; then
  echo "마스터 구성 결과에서 K3S_URL, K3S_TOKEN, K3S_VERSION 을 읽지 못했습니다."
  exit 1
fi
export K3S_URL K3S_TOKEN K3S_VERSION
echo "K3S_URL=$K3S_URL"
echo "K3S_VERSION=$K3S_VERSION"
echo "K3S_TOKEN=(출력 생략)"

echo "=== [4/7] 워커 노드 구성 (${WORKERS[*]}) ==="
worker_pids=()
for node in "${WORKERS[@]}"; do
  send_command "$node" "$COMMANDS_DIR/config-worker.sh" "$K3S_URL" "$K3S_TOKEN" "$K3S_VERSION" &
  worker_pids+=("$!")
done
failed_nodes=""
for index in "${!WORKERS[@]}"; do
  if ! wait "${worker_pids[$index]}"; then
    failed_nodes="$failed_nodes ${WORKERS[$index]}"
  fi
done
if [ -n "$failed_nodes" ]; then
  echo "구성에 실패한 워커:$failed_nodes"
  exit 1
fi

echo "=== [5/7] 노드 등록 대기 ==="
# CNI 를 설치하기 전이라 노드는 NotReady 가 정상이다. 여기서는 클러스터에 등록됐는지만 본다.
wait_for_nodes registered "$NODE_REGISTER_TIMEOUT"

echo "=== [6/7] Cilium 설치 ==="
api_endpoint="${K3S_URL#https://}"
send_command "$MASTER_NODE" "$COMMANDS_DIR/config-cilium.sh" \
  "${api_endpoint%:*}" "${api_endpoint##*:}" "$CILIUM_VERSION"

echo "=== [7/7] 노드 Ready 대기·검증 ==="
wait_for_nodes ready "$NODE_READY_TIMEOUT"
send_command "$MASTER_NODE" "$COMMANDS_DIR/verify-cilium.sh"

echo ""
echo "=== 클러스터 구성 완료 ==="
echo "연결성 테스트(약 10분): $SCRIPT_DIR/send-command.sh -t 1800 $MASTER_NODE $COMMANDS_DIR/verify-cilium.sh --connectivity-test"
