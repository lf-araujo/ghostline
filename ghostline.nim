## ghostline — fish-style ghost autosuggestions for bash.
##
## An rlwrap-style pty wrapper: it runs bash on a pseudo-terminal, owns the
## line editor itself, passes bash's real prompt through untouched, and draws
## a dim "ghost" completion (from history, else from the filesystem) that is
## accepted with →, End, C-f or TAB.

import std/[posix, os, strutils, algorithm]
import posix/termios

proc posixOpenpt(flags: cint): cint {.importc: "posix_openpt", header: "<stdlib.h>".}
proc grantpt(fd: cint): cint {.importc: "grantpt", header: "<stdlib.h>".}
proc unlockpt(fd: cint): cint {.importc: "unlockpt", header: "<stdlib.h>".}
proc ptsname(fd: cint): cstring {.importc: "ptsname", header: "<stdlib.h>".}
proc ioctlP(fd: cint, request: culong, arg: pointer): cint {.
  importc: "ioctl", header: "<sys/ioctl.h>", varargs.}

const
  TIOCSWINSZ = culong(0x5414)
  TIOCSCTTY = culong(0x540E)
  SIGWINCH = 28.cint          # Linux

var
  mfd: cint = -1            # pty master
  childPid: Pid = 0
  cols = 80
  rows = 24
  savedTio: Termios
  line: string = ""          # current input line (UTF-8)
  cur = 0                    # cursor byte offset into `line`
  hist: seq[string]
  histIdx = -1               # -1 = not browsing history
  savedLine = ""
  prompt = ""                # unterminated tail of child output = current prompt
  promptRows = 0             # prompt layout at last render
  promptLast = 0
  anchorRow = 0              # cursor row within our drawn region
  keys = ""                  # pending input bytes
  dirty = false
  drawn = false              # do we have a line drawing on screen?
  fullRedraw = false
  winchFlag = false
  running = true

proc writeStr(fd: cint, s: string) =
  ## Write all of `s` to `fd`, retrying on partial writes and EINTR.
  var i = 0
  while i < s.len:
    let n = posix.write(fd, unsafeAddr s[i], s.len - i)
    if n > 0:
      inc i, n
    elif n < 0 and errno == EINTR:
      discard
    else:
      break

proc runeLen(b: byte): int =
  ## Length in bytes of the UTF-8 sequence that starts with byte `b`.
  if b < 0x80: 1
  elif b < 0xC0: 1
  elif b < 0xE0: 2
  elif b < 0xF0: 3
  else: 4

proc nextRune(s: string, i: var int): int32 =
  ## Decode the rune at `s[i]`, advancing `i` past it. Stray continuation
  ## bytes decode as themselves.
  let b0 = s[i].ord
  let n = runeLen(s[i].byte)
  if i + n > s.len:
    inc i
    return b0.int32
  var r: int = b0
  if n == 2:
    r = ((b0 and 0x1F) shl 6) or (s[i+1].ord and 0x3F)
  elif n == 3:
    r = ((b0 and 0x0F) shl 12) or ((s[i+1].ord and 0x3F) shl 6) or
       (s[i+2].ord and 0x3F)
  elif n == 4:
    r = ((b0 and 0x07) shl 18) or ((s[i+1].ord and 0x3F) shl 12) or
       ((s[i+2].ord and 0x3F) shl 6) or (s[i+3].ord and 0x3F)
  inc i, n
  r.int32

proc runeWidth(r: int32): int =
  ## Terminal column width of a rune: 0 for control and combining
  ## characters, 2 for East Asian wide ranges, 1 otherwise.
  if r < 0x20: return 0
  if (r >= 0x0300 and r <= 0x036F) or (r >= 0x1AB0 and r <= 0x1AFF) or
     (r >= 0x20D0 and r <= 0x20FF) or (r >= 0xFE00 and r <= 0xFE0F) or
     (r >= 0xFE20 and r <= 0xFE2F): return 0
  if (r >= 0x1100 and r <= 0x115F) or (r >= 0x2E80 and r <= 0x303E) or
     (r >= 0x3041 and r <= 0x33FF) or (r >= 0x3400 and r <= 0x4DBF) or
     (r >= 0x4E00 and r <= 0x9FFF) or (r >= 0xAC00 and r <= 0xD7A3) or
     (r >= 0xF900 and r <= 0xFAFF) or (r >= 0xFE30 and r <= 0xFE4F) or
     (r >= 0xFF00 and r <= 0xFF60) or (r >= 0xFFE0 and r <= 0xFFE6) or
     (r >= 0x1F300 and r <= 0x1F64F) or (r >= 0x20000 and r <= 0x3FFFD):
    return 2
  1

