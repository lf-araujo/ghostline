# ghostline

Fish-style ghost (phantom) autosuggestions for bash and zsh, in pure Nim — a
fast replacement for ble.sh's `auto-complete` or zsh-autosuggestions. Runs on
Linux and macOS.

## How it works

An external program cannot paint text into bash's own readline, so ghostline
works like rlwrap: it puts your terminal in raw mode, runs your shell on a
pseudo-terminal, and owns the line editor itself. The shell's real prompt
(colors, multi-line, git branch — everything) is passed through untouched. As
you type, ghostline draws a dim gray suggestion:

- from your history — the most recent entry that starts with what you typed.
  The file is `$GHOSTLINE_HISTFILE`, else an exported `$HISTFILE`, else
  `${ZDOTDIR:-~}/.zsh_history` for zsh and `~/.bash_eternal_history` (or
  `~/.bash_history`) for bash. zsh's `EXTENDED_HISTORY` format is understood.
- otherwise, from the filesystem — the first match for the current word
  (supports `~`)

ghostline only edits while bash's readline is waiting for a command. When
anything else reads the terminal (a running program, a password prompt,
`read -s`, a full-screen app like vim or Claude Code), keys go straight
through, so the terminal's own echo settings apply.

## Usage

    ./ghostline            # runs $SHELL -i
    ./ghostline zsh -i     # or any other program

ghostline sets `GHOSTLINE=1` for the shell it runs. Use it to start ghostline
automatically without recursing, and to keep other line-editor add-ons (which
would fight over the terminal) out of the inner shell.

### zsh

In `~/.zshrc`:

    if [[ -z $GHOSTLINE && -o interactive && -t 0 ]] && command -v ghostline >/dev/null; then
      exec ghostline
    fi
    # anything below runs inside ghostline; don't load zsh-autosuggestions here

A precmd prompt such as nicy works unchanged.

### bash

Add an alias in ~/.bashrc if you like:

    alias gsh='~/Documents/OneDrive/Coding/Nim/Programas/ghostline/ghostline'

ble.sh must not load inside ghostline, so .bashrc should guard it:

    if [ -z "$GHOSTLINE" ]; then
      source ~/.local/share/blesh/ble.sh
    fi

## Empty-command hook

Set `GHOSTLINE_EMPTY_CMD` to a command that runs when you press Enter twice
on an empty line — a stray single Enter still just gives a fresh prompt.
In `~/.bashrc` or `~/.zshrc`:

    export GHOSTLINE_EMPTY_CMD=nitch

Any real command or C-c resets the count.

## Keys

| Key            | Action                                  |
|----------------|-----------------------------------------|
| → / End / C-f  | accept the ghost suggestion             |
| Tab            | accept the ghost suggestion             |
| any typing     | suggestion updates live                 |
| ↑ / ↓          | browse history                          |
| C-a / C-e / ←  | home / end / left                       |
| C-k / C-u      | kill to end / kill whole line          |
| C-w / M-backspace | kill word left                      |
| M-b / M-f / M-d | word left / word right / kill word right |
| C-c            | cancel line, interrupt the shell        |
| C-l            | clear screen                            |
| C-d (empty line) | exit                                    |

## Build

    nim c -d:release --opt:speed -o:ghostline ghostline.nim

## Limitations

- Tab only accepts the ghost; the shell's own TAB-completion menus are not
  reimplemented (that's the point — this does *only* the phantom completion).
- No C-r reverse search, no C-z suspend of ghostline itself.
- Editing lines longer than the screen height is not scroll-aware.
- Multi-line history entries are not suggested.
