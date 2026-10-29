#!/bin/bash
#
# test.sh - regression tests for ai-aligned-zsh
#
# Every shell runs under `env -i` with a throwaway HOME and ZDOTDIR, so the
# real ~/.zshenv, the real dotfiles and the agent that may be running this
# suite never leak in. The bash-compatibility cases come from commands that
# failed in real agent sessions; each is run through bash, through an agent's
# zsh -c, and through a human's zsh -c.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$REPO/executable_ai-aligned-zsh"
ZSH_BIN="$(command -v zsh || true)"
BASH_BIN="$(command -v bash)"
[ -n "$ZSH_BIN" ] || { echo "zsh is required" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-aligned-zsh-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '%s✓%s %s\n' "$GREEN" "$NC" "$1"; }
bad()  { fail=$((fail + 1)); printf '%s✗%s %s\n' "$RED" "$NC" "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; }
section() { printf '\n%s%s%s\n' "$YELLOW" "$1" "$NC"; }

# assert_eq NAME EXPECTED ACTUAL
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $(printf '%q' "$2")"$'\n'"actual:   $(printf '%q' "$3")"; fi
}
assert_ne() {
    if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "both: $(printf '%q' "$2")"; fi
}

# A fresh home with the hook at the top of .zshenv, followed by $2 if given.
new_home() {
    local h="$WORK/$1"
    mkdir -p "$h"
    {
        printf '[[ -r "%s" ]] && source "%s"\n' "$HOOK" "$HOOK"
        printf '%s\n' "${2:-}"
    } > "$h/.zshenv"
    printf '%s' "$h"
}

CLEAN_PATH="$(dirname "$ZSH_BIN"):$(dirname "$BASH_BIN"):/usr/bin:/bin"

# zsh_in HOME [VAR=value ...] -- ARGS...: zsh with nothing but what is given.
zsh_in() {
    local h="$1"; shift
    local -a vars=()
    while [ "$1" != "--" ]; do vars+=("$1"); shift; done
    shift
    env -i HOME="$h" ZDOTDIR="$h" PATH="$CLEAN_PATH" LC_ALL=C ${vars[@]+"${vars[@]}"} "$ZSH_BIN" "$@"
}
agent() { local h="$1"; shift; zsh_in "$h" CLAUDECODE=1 -- -c "$*" 2>&1; }
human() { local h="$1"; shift; zsh_in "$h" -- -c "$*" 2>&1; }
bash_c() { env -i HOME="$WORK/bashhome" PATH="$CLEAN_PATH" LC_ALL=C "$BASH_BIN" -c "$*" 2>&1; }

HOME_PLAIN="$(new_home plain)"
mkdir -p "$WORK/bashhome"

# ------------------------------------------------------------------------------
section "Detection: every agent am-i-ai recognises by environment"

while read -r expect assignment; do
    out=$(zsh_in "$HOME_PLAIN" "$assignment" -- -c 'print -r -- ${AI_ALIGNED_ZSH_ACTIVE:-none}' 2>&1)
    assert_eq "$assignment -> $expect" "$expect" "$out"
done <<'EOF'
claude CLAUDECODE=1
claude CLAUDE_CODE_ENTRYPOINT=cli
claude CLAUDE_CODE_ENTRYPOINT=sdk-ts
codex CODEX_THREAD_ID=019a
codex CODEX_SANDBOX=seatbelt
codex CODEX_CLI=1
codex CODEX_SHELL=1
gemini GEMINI_CLI=1
cursor CURSOR_AGENT=1
amp AGENT=amp
amp AMP_HOME=/x
opencode OPENCODE_AI=1
droid DROID_CLI=1
auggie AUGMENT_AGENT=1
auggie AUGMENT_API_TOKEN=x
pi PI_CODING_AGENT=true
copilot GITHUB_COPILOT_CLI_MODE=true
qwen QWEN_CODE=1
kimi KIMI_CLI=1
grok GROK_BUILD=1
grok GROK_MODEL=grok-build
aider OR_APP_NAME=Aider
openhands OR_APP_NAME=OpenHands
goose GOOSE_TERMINAL=1
cline CLINE_TASK_ID=1
roo ROO_CODE_TASK_ID=1
windsurf WINDSURF_SESSION=1
windsurf TERM_PROGRAM=windsurf
none CLAUDE_CODE_ENTRYPOINT=other
none GITHUB_COPILOT_CLI_MODE=false
none AGENT=someone-else
none TERM_PROGRAM=ghostty
none ZED_ENVIRONMENT=1
EOF
assert_eq "no agent variables -> none" "none" "$(human "$HOME_PLAIN" 'print -r -- ${AI_ALIGNED_ZSH_ACTIVE:-none}')"

