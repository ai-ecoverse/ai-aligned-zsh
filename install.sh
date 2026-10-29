#!/bin/sh
#
# install.sh - install ai-aligned-zsh and hook it into ~/.zshenv
#
# Copies the hook to ~/.local/bin/ai-aligned-zsh and adds a clearly marked
# block that sources it to the top of ${ZDOTDIR:-$HOME}/.zshenv, the only file
# a non-interactive `zsh -c` reads. Running it again replaces the block rather
# than adding a second one. If chezmoi manages .zshenv, it leaves the file
# alone and prints the block to add to the chezmoi source instead.
#
# Supports both local installation and curl | sh:
#   curl -fsSL https://raw.githubusercontent.com/ai-ecoverse/ai-aligned-zsh/main/install.sh | sh
#
#   ./install.sh               install, or update in place
#   ./install.sh --uninstall   remove the block and the hook

set -eu

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
RAW_BASE_URL="https://raw.githubusercontent.com/ai-ecoverse/ai-aligned-zsh/main"
SOURCE_SCRIPT="executable_ai-aligned-zsh"
ZSHENV="${ZDOTDIR:-$HOME}/.zshenv"
CHEZMOI_DIR="${CHEZMOI_SOURCE_DIR:-$HOME/.local/share/chezmoi}"
BEGIN_MARK="# >>> ai-aligned-zsh >>>"
END_MARK="# <<< ai-aligned-zsh <<<"

# $0 is "sh" when piped from curl; the download path below handles a missing
# local copy.
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || pwd)"
SOURCE="$SCRIPT_DIR/$SOURCE_SCRIPT"

if [ -t 1 ]; then
    RED=$(printf '\033[0;31m'); GREEN=$(printf '\033[0;32m'); YELLOW=$(printf '\033[1;33m'); NC=$(printf '\033[0m')
