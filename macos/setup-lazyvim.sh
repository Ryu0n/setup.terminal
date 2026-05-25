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

# fd 설치 (venv-selector.nvim이 가상환경 검색에 필요)
if command -v fd &> /dev/null; then
  echo "fd가 이미 설치되어 있습니다."
else
  echo "fd를 설치합니다 (venv-selector 의존성)..."
  brew install fd
fi

# Anaconda 가상환경 인식을 위한 venv-selector 설정
echo "=== venv-selector Anaconda 설정 ==="

VENV_SELECTOR_CONFIG="$NVIM_CONFIG/lua/plugins/venv-selector.lua"

# Anaconda 설치 경로 자동 감지
ANACONDA_BASE=""
for candidate in "/opt/anaconda3" "$HOME/anaconda3" "$HOME/miniconda3" "$HOME/miniforge3" "$HOME/mambaforge"; do
  if [ -d "$candidate" ]; then
    ANACONDA_BASE="$candidate"
    break
  fi
done

if [ -n "$ANACONDA_BASE" ]; then
  # __ANACONDA__ 플레이스홀더를 사용해 경로 치환
  sed "s|__ANACONDA__|$ANACONDA_BASE|g" > "$VENV_SELECTOR_CONFIG" << 'LUAEOF'
return {
  "linux-cultist/venv-selector.nvim",
  opts = {
    search = {
      anaconda_envs = {
        command = "$FD 'bin/python$' __ANACONDA__/envs --no-ignore-vcs --full-path --color never",
        type = "anaconda",
      },
      anaconda_base = {
        command = "$FD '/python$' __ANACONDA__/bin --full-path --color never",
        type = "anaconda",
      },
    },
  },
}
LUAEOF
  echo "Anaconda 경로를 감지했습니다: $ANACONDA_BASE"
  echo "venv-selector 설정을 추가했습니다."
else
  echo "Anaconda 설치를 찾지 못했습니다. venv-selector 설정을 건너뜁니다."
fi

echo ""
echo "=== LazyVim 설치 완료 ==="
echo "nvim을 실행하면 플러그인이 자동으로 설치됩니다."
