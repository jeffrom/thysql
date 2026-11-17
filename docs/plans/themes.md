# Plan: colour themes, Catppuccin, and light/dark mode

Let users pick a syntax-highlighting theme, ship the four Catppuccin flavours, and pick
the light or dark variant from the terminal's background:

```ini
# ~/.config/thysql/config
theme = light:catppuccin-latte,dark:catppuccin-mocha
```

```sh
thysql --theme=catppuccin-mocha
thysql --theme=catppuccin        # same as light:catppuccin-latte,dark:catppuccin-mocha
```

## Where things are today

- `replete.Theme` (`lib/replete/src/highlight.zig`) holds one SGR string per `Style`. Its
  defaults are 256-colour mid-tones meant for both light and dark backgrounds.
- thysql never sets a theme: the line editor gets replete's default config theme, and
  `SqlHighlight.Highlighter` (`src/sql_highlight.zig`, used for `SHOW CREATE` output in
  `src/root.zig`) has `theme: replete.Theme = .{}`. The completion menu colours candidates
  through the same theme.
- Colour is on only when stdout is a terminal and `NO_COLOR` is unset or empty
  (`use_color` in `src/root.zig`). Keep that rule.
- The only config today is the connections directory (`src/connections.zig`, ini-like,
  unknown keys are errors) and my.cnf groups (`src/option_file.zig`).

## Step 1: built-in themes (replete + thysql)

Add a theme registry to thysql, e.g. `src/theme.zig`:

- `default`: today's `replete.Theme{}`, unchanged.
- `catppuccin-latte`, `catppuccin-frappe`, `catppuccin-macchiato`, `catppuccin-mocha`.
  Build each from a `Palette` struct with one function `fromPalette(comptime p: Palette) replete.Theme`
  so the four share one mapping. Use truecolor SGR (`38;2;R;G;B`), built at comptime
  (`std.fmt.comptimePrint`).
- Lookup by name, case-insensitive, `-` and `_` the same (as `OptionFile.sameName` does).

Mapping (Catppuccin style guide):

| Style | Colour |
| --- | --- |
| keyword | mauve, bold |
| keyword_nonreserved | mauve |
| identifier | plain (`""`) |
| quoted_identifier | flamingo |
| string | green |
| number | peach |
| comment | overlay2, italic (`3`) |
| operator | sky |
| variable | maroon |
| function | blue |
| delimiter | overlay2, bold |
| client_command | pink |
| error | curly underline in red: `\x1b[4:3m\x1b[58:2::R:G:Bm` |
| hint | overlay1 |
| diagnostic | red |

`Theme.sgr` returns a hard-coded `\x1b[4m` for errors when `undercurl` is false. Keep the
underline colour in that case too: add a `error_color: []const u8 = ""` field to
`replete.Theme` (an SGR such as `\x1b[58:2::R:G:Bm`, appended after the underline in both
cases) rather than baking it into `error`. Update replete's tests.

Palettes (hex):

| | latte | frappe | macchiato | mocha |
| --- | --- | --- | --- | --- |
| flamingo | dd7878 | eebebe | f0c6c6 | f2cdcd |
| pink | ea76cb | f4b8e4 | f5bde6 | f5c2e7 |
| mauve | 8839ef | ca9ee6 | c6a0f6 | cba6f7 |
| red | d20f39 | e78284 | ed8796 | f38ba8 |
| maroon | e64553 | ea999c | ee99a0 | eba0ac |
| peach | fe640b | ef9f76 | f5a97f | fab387 |
| yellow | df8e1d | e5c890 | eed49f | f9e2af |
| green | 40a02b | a6d189 | a6da95 | a6e3a1 |
| teal | 179299 | 81c8be | 8bd5ca | 94e2d5 |
| sky | 04a5e5 | 99d1db | 91d7e3 | 89dceb |
| blue | 1e66f5 | 8caaee | 8aadf4 | 89b4fa |
| overlay2 | 7c7f93 | 949cbb | 939ab7 | 9399b2 |
| overlay1 | 8c8fa1 | 838ba7 | 8087a2 | 7f849c |

Thread a `replete.Theme` through to both the line editor config and every
`SqlHighlight.Highlighter` construction (`src/root.zig`, and the test in `src/mysql.zig`),
so one chosen theme is used everywhere. In this step it is always `default`, so behaviour
does not change. Tests: lookup by name and aliases, every Catppuccin style but
`identifier` non-empty, the mocha keyword is `\x1b[1;38;2;203;166;247m`.

## Step 2: the `theme` setting

- New general config file `$XDG_CONFIG_HOME/thysql/config`, or `$HOME/.config/thysql/config`
  when XDG_CONFIG_HOME is unset or empty (the same rule as `connections.rootDir`; share the
  helper). Same ini-like syntax as connection files: `key = value`, `#` comments. Unknown
  keys are an error naming the file and line. A missing file is fine. Only key for now: `theme`.
- New flag `--theme=<spec>`, in the output group of `src/options.zig`. The flag wins over the file.
- `<spec>` is one of:
  - a theme name: `default`, `catppuccin-latte`, ... ;
  - `catppuccin`: shorthand for `light:catppuccin-latte,dark:catppuccin-mocha`;
  - a pair `light:<name>,dark:<name>` (either order, spaces around `,` and `:` allowed).
  Parse into `ThemeChoice = union(enum) { fixed: Name, pair: struct { light: Name, dark: Name } }`.
  Bad specs are an error that lists the valid names.
