#!/usr/bin/env bash
set -euo pipefail

# =========================
# Utility / logging
# =========================
log() { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*" >&2; }
err() { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || return 1; }

SUDO="sudo"
if [ "$(id -u)" -eq 0 ]; then SUDO=""; fi

# =========================
# General Utility
# =========================
detect_distro() {
  local kernel
  kernel="$(uname -s 2>/dev/null || true)"

  case "$kernel" in
  Darwin) echo "macos"; return 0 ;;
  Linux) ;;
  *) echo "unknown"; return 0 ;;
  esac

  if [ -r /etc/os-release ]; then
    . /etc/os-release
    local distro_id distro_like
    distro_id="$(printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')"
    distro_like="$(printf '%s' "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"

    case "$distro_id" in
    arch | artix | endeavouros | manjaro) echo "arch" ;;
    ubuntu | debian | pop | linuxmint) echo "ubuntu" ;; # treat Debian-likes as ubuntu path
    *)
      case " $distro_like " in
      *" arch "*) echo "arch" ;;
      *" debian "* | *" ubuntu "*) echo "ubuntu" ;;
      *) echo "unknown" ;;
      esac
      ;;
    esac
  else
    echo "unknown"
  fi
}

DISTRO="$(detect_distro)"
if [ "$DISTRO" = "unknown" ]; then
  warn "Unknown distro. Script supports Arch and Ubuntu-like. Continuing may fail."
fi

pkg_update() {
  case "$DISTRO" in
  arch) $SUDO pacman -Sy --noconfirm ;;
  ubuntu) $SUDO apt-get update -y ;;
  macos)
    if ! need brew; then
      err "Homebrew is required on macOS: https://brew.sh"
      return 1
    fi
    brew update
    ;;
  *) warn "Skipping pkg update (unknown distro)" ;;
  esac
}

pkg_install() {
  local pkgs=("$@")
  local missing_pkgs=()

  if [ "${#pkgs[@]}" -eq 0 ]; then
    return 0
  fi

  case "$DISTRO" in
  arch)
    if [ "$REINSTALL" -eq 1 ]; then
      $SUDO pacman -S --noconfirm "${pkgs[@]}"
      return 0
    fi
    for pkg in "${pkgs[@]}"; do
      pacman -Q "$pkg" >/dev/null 2>&1 || missing_pkgs+=("$pkg")
    done
    if [ "${#missing_pkgs[@]}" -eq 0 ]; then
      log "Packages already installed: ${pkgs[*]}"
      return 0
    fi
    $SUDO pacman -S --needed --noconfirm "${missing_pkgs[@]}"
    ;;
  ubuntu)
    if [ "$REINSTALL" -eq 1 ]; then
      $SUDO apt-get install -y --reinstall "${pkgs[@]}"
      return 0
    fi
    for pkg in "${pkgs[@]}"; do
      dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || missing_pkgs+=("$pkg")
    done
    if [ "${#missing_pkgs[@]}" -eq 0 ]; then
      log "Packages already installed: ${pkgs[*]}"
      return 0
    fi
    $SUDO apt-get install -y "${missing_pkgs[@]}"
    ;;
  macos)
    if ! need brew; then
      err "Homebrew is required on macOS: https://brew.sh"
      return 1
    fi
    if [ "$REINSTALL" -eq 1 ]; then
      for pkg in "${pkgs[@]}"; do
        if brew list "$pkg" >/dev/null 2>&1; then
          brew reinstall "$pkg"
        else
          brew install "$pkg"
        fi
      done
      return 0
    fi
    for pkg in "${pkgs[@]}"; do
      brew list "$pkg" >/dev/null 2>&1 || missing_pkgs+=("$pkg")
    done
    if [ "${#missing_pkgs[@]}" -eq 0 ]; then
      log "Packages already installed: ${pkgs[*]}"
      return 0
    fi
    brew install "${missing_pkgs[@]}"
    ;;
  *) warn "Cannot install packages on unknown distro: ${pkgs[*]}" ;;
  esac
}

