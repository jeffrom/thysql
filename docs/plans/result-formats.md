# Plan: JSON and CSV output, and copying results to the clipboard

Add JSON and CSV result formats for scripting, and a REPL command that copies the
last result set to the clipboard:

```sh
thysql -C prod_ro --json -e 'select id, name from users limit 2'
{"id":1,"name":"ada"}
{"id":2,"name":"grace"}

thysql --result-format=json -e 'select id from users limit 2'
[{"id":1},{"id":2}]

thysql --csv -e 'select id, name from users limit 2'
id,name
1,ada
2,"grace, rear admiral"
```

```
thysql> select id, name from users limit 50;
...
50 rows in set (0.01 sec)

thysql> \y csv
Copied 50 rows as csv to the clipboard (1.2 KB).
```

## Where things are today

- `Options.ResultFormat` is `table | tab | vertical` (`src/options.zig`), picked by
  `resultFormat()` from `-B`, `-t`, `-E`, `-s` and a trailing `\G`.
- Batch and `-e` render through `Mysql.render_script_result` (`src/mysql.zig`), which
  prints nothing for an empty result and never prints a footer.
- The REPL renders through `renderResult` (`src/root.zig`): table or vertical only,
  with the timing footer, through the pager (`Client.ResultSink`). The result is freed
  as soon as it is rendered.
- Field metadata is already used: `field.type`, `charsetnr == 63` for binary,
  `NOT_NULL_FLAG`. The MariaDB connector defines `MYSQL_TYPE_JSON=245`.
- Every result is read with `mysql_store_result`, so it is all in memory before rendering.
- Client commands are in `src/client_command.zig`. `\y` and `\Y` are unused.

## Decisions: formats and flags

| Topic | Decision |
|---|---|
| Formats | `ResultFormat` becomes `table \| tab \| vertical \| json \| ndjson \| csv`. |
| Flags | Add `--result-format=<format>`. `-B`, `-t` and `-E` become shorthands for it; `--json` / `-J` set `ndjson`; `--csv` sets `csv`. The last flag given wins. Also settable in option files and connection configs (`result-format = csv`). |
| Default without flags | Unchanged: tab output for batch and pipes, table output in the REPL, for mysql.cc compatibility. JSON and CSV are opt-in. |
| Shared value rules | NULL, binary data (base64) and invalid UTF-8 (`�` in JSON, bytes left alone in CSV) are handled by one per-field classifier that both writers use. |
| Rendering | One row at a time, with no first pass over the data, so moving to `mysql_use_result` later is cheap. |

## Decisions: JSON

