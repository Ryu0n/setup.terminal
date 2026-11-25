#!/bin/bash
# 메모리 cgroup 을 켠다. k3s 는 메모리 cgroup 없이는 뜨지 못하는데 라즈베리파이는 기본값이 꺼짐이다. (노션 Phase 0)
# send-command.sh 로 전송되어 노드에서 root 로 실행된다. 다시 실행해도 안전하다.
#
# 이미 켜져 있으면 아무것도 바꾸지 않는다.
# 꺼져 있으면 부트 파티션의 cmdline.txt 에 커널 인자를 추가한다. 재부팅해야 적용된다.
#
# 사용법: config-cgroup.sh [REBOOT]
#   REBOOT  true 면 재부팅이 필요할 때 5초 뒤 재부팅하도록 예약한다. (기본 false)
#
# 결과(stdout): CGROUP=<enabled | reboot-scheduled | reboot-required>
set -euo pipefail
exec 3>&1 1>&2 # fd 3 = 결과(stdout). 그 외 출력은 모두 로그(stderr)

REBOOT="${1:-false}"

if [ "$(uname -s)" != "Linux" ] || [ "$(id -u)" -ne 0 ]; then
  echo "노드(Linux)에서 root 로 실행해야 합니다. send-command.sh 로 전송하세요."
  exit 1
fi

if grep -qsw memory /sys/fs/cgroup/cgroup.controllers \
  || [ "$(awk '$1 == "memory" { print $4 }' /proc/cgroups 2> /dev/null)" = "1" ]; then
  echo "메모리 cgroup 이 이미 켜져 있습니다."
  echo "CGROUP=enabled" >&3
  exit 0
fi

# 펌웨어가 읽는 커널 인자 파일을 찾는다.
# Ubuntu 25.10 부터는 부트 자산이 current/ 아래에 있고, 다음 부팅에 쓰일 new/ 와 되돌리기용 old/ 가 함께 있을 수 있다.
cmdline_files=()
for candidate in /boot/firmware/current/cmdline.txt /boot/firmware/new/cmdline.txt /boot/firmware/old/cmdline.txt; do
  if [ -f "$candidate" ]; then
    cmdline_files+=("$candidate")
  fi
done
if [ "${#cmdline_files[@]}" -eq 0 ]; then
  for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    if [ -f "$candidate" ]; then
      cmdline_files+=("$candidate")
      break
    fi
  done
fi
if [ "${#cmdline_files[@]}" -eq 0 ]; then
  echo "메모리 cgroup 이 꺼져 있는데 cmdline.txt 를 찾지 못했습니다. 이 장비의 부트로더 설정에서 직접 켜야 합니다."
  exit 1
fi

# 파일의 첫 줄(커널 인자)에 아직 없는 인자를 출력한다.
missing_flags() {
  local kernel_args flag
  IFS= read -r kernel_args < "$1" || true
  for flag in cgroup_memory=1 cgroup_enable=memory; do
    case " $kernel_args " in
      *" $flag "*) ;;
      *) printf ' %s' "$flag" ;;
    esac
  done
}

for cmdline_file in "${cmdline_files[@]}"; do
  flags="$(missing_flags "$cmdline_file")"
  if [ -z "$flags" ]; then
    echo "$cmdline_file: 커널 인자가 이미 들어 있습니다."
    continue
  fi
  # 펌웨어는 첫 줄만 읽으므로 첫 줄 끝에 덧붙인다. 원본은 처음 한 번만 백업한다.
  if [ ! -e "$cmdline_file.bak" ]; then
    cp "$cmdline_file" "$cmdline_file.bak"
  fi
  sed -i "1 s/[[:space:]]*\$/$flags/" "$cmdline_file"
  if [ -n "$(missing_flags "$cmdline_file")" ]; then
    echo "$cmdline_file 을 고치지 못했습니다. (원본: $cmdline_file.bak)"
    exit 1
  fi
  echo "$cmdline_file: 추가함$flags (원본: $cmdline_file.bak)"
done

if [ "$REBOOT" = true ]; then
  echo "메모리 cgroup 을 적용하려고 5초 뒤 재부팅합니다."
  # 이 명령이 정상 종료된 뒤에 내려가도록 예약만 해 둔다. (타이머 기본 정확도는 1분이라 1초로 좁힌다)
  systemd-run --quiet --on-active=5s --timer-property=AccuracySec=1s systemctl reboot
  echo "CGROUP=reboot-scheduled" >&3
else
  echo "재부팅해야 적용됩니다."
  echo "CGROUP=reboot-required" >&3
fi
