#!/bin/bash
# 클러스터에 등록된 노드와 Ready 여부를 조회한다. 아무것도 변경하지 않는다.
# send-command.sh 로 전송되어 마스터 노드에서 root 로 실행된다.
#
# 사용법: get-nodes.sh
# 결과(stdout): 노드마다 한 줄 "<노드 이름> <Ready 조건: True | False | Unknown>"
set -euo pipefail

k3s kubectl get nodes --no-headers \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'