| Topic | Decision |
|---|---|
| Shapes | `ndjson`: one compact object per row per line. `json`: one array of objects per result set, compact in batch mode and pretty-printed in the REPL. Several result sets in `json` mode make several top-level documents, one after another (jq reads them; strict parsers don't). |
| Default JSON shape | `ndjson`. `--json` means `--result-format=ndjson`. |
| NULL | `null` |
| Integer types, YEAR | JSON number, using the server's text so BIGINT UNSIGNED stays exact, with leading zeros dropped (ZEROFILL `00042` is `42`, YEAR `0000` is `0`). Only the zeros before the integer digits go; a sign and a single `0` stay. |
| DECIMAL / NEWDECIMAL | JSON **string**, so precision survives. |
| FLOAT, DOUBLE | JSON number, with the same leading zeros dropped (`00001.5` is `1.5`, `0.5` is unchanged). |
| JSON columns (245) | Embedded as raw JSON, not as a quoted string. |
| Binary data (`charsetnr` 63: BLOB, BINARY, VARBINARY, BIT, GEOMETRY) | Standard base64 string, with padding. |
| Dates, times, ENUM, SET, text | JSON string, escaped (`"`, `\`, control characters as `\uXXXX` or the short forms). |
| Text that isn't valid UTF-8 | Invalid bytes become `�`. |
| TINYINT(1) | Number. The protocol can't tell it from a boolean. |
| Duplicate column names | Add a suffix to later ones: `a`, `a_2`, `a_3`. Print one warning on stderr per result set. |
| Empty result | `json`: `[]`. `ndjson`: nothing. |

## Decisions: CSV

| Topic | Decision |
|---|---|
| Dialect | RFC 4180 quoting: a field is quoted when it holds `,`, `"`, CR or LF, or has leading or trailing spaces; `"` is doubled. Lines end in `\n`, not CRLF. No BOM. |
| Header | Column names on the first line. `-N` / `-ss` omit it. Duplicate names are written as they are. |
| NULL vs empty string | NULL is an empty unquoted field; an empty string is `""` (as PostgreSQL's `COPY ... CSV` does). |
| Numbers, dates, text | The server's text, quoted only when needed. DECIMAL is not quoted. Leading zeros stay (`00042`), as they are part of the text. |
| Binary data | Base64, as in JSON. |
| JSON columns | The JSON text, quoted as needed. |
| Empty result | Header line only (so the columns are still known), or nothing with `-N`. |
| Multiple result sets | One blank line between them. |
| Delimiter | Comma. A `--csv-delimiter` option is in Later. |

## Decisions: clipboard

| Topic | Decision |
|---|---|
| Command | `\y [format]` / `yank [format]` copies the **last result set** shown in the REPL. With no format it uses the clipboard default (below). |
| Default copy format | `tab` without escaping (`-r` style). It pastes into spreadsheet cells, unlike CSV, which Google Sheets pastes into one cell. `\y csv`, `\y json` and so on choose another format. Configurable with `clipboard-format`. |
| What's kept | The REPL keeps the last `MYSQL_RES` instead of freeing it right after rendering, and frees it when the next statement returns a result set or the session ends. Only the last result set of a multi-result statement is kept. An OK-only statement leaves the kept result alone. |
| Memory | The result is already in memory while it renders, so this only extends its lifetime. Results larger than `clipboard-max-bytes` aren't kept; `\y` then says so. The size is the sum of the field lengths over all rows (`mysql_fetch_lengths`), counted while rendering, so no extra pass is needed. |
| `clipboard-max-bytes` | Default `64M`. Takes a plain byte count or a `K`, `M` or `G` suffix (powers of 1024, as mysql.cc option sizes are). `0` turns keeping off, so `\y` is disabled. 64 MiB is far more than anyone pastes, yet small next to the memory the rendered table already used. |
| Backend order | 1. `clipboard-command` from config, run with `/bin/sh -c`, gets the text on stdin. 2. Over SSH (`$SSH_TTY` or `$SSH_CONNECTION` set): OSC 52, so the copy lands on the local machine, not the remote host. 3. macOS: `pbcopy`. 4. Linux: `wl-copy` under Wayland (`$WAYLAND_DISPLAY`), else `xclip -selection clipboard`, else `xsel --clipboard --input`. 5. Fallback: OSC 52 written to the terminal (works over SSH and in tmux with `set-clipboard on`). |
| OSC 52 limits | Many terminals cap OSC 52 at around 100 KB. Above `osc52-max-bytes` (default 100000) refuse with a message instead of copying a truncated result. |
| Feedback | `Copied N rows as <format> to the clipboard (size).` on stdout, or an error naming the backend that failed. Nothing is written to the tee file except that message. |
| Batch mode | No `\y`. Pipe output instead: `thysql --csv -e '...' \| pbcopy`. |

## Steps

Each step is one or more commits on `main` with `zig build test` green.

### 1. Value classifier and `src/json_output.zig`

- `src/result_value.zig`: classify a field as `null | number | decimal | json | binary | text`
  from the type and charset; base64 writer.
- `src/json_output.zig`, pure and tested without a server:
  - `writeString(out, bytes)`: JSON string escaping, invalid UTF-8 → `�`.
  - `writeValue(out, field, value: ?[]const u8)`: the type mapping above.
  - `columnKeys(allocator, fields)`: names with duplicates given suffixes.
  - `writeRowObject(out, keys, fields, row, lengths)`.

Tests use the fake fields from `mysqlField` / `mysqlBinaryField` / `mysqlFieldWithFlags`
in `src/mysql.zig`, as the tab tests do. Cover each type, NULL, empty strings,
control characters, invalid UTF-8, a JSON column, BIGINT UNSIGNED max, DECIMAL and
duplicate names.

### 2. `src/csv_output.zig`

`writeField`, `writeHeader` and `writeRow`, using the same classifier. Tests: quoting
of each special character, leading and trailing spaces, NULL vs `""`, binary data, header with `-N`.

### 3. Format plumbing

- `ResultFormat` gains `json`, `ndjson` and `csv`.
- Replace the `batch`/`table`/`vertical` booleans with an optional explicit format.
  `-B`, `-t`, `-E`, `--json`/`-J`, `--csv`, `--result-format` set it; the last one wins.
  `resultFormat()` still makes trailing `\G`/`\J` win and keeps today's defaults. `isBatch()`
  still sees `-B`.
- Option file and connection config keys: `result-format`, `json`, `csv`,
  `clipboard-command`, `clipboard-format`, `clipboard-max-bytes`, `osc52-max-bytes`.
- A small size parser (`64M`, `512K`, `1G`, plain bytes) shared by the two size options, with unit tests.
- Update the `resultFormat` tests and regenerate the help text.

### 4. One render entry point

Add `renderResultAs(out, result, format, options)` in `src/mysql.zig`. It handles every format and is
used by the batch path, the REPL path and `\y`. Only the batch path skips empty results
for `table`, `tab` and `vertical`.

### 5. Batch and `-e` path

- `render_script_result` dispatches through `renderResultAs`, before the early return for zero rows
  (so `json` prints `[]` and `csv` prints the header).
- In `ndjson` mode, flush after each row when stdout is a tty or a pipe, so a
  consumer sees rows as they arrive.

### 6. REPL path

- `Batch.parseQueryInput`: replace `vertical: bool` with a terminator format
  (`none | vertical | ndjson`) so `\J` works alongside `\G`. Update the batch scanner
  where it checks for `'G'`.
- `renderResult`: dispatch on format. Pretty-print `json` here. Footer to stderr for
  JSON and CSV formats.
- Pager and tee keep working unchanged.

### 7. Clipboard

- `src/clipboard.zig`: `copy(io, allocator, env, config, bytes)` that tries the backend order above,
  plus a pure `osc52(out, bytes)` (base64 of the text, terminated with ST) that is unit tested.
  Spawning follows the pager code in `Client.ResultSink`.
- `Client` gains `last_result: ?*MYSQL_RES`, its row count and its byte size. `executeQuery` stores
  results there instead of freeing them; `Client.deinit` and the next result free them.
- `client_command.zig`: `yank` / `\y` with an optional format argument. Render into an
  `std.Io.Writer.Allocating` with `renderResultAs`, then `copy`.
- `\h` help text.

### 8. e2e tests (`tests/e2e`)

Against a real server:
- JSON, checked with `jq -e`: every type in the table, multiple statements, empty
  results in both shapes, duplicate columns, a latin1 column with non-UTF-8 bytes,
  `-e` and stdin input, `--force` with an error between results.
- CSV, checked with Python's `csv` module (`python3 -I -c ...`): quoting, NULL vs empty string, multiple result sets.
- Clipboard: set `clipboard-command = cat > $TMPFILE` and check the file after `\y`,
  `\y csv` and `\y` with nothing kept, and a result over a small `clipboard-max-bytes`.

### 9. Docs

README section and `--help` text.

## Later

- `mysql_use_result` streaming for large exports (check Ctrl-C and `nextResult`).
- An envelope mode with column names and types, row counts and structured errors.
- Coloured JSON in the REPL.
- An option to print DECIMAL as a JSON number.
- `--csv-delimiter`, CRLF line endings, a BOM for Excel.
- A session command to change the REPL's default format.