- Resolve the choice to a theme once at startup. In this step a pair always resolves to
  its `dark` theme (step 3 adds detection).
- Truecolor: if the chosen theme is not `default` and `COLORTERM` is not `truecolor` or
  `24bit`, still use it (most modern terminals support truecolor without setting COLORTERM
  over ssh). Do not add a fallback.
- `NO_COLOR` / not-a-tty still turns all colour off, as today.
- Shell completion: `thysql complete` and `src/completion/thysql.bash` should complete
  `--theme` values with the names and `catppuccin`, if the existing completion code makes
  that easy for enum-valued flags; skip it otherwise.
- Document the config file and `--theme` in README.md (short section).
- Tests: spec parsing (names, alias, pair, both orders, errors), the config file parser
  (theme key, unknown key error with file:line, missing file), flag overrides file.

## Step 3: light/dark detection at startup

Only when the choice is a `pair` and stdin and stdout are terminals and colour is on.

- In replete `terminal.zig`, add `pub fn queryBackground(in_fd, out_fd, timeout_ms) ?Rgb`:
  1. Enter raw mode (reuse `TermState`), restore it on every path.
  2. Write `\x1b]11;?\x1b\\` then `\x1b[c` (DA1). Every terminal answers DA1, so when the
     DA1 reply (`\x1b[?...c`) arrives before an OSC 11 reply, the terminal does not
     support the query and we stop without waiting out the timeout.
  3. Read with `waitInput`, total budget `timeout_ms` (use 100 ms from thysql).
  4. Parse `\x1b]11;rgb:RRRR/GGGG/BBBB` ended by BEL or `ESC \`. Components may have 1-4
     hex digits; scale each to 0-255.
  5. Return null on timeout, parse failure, or no OSC 11 reply.
  Put the reply parser in its own pure function with tests (BEL and ST endings, 2- and
  4-digit components, garbage, DA1-only).
- `pub fn isDark(rgb) bool`: relative luminance (sRGB weights 0.2126/0.7152/0.0722 on
  0-1 values; no gamma correction needed) below 0.5.
- Fallback when the query returns null: `COLORFGBG` env (`fg;bg` or `fg;x;bg`; take the
  last field; 0-6 and 8 are dark, 7 and 9-15 are light). Otherwise dark.
- thysql resolves the pair with this before the line editor starts. Keystrokes typed during
  the ~100 ms window may be lost; that is acceptable.
- Tests for the parser, `isDark`, and the COLORFGBG fallback (as pure functions taking the
  env value).

## Step 3b: per-connection themes

- Connection files and directory `config` files in the connections tree may set `theme`,
  with the same values as the general config file. It works like `prompt-color`
  (`src/connections.zig`): not a setting passed to the server, the nearest file or
  directory with one wins, and the result is exposed as `Selection.theme()` (`?Theme.Choice`).
  It is no longer an unknown key there.
- Precedence: `--theme`, then the connection's theme, then the general config file, then `default`.
- `\C` (the connection switch in `src/root.zig`, next to where `connection_color` is updated)
  re-resolves the theme for the new connection, so switching from `prod` to `dev` can change
  colours. `--theme` still wins over every connection.
- The background is detected at most once per process: cache the dark/light answer from
  startup (or detect lazily the first time a pair is in effect) and reuse it on `\C`.
- The line editor must pick up the new theme without restarting: add a way to change the
  theme of a running replete editor (e.g. `Repl.setTheme` or a mutable theme the config
  points at) that the next redraw uses, and update `Repl.theme` in thysql so `SHOW CREATE`
  output follows too. Keep one function in thysql, e.g. `applyTheme(session, choice)`,
  that both `\C` and step 4 call.
- README: mention `theme` next to `prompt-color` in the connections section.
- Tests: connection theme parsing and inheritance (nearest wins, invalid value names file
  and line), precedence, and the editor's theme changing at runtime.

## Step 4: live light/dark switching (mode 2031)

Terminals such as Ghostty, kitty and Contour report OS appearance changes:

- Enable with `CSI ? 2031 h` (`\x1b[?2031h`) when the line editor starts, and disable with
  `CSI ? 2031 l` when it stops and on every exit path (including signals/panics where
  replete already restores the terminal). Terminals that do not support it ignore it.
- On a change the terminal sends `CSI ? 997 ; 1 n` (dark) or `CSI ? 997 ; 2 n` (light).
  replete's key/escape parser must recognise this sequence, never insert it as text, and
  report it through a new optional callback in replete's config, e.g.
  `color_scheme: ?struct { context: *anyopaque, changed: *const fn (*anyopaque, dark: bool) void }`.
  After the callback the editor redraws the current line with the (possibly new) theme.
- Enable the mode only when a config callback is set; thysql sets it only when the theme in
  effect is a pair (re-evaluate on `\C`: a connection may move from a fixed theme to a pair).
- thysql's callback updates the cached dark/light answer and calls the step 3b
  `applyTheme`. Reports that arrive while a query is running are read the next time the
  editor reads input, which is fine.
- Tests: the parser turns both reports into callback calls and leaves the line unchanged;
  unrelated `CSI ? ... n` sequences are still ignored as before; the enable/disable
  sequences are written only with a callback set.

## Out of scope for now

User-defined theme files.
