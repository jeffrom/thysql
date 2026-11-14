# thysql

tql -u root -h 127.0.0.1 -p

## dependencies

<!-- zig 0.17.1 -->
zig 0.16 should be good now

Also needed:

- CMake
- OpenSSL headers/libs
- zstd headers/libs
- GSSAPI/Kerberos headers/libs
- Git submodules initialized

On macOS with Homebrew OpenSSL, the default build looks in `/opt/homebrew/lib`.
Use `-Dopenssl-lib-dir=/path/to/lib` if OpenSSL is somewhere else.

## build

```sh
git submodule update --init --recursive
zig build
zig build test
```

The build compiles MariaDB Connector/C from `deps/mariadb-connector-c` and links
its static `libmysqlclient.a` into `thysql`. MySQL 8 auth plugins
`caching_sha2_password` and `sha256_password`, plus `dialog`,
`client_ed25519`, `parsec`, `auth_gssapi_client`, `mysql_clear_password`, and
`zstd` are built into the static client, so no MariaDB plugin directory is
required at runtime for those plugins.

Run the app:

```sh
zig build run -- -u root -h 127.0.0.1 -p
```

Example with the password supplied by the environment:

```sh
MYSQL_PWD=foo zig build run -- -h 127.0.0.1 -uroot hi
```

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
4. command-line flags

`-C` may appear anywhere on the command line, and the last one wins. `--print-defaults -C main/ro`
prints the settings that the connection expands to. Inside the REPL, `connect` does not
switch connections yet.

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
- The first line of stdout is the password. A trailing `\r\n` or `\n` is removed. Empty
  output is an error, and so is a nonzero exit status. The command's stderr has already
  reached you, so thysql does not print it again.
- The command sees these environment variables, so one script can serve many connections:
  `THYSQL_HOST`, `THYSQL_PORT`, `THYSQL_USER`, `THYSQL_DATABASE`, `THYSQL_SOCKET`,
  `THYSQL_CONNECTION` (empty without `-C`), and `THYSQL_REASON` (`connect`, `reconnect`,
  or `complete`).

An example for AWS RDS IAM tokens:

```ini
# ~/.config/thysql/connections/rds/prod
host = prod.cluster-abc123.us-east-1.rds.amazonaws.com
port = 3306
user = app_iam
auth-command = aws rds generate-db-auth-token --hostname "$THYSQL_HOST" --port "$THYSQL_PORT" --username "$THYSQL_USER"
```

Then run `thysql -C rds/prod`. RDS IAM tokens are sent with MySQL's `mysql_clear_password`
plugin, which thysql does not enable yet. This example has not been tested against RDS,
and it may fail with an authentication error until that plugin is enabled.

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
- `prompt [fmt]`, `\R [fmt]`: sets the prompt. With no argument it returns to the default.
  The text after the command is kept as typed, including trailing spaces.
- `rehash`, `\#`: reloads the names used for completion.
- Flags: `--pager[=cmd]`, `--tee=file`, `--show-warnings`. Pager and tee are
  interactive only, as in mysql.cc.

Not supported: server-side `help <topic>`, and backslash commands in the middle
of a statement. In batch input, a named command such as `quit` must end with its
delimiter, unless it is the last input. Batch input ignores `prompt`, and `rehash`
does nothing there, as in mysql.cc.

## prompt

The default prompt is `user@host:port/db> `. Set another one with `--prompt=fmt`,
the `prompt` command, or `MYSQL_PS1`. The option wins over `MYSQL_PS1`, and
`prompt` with no argument goes back to `MYSQL_PS1`, or to the default when that
is not set. Continuation prompts such as `    -> ` do not change.

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

```sh
docker build --target build -t thysql-build .
docker build -t thysql-release .
docker run --rm --entrypoint ldd thysql-release /usr/local/bin/thysql
```