add_alias() {
  local name="$1"
  local value="$2"
  local file="$HOME/.bashrc"

  # Check if alias name exists at all (regardless of value)
  local existing
  existing=$(grep -E "^alias $name=" "$file" || true)

  if [ -n "$existing" ]; then
    log "Alias '$name' already exists:"
    log "  $existing"
    return 0
  fi

  # If no alias exists yet, append it
  echo "alias $name=\"$value\"" >>"$file"
  log "Added alias $name → \"$value\""
}

add_function() {
  local func_name="$1"
  local file="$HOME/.bashrc"

  # If function already exists, skip
  if grep -Eq "^${func_name}\s*\(\)" "$file"; then
    log "Function '$func_name' already exists in .bashrc"
    return 0
  fi

  log "Adding function '$func_name' to .bashrc"

  {
    echo ""
    echo "# --- Added by setup script ---"
    echo "${func_name}() {"
    shift
    printf '  %s\n' "$@"
    echo "}"
    echo "# --- End of $func_name ---"
  } >>"$file"
}

# git_sync_repo <repo_url> <target_dir> [branch]
git_sync_repo() {
  local repo_url="$1"
  local target_dir="$2"
  local branch="${3:-}"

  if [ -z "${repo_url-}" ] || [ -z "${target_dir-}" ]; then
    log "Usage: git_sync_repo <repo_url> <target_dir> [branch]" >&2
    return 2
  fi

  # CASE 1: target does not exist -> clone
  if [ ! -d "$target_dir" ]; then
    if [ -n "$branch" ]; then
      git clone -b "$branch" --single-branch "$repo_url" "$target_dir"
    else
      git clone "$repo_url" "$target_dir"
    fi
    return
  fi

  # CASE 2: target exists but is not a git repo
  if [ ! -d "$target_dir/.git" ]; then
    warn "Target exists but is not a git repo: $target_dir" >&2
    return 1
  fi

  # CASE 3: target is a git repo -> verify remote and update
  local current_remote
  current_remote="$(git -C "$target_dir" config --get remote.origin.url || true)"

  if [ "$current_remote" != "$repo_url" ]; then
    warn "Remote URL mismatch in $target_dir" >&2
    warn "  expected: $repo_url" >&2
    warn "  found:    $current_remote" >&2
    return 1
  fi

  # Fetch and update
  git -C "$target_dir" fetch --all --prune

  if [ -n "$branch" ]; then
    # ensure we are on the desired branch, then hard-reset to origin/<branch>
    git -C "$target_dir" checkout "$branch"
    git -C "$target_dir" reset --hard "origin/$branch"
  else
    # no branch specified: fast-forward current branch
    git -C "$target_dir" pull --ff-only
  fi
}

backup() {
  local src="$1"

  if [ ! -e "$src" ]; then
    log "File not found, skipping: $src"
    return 0
  fi

  local ts
  ts=$(date +"%Y%m%d-%H%M%S")

  local dest="${src}.${ts}.bak"

  mv "$src" "$dest"
  log "Backed up $src → $dest"

  # return the backup name for callers to use
  BACKUP_DEST="$dest"
  log "Backed up $src to $dest."
}

append_bashrc() {
  local line="$1"
  local file="$HOME/.bashrc"

  # Check if the line already exists (exact match)
  if grep -Fxq "$line" "$file"; then
    log "Line already exists in .bashrc:"
    log "  $line"
    return 0
  fi

  # Append the line
  echo "$line" >>"$file"
  log "Added line to .bashrc:"
  log "  $line"
}

ensure_basics_neovim() {
  local needed_pkgs=()
  need curl || needed_pkgs+=("curl")
  need tar || needed_pkgs+=("tar")
  if [ "${#needed_pkgs[@]}" -gt 0 ]; then
    log "Installing prerequisites: ${needed_pkgs[*]}"
    pkg_update
    pkg_install "${needed_pkgs[@]}"
  fi
}