proc stripAnsi(s: string): string =
  ## Remove ANSI escape sequences (CSI, OSC, two-byte ESC) so the result's
  ## width reflects only visible text.
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '\x1b':
      inc i
      if i < s.len and s[i] == '[':
        inc i
        while i < s.len and s[i].ord < 0x40: inc i
        if i < s.len: inc i
      elif i < s.len and s[i] == ']':
        inc i
        while i < s.len:
          if s[i] == '\x07': inc i; break
          if s[i] == '\x1b' and i + 1 < s.len and s[i+1] == '\\':
            inc(i, 2); break
          inc i
      elif i < s.len:
        inc i
    else:
      result.add s[i]
      inc i

proc strWidth(s: string): int =
  ## Sum of the terminal column widths of all runes in `s`.
  var i = 0
  while i < s.len:
    inc result, runeWidth(nextRune(s, i))

# (rows before the last line, width of the last line)
proc layout(s: string): tuple[rows, last: int] =
  ## Geometry of a possibly multi-line prompt: how many rows precede its
  ## last line, and the width of that last line.
  let t = stripAnsi(s)
  var row = 0
  var w = 0
  var i = 0
  while i < t.len:
    let r = nextRune(t, i)
    if r == 10:
      inc row, (w div cols) + 1
      w = 0
    else:
      inc w, runeWidth(r)
  (row, w)

proc fileGhost(): string =
  ## Ghost completion for the current word as a filesystem path: the first
  ## entry in the word's directory that extends what was typed (directories
  ## get a trailing '/'). Supports '~' and '~/' prefixes.
  result = ""
  if line.len == 0: return
  var j = line.len - 1
  while j >= 0 and line[j] notin {' ', '\t'}: dec j
  var w = line[j+1 .. ^1]
  if w.len == 0 or '\n' in w: return
  if w.startsWith("~"):
    if w == "~" or w.startsWith("~/"):
      w = getHomeDir() / w[1 .. ^1]
    else:
      return               # ~user not supported
  let slash = w.rfind('/')
  var dir, base: string
  if slash < 0:
    dir = "."; base = w
  elif slash == 0:
    dir = "/"; base = w[1 .. ^1]
  else:
    dir = w[0 ..< slash]; base = w[slash+1 .. ^1]
  if base.len == 0 or not dirExists(dir): return
  var cands: seq[string]
  for kind, e in walkDir(dir):
    let name = lastPathPart(e)
    if not name.startsWith(base): continue
    if name == base: continue
    if base[0] != '.' and name[0] == '.': continue
    cands.add name & (if kind == pcDir: "/" else: "")
  if cands.len == 0: return
  sort(cands)
  result = cands[0][base.len .. ^1]

proc ghost(): string =
  ## The ghost suggestion for the current line: the remainder of the most
  ## recent history entry that starts with `line`, falling back to a
  ## filesystem match for the last word.
  if line.len == 0: return ""
  for i in countdown(hist.high, 0):
    if hist[i].len > line.len and hist[i].startsWith(line):
      return hist[i][line.len .. ^1]
  return fileGhost()

proc render() =
  ## Draw prompt + line + ghost at the anchor, then place the cursor. When
  ## a drawing is already on screen it is erased first; otherwise the line
  ## is simply appended after the prompt the child left.
  if line.len == 0 and not drawn and not fullRedraw:
    return
  var o = ""
  let (pRows, pLast) = layout(prompt)
  promptRows = pRows
  promptLast = pLast
  if drawn or fullRedraw:
    if anchorRow > 0:
      o.add "\x1b[" & $anchorRow & "A"
    o.add "\r\x1b[J"
    o.add prompt
  else:
    anchorRow = pRows      # cursor already sits at the end of the prompt
  let g = ghost()
  o.add line
  if g.len > 0:
    o.add "\x1b[90m" & g & "\x1b[39m"
  let cW = strWidth(line[0 ..< cur])
  let lastW = pLast + strWidth(line) + strWidth(g)
  let cursorRow = pRows + (pLast + cW) div cols
  let cursorCol = (pLast + cW) mod cols
  let afterRow = pRows + (if lastW == 0: 0
                          elif lastW mod cols == 0: lastW div cols - 1
                          else: lastW div cols)
  o.add "\r"
  if afterRow > cursorRow:
    o.add "\x1b[" & $(afterRow - cursorRow) & "A"
  if cursorCol > 0:
    o.add "\x1b[" & $cursorCol & "C"
  anchorRow = cursorRow
  drawn = true
  fullRedraw = false
  writeStr(1, o)