# ------------------------------------------------------------------------------
section "Detection: the zsh mirror agrees with bundled am-i-ai"

BUNDLE="$WORK/am-i-ai.bash"
sed -n '/^# --- BEGIN BUNDLED am-i-ai ---$/,/^# --- END BUNDLED am-i-ai ---$/p' "$HOOK" > "$BUNDLE"
MIRROR="$WORK/mirror.zsh"
sed -n '/^_ai_aligned_zsh_check_env() {$/,/^}$/p' "$HOOK" > "$MIRROR"
grep -q '^ami_check_env()' "$BUNDLE" && ok "am-i-ai is bundled" || bad "am-i-ai is bundled"

# Every variable ami_check_env reads must appear in the mirror.
ami_vars=$(sed -n '/^ami_check_env() {$/,/^}$/p' "$BUNDLE" | grep -o '\$[A-Z_][A-Z0-9_]*\|\${[A-Z_][A-Z0-9_]*' | tr -d '${' | sort -u)
missing=""
for v in $ami_vars; do grep -Eq "[\$][{]?${v}([^A-Za-z0-9_]|\$)" "$MIRROR" || missing="$missing $v"; done
assert_eq "mirror reads every variable ami_check_env reads ($(echo $ami_vars | wc -w | tr -d ' ') of them)" "" "$missing"

# Every literal ami_check_env compares against, and "1" for every variable.
fixtures=()
for v in $ami_vars; do
    case "$v" in SHLVL|PPID|OSTYPE) continue ;; esac
    fixtures+=("$v=1")
done
while IFS= read -r pair; do fixtures+=("$pair"); done < <(
    sed -n '/^ami_check_env() {$/,/^}$/p' "$BUNDLE" |
    grep -o '"\$[A-Z_][A-Z0-9_]*" = "[^"]*"' | sed 's/^"\$\([A-Z_0-9]*\)" = "\(.*\)"$/\1=\2/' | sort -u)
fixtures+=("ZED_ENVIRONMENT=1 TERM_PROGRAM=zed SHLVL=1" "ZED_ENVIRONMENT=1 ZED_TERM=1 SHLVL=3" "CLAUDECODE=1 CODEX_THREAD_ID=1 AGENT=amp" "")
mismatch=0
for f in "${fixtures[@]}"; do
    # shellcheck disable=SC2086
    want=$(env -i PATH="$CLEAN_PATH" $f "$BASH_BIN" -c "source '$BUNDLE'; ami_check_env")
    # shellcheck disable=SC2086
    got=$(env -i PATH="$CLEAN_PATH" $f "$ZSH_BIN" -f -c "source '$MIRROR'; _ai_aligned_zsh_check_env; print -r -- \"\$REPLY\"")
    if [ "$want" != "$got" ]; then
        mismatch=$((mismatch + 1)); bad "parity: ${f:-<empty>}" "am-i-ai: '$want'  mirror: '$got'"
    fi
done
[ "$mismatch" -eq 0 ] && ok "mirror == ami_check_env on ${#fixtures[@]} environments"

# ------------------------------------------------------------------------------
section "Bash compatibility: commands that failed in real agent sessions"

FIX="$WORK/fixture"
mkdir -p "$FIX/src" "$FIX/data/run-1" "$FIX/empty"
echo "needle" > "$FIX/src/a.ts"; echo "hay" > "$FIX/src/b.ts"
echo '{}' > "$FIX/data/run-1/report.json"

# name | command. Each must print the same in bash and in an agent's zsh -c,
# and something else in a human's zsh -c (or the case proves nothing).
while IFS='|' read -r name cmd; do
    [ -n "$name" ] || continue
    want=$(cd "$FIX" && bash_c "$cmd" | sed 's/^bash: line [0-9]*: //')
    got=$(cd "$FIX" && agent "$HOME_PLAIN" "$cmd")
    plain=$(cd "$FIX" && human "$HOME_PLAIN" "$cmd")
    assert_eq "$name" "$want" "$got"
    assert_ne "  ...and a human's zsh still differs" "$want" "$plain"