python_venv_works() {
  local venv_dir
  venv_dir="$(mktemp -d)"
  if python3 -m venv "$venv_dir" >/dev/null 2>&1; then
    rm -rf "$venv_dir"
    return 0
  fi
  rm -rf "$venv_dir"
  return 1
}

ensure_basics_lazyvim() {
  local needed_pkgs=()
  local python_version

  case "$DISTRO" in
  arch)
    need git || needed_pkgs+=("git")
    need curl || needed_pkgs+=("curl")
    need unzip || needed_pkgs+=("unzip")
    need tar || needed_pkgs+=("tar")
    need gzip || needed_pkgs+=("gzip")
    need python3 || needed_pkgs+=("python")
    python3 -m pip --version >/dev/null 2>&1 || needed_pkgs+=("python-pip")
    need node || needed_pkgs+=("nodejs")
    need npm || needed_pkgs+=("npm")
    ;;
  ubuntu)
    need git || needed_pkgs+=("git")
    need curl || needed_pkgs+=("curl")
    need unzip || needed_pkgs+=("unzip")
    need tar || needed_pkgs+=("tar")
    need gzip || needed_pkgs+=("gzip")
    need python3 || needed_pkgs+=("python3")
    python3 -m pip --version >/dev/null 2>&1 || needed_pkgs+=("python3-pip")
    if ! python_venv_works; then
      needed_pkgs+=("python3-venv")
      python_version="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))' 2>/dev/null || true)"
      if [ -n "$python_version" ]; then
        needed_pkgs+=("python${python_version}-venv")
      fi
    fi
    need node || needed_pkgs+=("nodejs")
    need npm || needed_pkgs+=("npm")
    ;;
  macos)
    need git || needed_pkgs+=("git")
    need curl || needed_pkgs+=("curl")
    need unzip || needed_pkgs+=("unzip")
    need python3 || needed_pkgs+=("python")
    if ! need node || ! need npm; then
      needed_pkgs+=("node")
    fi
    ;;
  *)
    warn "Skipping LazyVim prerequisite installation (unknown distro)."
    return 0
    ;;
  esac

  if [ "${#needed_pkgs[@]}" -gt 0 ]; then
    log "Installing LazyVim/Mason prerequisites: ${needed_pkgs[*]}"
    pkg_update
    pkg_install "${needed_pkgs[@]}"
  fi
}

