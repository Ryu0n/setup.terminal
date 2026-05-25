#!/bin/bash
set -e

echo "=== Oh My Zsh 설치 ==="

# Oh My Zsh 설치 (이미 설치되어 있으면 건너뜀)
if [ -d "$HOME/.oh-my-zsh" ]; then
  echo "Oh My Zsh가 이미 설치되어 있습니다. 건너뜁니다."
else
  echo "Oh My Zsh를 설치합니다..."
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

echo "=== 플러그인 설치 ==="

# zsh-syntax-highlighting (하이라이팅)
if [ -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
  echo "zsh-syntax-highlighting이 이미 설치되어 있습니다. 건너뜁니다."
else
  echo "zsh-syntax-highlighting을 설치합니다..."
  git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
fi

# zsh-autosuggestions (자동 완성)
if [ -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
  echo "zsh-autosuggestions이 이미 설치되어 있습니다. 건너뜁니다."
else
  echo "zsh-autosuggestions을 설치합니다..."
  git clone https://github.com/zsh-users/zsh-autosuggestions.git "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi

# kube-ps1 (쿠버네티스 프롬프트)
# kubectl 플러그인은 Oh My Zsh 내장이므로 별도 설치 불필요
if [ -d "$ZSH_CUSTOM/plugins/kube-ps1" ]; then
  echo "kube-ps1이 이미 설치되어 있습니다. 건너뜁니다."
else
  echo "kube-ps1을 설치합니다..."
  git clone https://github.com/jonmosco/kube-ps1.git "$ZSH_CUSTOM/plugins/kube-ps1"
fi

echo "=== agnoster 테마 및 프롬프트 커스터마이징 ==="

# .zshrc에서 테마를 agnoster로 변경
if grep -q '^ZSH_THEME=' "$ZSHRC"; then
  sed -i '' 's/^ZSH_THEME=.*/ZSH_THEME="agnoster"/' "$ZSHRC"
  echo "테마를 agnoster로 변경했습니다."
else
  echo 'ZSH_THEME="agnoster"' >> "$ZSHRC"
  echo "테마 설정을 .zshrc에 추가했습니다."
fi

# prompt_context 커스터마이징 (랜덤 이모지 프롬프트)
PROMPT_CUSTOM='
# Custom prompt_context (agnoster 테마 커스터마이징)
prompt_context() {
  if [[ "$USER" != "$DEFAULT_USER" || -n "$SSH_CLIENT" ]]; then
    prompt_segment black default "%(!.%{%F{yellow}%}.)$USER"
  fi
}

prompt_context() {
  # Custom (Random emoji)
  emojis=("⚡️" "🔥" "🐭" "🐳" "🌸" "🦁" "🍳" "🦄" "🌈" "🍻" "🍭" "💡" "🎉" "🍖" "🧁" "🌙")
  RAND_EMOJI_N=$(( $RANDOM % ${#emojis[@]} + 1))
  prompt_segment black default "shawn ${emojis[$RAND_EMOJI_N]} "
}'

if grep -q "# Custom prompt_context" "$ZSHRC"; then
  echo "prompt_context 커스터마이징이 이미 적용되어 있습니다."
else
  echo "$PROMPT_CUSTOM" >> "$ZSHRC"
  echo "prompt_context 커스터마이징을 .zshrc에 추가했습니다."
fi

echo "=== .zshrc 플러그인 설정 ==="

ZSHRC="$HOME/.zshrc"

if [ ! -f "$ZSHRC" ]; then
  echo ".zshrc 파일이 존재하지 않습니다."
  exit 1
fi

# plugins=(...) 라인에 플러그인 추가
if grep -q "^plugins=" "$ZSHRC"; then
  # 이미 플러그인이 포함되어 있는지 확인 후 교체
  current_plugins=$(grep "^plugins=" "$ZSHRC")
  ALL_PRESENT=true
  for p in zsh-syntax-highlighting zsh-autosuggestions kubectl kube-ps1; do
    if ! echo "$current_plugins" | grep -q "$p"; then
      ALL_PRESENT=false
      break
    fi
  done
  if [ "$ALL_PRESENT" = true ]; then
    echo "플러그인이 이미 .zshrc에 설정되어 있습니다."
  else
    sed -i '' 's/^plugins=(.*)$/plugins=(git zsh-syntax-highlighting zsh-autosuggestions kubectl kube-ps1)/' "$ZSHRC"
    echo "플러그인을 .zshrc에 업데이트했습니다."
  fi
else
  echo 'plugins=(git zsh-syntax-highlighting zsh-autosuggestions kubectl kube-ps1)' >> "$ZSHRC"
  echo "plugins 라인을 .zshrc에 새로 추가했습니다."
fi

echo ""
echo "=== 설치 완료 ==="
echo "터미널을 재시작하거나 'source ~/.zshrc'를 실행하세요."