done <<'EOF'
word split: for f in $FILES|FILES="src/a.ts src/b.ts"; for f in $FILES; do echo "<$f>"; done
word split: command in a variable|R="printf %s-"; $R a b; echo
word split: set -- $line|t="pr-12 open"; set -- $t; echo "$# $2"
word split: ssh options in a variable|SSH="echo ssh -o ConnectTimeout=20 -p 22"; $SSH host
nomatch: grep --include=*.ts|grep -rl needle --include=*.ts . | sort
nomatch: URL with ?|echo https://example.com/api?per_page=100
nomatch: pip extras|echo pip install foo[dev]
nomatch: jq path|echo .headRefOid[0:7]
nomatch: empty directory glob|rm -f empty/*.tmp; echo "rc=$?"
nomatch: does not abort the line|ls nothing-here-* 2>/dev/null; echo after
equals: echo ==== separator|echo ====; echo =====next
equals: == inside [ ]|a=x; [ "$a" == x ] && echo same
glob_subst: glob kept in a variable|t=data/*/report.json; ls $t
modifier: $REV:src/file|R=ca8a83f; echo $R:src/index.ts
modifier: $C:r and $D:h|C=page.html; D=a/b; echo $C:r $D:h
subscript: "$i[ >]" in a grep pattern|i=icon; echo "<swc-$i[ >]"
arrays: 0-indexed|a=(x y z); echo ${a[0]} ${a[2]} ${#a[@]}
arrays: bare $a is the first element|a=(x y z); echo $a
BASH_REMATCH: capture groups|[[ v1.22.3 =~ ^v([0-9]+)\.([0-9]+) ]] && echo ${BASH_REMATCH[0]} ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}
malformed glob passes through|echo [WIP
EOF

# Cases where bash has nothing to compare: assert the agent's output directly.
assert_eq "bare glob qualifier stays literal" "shot*(1)" "$(cd "$FIX" && agent "$HOME_PLAIN" 'echo shot*(1)')"
assert_ne "  ...a human's zsh treats it as a qualifier" "shot*(1)" "$(cd "$FIX" && human "$HOME_PLAIN" 'echo shot*(1)')"

# Bash idioms that already worked must keep working under the new options.
# macOS's /bin/bash is 3.2, without associative arrays; there, say what bash 4+
# prints.
BASH_MAJOR=$("$BASH_BIN" -c 'echo "${BASH_VERSINFO[0]}"')
while IFS='|' read -r name cmd; do
    [ -n "$name" ] || continue
    want=$(cd "$FIX" && bash_c "$cmd")
    [ "$name" = "associative arrays" ] && [ "$BASH_MAJOR" -lt 4 ] && want="v 2"
    got=$(cd "$FIX" && agent "$HOME_PLAIN" "$cmd")
    assert_eq "still bash: $name" "$want" "$got"
done <<'EOF'
brace expansion|echo {1..3} x{a,b}
quoted expansion|V="a  b"; echo "$V"
command substitution splits|for w in $(echo one two); do echo "<$w>"; done
"$@" preserves arguments|f() { for a in "$@"; do echo "<$a>"; done; }; f "a b" c
${#var} ${var:1:2} ${var//a/b}|s=banana; echo ${#s} ${s:1:2} ${s//a/o}
${arr[@]:1} slice|a=(x y z); echo ${a[@]:1}
associative arrays|declare -A m; m[k]=v; m[j]=w; echo ${m[k]} ${#m[@]}
array append|a=(x); a+=(y); echo ${a[@]} ${#a[@]}
here-string read|read -r a b <<< "1 2"; echo "$b$a"
$'...' strings|printf '%s\n' $'a\tb' | od -c | head -1 | tr -s ' '
arithmetic|i=3; echo $((i * 2)) $((i++)) $i
case patterns|case foo.ts in *.ts) echo ts;; *) echo other;; esac
[[ pattern match ]]|[[ abc == a* ]] && echo yes
globs that match still glob|echo src/*.ts
comments|echo a # b
pipefail|set -o pipefail; false | true; echo $?
exit status|false; echo $?
EOF

# ------------------------------------------------------------------------------
section "Humans, interactive shells and zsh scripts are untouched"

assert_eq "human zsh -c: options unchanged" "off on on off" \
    "$(human "$HOME_PLAIN" 'print -r -- ${options[shwordsplit]} ${options[nomatch]} ${options[equals]} ${options[ksharrays]}')"
assert_eq "agent zsh -c: options set" "on off off on" \
    "$(agent "$HOME_PLAIN" 'print -r -- ${options[shwordsplit]} ${options[nomatch]} ${options[equals]} ${options[ksharrays]}')"
assert_eq "agent zsh -i -c (interactive): untouched" "off on none" \
    "$(zsh_in "$HOME_PLAIN" CLAUDECODE=1 -- -i -c 'print -r -- ${options[shwordsplit]} ${options[nomatch]} ${AI_ALIGNED_ZSH_ACTIVE:-none}' 2>/dev/null)"
printf 'V="a b"; for x in $V; do print -r -- "<$x>"; done\na=(x y); print -r -- $a[1]\n' > "$WORK/script.zsh"
assert_eq "agent runs a zsh script: zsh semantics" "<a b>"$'\n'"x" \
    "$(zsh_in "$HOME_PLAIN" CLAUDECODE=1 -- "$WORK/script.zsh" 2>&1)"
assert_eq "agent pipes commands to zsh: aligned" "<a>"$'\n'"<b>" \
    "$(printf 'V="a b"; for x in $V; do echo "<$x>"; done\n' | zsh_in "$HOME_PLAIN" CLAUDECODE=1 -- 2>&1)"
assert_eq "human pipes commands to zsh: untouched" "<a b>" \
    "$(printf 'V="a b"; for x in $V; do echo "<$x>"; done\n' | zsh_in "$HOME_PLAIN" -- 2>&1)"
ZWC_HOME="$WORK/zwc"; mkdir -p "$ZWC_HOME"
cp "$HOOK" "$ZWC_HOME/hook"; "$ZSH_BIN" -f -c "zcompile '$ZWC_HOME/hook'"
printf 'source "%s/hook"\n' "$ZWC_HOME" > "$ZWC_HOME/.zshenv"
[ -f "$ZWC_HOME/hook.zwc" ] && ok "zcompiled copy exists" || bad "zcompiled copy exists"
assert_eq "sourced from a zcompiled .zwc: agent" "<a>|<b>|claude" \
    "$(agent "$ZWC_HOME" 'V="a b"; for x in $V; do echo "<$x>"; done; echo $AI_ALIGNED_ZSH_ACTIVE' | paste -sd'|' -)"
assert_eq "sourced from a zcompiled .zwc: human" "<a b>" "$(human "$ZWC_HOME" 'V="a b"; for x in $V; do echo "<$x>"; done')"
assert_eq "sourcing it by hand never runs the command or exits" "still here" \
    "$(env -i HOME="$WORK" PATH="$CLEAN_PATH" "$ZSH_BIN" -f -c "source '$HOOK'; source '$HOOK' status; echo still here" 2>&1)"
assert_eq "no helper functions left behind" "0" \
    "$(agent "$HOME_PLAIN" 'typeset -f | grep -c _ai_aligned_zsh')"
assert_eq "no DEBUG trap left behind" "" "$(agent "$HOME_PLAIN" 'trap')"

# ------------------------------------------------------------------------------
section "Startup files keep their zsh semantics"

HOME_RC="$(new_home startup '
setopt extended_glob
arr=(a b c); [[ ${arr[1]} == a ]] || print -r -- "BROKEN zshenv array"
s="p q"; set -- $s; (( $# == 1 )) || print -r -- "BROKEN zshenv split"
f=dir/file.txt; [[ $f:t == file.txt ]] || print -r -- "BROKEN zshenv modifier"
userfn() { local a=(x y z) s="p q"; set -- $s; print -r -- "userfn ${a[1]} $# ${1:t}"; }
hasglob() { [[ main == ^dev ]] && print -r -- "userfn extended_glob ok"; }
[[ -o interactive ]] || return
print -r -- "NOT REACHED"')"
printf 'arr=(a b c); [[ ${arr[1]} == a ]] || print -r -- "BROKEN zprofile"\nx="a b"; set -- $x; (( $# == 1 )) || print -r -- "BROKEN zprofile split"\n' > "$HOME_RC/.zprofile"
printf 'p=(one two); [[ $p[2] == two ]] || print -r -- "BROKEN zlogin"\n' > "$HOME_RC/.zlogin"

out=$(zsh_in "$HOME_RC" CLAUDECODE=1 -- -lc 'userfn; hasglob; V="a b"; for x in $V; do echo "<$x>"; done; echo HEAD^ ${AI_ALIGNED_ZSH_ACTIVE}' 2>&1)
assert_eq "zsh -lc (Codex): startup files, user functions and agent code each behave" \
    "userfn x 1 p q"$'\n'"userfn extended_glob ok"$'\n'"<a>"$'\n'"<b>"$'\n'"HEAD^ claude" "$out"
out=$(zsh_in "$HOME_RC" CLAUDECODE=1 -- -c 'userfn; echo ${AI_ALIGNED_ZSH_ACTIVE}' 2>&1)
assert_eq "zsh -c after a .zshenv that returns early" "userfn x 1 p q"$'\n'"claude" "$out"
out=$(zsh_in "$HOME_RC" -- -lc 'userfn; V="a b"; for x in $V; do echo "<$x>"; done' 2>&1)
assert_eq "human zsh -lc: all zsh" "userfn x 1 p q"$'\n'"<a b>" "$out"

HOME_STATUS="$(new_home status 'false')"
assert_eq "\$? from the startup files reaches the command" "$(human "$HOME_STATUS" 'echo $?')" "$(agent "$HOME_STATUS" 'echo $?')"
assert_eq "exit status of the command" "3" "$(zsh_in "$HOME_PLAIN" CLAUDECODE=1 -- -c 'exit 3' >/dev/null 2>&1; echo $?)"
assert_eq "zsh -e stops at the first failure" "1:" "$(out=$(zsh_in "$HOME_PLAIN" CLAUDECODE=1 -- -e -c 'false; echo no' 2>&1); echo "$?:$out")"
printf 'print -r -- "[$ZSH_EVAL_CONTEXT]"\n' > "$HOME_RC/.zprofile"
assert_eq "prints nothing of its own" "[file]"$'\n'"x" "$(zsh_in "$HOME_RC" CLAUDECODE=1 -- -lc 'echo x' 2>&1 | grep -v userfn)"

# ------------------------------------------------------------------------------
section "Claude Code's command shape: snapshot first, then the agent's command"

SNAP_DIR="$WORK/claude/shell-snapshots"; mkdir -p "$SNAP_DIR"
cat > "$SNAP_DIR/snapshot-zsh-1-abc.sh" <<'EOF'
# Snapshot file
unalias -a 2>/dev/null || true
# Functions
mkfn () {
	local a=(one two three)
	local w="x y"
	print -r -- "mkfn ${a[1]} ${#a} $w:t"
}
# Shell Options
setopt nohashdirs
# Aliases
alias -- ll='ls -l'
export PATH="$HOME/.local/bin:$PATH"
EOF
CWD_FILE="$WORK/claude-cwd"
CMD="source $SNAP_DIR/snapshot-zsh-1-abc.sh 2>/dev/null || true && setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL 2>/dev/null || true && eval 'mkfn; F=\"a b\"; for f in \$F; do echo \"<\$f>\"; done; echo ===; echo --include=*.ts' < /dev/null && pwd -P >| $CWD_FILE"
out=$(cd "$FIX" && zsh_in "$HOME_PLAIN" CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=cli -- -c "$CMD" 2>&1)
assert_eq "snapshot function stays zsh, the agent's command is bash" \
    "mkfn one 3 x y"$'\n'"<a>"$'\n'"<b>"$'\n'"==="$'\n'"--include=*.ts" "$out"
assert_eq "cwd file written" "$(cd "$FIX" && pwd -P)" "$(cat "$CWD_FILE" 2>/dev/null)"

# A snapshot carries the user's interactive options: its functions keep them,
# the agent's command gets ours again.
printf 'setopt extendedglob\nsnapfn () {\n\t[[ main == ^dev ]] && print -r -- "snapfn extendedglob"\n}\n' > "$SNAP_DIR/snapshot-zsh-2-def.sh"
out=$(zsh_in "$HOME_PLAIN" CODEX_THREAD_ID=1 -- -c "source $SNAP_DIR/snapshot-zsh-2-def.sh; snapfn; echo \${options[extendedglob]} \${options[shwordsplit]}" 2>&1)
assert_eq "snapshot then ';': its function keeps its options, ours are back" "snapfn extendedglob"$'\n'"off on" "$out"
out=$(zsh_in "$HOME_PLAIN" CODEX_THREAD_ID=1 -- -c "source $SNAP_DIR/snapshot-zsh-2-def.sh && eval 'snapfn; echo \${options[extendedglob]}'" 2>&1)
assert_eq "snapshot then eval: the same" "snapfn extendedglob"$'\n'"off" "$out"

# ------------------------------------------------------------------------------
section "Switches"

assert_eq "AI_ALIGNED_ZSH=off" "off none" \
    "$(zsh_in "$HOME_PLAIN" CLAUDECODE=1 AI_ALIGNED_ZSH=off -- -c 'print -r -- ${options[shwordsplit]} ${AI_ALIGNED_ZSH_ACTIVE:-none}')"
assert_eq "AMI_PASSTHROUGH=true" "off none" \
    "$(zsh_in "$HOME_PLAIN" CLAUDECODE=1 AMI_PASSTHROUGH=true -- -c 'print -r -- ${options[shwordsplit]} ${AI_ALIGNED_ZSH_ACTIVE:-none}')"
assert_eq "AI_ALIGNED_ZSH=on without an agent" "on forced" \
    "$(zsh_in "$HOME_PLAIN" AI_ALIGNED_ZSH=on -- -c 'print -r -- ${options[shwordsplit]} ${AI_ALIGNED_ZSH_ACTIVE:-none}')"
assert_eq "AI_ALIGNED_ZSH=off set later in .zshenv" "off none" \
    "$(zsh_in "$(new_home lateoff 'AI_ALIGNED_ZSH=off')" CLAUDECODE=1 -- -c 'print -r -- ${options[shwordsplit]} ${AI_ALIGNED_ZSH_ACTIVE:-none}')"
assert_eq "AI_ALIGNED_ZSH_OPTIONS replaces the list" "off off on" \
    "$(zsh_in "$HOME_PLAIN" CLAUDECODE=1 'AI_ALIGNED_ZSH_OPTIONS=no_nomatch' -- -c 'print -r -- ${options[shwordsplit]} ${options[nomatch]} ${options[equals]}')"

# ------------------------------------------------------------------------------
section "install.sh"

IH="$WORK/install-home"; mkdir -p "$IH"
printf '# my zshenv\nexport FOO=1\n' > "$IH/.zshenv"
run_install() { env -i HOME="$IH" PATH="$CLEAN_PATH" sh "$REPO/install.sh" 2>&1; }

out=$(run_install); rc=$?
assert_eq "installs" "0" "$rc"
[ -x "$IH/.local/bin/ai-aligned-zsh" ] && ok "hook installed to ~/.local/bin" || bad "hook installed to ~/.local/bin" "$out"
assert_eq "block is at the top" "# >>> ai-aligned-zsh >>>" "$(head -1 "$IH/.zshenv")"
assert_eq "existing content kept" "export FOO=1" "$(tail -1 "$IH/.zshenv")"
assert_eq "path written \$HOME-relative" '[[ -r "$HOME/.local/bin/ai-aligned-zsh" ]] && source "$HOME/.local/bin/ai-aligned-zsh"' \
    "$(grep '^\[\[' "$IH/.zshenv")"
[ -f "$IH/.zshenv.ai-aligned-zsh.bak" ] && ok "original backed up" || bad "original backed up"
before=$(cat "$IH/.zshenv")
run_install >/dev/null
assert_eq "second run changes nothing" "$before" "$(cat "$IH/.zshenv")"
assert_eq "one block after two runs" "1" "$(grep -c '>>> ai-aligned-zsh >>>' "$IH/.zshenv")"
assert_eq "installed hook works" "<a>|<b>|claude" \
    "$(env -i HOME="$IH" PATH="$CLEAN_PATH" CLAUDECODE=1 "$ZSH_BIN" -c 'V="a b"; for x in $V; do echo "<$x>"; done; echo $AI_ALIGNED_ZSH_ACTIVE' 2>&1 | paste -sd'|' -)"
assert_eq "human shell after install" "<a b>" \
    "$(env -i HOME="$IH" PATH="$CLEAN_PATH" "$ZSH_BIN" -c 'V="a b"; for x in $V; do echo "<$x>"; done' 2>&1)"
out=$(env -i HOME="$IH" PATH="$CLEAN_PATH" sh "$REPO/install.sh" --uninstall 2>&1)
assert_eq "uninstall restores the original" "$(printf '# my zshenv\nexport FOO=1')" "$(cat "$IH/.zshenv")"
[ ! -e "$IH/.local/bin/ai-aligned-zsh" ] && ok "uninstall removes the hook" || bad "uninstall removes the hook"

CH="$WORK/chezmoi-home"; mkdir -p "$CH/.local/share/chezmoi"
printf 'export FOO=1\n' > "$CH/.zshenv"; cp "$CH/.zshenv" "$CH/.local/share/chezmoi/dot_zshenv"
out=$(env -i HOME="$CH" PATH="$CLEAN_PATH" sh "$REPO/install.sh" 2>&1)
assert_eq "chezmoi-managed .zshenv is not edited" "export FOO=1" "$(cat "$CH/.zshenv")"
assert_eq "chezmoi source is not edited" "export FOO=1" "$(cat "$CH/.local/share/chezmoi/dot_zshenv")"
case "$out" in *"chezmoi manages"*"dot_zshenv"*">>> ai-aligned-zsh >>>"*) ok "prints the block for the chezmoi source" ;; *) bad "prints the block for the chezmoi source" "$out" ;; esac

ZD="$WORK/zdotdir-home"; mkdir -p "$ZD/zdot"
env -i HOME="$ZD" ZDOTDIR="$ZD/zdot" PATH="$CLEAN_PATH" sh "$REPO/install.sh" >/dev/null 2>&1
[ -f "$ZD/zdot/.zshenv" ] && [ ! -e "$ZD/.zshenv" ] && ok "honours ZDOTDIR" || bad "honours ZDOTDIR"

# ------------------------------------------------------------------------------
section "Command"

out=$(env -i HOME="$HOME_PLAIN" PATH="$CLEAN_PATH" CLAUDECODE=1 "$ZSH_BIN" "$HOOK" status 2>&1)
case "$out" in *"aligned (claude)"*) ok "status: agent" ;; *) bad "status: agent" "$out" ;; esac
out=$(env -i HOME="$HOME_PLAIN" PATH="$CLEAN_PATH" "$ZSH_BIN" "$HOOK" status 2>&1)
case "$out" in *"untouched: no coding agent detected"*) ok "status: human" ;; *) bad "status: human" "$out" ;; esac
n=$(env -i PATH="$CLEAN_PATH" "$ZSH_BIN" "$HOOK" options | grep -c '#')
assert_eq "options lists the defaults" "9" "$n"
out=$(env -i HOME="$IH" PATH="$CLEAN_PATH" "$ZSH_BIN" "$HOOK" doctor 2>&1); rc=$?
assert_eq "doctor flags a missing hook" "1" "$rc"

# ------------------------------------------------------------------------------
section "Cost"

# Wall time per `zsh -c true`, measured inside zsh so it works on BSD date,
# with the three cases interleaved so machine load hits them alike.
EMPTY="$WORK/empty-home"; mkdir -p "$EMPTY"
env -i PATH="$CLEAN_PATH" E="$EMPTY" H="$HOME_PLAIN" "$ZSH_BIN" -f -c '
    zmodload zsh/datetime
    typeset -A t; integer r i; float s
    for r in {1..4}; do
        for k in none human agent; do
            s=$EPOCHREALTIME
            for i in {1..40}; do
                case $k in
                    (none) HOME=$E ZDOTDIR=$E zsh -c true ;;
                    (human) HOME=$H ZDOTDIR=$H zsh -c true ;;
                    (agent) HOME=$H ZDOTDIR=$H CLAUDECODE=1 zsh -c true ;;
                esac
            done
            (( t[$k] += (EPOCHREALTIME - s) * 1000.0 / 160 ))
        done
    done
    printf "  zsh -c true, ms per run: no hook %.1f, human %.1f (+%.1f), agent %.1f (+%.1f)\n" \
        $t[none] $t[human] $(( t[human] - t[none] )) $t[agent] $(( t[agent] - t[none] ))'

# ------------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
