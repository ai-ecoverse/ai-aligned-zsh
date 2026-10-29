# ai-aligned-zsh

[![0% Vibe_Coded](https://img.shields.io/badge/0%25-Vibe_Coded-ff69b4?style=for-the-badge&logo=githubcopilot&logoColor=white)](https://github.com/ai-ecoverse/vibe-coded-badge-action)

> **zsh: no matches found: your patience\***
>
> <sub>\* if you are a coding agent and the user's login shell is zsh.</sub>

A zsh that parses bash the way coding agents expect it to, for coding agents
only. One block at the top of `~/.zshenv`. No `CLAUDE.md` section, no
`AGENTS.md` rule, no skill. The agent runs the command it was always going to
run, and it works.

Humans get their zsh exactly as it was: interactive shells, zsh scripts and any
`zsh -c` without an agent behind it are untouched.

## Why

Coding agents write bash. When your login shell is zsh, Claude Code, Codex and
most of the rest run that bash through `zsh -c`, and zsh disagrees with it in
small ways that fail loudly or, worse, quietly:

```sh
grep -rn "needle" --include=*.ts .          # zsh: no matches found: --include=*.ts
gh api repos/o/r/actions/runs?per_page=100  # zsh: no matches found: repos/o/r/…?per_page=100
echo =====; cat handover.md                 # zsh: ==== not found, and the rest never runs
R=ca8a83f; git show $R:src/index.ts         # zsh: bad substitution ($R:s is a modifier)
FILES="a.ts b.ts"; for f in $FILES; do …    # one iteration, with f="a.ts b.ts"
SSH="ssh -p 2222 root@host"; $SSH uptime    # zsh: command not found: ssh -p 2222 root@host
```

These all come from one user's agent transcripts: 384 Claude Code sessions,
89,000 shell commands, all run through `zsh -c`.
**231 of the 384 sessions (60%) hit at least one zsh-only error.** The agent
usually recovers, by rewriting, quoting or retrying, and pays for it in turns,
tokens and the occasional wrong conclusion: "That was a bug in my script, not a
CI result: zsh doesn't split variables on whitespace the way bash does, so it
misread the PR's state."

The fix that started this
([via @dedene](https://x.com/dedene)) was one line in `~/.zshenv`:

```zsh
[[ ! -o interactive && ( -n $CLAUDECODE || -n $CODEX_THREAD_ID ) ]] && setopt sh_word_split no_nomatch no_equals
```

This repository is that line, made robust: every agent
[am-i-ai](https://github.com/ai-ecoverse/am-i-ai) knows, the options the
transcripts actually call for, and none of the side effects.

## What it does

1. **Recognises the agent** from its environment, using am-i-ai's rules:
   Claude Code (CLI, SDK, ACP), Codex, Gemini, Cursor, Copilot, Amp, OpenCode,
   Droid, Auggie, Pi, Qwen, Kimi, Grok, Aider, OpenHands, Goose, Cline, Roo,
   Windsurf and Zed's agent. No process-tree walk: a check costs well under a
   millisecond, because it runs for every `zsh -c`.
2. **Only for agent command strings.** It acts on a non-interactive `zsh -c`
   (or commands piped into zsh). Interactive shells, `zsh script.zsh` and
   `#!/bin/zsh` scripts are written for zsh and keep zsh.
3. **Waits for the agent's command.** The options switch on just before the
   first command of the `-c` string, after `.zshenv`, `.zprofile`, `.zlogin`
   and `/etc/zprofile` have all run with your options. Nothing in your startup
   files ever sees `sh_word_split` or `ksh_arrays`.
4. **Keeps your functions zsh.** Every function your startup files defined, and
   every function in the agent's snapshot of your interactive shell, is pinned
   to the options it was written for (zsh's sticky emulation). The agent can
   call your `mkcd`; it runs as you wrote it.
5. **Sets bash-compatible options**, and leaves no trace: no `DEBUG` trap, no
   helper functions, nothing exported.

### The options

Counts are sessions, out of 384, with that failure in the transcripts.

| option | what it changes | evidence |
| --- | --- | --- |
| `no_nomatch` | an unmatched glob stays literal, as in bash, instead of aborting the command | **208** sessions, ~1,500 errors: `--include=*.ts`, `*.tgz`, `?ref=v1`, `foo[dev]`, `.headRefOid[0:7]` |
| `no_equals` | a word starting with `=` is not a command path | **100** sessions, 275 errors: `echo ====` as a separator (321 commands) |
| `sh_word_split` | unquoted `$var` splits on whitespace | **51** sessions where the agent itself diagnosed it; explicit errors in 14 (`command not found: rustup run stable rustc`); the rest fail silently |
| `ksh_arrays` | arrays index from 0; `$a` is the first element; `$var[…]` and `$var:x` need braces to be a subscript or modifier | **11** sessions with errors: `bad substitution` from `git show $h:src/…` (`:s` is a modifier), `bad math expression` from `"<swc-icon-$i[ >]"` and `$fn[,:]`; more where `$C:r` silently ate an extension |
| `glob_subst` | a glob inside a variable expands when the variable is used unquoted | 1 clear case: `t=data/*/trace.json; ls $t` |
| `bash_rematch` | `[[ =~ ]]` fills `BASH_REMATCH`, and with `ksh_arrays` `${BASH_REMATCH[1]}` is the first group, exactly as in bash | no failures seen (2 uses); free once `ksh_arrays` is on, and without it zsh silently leaves `BASH_REMATCH` empty |
| `no_bad_pattern` | a malformed glob (`[WIP`) stays literal | 2 sessions; the same rule as `no_nomatch`, for patterns that do not parse |
| `no_bare_glob_qual` | `shot*(1)` is not a glob qualifier | none, because Claude Code already sets this before every command; other agents do not |
| `no_extended_glob` | `^`, `~`, `#` are not glob operators, whatever your startup files chose | as above: Claude Code sets it; `git show HEAD^` otherwise depends on your config |

`ksh_arrays` is the one that changes most, which is why point 4 exists:
startup files never see it, your functions are pinned to their own options,
and agents' transcripts sourced no zsh files of their own (0 of 89,000
commands sourced `~/.zshrc` or a `.zsh` file). The 36 real Claude Code shell
snapshots on the author's machine produce the same functions, aliases and
`PATH` with and without it.

### Deliberately left out

| | why |
| --- | --- |
| `interactive_comments` | non-interactive zsh already reads `#` as a comment |
| `bsd_echo` | zsh's `echo` expands `\n`, bash's does not, but no transcript failed on it, and switching would change the output of commands that work today. Add it with `AI_ALIGNED_ZSH_OPTIONS` if you want it |
| `ksh_glob`, `sh_glob` | `@(a\|b)` needs `shopt -s extglob` in bash, which `bash -c` does not have; no failures |
| `posix_builtins`, `posix_*` | change `command` and special builtins; no failures |
| `multios` | `cmd >a >b` writes both in zsh, only `b` in bash; no failures |
| `magic_equal_subst` | would expand `--prefix=~/x`, which bash does not |
| `octal_zeroes` | bash fails on `$((08))`; zsh's lenience breaks nothing |
| `PIPESTATUS`, `${v,,}`, `${!v}`, `mapfile`, `read -a`, `shopt` | no option makes zsh accept them; that would be a bash emulator, not a set of options |

### Where it hooks in

`~/.zshenv` is the only file a non-interactive `zsh -c` reads, so the hook
goes there, at the top, where a `.zshenv` that returns early for
non-interactive shells cannot skip it. Its position does not matter for
timing: it installs a one-shot `DEBUG` trap that waits until zsh's eval
context says the agent's command string has started (`cmdarg`, not `file`).
When that first command sources the agent's snapshot of your interactive
shell, as Claude Code's and Codex's do, it waits one command longer, pins the
snapshot's functions to the snapshot's options, and asserts its own again over
whatever the snapshot set.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ai-ecoverse/ai-aligned-zsh/main/install.sh | sh
```

or from a clone:

```bash
git clone https://github.com/ai-ecoverse/ai-aligned-zsh
cd ai-aligned-zsh
./install.sh
```

This copies the hook to `~/.local/bin/ai-aligned-zsh` and adds a marked block
to the top of `${ZDOTDIR:-$HOME}/.zshenv`, keeping a backup of the original.
Running it again updates the block in place; `./install.sh --uninstall` takes
it out.

**chezmoi.** If chezmoi manages your `.zshenv`, the installer does not touch it
(the next `chezmoi apply` would undo it anyway); it prints the block for you to
add to the top of `dot_zshenv` in your chezmoi source.

```bash
ai-aligned-zsh doctor
```

## Usage

There is none for the agent. For you:

```
ai-aligned-zsh status    would a zsh -c from this environment be aligned, and why
ai-aligned-zsh options   the options it sets
ai-aligned-zsh doctor    check the hook against your real startup files
ai-aligned-zsh detect    full am-i-ai detection, process tree included
```

| environment | |
| --- | --- |
| `AI_ALIGNED_ZSH=off` | leave this shell alone (also honoured when set in your startup files) |
| `AI_ALIGNED_ZSH=on` | align a non-interactive `zsh -c` even without a detected agent |
| `AI_ALIGNED_ZSH_OPTIONS="…"` | replace the option list |
| `AMI_PASSTHROUGH=true` | am-i-ai's opt-out; treated as no agent |

In an aligned shell, `$AI_ALIGNED_ZSH_ACTIVE` names the agent.

## Limits

- **Environment only.** Agents that am-i-ai finds only by walking the process
  tree (Crush, Grok without its variables) are not detected: that walk costs
  150 ms. Set `AI_ALIGNED_ZSH=on` in that agent's environment.
- **am-i-ai's false positives are its own.** A human who exports
  `AUGMENT_API_TOKEN` or `AMP_HOME` in their shell is an agent as far as
  am-i-ai is concerned; their own non-interactive `zsh -c` gets aligned (their
  interactive shell and their scripts still do not).
- **Agents in a pty** run an interactive zsh, which is left alone by design.
- **Nested `zsh -c`** started under an agent, say by a Makefile with
  `SHELL = zsh`, inherits the agent's environment and is aligned too. Code
  written for zsh there wants `AI_ALIGNED_ZSH=off`.
- **A `DEBUG` trap in your startup files** replaces the hook's. `doctor`
  notices.
- Functions defined after the agent's command starts, for instance by a zsh
  file the agent sources itself, run with the agent's options.

## Testing

```bash
./test.sh
```

Every shell runs under `env -i` with a throwaway `HOME` and `ZDOTDIR`, so
neither your dotfiles nor the agent running the suite leak in. The
compatibility cases are commands from the transcripts above: each runs through
bash, through an agent's `zsh -c` and through a human's, and must match bash in
the first and not in the second. Detection is checked against the bundled
am-i-ai for every variable it reads, startup files and snapshots are checked to
keep their zsh semantics, and the installer is run against fake homes,
including a chezmoi-managed one.

## Related

Part of the [AI Ecoverse](https://github.com/ai-ecoverse): see also
[ai-aligned-git](https://github.com/ai-ecoverse/ai-aligned-git),
[ai-aligned-gh](https://github.com/ai-ecoverse/ai-aligned-gh),
[ai-aligned-xcode](https://github.com/ai-ecoverse/ai-aligned-xcode),
[ai-aligned-pkill](https://github.com/ai-ecoverse/ai-aligned-pkill) and
[am-i-ai](https://github.com/ai-ecoverse/am-i-ai).

## License

Apache 2.0, see [LICENSE](LICENSE).