proc eraseLine() =
  ## Erase the line/ghost drawing, leaving the child's prompt on screen
  ## with the cursor at its end.
  var o = ""
  let up = anchorRow - promptRows
  if up > 0:
    o.add "\x1b[" & $up & "A"
  o.add "\r"
  if promptLast > 0:
    o.add "\x1b[" & $promptLast & "C"
  o.add "\x1b[J"
  anchorRow = promptRows
  drawn = false
  writeStr(1, o)

proc clearScreen() =
  ## C-l: wipe the screen and redraw prompt + line from the top.
  writeStr(1, "\x1b[2J\x1b[H")
  anchorRow = 0
  drawn = false
  fullRedraw = true
  render()
  dirty = false

proc insertText(s: string) =
  ## Insert `s` at the cursor and advance the cursor past it.
  if s.len == 0: return
  line = line[0 ..< cur] & s & line[cur .. ^1]
  inc cur, s.len
  histIdx = -1
  dirty = true

proc backspace() =
  ## Delete the rune before the cursor.
  if cur == 0: return
  var i = cur - 1
  while i > 0 and (line[i].byte and 0xC0) == 0x80: dec i
  line.delete(i .. cur - 1)
  cur = i
  dirty = true

proc deleteAt() =
  ## Delete the rune at the cursor.
  if cur >= line.len: return
  var j = cur + 1
  while j < line.len and (line[j].byte and 0xC0) == 0x80: inc j
  line.delete(cur .. j - 1)
  dirty = true

proc moveLeft() =
  ## Move the cursor one rune to the left.
  if cur > 0:
    dec cur
    while cur > 0 and (line[cur].byte and 0xC0) == 0x80: dec cur
    dirty = true

proc moveRight() =
  ## Move the cursor one rune to the right.
  if cur < line.len:
    inc cur
    while cur < line.len and (line[cur].byte and 0xC0) == 0x80: inc cur
    dirty = true

proc wordStart(): int =
  ## Byte offset of the start of the word before the cursor, skipping any
  ## preceding whitespace.
  var i = cur
  while i > 0 and line[i-1] in {' ', '\t'}: dec i
  while i > 0 and line[i-1] notin {' ', '\t'}: dec i
  i

proc wordEnd(): int =
  ## Byte offset just past the word at the cursor, skipping any whitespace.
  var i = cur
  while i < line.len and line[i] in {' ', '\t'}: inc i
  while i < line.len and line[i] notin {' ', '\t'}: inc i
  i

proc killWordLeft() =
  ## Delete from the start of the previous word up to the cursor.
  if cur == 0: return
  let i = wordStart()
  line.delete(i .. cur - 1)
  cur = i
  dirty = true

proc killWordRight() =
  ## Delete from the cursor to the end of the next word.
  let j = wordEnd()
  if j > cur:
    line.delete(cur .. j - 1)
    dirty = true

proc moveWordLeft() =
  ## Move the cursor to the start of the previous word.
  cur = wordStart()
  dirty = true

proc moveWordRight() =
  ## Move the cursor just past the next word.
  cur = wordEnd()
  dirty = true

proc histPrev() =
  ## Up-arrow: replace the line with the previous history entry, saving the
  ## line being edited first.
  if hist.len == 0: return
  if histIdx == -1:
    savedLine = line
    histIdx = hist.high
  elif histIdx > 0:
    dec histIdx
  else:
    return
  line = hist[histIdx]
  cur = line.len
  dirty = true

proc histNext() =
  ## Down-arrow: move forward in history, restoring the saved line at the
  ## end of the browse.
  if histIdx == -1: return
  inc histIdx
  if histIdx > hist.high:
    histIdx = -1
    line = savedLine
  else:
    line = hist[histIdx]
  cur = line.len
  dirty = true

proc acceptGhost(): bool =
  ## Accept the ghost suggestion when the cursor is at end of line.
  ## Returns true if a suggestion was accepted.
  if cur == line.len:
    let g = ghost()
    if g.len > 0:
      line.add g
      cur = line.len
      histIdx = -1
      dirty = true
      return true
  false

