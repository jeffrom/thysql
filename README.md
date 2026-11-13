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
newline, `\t` tab, `\\` backslash. Any other escaped character is written as is.

```sh
thysql --prompt='[\u|\d|\c]\_' -u root thysql_test
```

## completion

Tab completes SQL keywords, database names, and the table and column names of the
current database. A column is offered by its name and as `table.column`. The
names load on connect and on `use` when the database changes. They are reloaded
with `rehash`. The notice about loading is printed on connect and `use`, unless
`--silent` is given.

`-A` (or `--no-auto-rehash`) skips loading. Then only keywords complete until
`rehash` runs. `--auto-rehash` turns loading back on.

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