install_neovim_tar() {
  if need nvim && [ "$REINSTALL" -eq 0 ]; then
    log "Neovim already installed: $(nvim --version | head -n 1)"
    add_alias n nvim
    return 0
  fi
  if need nvim; then
    log "Reinstalling Neovim: $(nvim --version | head -n 1)"
  fi

  if [ "$DISTRO" = "macos" ]; then
    local machine
    machine="$(uname -m)"
    case "$machine" in
    arm64 | aarch64)
      local url="https://github.com/neovim/neovim/releases/download/nightly/nvim-macos-arm64.tar.gz"
      local tarball="/tmp/nvim-macos-arm64.tar.gz"
      local opt_dir="/opt/nvim-macos-arm64"
      ;;
    x86_64)
      local url="https://github.com/neovim/neovim/releases/download/nightly/nvim-macos-x86_64.tar.gz"
      local tarball="/tmp/nvim-macos-x86_64.tar.gz"
      local opt_dir="/opt/nvim-macos-x86_64"
      ;;
    *)
      err "Unsupported macOS architecture: $machine"
      exit 1
      ;;
    esac
  else
    # https://github.com/neovim/neovim/blob/master/INSTALL.md#pre-built-archives-2
    local url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz"
    local tarball="/tmp/nvim-linux-x86_64.tar.gz"
    local opt_dir="/opt/nvim-linux-x86_64"
  fi
  local bin_dir="$opt_dir/bin"
  local target="$bin_dir/nvim"
  local symlink="/usr/local/bin/nvim"

  ensure_basics_neovim

  log "Downloading Neovim tarball..."
  curl -L -o "$tarball" "$url"

  log "Removing previous Neovim at $opt_dir (if any)..."
  $SUDO rm -rf "$opt_dir"

  log "Extracting to /opt..."
  $SUDO tar -C /opt -xzf "$tarball"

  log "Remove now redundant tarball."
  rm "$tarball"

  if [ ! -x "$target" ]; then
    err "nvim binary not found at $target after extract"
    exit 1
  fi

  # Prefer a stable CLI path via /usr/local/bin
  if [ -L "$symlink" ] || [ -e "$symlink" ]; then
    log "Updating existing symlink $symlink -> $target"
    $SUDO rm -f "$symlink"
  fi
  log "Linking $symlink -> $target"
  $SUDO ln -s "$target" "$symlink"

  # Fallback PATH method for environments without /usr/local/bin in PATH
  if ! printf '%s\n' "$PATH" | grep -qE '(^|:)/usr/local/bin(:|$)'; then
    warn "/usr/local/bin not in PATH. Adding profile.d fallback."
    local prof="/etc/profile.d/nvim_path.sh"
    echo 'export PATH="/usr/local/bin:$PATH"' | $SUDO tee "$prof" >/dev/null
    $SUDO chmod 644 "$prof"
  fi

  # Verify
  if need nvim; then
    log "Neovim installed: $(nvim --version | head -n 1)"
  else
    warn "nvim not on PATH for current shell. You may need to re-login or source your profile."
    warn "As a last resort, add to your shell rc: export PATH=\"\$PATH:$bin_dir\""
  fi
  append_bashrc "export PATH=\"\$PATH:$bin_dir\""
  add_alias n nvim
}

install_lazyvim() {
  # See https://www.lazyvim.org/installation

  if ! need nvim; then
    err "neovim could not be found! Required to install lazyvim!"
    exit 1
  fi

  ensure_basics_lazyvim

  if [ -d "$HOME/.config/nvim" ] && [ "$REINSTALL" -eq 0 ]; then
    warn "Neovim config already exists at ~/.config/nvim. Skipping LazyVim setup."
    warn "Move or remove that directory before running --lazyvim if you want to replace it."
    configure_lazyvim_python
    sync_lazyvim_plugins
    return 0
  fi

  # backup of current config
  ## required
  log "Backing up neovim configs."
  backup ~/.config/nvim
  ## optional but recommended
  backup ~/.local/share/nvim
  backup ~/.local/state/nvim
  backup ~/.cache/nvim
  log "Setting up LazyVim configs."
  git_sync_repo https://github.com/LazyVim/starter ~/.config/nvim
  rm -rf ~/.config/nvim/.git
  configure_lazyvim_python
  sync_lazyvim_plugins
}

sync_lazyvim_plugins() {
  local nvim_config="$HOME/.config/nvim"
  local lazy_file="$nvim_config/lua/config/lazy.lua"

  if [ ! -f "$lazy_file" ] || ! grep -Fq 'LazyVim/LazyVim' "$lazy_file"; then
    warn "$nvim_config does not look like a LazyVim config. Skipping plugin sync."
    return 0
  fi

  log "Installing LazyVim plugins with lazy.nvim."
  nvim --headless "+Lazy! sync" +qa
}

