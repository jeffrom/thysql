# Plan: a clearer prompt for -C and \C connections

Since `0f8e34a`, a `-C` or `\C` connection's built-in prompt is `name/database> `, such as
`main/ro/mydb> `. Connection names can contain `/`, so you can't tell where the name ends and the
database starts. It also reads like the `user@host:port/database> ` prompt used without `-C`, as if
`main` were a host and `ro/mydb` a path.

## Decisions

| Topic | Decision |
|---|---|
| Format | `[name] database> `, such as `[main/ro] mydb> ` and `[main/ro] (none)> `. The brackets set the connection off as a tag, and a space separates the database. |
| Without -C | Unchanged: `user@host:port/database> `. |
| Colour | New connection-file key `prompt-color`. With it set, the `[name]` tag (brackets included) is drawn in that colour; without it, no colour. Values: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, their `bright-` forms, and `none`. An unknown name is an error when the connection is loaded, naming the file and line. |
| Where `prompt-color` is allowed | Connection files and directory `config` files (so `main/config` can colour every connection under `main`). Not a command-line flag or my.cnf key. |
| When colour is drawn | Only when stdout is a terminal and `NO_COLOR` is unset or empty. |
| Tee file | The tee copy of the prompt never has escape codes. |
| `\C` switching | The tag and its colour follow the new connection. A `\C` that fails keeps the old prompt. |
| `--prompt` / `MYSQL_PS1` / `prompt` command | Unchanged: a custom format replaces the built-in prompt entirely, colour included. The `\C` escape still prints the bare name. |

## Steps

Each step is one or more commits on `main` with `zig build test` green.

### 1. Prompt text

- `connectionPrompt` in `src/root.zig` builds `[name] database> ` for connections. Move it to
  `src/prompt.zig` as a pure function (`builtinPrompt(allocator, facts, color: ?Color, use_color: bool)`)
  so it can be unit tested without a REPL.
- Unit tests: with and without a connection, `(none)`, names with `/`.
- Update the README's prompt description and the e2e tests that expect `name/db> `
  (grep `tests/e2e` for prompts ending in `> `).

### 2. `prompt-color`

- `src/connections.zig`: parse `prompt-color` in connection files and directory `config`
  files; a connection file's value overrides its directory's. Validate the colour name.
- Carry it through `Options` (or the resolved connection) to the REPL, and through `\C`.
- `src/prompt.zig`: wrap the tag in `ESC[<n>m` … `ESC[0m` when `use_color`. replete already
  measures CSI sequences as zero width (`appendPrompt` in `lib/replete/src/display.zig`), so
  cursor placement stays right. Add a replete test for a coloured prompt if there isn't one.
- Tee: strip CSI sequences from the prompt in `Client.teeLine` (or pass it the plain text).
- `NO_COLOR` and non-tty stdout turn colour off.
- Unit tests: each colour code, `none`, an invalid name with its file and line, directory inheritance.

### 3. e2e tests

- `-C` prompt shows `[name] db> `, and `\C other` changes it.
- `prompt-color = red` shows `ESC[31m[name]ESC[0m` in a pty, and not with `NO_COLOR=1`.
- An invalid `prompt-color` fails with the file and line.
- The tee file has no escape codes.

### 4. Docs

README: the connection prompt, `prompt-color` with a "prod in red" example, `NO_COLOR`.
