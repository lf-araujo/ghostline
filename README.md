# ghostline

Fish-style ghost (phantom) autosuggestions for bash, in pure Nim — a fast
replacement for the ble.sh `auto-complete` feature.

## How it works

An external program cannot paint text into bash's own readline, so ghostline
works like rlwrap: it puts your terminal in raw mode, runs bash on a
pseudo-terminal, and owns the line editor itself. Bash's real prompt (colors,
multi-line, git branch — everything) is passed through untouched. As you
type, ghostline draws a dim gray suggestion:

- from your history (`$HISTFILE`, default `~/.bash_eternal_history`) — the
  most recent entry that starts with what you typed
- otherwise, from the filesystem — the first match for the current word
  (supports `~`)

## Usage

    ./ghostline            # runs bash -i
    ./ghostline bash       # or any other program

Add an alias in ~/.bashrc if you like:

    alias gsh='~/Documents/OneDrive/Coding/Nim/Programas/ghostline/ghostline'

ble.sh must not load inside ghostline (it would fight over the terminal), so
.bashrc should guard it:

    if [ -z "$GHOSTLINE" ]; then
      source ~/.local/share/blesh/ble.sh
    fi

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
| C-c            | cancel line, interrupt bash             |
| C-l            | clear screen                            |
| C-d (empty line) | exit                                    |

## Build

    nim c -d:release --opt:speed -o:ghostline ghostline.nim

## Limitations

- Tab only accepts the ghost; bash's full TAB-completion menus are not
  reimplemented (that's the point — this does *only* the phantom completion).
- No C-r reverse search, no C-z suspend of ghostline itself.
- Editing lines longer than the screen height is not scroll-aware.
