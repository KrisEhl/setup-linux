#!/usr/bin/en
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
# Distro detection
# =========================
detect_distro() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID,,}" in
    arch | artix | endeavouros | manjaro) echo "arch" ;;
    ubuntu | debian | pop | linuxmint) echo "ubuntu" ;; # treat Debian-likes as ubuntu path
    *) echo "unknown" ;;
    esac
  else
    echo "unknown"
  fi
}

DISTRO="$(detect_distro)"
if [ "$DISTRO" = "unknown" ]; then
  warn "Unknown distro. Script supports Arch and Ubuntu-like. Continuing may fail."
fi

# =========================
# Package manager helpers
# =========================
pkg_update() {
  case "$DISTRO" in
  arch) $SUDO pacman -Sy --noconfirm ;;
  ubuntu) $SUDO apt-get update -y ;;
  *) warn "Skipping pkg update (unknown distro)" ;;
  esac
}

pkg_install() {
  local pkgs=("$@")
  case "$DISTRO" in
  arch) $SUDO pacman -S --needed --noconfirm "${pkgs[@]}" ;;
  ubuntu) $SUDO apt-get install -y "${pkgs[@]}" ;;
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
    echo "Function '$func_name' already exists in .bashrc"
    return 0
  fi

  echo "Adding function '$func_name' to .bashrc"

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

backup() {
  local src="$1"

  if [ ! -e "$src" ]; then
    log "File not found, skipping: $src"
    return 1
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

# =========================
# Neovim install (tarball)
# https://github.com/neovim/neovim/blob/master/INSTALL.md#pre-built-archives-2
# =========================
install_neovim_tar() {
  local url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz"
  local tarball="/tmp/nvim-linux-x86_64.tar.gz"
  local opt_dir="/opt/nvim-linux-x86_64"
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
  if ! log "$PATH" | grep -qE '(^|:)/usr/local/bin(:|$)'; then
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
  append_bashrc 'export PATH="$PATH:/opt/nvim-linux-x86_64/bin"'
  add_alias n nvim
}

install_lazyvim() {
  # See https://www.lazyvim.org/installation

  if ! need nvim; then
    err "neovim couldn't be found! Required to install lazyvim!"
    exit 1
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
  git clone https://github.com/LazyVim/starter ~/.config/nvim
  rm -rf ~/.config/nvim/.git
}

install_fzf() {
  if [ -d "${HOME}/.fzf" ]; then
    warn "fzf already installed. Remove ~/.fzf to re-install!"
    return 0
  fi
  git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
  ~/.fzf/install
  log "Installed fzf."
}

install_zoxide() {
  # https://github.com/ajeetdsouza/zoxide?tab=readme-ov-file#installation
  append_bashrc 'export PATH=$PATH:/home/kristian/.local/bin'
  curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
  log "Installed zoxide."
  ~/.local/bin/zoxide init --cmd cd bash
  append_bashrc 'eval "$(zoxide init bash)"'
}

install_essentials() {
  case "$DISTRO" in
  arch) $sudo pacman -S --needed --noconfirm base-devel ;;
  ubuntu) $SUDO apt-get update -y && sudo apt install -y build-essential ;;
  *) warn "Skipping pkg update (unknown distro)" ;;
  esac
}

install_rust() {
  install_essentials
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
}

install_ripgrep() {
  install_rust
  git clone https://github.com/BurntSushi/ripgrep ~/.rg
  cd ~/.rg && . "$HOME/.cargo/env" && cargo build --release
  path_installation=${HOME}/.rg/target/release/
  append_bashrc "export PATH=\"\$PATH:${path_installation}\""
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
Usage: $0 [--all] [<App>] [--dry-run]

Options:
  --all       Run all setup steps.
  --dry-run   Show what would run, without executing (best effort).
  Apps (pick any or --all)
    --neovim    Install Neovim (from tarball into /opt, create /usr/local/bin symlink).
    --lazyvim   Install LazyVim (backups current neovim config files, before setting up lazyvim).
    --fzf       Install fzf (fuzzy find for files).
    --zoxide    Replace cd with zoxide, which remembers visited paths.
    --rg        Install ripgrep for faster grep experience.
    -h, --help  Show this help.
EOF
}

DRY_RUN=0
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "[DRY] %s\n" "$*"
  else
    eval "$@"
  fi
}

main() {
  local do_all=0 do_neovim=0 do_lazyvim=0 do_fzf=0 do_zoxide=0 do_rg=0

  while [ $# -gt 0 ]; do
    case "$1" in
    --all) do_all=1 ;;
    --neovim) do_neovim=1 ;;
    --lazyvim) do_lazyvim=1 ;;
    --fzf) do_fzf=1 ;;
    --zoxide) do_zoxide=1 ;;
    --rg) do_rg=1 ;;
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

  log "Detected distro: $DISTRO"
  trap 'err "Script failed at line $LINENO"; exit 1' ERR

  if [ "$do_all" -eq 1 ] || [ "$do_neovim" -eq 1 ]; then
    run install_neovim_tar
  fi

  if [ "$do_all" -eq 1 ] || [ "$do_lazyvim" -eq 1 ]; then
    run install_lazyvim
  fi

  if [ "$do_all" -eq 1 ] || [ "$do_fzf" -eq 1 ]; then
    run install_fzf
  fi

  if [ "$do_all" -eq 1 ] || [ "$do_zoxide" -eq 1 ]; then
    run install_zoxide
  fi

  if [ "$do_all" -eq 1 ] || [ "$do_rg" -eq 1 ]; then
    run install_ripgrep
  fi

  run add_misc_to_bashrc

  log 'Open a new terminal (or exec "$SHELL") to make sure setup complete!'
  log "Done."
}

main "$@"