configure_lazyvim_python() {
  local nvim_config="$HOME/.config/nvim"
  local lazy_file="$nvim_config/lua/config/lazy.lua"
  local plugin_file="$nvim_config/lua/plugins/lazyvim-python.lua"
  local options_file="$nvim_config/lua/config/options.lua"

  if [ ! -d "$nvim_config" ]; then
    warn "LazyVim config not found at $nvim_config. Skipping Python LSP setup."
    return 0
  fi
  if [ ! -f "$lazy_file" ] || ! grep -Fq 'LazyVim/LazyVim' "$lazy_file"; then
    warn "$nvim_config does not look like a LazyVim config. Skipping Python LSP setup."
    return 0
  fi

  ensure_lazyvim_extra_import "$lazy_file" "lazyvim.plugins.extras.lang.python"

  if [ -f "$plugin_file" ] && grep -Fq 'lazyvim.plugins.extras.lang.python' "$plugin_file"; then
    rm -f "$plugin_file"
    log "Removed old Python extra import from $plugin_file."
  elif [ -f "$plugin_file" ]; then
    warn "$plugin_file already exists but is not the generated Python extra file. Leaving it unchanged."
  fi

  if [ -f "$options_file" ]; then
    if ! grep -Fxq 'vim.g.lazyvim_python_lsp = "pyright"' "$options_file"; then
      echo "" >>"$options_file"
      echo "-- Python language tooling" >>"$options_file"
      echo 'vim.g.lazyvim_python_lsp = "pyright"' >>"$options_file"
      log "Configured LazyVim to use pyright for Python."
    else
      log "LazyVim Python LSP options already configured."
    fi
    if ! grep -Fxq 'vim.g.lazyvim_python_ruff = "ruff"' "$options_file"; then
      echo 'vim.g.lazyvim_python_ruff = "ruff"' >>"$options_file"
      log "Configured LazyVim to use ruff for Python linting and formatting."
    fi
  else
    warn "Options file not found at $options_file. Python extra will use LazyVim defaults."
  fi
}

ensure_lazyvim_extra_import() {
  local lazy_file="$1"
  local import_name="$2"
  local tmp_file

  if grep -Fq "$import_name" "$lazy_file"; then
    log "LazyVim extra already enabled in $lazy_file: $import_name"
    return 0
  fi

  tmp_file="$(mktemp)"
  if awk -v import_name="$import_name" '
    {
      print
      if (index($0, "\"LazyVim/LazyVim\"") && index($0, "import = \"lazyvim.plugins\"")) {
        print "    { import = \"" import_name "\" },"
        inserted = 1
      }
    }
    END {
      if (!inserted) {
        exit 42
      }
    }
  ' "$lazy_file" >"$tmp_file"; then
    mv "$tmp_file" "$lazy_file"
    log "Enabled LazyVim extra in $lazy_file: $import_name"
  else
    rm -f "$tmp_file"
    warn "Could not insert $import_name into $lazy_file. Enable it with :LazyExtras."
  fi
}

install_fzf() {
  if [ -d "${HOME}/.fzf" ] && [ "$REINSTALL" -eq 0 ]; then
    warn "fzf already installed. Remove ~/.fzf to re-install!"
    return 0
  fi
  git_sync_repo https://github.com/junegunn/fzf.git ~/.fzf
  ~/.fzf/install
  log "Installed fzf."
}

install_zoxide() {
  if { need zoxide || [ -x "$HOME/.local/bin/zoxide" ]; } && [ "$REINSTALL" -eq 0 ]; then
    log "zoxide already installed."
    append_bashrc 'eval "$(zoxide init bash)"'
    add_alias cd z
    return 0
  fi

  # https://github.com/ajeetdsouza/zoxide?tab=readme-ov-file#installation
  append_bashrc 'export PATH="$PATH:$HOME/.local/bin"'
  curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
  log "Installed zoxide."
  ~/.local/bin/zoxide init --cmd cd bash
  append_bashrc 'eval "$(zoxide init bash)"'
  add_alias cd z
}

install_essentials() {
  case "$DISTRO" in
  arch) pkg_install base-devel ;;
  ubuntu) pkg_update && pkg_install build-essential ;;
  macos) pkg_install gcc make ;;
  *) warn "Skipping pkg update (unknown distro)" ;;
  esac
}

install_rust() {
  if need cargo && [ "$REINSTALL" -eq 0 ]; then
    log "Rust/Cargo already installed."
    return 0
  fi
  if need rustup; then
    log "Updating Rust toolchain."
    rustup update
    return 0
  fi

  install_essentials
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
}