else
    RED=""; GREEN=""; YELLOW=""; NC=""
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$NC" "$*"; }
die()  { printf '%s✗%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

# The path as written into .zshenv: $HOME-relative where possible, so a
# dotfiles repo that carries the block works on every machine.
hook_path() {
    case "$INSTALL_DIR/ai-aligned-zsh" in
        "$HOME"/*) printf '%s' "\$HOME/${INSTALL_DIR#"$HOME"/}/ai-aligned-zsh" ;;
        *)         printf '%s' "$INSTALL_DIR/ai-aligned-zsh" ;;
    esac
}

block() {
    p=$(hook_path)
    say "$BEGIN_MARK"
    say "# Bash-compatible options for coding agents' non-interactive zsh -c."
    say "# Humans and interactive shells are untouched. Keep this at the top."
    say "# https://github.com/ai-ecoverse/ai-aligned-zsh"
    say "[[ -r \"$p\" ]] && source \"$p\""
    say "$END_MARK"
}

# The file without our block (and the blank line after it).
strip_block() {
    [ -f "$1" ] || return 0
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0 == b { skip = 1; next }
        skip && $0 == e { skip = 0; ended = 1; next }
        skip { next }
        ended && $0 == "" { ended = 0; next }
        { ended = 0; print }
    ' "$1"
}

# Prints the chezmoi source file for .zshenv if chezmoi manages it.
chezmoi_source() {
    if command -v chezmoi >/dev/null 2>&1; then
        if src=$(chezmoi source-path "$ZSHENV" 2>/dev/null) && [ -n "$src" ]; then
            printf '%s' "$src"
            return 0
        fi
    fi
    [ "$ZSHENV" = "$HOME/.zshenv" ] || return 1
    for f in dot_zshenv dot_zshenv.tmpl private_dot_zshenv private_dot_zshenv.tmpl; do
        if [ -e "$CHEZMOI_DIR/$f" ]; then
            printf '%s' "$CHEZMOI_DIR/$f"
            return 0
        fi
    done
    return 1
}

# Writes stdin to $ZSHENV through a temp file, keeping symlinks and modes.
replace_zshenv() {
    tmp=$(mktemp "${TMPDIR:-/tmp}/ai-aligned-zsh.XXXXXX")
    cat > "$tmp"
    cat "$tmp" > "$ZSHENV"
    rm -f "$tmp"
}

managed_notice() {
    warn "chezmoi manages $ZSHENV (source: $1)."
    say "  Not editing it: chezmoi apply would undo the change. Add this block to"
    say "  the top of $1, then run chezmoi apply:"
    say ""
    block | sed 's/^/    /'
    say ""
}

# --- uninstall ---------------------------------------------------------------

if [ "${1:-}" = "--uninstall" ]; then
    if src=$(chezmoi_source); then
        warn "chezmoi manages $ZSHENV; remove the ai-aligned-zsh block from $src yourself."
    elif [ -f "$ZSHENV" ] && grep -qF "$BEGIN_MARK" "$ZSHENV"; then
        strip_block "$ZSHENV" | replace_zshenv
        ok "removed the hook from $ZSHENV"
    else
        say "No hook in $ZSHENV"
    fi
    if [ -e "$INSTALL_DIR/ai-aligned-zsh" ]; then
        rm -f "$INSTALL_DIR/ai-aligned-zsh"
        ok "removed $INSTALL_DIR/ai-aligned-zsh"
    fi
    exit 0
fi

# --- install the hook ----------------------------------------------------------

command -v zsh >/dev/null 2>&1 || die "zsh not found; ai-aligned-zsh only changes zsh"

say "Installing ai-aligned-zsh to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

if [ -r "$SOURCE" ]; then
    cp "$SOURCE" "$INSTALL_DIR/ai-aligned-zsh"
    chmod 0755 "$INSTALL_DIR/ai-aligned-zsh"
    ok "installed ai-aligned-zsh from $SOURCE"
else
    say "No local copy found; downloading from $RAW_BASE_URL"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$RAW_BASE_URL/$SOURCE_SCRIPT" -o "$INSTALL_DIR/ai-aligned-zsh"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$INSTALL_DIR/ai-aligned-zsh" "$RAW_BASE_URL/$SOURCE_SCRIPT"
    else
        die "neither curl nor wget is available"
    fi
    chmod 0755 "$INSTALL_DIR/ai-aligned-zsh"
    ok "downloaded and installed ai-aligned-zsh"
fi
zsh -n "$INSTALL_DIR/ai-aligned-zsh" || die "$INSTALL_DIR/ai-aligned-zsh does not parse"

# --- hook it into .zshenv ------------------------------------------------------
#
# At the top, not the bottom: a .zshenv that returns early for non-interactive
# shells would otherwise never reach it. The position does not change when the
# options apply; that is always after the last startup file.

say ""
if src=$(chezmoi_source); then
    if grep -qF "$BEGIN_MARK" "$ZSHENV" 2>/dev/null; then
        ok "$ZSHENV already has the hook (managed by chezmoi via $src)"
    else
        managed_notice "$src"
    fi
else
    if [ -L "$ZSHENV" ]; then
        warn "$ZSHENV is a symlink; editing its target"
    fi
    new=$(mktemp "${TMPDIR:-/tmp}/ai-aligned-zsh.XXXXXX")
    {
        block
        rest=$(strip_block "$ZSHENV")
        if [ -n "$rest" ]; then
            say ""
            printf '%s\n' "$rest"
        fi
    } > "$new"
    if [ -f "$ZSHENV" ] && cmp -s "$new" "$ZSHENV"; then
        ok "$ZSHENV already has the hook"
    else
        if [ -f "$ZSHENV" ] && ! grep -qF "$BEGIN_MARK" "$ZSHENV" && [ ! -e "$ZSHENV.ai-aligned-zsh.bak" ]; then
            cp "$ZSHENV" "$ZSHENV.ai-aligned-zsh.bak"
            ok "backed up $ZSHENV to $ZSHENV.ai-aligned-zsh.bak"
        fi
        replace_zshenv < "$new"
        ok "hooked into the top of $ZSHENV"
    fi
    rm -f "$new"
fi

say ""
"$INSTALL_DIR/ai-aligned-zsh" doctor || true
say ""
say "Agents' zsh -c now parses bash the way they expect; humans are untouched."
say "Turn it off with AI_ALIGNED_ZSH=off, force it with AI_ALIGNED_ZSH=on."