proc submit() =
  ## Enter: send the line to the child shell and reset the editor. The
  ## child's readline echoes the line itself, so only our drawing is
  ## erased first.
  if drawn: eraseLine()
  let l = line
  line = ""
  cur = 0
  histIdx = -1
  savedLine = ""
  anchorRow = 0
  promptRows = 0
  promptLast = 0
  drawn = false
  if l.len > 0 and (hist.len == 0 or hist[^1] != l):
    hist.add l
  writeStr(mfd, l & "\n")
  dirty = false

proc interrupt() =
  ## C-c: discard the line and forward SIGINT to the child's foreground
  ## process group, letting bash print its own '^C' and a fresh prompt.
  if drawn: eraseLine()
  line = ""
  cur = 0
  histIdx = -1
  savedLine = ""
  anchorRow = 0
  promptRows = 0
  promptLast = 0
  drawn = false
  let pg = tcgetpgrp(mfd)
  if pg > 1:
    discard kill(-pg, SIGINT)
  dirty = false

proc eofKey() =
  ## C-d on an empty line: ask the child shell to exit.
  if line.len == 0:
    if drawn: eraseLine()
    drawn = false
    writeStr(mfd, "exit\n")
    dirty = false

proc dispatchOne(): bool =
  ## Consume and act on one key or escape sequence from `keys`. Returns
  ## false when more bytes are needed to complete the sequence at the head.
  if keys.len == 0: return false
  let c = keys[0]
  if c == '\x1b':
    if keys.len == 1: return false          # lone ESC: wait for more
    case keys[1]
    of '[':
      if keys.startsWith("\x1b[200~"):     # bracketed paste
        let k = keys.find("\x1b[201~")
        if k < 0: return false
        insertText(keys[6 ..< k])
        keys.delete(0 .. k + 4)
        return true
      var i = 2
      while i < keys.len and keys[i].ord < 0x40: inc i
      if i >= keys.len: return false        # incomplete CSI
      let final = keys[i]
      let params = keys[2 ..< i]
      keys.delete(0 .. i)
      case final
      of 'A': histPrev()
      of 'B': histNext()
      of 'C':
        if not acceptGhost(): moveRight()
      of 'D': moveLeft()
      of 'H': cur = 0; dirty = true
      of 'F': cur = line.len; dirty = true
      of '~':
        case params
        of "1", "7": cur = 0; dirty = true
        of "4", "8": cur = line.len; dirty = true
        of "3": deleteAt()
        else: discard
      else: discard
      return true
    of 'O':
      if keys.len < 3: return false
      let f2 = keys[2]
      keys.delete(0 .. 2)
      case f2
      of 'A': histPrev()
      of 'B': histNext()
      of 'C':
        if not acceptGhost(): moveRight()
      of 'D': moveLeft()
      of 'H': cur = 0; dirty = true
      of 'F': cur = line.len; dirty = true
      else: discard
      return true
    of 'b': keys.delete(0 .. 1); moveWordLeft(); return true
    of 'f': keys.delete(0 .. 1); moveWordRight(); return true
    of 'd': keys.delete(0 .. 1); killWordRight(); return true
    of '\x7f': keys.delete(0 .. 1); killWordLeft(); return true
    else: keys.delete(0 .. 1); return true
  if c < ' ' or c == '\x7f':
    keys.delete(0 .. 0)
    case c
    of '\r', '\n': submit()
    of '\x7f': backspace()
    of '\x03': interrupt()
    of '\x04': eofKey()
    of '\x01': cur = 0; dirty = true
    of '\x05': cur = line.len; dirty = true
    of '\x02': moveLeft()
    of '\x06':
      if not acceptGhost(): moveRight()
    of '\x0b':
      if cur < line.len:
        line.delete(cur .. line.len - 1)
        dirty = true
    of '\x15': line = ""; cur = 0; dirty = true
    of '\x17': killWordLeft()
    of '\x0c': clearScreen()
    of '\x09': discard acceptGhost()
    of '\x08': backspace()
    else: discard
    return true
  let n = runeLen(keys[0].byte)
  if keys.len < n: return false             # incomplete UTF-8
  insertText(keys[0 ..< n])
  keys.delete(0 .. n - 1)
  true

proc handleInput(s: string) =
  ## Append newly read bytes and dispatch as many keys as possible.
  keys.add s
  while dispatchOne():
    if not running: break