install_ripgrep() {
  if need rg && [ "$REINSTALL" -eq 0 ]; then
    log "ripgrep already installed."
    return 0
  fi

  install_rust
  git_sync_repo https://github.com/BurntSushi/ripgrep ~/.rg
  cd ~/.rg && . "$HOME/.cargo/env" && cargo build --release
  path_installation=${HOME}/.rg/target/release/
  append_bashrc "export PATH=\"\$PATH:${path_installation}\""
  log "Installed ripgrep ('rg')."
}

install_eza_theme() {
  git_sync_repo https://github.com/eza-community/eza-themes.git ~/.eza-themes
  mkdir -p ~/.config/eza
  ln -sf "${HOME}/.eza-themes/themes/frosty.yml" ~/.config/eza/theme.yml
}

install_eza() {
  if need eza && [ "$REINSTALL" -eq 0 ]; then
    log "eza already installed."
    add_alias ls 'eza -lh --group-directories-first --icons=auto'
    add_alias lt 'eza --tree --level=2 --long --icons --git'
    install_eza_theme
    return 0
  fi

  install_rust
  cargo install eza --force
  add_alias ls 'eza -lh --group-directories-first --icons=auto'
  add_alias lt 'eza --tree --level=2 --long --icons --git'
  log "Installed eza (try 'ls', 'lt')."
  install_eza_theme
  log "Installed eza theme."
}

install_fd() {
  if need fd && [ "$REINSTALL" -eq 0 ]; then
    log "fd already installed."
    return 0
  fi

  install_rust
  cargo install fd-find --force
  log "Installed 'fd'."
}

install_tmux() {
  if need tmux && [ "$REINSTALL" -eq 0 ]; then
    log "tmux already installed."
    return 0
  fi

  pkg_update
  pkg_install tmux
  log "Installed tmux."
}

install_starship() {
  if need starship && [ "$REINSTALL" -eq 0 ]; then
    log "starship already installed."
    append_bashrc 'eval "$(starship init bash)"'
    return 0
  fi

  curl -sS https://starship.rs/install.sh | sh -s -- -y
  append_bashrc 'eval "$(starship init bash)"'
}

install_uv() {
  if need uv && [ "$REINSTALL" -eq 0 ]; then
    log "uv already installed."
    return 0
  fi

  curl -LsSf https://astral.sh/uv/install.sh | sh
}

install_ollama() {
  if need ollama && [ "$REINSTALL" -eq 0 ]; then
    log "ollama already installed."
    return 0
  fi

  if [ "$DISTRO" = "macos" ]; then
    echo Install App from Website https://ollama.com/download !
  else
    pkg_update
    pkg_install zstd
    curl -fsSL https://ollama.com/install.sh | sh
  fi  
}

add_misc_to_bashrc() {
  add_alias s "git status"
  add_alias b "git branch"
  add_alias d "git diff"
  add_function add_alias \
    'if [ "$#" -lt 2 ]; then' \
    '  echo "Usage: add_alias <name> <value>"' \
    '  return 1' \
    'fi' \
    'local name="$1"' \
    'local value="$2"' \
    'local file="$HOME/.bashrc"' \
    '' \
    '# Check if alias already exists' \
    'if grep -Fxq "alias $name=\"$value\"" "$file"; then' \
    '  echo "Alias $name already exists"' \
    '  return 0' \
    'fi' \
    '' \
    'echo "alias $name=\"$value\"" >> "$file"' \
    'echo "Added alias $name"'
}

