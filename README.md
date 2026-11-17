# thysql

```sh
thysql -u root -h 127.0.0.1 -p
```

## install

Three ways to install. Each release has one tarball per platform and a `SHA256SUMS`
file, on the [releases page](https://github.com/jeffrom/thysql/releases).

### Homebrew (macOS)

```sh
brew tap jeffrom/thysql https://github.com/jeffrom/thysql
brew install --cask thysql
```

The cask installs the darwin tarball for Apple silicon or Intel. The binary is ad-hoc
signed and not notarized by Apple. After installing, the cask removes the
`com.apple.quarantine` attribute, so Gatekeeper does not block the first run. Bash
completion is linked into `$(brew --prefix)/etc/bash_completion.d/`.

### Linux tarball

Download `thysql-<version>-linux-<arch>.tar.gz` (`x86_64` or `arm64`) and `SHA256SUMS`
from the release, then check and unpack it:

```sh
sha256sum --ignore-missing -c SHA256SUMS
tar -xzf thysql-<version>-linux-<arch>.tar.gz
thysql-<version>-linux-<arch>/thysql --version
```

The Linux binaries use the system OpenSSL, zstd and Kerberos libraries. On Ubuntu 22.04
and 24.04, install these first:

```sh
sudo apt-get install -y libssl3 libzstd1 libkrb5-3 libgssapi-krb5-2
```

### Build it yourself

Build from source with the steps under [build](#build). The Docker image is the option
with no runtime dependencies. No image is published, so build it here:

```sh
docker build -t thysql .
```

## dependencies

Building needs Zig 0.17.1, as `build.zig.zon` requires. Also needed:

- CMake
- OpenSSL headers/libs
- zstd headers/libs
- GSSAPI/Kerberos headers/libs
- Git submodules initialized

On macOS with Homebrew OpenSSL, the default build looks in `/opt/homebrew/lib`.
Use `-Dopenssl-lib-dir=/path/to/lib` if OpenSSL is somewhere else. Headers come from the
`include/` beside that directory, or from `-Dopenssl-include-dir=/path/to/include`. zstd
is found on the library search path, or use `-Dzstd-lib-dir=/path/to/lib`.

## build

```sh
git submodule update --init --recursive
zig build
zig build test
zig build run -- -u root -h 127.0.0.1 -p
```

Example with the password supplied by the environment:

```sh
MYSQL_PWD=foo zig build run -- -h 127.0.0.1 -uroot hi
```

`zig build e2e` runs the end-to-end suite against MySQL 8.4 and MariaDB 11.4 in Docker.
See [tests/e2e/README.md](tests/e2e/README.md).

The build compiles MariaDB Connector/C from `deps/mariadb-connector-c` and links
its static `libmysqlclient.a` into `thysql`. MySQL 8 auth plugins
`caching_sha2_password` and `sha256_password`, plus `dialog`,
`client_ed25519`, `parsec`, `auth_gssapi_client`, `mysql_clear_password`, and
`zstd` are built into the static client, so no MariaDB plugin directory is
required at runtime for those plugins.

### static build

`-Dstatic-deps=true` links OpenSSL and zstd statically, so the binary needs no shared
libraries from Homebrew. Kerberos stays the system library. Point the library options
at the directories that hold `libssl.a`, `libcrypto.a` and `libzstd.a`:

```sh
zig build -Doptimize=ReleaseSafe -Dstatic-deps=true \
  -Dopenssl-lib-dir="$(brew --prefix openssl@3)/lib" \
  -Dzstd-lib-dir="$(brew --prefix zstd)/lib"
sh tools/check_linkage.sh zig-out/bin/thysql
```

The bundled MariaDB is built against the same OpenSSL root that thysql links. Zig falls
back to a shared library when it finds no `.a`, so `tools/check_linkage.sh` fails on macOS
if anything outside `/System` and `/usr/lib` is loaded.

### docker

```sh
docker build -t thysql .
docker run --rm --entrypoint ldd thysql /usr/local/bin/thysql
```

The image compiles in a stage with the toolchain, then copies the binary into a plain
Ubuntu 24.04 image with only the runtime libraries.

### packaging

`tools/package.sh` builds a release tarball for the machine it runs on. On macOS it uses
the static build above, with OpenSSL and zstd from `OPENSSL_PREFIX` and `ZSTD_PREFIX`
(default: `brew --prefix openssl@3` and `brew --prefix zstd`). It then checks the linkage,
ad-hoc signs the binary, runs smoke tests, and prints the tarball's sha256:

```sh
tools/package.sh 0.1.0 darwin arm64    # writes dist/thysql-0.1.0-darwin-arm64.tar.gz
```

The arguments are `<version> <darwin|linux> <arm64|x86_64>`. It does not cross-compile, so
run it on the matching OS and architecture. On Linux it builds the dynamic binary, and
`check_linkage.sh` prints its `ldd` output instead of checking the linkage.

## ci

`.github/workflows/ci.yml` runs on pushes to `main`, on pull requests, and on demand:

- `test`: `zig build test` on `macos-15` and `ubuntu-22.04`.
- `e2e`: `zig build e2e` on `ubuntu-22.04`, with Docker.
- `static-macos`: `tools/package.sh` for darwin arm64 on `macos-15`, which checks the static
  linkage and runs the smoke tests.

The release builds are in `.github/workflows/release.yml`, described under releasing.

## releasing

A release is a tag `vX.Y.Z` that matches `.version` in `build.zig.zon`. Pushing the tag runs
`.github/workflows/release.yml`, which builds the four tarballs and a **draft** GitHub release
with `SHA256SUMS`. `tools/release.sh` and `tools/update_cask.sh` cut the tag and update the
cask; neither pushes. The full checklist, the first-release steps, the end-to-end checks and
troubleshooting are in [docs/releasing.md](docs/releasing.md).

## TLS and sockets

These options match mysql.cc and are passed to the bundled Connector/C.

- TLS is used when the server offers it, as in mysql.cc. `--skip-ssl` turns it off.
- `--ssl-ca`, `--ssl-capath`, `--ssl-cert`, `--ssl-key`, `--ssl-cipher`, `--ssl-crl`,
  `--ssl-crlpath`, and `--tls-version` each turn TLS on. `--ssl` turns it on by name.
- The server certificate is verified when `--ssl-verify-server-cert` is given, or when
  `--ssl-ca` or `--ssl-capath` is given. `--ssl-verify-server-cert=0` and
  `--skip-ssl-verify-server-cert` turn verification off.
- `-P`/`--port` selects TCP. `-S`/`--socket=path` selects the socket.
  `--protocol=tcp|socket` sets it directly. The last of these flags wins.
- The library uses the socket only when the host is `localhost` or unset. For example,
  `-h 127.0.0.1 -S path` still connects over TCP. A bare `-h localhost` with no
  `-P`, `-S`, or `--protocol` uses the socket at the library's default path.
- Not supported: `--protocol=pipe` and `memory`.

## option files

These match mysql.cc and MariaDB's load_defaults. By default, thysql reads
`/etc/my.cnf`, `/etc/mysql/my.cnf`, then `~/.my.cnf`. Later files override earlier
ones, and command-line flags override all of them.

- Groups read: `[client]`, `[mysql]`, `[mariadb-client]`, `[client-mariadb]`, `[mariadb]`.
  Other groups are skipped.
- `--defaults-file=path` reads only that file. It is an error if the file is missing.
  `--defaults-extra-file=path` is read after the system files and before `~/.my.cnf`.
  `--no-defaults` reads nothing. `--print-defaults` prints the resulting arguments and exits.
  These four must come first on the command line, each at most once.
- `!include file` and `!includedir dir` read more files. `!includedir` reads `*.cnf` files in
  name order.
- `#` and `;` start comments. A `#` inside quotes is not a comment. A matching pair of quotes
  around a value is removed, and `\n \t \r \b \s \" \' \\` are expanded.
- A bare name such as `skip-column-names` turns the flag on. `skip-x=0` turns on the positive
  form, and `x=0` turns the flag off. `loose-` names and unknown names are ignored.
  Dashes and underscores are interchangeable.
- Unlike the command line, a `password=` line is allowed, and it overrides `MYSQL_PWD`.
  A bare `password` line prompts. `--print-defaults` shows the password as `***`.

## connections

Saved connections let `-C name` stand for a set of settings, so you do not repeat the
host and user each time. They live in `$XDG_CONFIG_HOME/thysql/connections`, or in
`~/.config/thysql/connections` when `XDG_CONFIG_HOME` is unset or empty.

```
connections/
  config          # defaults for every connection below
  local           # connection "local"
  main/
    config        # defaults for main/*, and default-conn
    ro            # connection "main/ro"
    write
    eu/
      config
      ro          # connection "main/eu/ro"
```

- A connection is a regular file. Its name is its path below the root, joined with `/`.
  Directories nest to any depth. `config` is reserved in every directory, and names
  that start with `.` are ignored.
- Each line is `key = value`, and a line starting with `#` is a comment. Keys are long
  option names, and `-` and `_` are interchangeable. A value may be wrapped in double
  quotes, which are removed. A bare `key` turns a flag on, as in my.cnf. `key =` resets
  the key to its default. A leading `~/` in a path value (`ssl-ca`, `ssl-capath`,
  `ssl-cert`, `ssl-key`, `ssl-crl`, `ssl-crlpath`, `socket`, `tee`) means your home
  directory.
- An unknown key is an error that names the file and line. Unlike my.cnf, these files
  belong to thysql, so a typo is not ignored.
- `password = value` is refused, so a password is never stored in these files. Use
  `keychain = true` or `auth-command` instead. A bare `password` line means prompt.
- `prompt-color = name` colours the `[name]` tag in the prompt. It can go in a connection
  file or a `config` file, and a connection's own file overrides its directory's. It is
  not a setting, so it is not a command-line flag and not a my.cnf key. See
  [prompt](#prompt).

```
# ~/.config/thysql/connections/main/ro
host = db.example.com
port = 3306
user = app_ro
database = app
keychain = true
ssl-ca = ~/certs/prod-ca.pem
```

A `config` file gives defaults to every connection in its directory and below. In a
directory's `config`, `default-conn = ro` makes the bare name `main` stand for `main/ro`,
so `-C main` and `-C main/ro` are the same. `default-conn` may point into another
directory, up to 8 hops, and a cycle is an error.

Settings apply in this order, and later ones win:

1. my.cnf files
2. the `config` files, from the root down to the connection's own directory
3. the connection file
4. the settings in an `--auth-command` JSON object, if it prints one (see
   [JSON settings](#json-settings))
5. command-line flags

`-C` may appear anywhere on the command line, and the last one wins. `--print-defaults -C main/ro`
prints the settings that the connection expands to. Inside the REPL, `\C name` switches to
another connection, as described under client commands.

Errors go to stderr, and thysql exits 1. An unknown name can come with a suggestion, such as
`did you mean "main/ro"?`. A directory with no `default-conn` lists its children, so you
can pick one.

## authentication

The password comes from one source. Each of these sets it, and the last one set wins, as
with other options:

- `MYSQL_PWD`, or `password = value` in my.cnf. This is the default when it is set.
- `-p` or `--password`, or a bare `password` line in an option file. thysql asks once,
  without echo, at startup, and keeps the password for reconnects. It does not ask again
  on reconnect.
- `--auth-command=command`, or `auth-command = command` in a file. See below.
- `--keychain`, or `keychain = true` in a file, on macOS. See below.

### auth command

`--auth-command` runs a shell command to get the password. thysql runs it on every connect:
the first connect, each reconnect after the server drops the connection, and `connect` in
the REPL. Nothing is cached, so short-lived tokens work.

- The command runs with `/bin/sh -c`. Its stdin and stderr are the terminal's, so a helper
  can prompt or open a browser. Its stdout is captured, up to 64 KiB.
- The output is either a password or a JSON object. Without a JSON object, the first line
  of stdout is the password. A trailing `\r\n` or `\n` is removed. Empty output is an error,
  and so is a nonzero exit status. The command's stderr has already reached you, so thysql
  does not print it again.
- The command sees these environment variables, so one script can serve many connections:
  `THYSQL_HOST`, `THYSQL_PORT`, `THYSQL_USER`, `THYSQL_DATABASE`, `THYSQL_SOCKET`,
  `THYSQL_CONNECTION` (empty without `-C`), and `THYSQL_REASON` (`connect`, `reconnect`,
  or `complete`). They hold the values from flags and files, before any JSON settings are
  applied, and they stay the same on reconnects.

An example for AWS RDS IAM tokens:

```ini
# ~/.config/thysql/connections/rds/prod
host = prod.cluster-abc123.us-east-1.rds.amazonaws.com
port = 3306
user = app_iam
ssl-ca = ~/certs/rds-global-bundle.pem
auth-command = aws rds generate-db-auth-token --hostname "$THYSQL_HOST" --port "$THYSQL_PORT" --username "$THYSQL_USER"
```

Then run `thysql -C rds/prod`. The token is a fresh one on every connect and reconnect, so
an expired token is never reused. RDS sends it with the `mysql_clear_password` plugin.
thysql has that plugin built in and always allows it, as the MariaDB client does, so no
`--enable-cleartext-plugin` is needed. Because the token goes over the wire as plain text,
set `ssl-ca` to the RDS CA bundle: with a CA, thysql verifies the server certificate. This
example has not been tested against RDS.

### JSON settings

If the output, with whitespace trimmed from both ends, starts with `{`, thysql reads it as
a JSON object of connection settings instead of a password line. The object can set the
password as well as the other connection fields. A helper can then supply a Vault login, a
failover host, or a client certificate:

```sh
#!/bin/sh
# ~/bin/db-creds: print connection settings for thysql
creds=$(vault read -format=json database/creds/readonly)
cat <<EOF
{
  "host": "db-primary.internal",
  "port": 3306,
  "user": $(echo "$creds" | jq .data.username),
  "password": $(echo "$creds" | jq .data.password),
  "ssl-ca": "/etc/ssl/internal-ca.pem"
}
EOF
```

```ini
# ~/.config/thysql/connections/prod
auth-command = ~/bin/db-creds
```

The keys are the long option names. `-` and `_` are interchangeable, as they are in
connection files:

| Key | Value |
|---|---|
| `host`, `user`, `password`, `database`, `socket` | string |
| `port` | number, or a string of digits |
| `protocol` | a name that `--protocol` takes |
| `ssl`, `ssl-verify-server-cert` | `true` or `false`. A word that `--ssl` takes, such as `"on"`, also works. |
| `ssl-ca`, `ssl-capath`, `ssl-cert`, `ssl-key`, `ssl-cipher`, `ssl-crl`, `ssl-crlpath`, `tls-version` | string |

- `null` means the key is not set. A value of any other type is an error that names the key.
- Any `ssl-*` path or `tls-version` turns TLS on, as the flags do. `"ssl": false` turns it off.
- No `password` key means an empty password, which suits certificate or socket-peer
  authentication.
- An unknown key fails the connect, with a message such as `auth command: unknown key "hostname"`.
  Keys that start with `_` are ignored, and so are their values. A helper can use them for
  metadata, such as `"_expires"`.
- The settings sit between connection files and command-line flags. A flag for a field, such
  as `-u`, wins over the JSON value. So does a host or database given to `connect`.
- The command runs again on every connect, and its JSON is applied each time. A failover
  helper can therefore send a reconnect to another host. After a lost connection, a database
  chosen with `use` wins over the JSON `database`.
- `THYSQL_*` hold the values before the JSON is applied, as described above. The prompt,
  `\s`, and the connect messages show the values in effect, after the JSON.
- Only the first 64 KiB of output is read. JSON cut off by that limit is an error, and
  thysql does not fall back to using it as a password.

A password line that starts with `{` but is not valid JSON, such as `{abc`, still works as a
password. If the connect then fails, thysql says so, for example:
`auth command output starts with "{" but is not valid JSON (<parse error>); it was used as the password`.

### keychain (macOS)

On macOS, thysql can read the password from the keychain. Elsewhere the keychain commands
and the `keychain` setting report that the keychain is only supported on macOS.

```sh
thysql keychain set main/ro      # prompts without echo; a piped line also works
thysql keychain status main/ro   # prints "stored" or "not stored", never the password
thysql keychain delete main/ro
```

- `<conn>` resolves as `-C` does, so `main` means `main/ro`. For an account with no
  connection file, use `--account=name` in place of `<conn>`.
- Each item is a generic password. Its service is `thysql`, and its account is the
  connection name (`main/ro`), or the `--keychain-account` value when that is given.
- Turn it on with `keychain = true` in a connection file, or `--keychain` on the command
  line. Without `-C` or `--keychain-account`, thysql says `keychain needs -C or
  --keychain-account`. Reconnects read the keychain again.
- When the item is missing, the interactive client prints
  `No keychain password for "main/ro"; store one with: thysql keychain set main/ro`, then
  asks for the password. In batch mode it prints the same hint and exits 1.
- `THYSQL_KEYCHAIN=path` points thysql at another keychain file. Without it, thysql uses
  the default search list.
- The first read of an item after a rebuild may show a macOS "thysql wants to use the
  keychain" dialog. Items in the login keychain trigger it, because the ad-hoc signature
  changes with each build.

## client commands

These match mysql.cc. Each works at the prompt, and the backslash forms also work
at the start of a statement, such as `\P less` on its own line.

- `quit`, `exit`, `\q`; `help`, `\h`, `?`; `status`, `\s`; `use <db>`, `\u <db>`;
  `print`, `\p`.
- `pager [cmd]`, `\P [cmd]`, `nopager`, `\n`: result sets go through `cmd` via the
  shell. With no `cmd`, `$PAGER` is used.
- `tee <file>`, `\T <file>`, `notee`, `\t`: copy everything, including the typed input,
  to the file. Messages do not go to the file.
- `warnings`, `\W`, `nowarning`, `\w`: show `Warning (Code N): ...` after a
  statement with warnings.
- `connect [db [host]]`, `\r [db [host]]`: reconnects. With no arguments it
  reconnects to the current database and host. A failed connect keeps the old one.
- `connection <name>`, `\C <name>`: switches to a saved connection, as `-C` does, and the
  notice and connection info print as with `connect`. The prompt, the completion names,
  and the reconnects follow the new connection. With no name, it lists the saved
  connections, with `* ` before the one in use. Tab completes the names after `\C`.
  A failed switch prints the reason and keeps the old connection. The connection flags
  given at startup (`-h`, `-P`, `-u`, `-p`, `-D`, `--auth-command`, and so on) do not carry
  over. The others do, such as `--prompt`, `--connect-timeout`, and `--skip-reconnect`.
- `prompt [fmt]`, `\R [fmt]`: sets the prompt. With no argument it returns to the default.
  The text after the command is kept as typed, including trailing spaces.
- `rehash`, `\#`: reloads the names used for completion.
- `yank [format]`, `\y [format]`: copies the last result set to the clipboard. This is
  thysql's own command, not from mysql.cc. See [output formats](#output-formats).
- Flags: `--pager[=cmd]`, `--tee=file`, `--show-warnings`. Pager and tee are
  interactive only, as in mysql.cc.

Not supported: server-side `help <topic>`, and backslash commands in the middle
of a statement. In batch input, a named command such as `quit` must end with its
delimiter, unless it is the last input. Batch input ignores `prompt`, and `rehash`
does nothing there, as in mysql.cc.

## output formats

| Format | Output |
|---|---|
| `table` | Boxed table with a timing footer. The default in the REPL. |
| `tab` | Tab-separated, escaped as in mysql. No footer. The default in batch mode, with `-e`, and in pipes. |
| `vertical` | One block per row, as with `\G`. |
| `json` | One JSON array of objects per result set. |
| `ndjson` | One JSON object per row, one row per line. |
| `csv` | RFC 4180 CSV, with a header line. |

Pick one with `--result-format=format`. `-B`, `-t` and `-E` are shorthands for `tab`,
`table` and `vertical`. `-J` or `--json` is `ndjson`, and `--csv` is `csv`. The last
output flag given wins. A trailing `\G` or `\J` on a statement picks `vertical` or `ndjson`
for that statement only. JSON and CSV are opt-in, so the defaults above do not change.

Option files and connections take the same settings: `result-format = csv`, or a bare
`json` or `csv` line.

```sh
thysql -C prod_ro --json -e 'select id, name from users limit 2'
{"id":1,"name":"ada"}
{"id":2,"name":"grace"}

thysql --csv -e 'select id, name from users limit 2'
id,name
1,ada
2,"grace, rear admiral"
```

### JSON

- `ndjson` writes one compact object per row. `json` writes one array per result set,
  compact in batch mode and pretty-printed in the REPL. Several result sets in `json`
  mode are several top-level documents, one after another. `jq` reads them; strict
  parsers do not.
- An empty result is `[]` in `json` and nothing in `ndjson`.
- Column names are the object keys. A duplicate name gets a suffix (`a`, `a_2`, `a_3`),
  and one warning goes to stderr for each result set that has duplicates.

| Column type | JSON |
|---|---|
| NULL | `null` |
| Integers, YEAR | Number, from the server's text, so `BIGINT UNSIGNED` stays exact. Leading zeros are dropped: ZEROFILL `00042` is `42`. |
| DECIMAL | String, so precision survives: `"12.30"`. |
| FLOAT, DOUBLE | Number. |
| JSON | Embedded as JSON. MariaDB stores JSON as LONGTEXT, so its values are embedded when the text parses as JSON. Otherwise they are strings. |
| BLOB, BINARY, VARBINARY, BIT, GEOMETRY | Base64 string, with padding. |
| Dates, times, ENUM, SET, text | String, escaped. Control characters become `\uXXXX` or the short forms. |

Text that is not valid UTF-8 has each bad byte replaced with `�`. TINYINT(1) is a number,
because the protocol cannot tell it from a boolean.

### CSV

- A field is quoted when it holds a comma, a double quote, CR or LF, or has leading or
  trailing spaces. Quotes are doubled. Lines end in `\n`, with no BOM.
- NULL is an empty field with no quotes. An empty string is `""`, as in PostgreSQL's
  `COPY ... CSV`.
- Numbers, dates and text are the server's text. DECIMAL is not quoted. Leading zeros stay,
  so `00042` is written as it is. Binary data is base64, as in JSON, and JSON columns are
  their text.
- The header line is the column names. `-N` leaves it out. An empty result gives the
  header only, or nothing with `-N`. Several result sets are separated by one blank line.
- The delimiter is always a comma.

## clipboard

`\y [format]`, or `yank [format]`, copies the last result set shown in the REPL. Without a
format it uses `clipboard-format`, which defaults to `tab` with no escaping. That format
pastes into spreadsheet cells, where CSV would paste into one cell in Google Sheets.

```
thysql> select id, name from users limit 50;
...
50 rows in set (0.01 sec)

thysql> \y csv
Copied 50 rows as csv to the clipboard (1.2 KB).
```

- Only the last result set of a statement is kept. A statement that returns no result set
  leaves it alone. A result set over `clipboard-max-bytes` is not kept, and `\y` says so.
- `clipboard-max-bytes` defaults to `64M`. Sizes take `K`, `M` or `G` for powers of 1024, or
  a plain byte count. `0` turns `\y` off.
- The text goes to the first of these that works: `clipboard-command`, run by `/bin/sh -c`
  with the text on stdin; OSC 52 over SSH, so the copy lands on your local machine; `pbcopy`
  on macOS; `wl-copy` under Wayland, else `xclip` or `xsel` on Linux; and OSC 52 written to
  the terminal as a last resort. tmux needs `set-clipboard on` for that last one.
- Many terminals cut OSC 52 short. A copy over `osc52-max-bytes` (default `100000`) is refused
  with a message, instead of pasting a truncated result. Set `clipboard-command` for larger
  copies.
- Batch input has no `\y`. Pipe the output instead: `thysql --csv -e '...' | pbcopy`.

```sh
# ~/.config/thysql/connections/main/ro
clipboard-format = csv
clipboard-command = pbcopy
clipboard-max-bytes = 512K
```

## prompt

The default prompt is `user@host:port/db> `, or `[connection] db> ` when connected
with `-C` or `\C`. The brackets set the connection name off from the database. Set
another one with `--prompt=fmt`,
the `prompt` command, or `MYSQL_PS1`. The option wins over `MYSQL_PS1`, and
`prompt` with no argument goes back to `MYSQL_PS1`, or to the default when that
is not set. Continuation prompts such as `    -> ` do not change.

The tag can be coloured with `prompt-color` in a connection file or a `config` file. Set it
to `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan` or `white`, or to a `bright-`
form such as `bright-red`. `none` turns colour off, which is the default. The brackets are
part of the tag, so they are coloured too. An unknown name is an error that names the file and line. Put it in
a `config` file to colour every connection below it. Colour is drawn only when stdout is a
terminal and `NO_COLOR` is unset or empty, so `NO_COLOR=1 thysql -C prod` prints the plain
tag. The tee file never has colour codes. A prompt set with `--prompt`, `MYSQL_PS1` or the
`prompt` command replaces the built-in prompt, colour included.

```
# ~/.config/thysql/connections/prod
host = db.example.com
user = app_ro
prompt-color = red
```

With `thysql -C prod`, the prompt is `[prod] (none)> `, and `[prod]` is drawn in red.

Escapes are those of mysql.cc: `\u` user, `\U` user@host, `\h` host, `\H` host
name, `\p` port or socket name, `\d` database, `\N` server name, `\v` server
version, `\c` a counter that goes up each time the prompt is drawn, `\R`/`\r` hour
(24h/12h), `\m` minute, `\s` second, `\y`/`\Y` year, `\o`/`\O` month, `\w` day,
`\P` am/pm, `\D` the date, `\l` delimiter, `\S` `;`, `\_` or `\ ` space, `\n`
newline, `\t` tab, `\\` backslash. `\C` is thysql's own: the `-C` connection name, empty
without `-C`. Any other escaped character is written as is.

```sh
thysql --prompt='[\u|\d|\c]\_' -u root thysql_test
```

## colour themes

`--theme` picks the colours of the SQL in the line editor and of `SHOW CREATE` output:

```sh
thysql --theme=catppuccin-mocha
thysql --theme=catppuccin        # light:catppuccin-latte,dark:catppuccin-mocha
thysql --theme=light:catppuccin-latte,dark:catppuccin-mocha
```

The names are `default`, `catppuccin-latte`, `catppuccin-frappe`, `catppuccin-macchiato` and
`catppuccin-mocha`. Case does not matter, and `_` is the same as `-`. A pair names a light and a
dark theme; for now it always uses the dark one. Colour is off when stdout is not a terminal or
`NO_COLOR` is set, as before.

To set the theme for every session, put it in the config file,
`$XDG_CONFIG_HOME/thysql/config` or `~/.config/thysql/config`. It takes `key = value` lines and
`#` comments, and its only key is `theme`:

```ini
# ~/.config/thysql/config
theme = catppuccin
```

`--theme` overrides the file. An unknown key or a bad theme is an error that names the file and
line.

## completion

Tab completes SQL keywords, database names, and the table and column names of the
current database. A column is offered by its name and as `table.column`. The
names load on connect and on `use` when the database changes. They are reloaded
with `rehash`. The notice about loading is printed on connect and `use`, unless
`--silent` is given.

A hint shown at the end of the line is accepted whole by Meta-L, Right, End, Ctrl-E or
Ctrl-F. Meta-W accepts it up to the end of the word, or completes the word when no hint
is shown, and Meta-F accepts its next word. Tab always completes the word. On macOS the Meta keys are Option, with the terminal set to
use Option as Meta.

`-A` (or `--no-auto-rehash`) skips loading. Then only keywords complete until
`rehash` runs. `--auto-rehash` turns loading back on.

## shell completion

`thysql completion bash` prints a bash completion script. It completes option names and
values, connection names from `~/.config/thysql/connections`, and database names from the
server. The script calls `thysql complete`, which never asks for a password: with `-p`, or
when the connection fails, it offers no database names.

Install it with either of these:

```sh
thysql completion bash > ~/.local/share/bash-completion/completions/thysql
eval "$(thysql completion bash)"    # in ~/.bashrc
```

The script works with bash 3.2, the version macOS ships. Bash 3.2 has no `compopt`, so
after `--ssl-ca=` and other options that take a value, it adds a space where newer bash
does not.

Completion connects with a 2-second timeout, unless `--connect-timeout` is given. It never
prompts. A `--auth-command` runs with `THYSQL_REASON=complete`, with stdin from
`/dev/null`, its stderr hidden, and a 5-second limit, so a helper that opens a browser
gets no candidates. A keychain password is read without the fallback prompt.

## parser

The interactive client parses SQL with the MySQL Workbench grammar, as ANTLR4 parser,
for the version and `sql_mode` of the server. Both are read on connect and reconnect.
The parser is used three ways:

- **As you type.** When input has been idle for 200 ms, the statement under the cursor
  is checked. The first error is shown below the line, and its text is underlined in
  the line. An error that runs to the end of the text is not shown while you are still
  typing it. A space after it shows it.
- **After a syntax error from the server.** The server's error comes first. Then the
  parser's message and a caret under the offending text. The server stays the authority,
  so a statement the parser rejects is still sent.
- **Completion.** Tab and the hint take the parser's candidates at the cursor, and the
  names come from the names that completion loads. When the parser gives nothing, the
  lexer's context is used.

`--no-parser` turns all three off. Highlighting and completion then use the lexer alone.
The lexer follows `ANSI_QUOTES` and `NO_BACKSLASH_ESCAPES` in both cases.

A MariaDB server is parsed as the nearest MySQL version: 8.0 from MariaDB 10.2, and 5.7
before. MariaDB-only syntax is reported as an error, so use `--no-parser` when it matters.

## reconnect

When the server drops the connection, the interactive client prints the error
(2006 or 2013), then `No connection. Trying to reconnect...`, reconnects to the
same database, and runs the statement once more. Use `--skip-reconnect` to turn
this off. Batch input never reconnects, as in mysql.cc.

Over TLS, the server's close appears as error 2026 (TLS EOF). That is not treated
as a lost connection, so use `--skip-ssl` if you need reconnects.

## history

History goes to `$MYSQL_HISTFILE`, then `$XDG_STATE_HOME/thysql/history`, then
`~/.local/state/thysql/history`. `MYSQL_HISTIGNORE` is a list of glob patterns
separated by colons. A statement that matches any of them is not saved. `*` matches
any run of characters, `?` matches one, and case is ignored.

## misc

```sql
select concat('line1', char(10), 'line2') as text_value, cast(unhex('0001FF') as binary) as binary_value;
select concat('safe ', '東京', char(9), 'end') as mixed;
```

## license

thysql is licensed under GPL-2.0-or-later with an OpenSSL linking exception; see
`LICENSE` and `COPYING`. The MySQL grammar from MySQL Workbench is GPL-2.0-only, so
binary releases are distributed under GPL version 2.