proc pump() =
  ## Read child output, pass it through to the terminal, and keep the
  ## unterminated tail as the current prompt. Any line drawing is erased
  ## first so new output lands right after the prompt.
  var data: array[8192, char]
  let n = read(mfd, addr data[0], 8192)
  if n <= 0:
    if errno == EINTR: return
    running = false
    return
  var s = newString(n)
  copyMem(addr s[0], addr data[0], n)
  if drawn:
    eraseLine()
  writeStr(1, s)
  anchorRow = 0
  prompt.add s
  let nl = prompt.rfind('\n')
  if nl >= 0:
    prompt = prompt[nl + 1 .. ^1]
  if prompt.len > 16384:
    prompt = ""
  dirty = true

proc syncSize() =
  ## Adopt the real terminal's size and push it to the pty.
  var ws: IOctl_WinSize
  if ioctl(0, TIOCGWINSZ, addr ws) == 0 and ws.ws_col > 0:
    cols = ws.ws_col.int
    rows = ws.ws_row.int
  var w2: IOctl_WinSize
  w2.ws_row = rows.cushort
  w2.ws_col = cols.cushort
  discard ioctlP(mfd, TIOCSWINSZ, addr w2)

proc main() =
  ## Set up the pty and child shell, put the terminal in raw mode, and run
  ## the select loop until the child exits.
  if isatty(0) == 0:
    # not a terminal: no line editing to do, just exec
    var args = commandLineParams()
    if args.len == 0: args = @["bash"]
    let cargv = allocCStringArray(args)
    discard execvp(cstring(args[0]), cargv)
    quit(127)

  putEnv("GHOSTLINE", "1")

  let histFile = getEnv("HISTFILE", getHomeDir() / ".bash_eternal_history")
  if fileExists(histFile):
    for l in lines(histFile):
      if l.len > 0:
        hist.add l

  mfd = posixOpenpt(O_RDWR or O_NOCTTY)
  if mfd < 0:
    stderr.writeLine("ghostline: cannot allocate pty")
    quit(1)
  discard grantpt(mfd)
  discard unlockpt(mfd)
  let slavePath = $ptsname(mfd)

  let pid = fork()
  if pid == 0:
    discard setsid()
    let slave = open(cstring(slavePath), O_RDWR)
    if slave < 0: quit(1)
    discard ioctlP(slave, TIOCSCTTY, nil)
    discard dup2(slave, 0)
    discard dup2(slave, 1)
    discard dup2(slave, 2)
    if slave > 2: discard close(slave)
    discard close(mfd)
    var args: seq[string]
    if commandLineParams().len > 0:
      args = commandLineParams()
    else:
      args = @["bash", "-i"]
    let cargv = allocCStringArray(args)
    discard execvp(cstring(args[0]), cargv)
    quit(127)
  childPid = pid

  discard tcGetAttr(0, addr savedTio)
  var t = savedTio
  t.c_iflag = t.c_iflag and not (IGNBRK or BRKINT or PARMRK or ISTRIP or
                                 INLCR or IGNCR or ICRNL or IXON)
  t.c_oflag = t.c_oflag and not OPOST
  t.c_lflag = t.c_lflag and not (ECHO or ECHONL or ICANON or ISIG or IEXTEN)
  t.c_cflag = t.c_cflag and not (CSIZE or PARENB)
  t.c_cflag = t.c_cflag or CS8
  t.c_cc[VMIN] = '\x01'
  t.c_cc[VTIME] = '\x00'
  discard tcSetAttr(0, TCSANOW, addr t)

  onSignal(SIGWINCH):
    winchFlag = true

  syncSize()

  while running:
    if winchFlag:
      winchFlag = false
      syncSize()
      dirty = true
    var rf: TFdSet
    FD_ZERO(rf)
    FD_SET(mfd, rf)
    FD_SET(0, rf)
    let nfd = (if mfd > 0: mfd else: 0) + 1
    let r = select(nfd, addr rf, nil, nil, nil)
    if r < 0:
      if errno == EINTR: continue
      break
    if FD_ISSET(0, rf) != 0:
      var data: array[4096, char]
      let n = read(0, addr data[0], 4096)
      if n > 0:
        var s = newString(n)
        copyMem(addr s[0], addr data[0], n)
        handleInput(s)
      elif n == 0:
        running = false
    if running and FD_ISSET(mfd, rf) != 0:
      pump()
    if dirty:
      render()
      dirty = false

  discard tcSetAttr(0, TCSANOW, addr savedTio)
  var status: cint = 0
  discard waitpid(childPid, status, 0)
  if (status and 0x7F) == 0:
    quit(((status shr 8) and 0xFF).int)
  else:
    quit((128 + (status and 0x7F)).int)

main()