# =========================
# Extensible task runner
# =========================
usage() {
  cat <<EOF
Usage: $0 [--all] [<App>] [--reinstall] [--dry-run]

Options:
  --all        Run all setup steps (default when no app flag is given).
  --reinstall  Reinstall selected apps even when they are already present.
  --dry-run    Show what would run, without executing (best effort).
  Apps (pick any or --all)
    --neovim    Install Neovim (from tarball into /opt, create /usr/local/bin symlink).
    --lazyvim   Install LazyVim (backups current neovim config files, before setting up lazyvim).
    --fzf       Install fzf (fuzzy find for files).
    --zoxide    Replace cd with zoxide, which remembers visited paths.
    --rg        Install ripgrep for faster grep experience.
    --eza       Install eza for more powerful ls capabilities.
    --fd        Install fd for faster find.
    --tmux      Install tmux terminal multiplexer.
    --starship  Install starship for custom user prompts.
    --uv        Install uv to manage python environments.
    --ollama    Install ollama to run local LLMs.
    -h, --help  Show this help.
EOF
}

DRY_RUN=0
REINSTALL=0
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "[DRY] %s\n" "$*"
  else
    eval "$@"
  fi
}

main() {
  local do_all=0 do_neovim=0 do_lazyvim=0 do_fzf=0 do_zoxide=0 do_rg=0 do_eza=0 do_fd=0 do_tmux=0 do_starship=0 do_uv=0 do_ollama=0
  local selected_count=0

  while [ $# -gt 0 ]; do
    case "$1" in
    --all) do_all=1; selected_count=$((selected_count + 1)) ;;
    --neovim) do_neovim=1; selected_count=$((selected_count + 1)) ;;
    --lazyvim) do_lazyvim=1; selected_count=$((selected_count + 1)) ;;
    --fzf) do_fzf=1; selected_count=$((selected_count + 1)) ;;
    --zoxide) do_zoxide=1; selected_count=$((selected_count + 1)) ;;
    --rg) do_rg=1; selected_count=$((selected_count + 1)) ;;
    --eza) do_eza=1; selected_count=$((selected_count + 1)) ;;
    --fd) do_fd=1; selected_count=$((selected_count + 1)) ;;
    --tmux) do_tmux=1; selected_count=$((selected_count + 1)) ;;
    --starship) do_starship=1; selected_count=$((selected_count + 1)) ;;
    --uv) do_uv=1; selected_count=$((selected_count + 1)) ;;
    --ollama) do_ollama=1; selected_count=$((selected_count + 1)) ;;
    --reinstall) REINSTALL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      err "Unknown arg: $1"
      usage
      exit 2
      ;;
    esac
    shift
  done

  if [ "$selected_count" -eq 0 ]; then
    do_all=1
  fi

  log "Detected distro: $DISTRO"
  trap 'err "Script failed at line $LINENO"; exit 1' ERR

  maybe_run_feature() {
    local feature_name="$1"
    local enabled_flag="$2"
    local feature_cmd="$3"
    local flag_name="do_${feature_name}"

    log "Checking feature: $feature_name"
    log "do_all: $do_all, ${flag_name}: $enabled_flag"
    if [ "$do_all" -eq 1 ] || [ "$enabled_flag" -eq 1 ]; then
      log "Running feature: $feature_cmd"
      run "$feature_cmd"
    fi
  }

  maybe_run_feature "neovim" "$do_neovim" "install_neovim_tar"
  maybe_run_feature "lazyvim" "$do_lazyvim" "install_lazyvim"
  maybe_run_feature "fzf" "$do_fzf" "install_fzf"
  maybe_run_feature "zoxide" "$do_zoxide" "install_zoxide"
  maybe_run_feature "rg" "$do_rg" "install_ripgrep"
  maybe_run_feature "eza" "$do_eza" "install_eza"
  maybe_run_feature "fd" "$do_fd" "install_fd"
  maybe_run_feature "tmux" "$do_tmux" "install_tmux"
  maybe_run_feature "starship" "$do_starship" "install_starship"
  maybe_run_feature "uv" "$do_uv" "install_uv"
  maybe_run_feature "ollama" "$do_ollama" "install_ollama"

  run add_misc_to_bashrc

  log 'Open a new terminal (or exec "$SHELL") to make sure setup complete!'
  log "Done."
}

main "$@"
