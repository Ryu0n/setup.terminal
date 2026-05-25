#!/bin/bash
set -e

echo "=== LazyVim 설치 ==="

# Neovim 설치
if command -v nvim &> /dev/null; then
  echo "Neovim이 이미 설치되어 있습니다. ($(nvim --version | head -1))"
else
  echo "Neovim을 설치합니다..."
  brew install neovim
fi

# 기존 Neovim 설정 백업
NVIM_CONFIG="$HOME/.config/nvim"
NVIM_SHARE="$HOME/.local/share/nvim"
NVIM_STATE="$HOME/.local/state/nvim"
NVIM_CACHE="$HOME/.cache/nvim"

if [ -d "$NVIM_CONFIG" ]; then
  BACKUP="$NVIM_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  echo "기존 Neovim 설정을 백업합니다: $BACKUP"
  mv "$NVIM_CONFIG" "$BACKUP"
fi

if [ -d "$NVIM_SHARE" ]; then
  mv "$NVIM_SHARE" "$NVIM_SHARE.bak.$(date +%Y%m%d%H%M%S)"
fi

if [ -d "$NVIM_STATE" ]; then
  mv "$NVIM_STATE" "$NVIM_STATE.bak.$(date +%Y%m%d%H%M%S)"
fi

if [ -d "$NVIM_CACHE" ]; then
  mv "$NVIM_CACHE" "$NVIM_CACHE.bak.$(date +%Y%m%d%H%M%S)"
fi

# LazyVim starter 클론
echo "LazyVim starter를 설치합니다..."
git clone https://github.com/LazyVim/starter "$NVIM_CONFIG"

# starter의 .git 제거 (사용자가 자체적으로 버전 관리할 수 있도록)
rm -rf "$NVIM_CONFIG/.git"

# Anaconda 가상환경 인식을 위한 venv-selector 설정
echo "=== venv-selector Anaconda 설정 ==="

VENV_SELECTOR_CONFIG="$NVIM_CONFIG/lua/plugins/venv-selector.lua"

# Anaconda 설치 경로 자동 감지
ANACONDA_BASE=""
for candidate in "$HOME/anaconda3" "$HOME/miniconda3" "$HOME/miniforge3" "$HOME/mambaforge"; do
  if [ -d "$candidate" ]; then
    ANACONDA_BASE="$candidate"
    break
  fi
done

if [ -n "$ANACONDA_BASE" ]; then
  cat > "$VENV_SELECTOR_CONFIG" << EOF
return {
  "linux-cultist/venv-selector.nvim",
  opts = {
    anaconda_base_path = "$ANACONDA_BASE",
    anaconda_envs_path = "$ANACONDA_BASE/envs",
  },
}
EOF
  echo "Anaconda 경로를 감지했습니다: $ANACONDA_BASE"
  echo "venv-selector 설정을 추가했습니다."
else
  echo "Anaconda 설치를 찾지 못했습니다. venv-selector 설정을 건너뜁니다."
fi

echo ""
echo "=== LazyVim 설치 완료 ==="
echo "nvim을 실행하면 플러그인이 자동으로 설치됩니다."
