# Plan: connection settings from `--auth-command` JSON

Today `--auth-command` prints a password: the first line of stdout. Let it print a JSON
object instead, which can set the other connection fields as well as the password. This covers
helpers that hand out more than a password: Vault dynamic credentials (user and password),
service discovery or failover (host and port), and certificate-issuing proxies such as
Teleport (TLS client certificate and key).

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

```
# ~/.config/thysql/connections/prod
auth-command = ~/bin/db-creds
```

A plain password line works as before.

## Where things are today

- `Options.PasswordSource.command` (`src/options.zig`) holds the command. `--auth-command` and the
  `auth-command` key in option and connection files set it.
- `password.runCommand` (`src/password.zig`) runs `/bin/sh -c`, reads up to 64 KiB of stdout
  (zeroed afterwards), and returns the first line as a `Secret`. The command gets
  `THYSQL_HOST`, `THYSQL_PORT`, `THYSQL_USER`, `THYSQL_DATABASE`, `THYSQL_SOCKET`,
  `THYSQL_CONNECTION` and `THYSQL_REASON`.
- `Mysql.PasswordProvider.fetchFn` returns only a `Secret`. `connectWith` (`src/mysql.zig`)
  fetches it on every connect (first connect, reconnect, `connect`, `\C`, `thysql complete`)
  and puts it into `ConnectParams`.
- `DB` keeps one set of host, user, port, database, socket, protocol and TLS values. They are
  used for every reconnect, and for the prompt and `\s`.
- Options are merged in one pass: environment, then option files and connection files,
  then the command line. Nothing records which values came from the command line.

## Decisions

| Topic | Decision |
|---|---|
| Detection | Trim whitespace from all of stdout. If the result starts with `{` and parses as a JSON object, it's JSON. Otherwise the first line is the password, as today. So a password like `{abc` still works. |
| Fallback hint | When the output started with `{` but wasn't valid JSON, it is used as a password line. If that connect then fails, also print `auth command output starts with "{" but is not valid JSON (<parse error>); it was used as the password`. |
| Keys | `host`, `port`, `user`, `password`, `database`, `socket`, `protocol`, `ssl`, `ssl-ca`, `ssl-capath`, `ssl-cert`, `ssl-key`, `ssl-cipher`, `ssl-crl`, `ssl-crlpath`, `tls-version`, `ssl-verify-server-cert`. `-` and `_` are interchangeable, as in option files (`OptionFile.sameName`). |
| Value types | Strings for all of them. `port` also takes a number, `ssl` and `ssl-verify-server-cert` also take booleans, and `protocol` takes the same names as `--protocol`. `null` means "not set". Any other type is an error naming the key. |
| TLS implications | As with the flags: any `ssl-*` path or `tls-version` turns TLS on. `"ssl": false` turns it off. |
| Unknown keys | An error that fails the connect: `auth command: unknown key "hostname"`. Exception: keys that start with `_` are ignored, so a helper can include metadata such as `"_expires"`. |
| Missing password | No `password` key means an empty password (for certificate or socket-peer authentication). |
| Precedence | Lowest to highest: environment < option files < connection file < **auth JSON** < command-line flags. An explicit command-line flag always wins over the JSON. |
| `connect` / `\r` arguments | `connect db host` arguments are explicit, so they win over the JSON, like flags. |
| Reconnect | The command runs again on every connect, as now, and its JSON is applied again. So a failover helper can point a reconnect at a new host. On a reconnect after a lost connection, the session's current database (from `use`) wins over the JSON `database`. |
| What the command sees | `THYSQL_*` are the values from flags and files, before any JSON is applied. They stay the same across reconnects; a previous JSON doesn't feed back in. |
| What the user sees | The prompt, `\s` and connect messages show the values in effect (after JSON). |
| Secrets | The password and the JSON text stay in zeroed memory: parse with `std.json` into a `FixedBufferAllocator` over a buffer that is `secureZero`ed afterwards, like the output buffer. Only the password is copied out, into a `Secret`. |
| Size | The 64 KiB stdout limit stays. JSON that is cut off by it is an error, not a fallback to the password line. |

## Steps

Each step is one or more commits on `main` with `zig build test` green.

### 1. Record which options came from the command line

- `Options` gains `cli_set: std.EnumSet(Id)`. `parseLong`, `parseShortCluster` and the positional
  database add each option's `Id` when it comes from `args`. Option files and connection files
  don't.
- Add a helper `Options.lockedFields()` that returns the connection fields the JSON may not change
  (a small `ConnectField` enum set: host, port, user, password, database, socket, protocol and each TLS field).
  Only `-p`/`--password` on the command line lock `password`; `MYSQL_PWD` is environment, below the JSON.
  Note that `-p` and `--auth-command` both set the password source, so `password` is only locked
  when `-p` came after `--auth-command` on the command line, which means the command isn't run at all.
  In practice, then, the JSON password is always used when the command runs.
- Tests: the same option from a file and from args; `-h` locks host; a connection file's
  host doesn't.

### 2. Parse auth command output (`src/password.zig`)

- New `AuthOutput` with `password: Secret` and `settings: Settings` (every key above, each optional,
  strings owned by an arena the caller frees).
- `parseAuthOutput(allocator, bytes) !AuthOutput` with the detection, key, type and
  unknown-key rules. Errors carry a message for `report`: `auth command: unknown key "x"`,
  `auth command: "port" must be a number or string`, `auth command: invalid protocol "x"`, etc.
- `runCommand` returns `AuthOutput`. Literal, prompt and keychain sources return empty `settings`.
- Unit tests: plain line; `{abc` line; JSON with every key; numbers and numeric strings for port;
  booleans; `null`; `_meta` ignored; unknown key; wrong types; missing password; nested
  objects rejected; whitespace around the JSON; JSON cut off at 64 KiB; JSON escapes in the password.

### 3. Apply settings on connect (`src/mysql.zig`)

- `PasswordProvider.fetchFn` returns `AuthOutput` instead of `Secret`. `Supplier` updates to match.
- `DBInfo` gains `locked: ConnectFieldSet`. `DB` keeps the **base** params (from options, used for
  `THYSQL_*` and as the start of every connect) and the **effective** params (the last successful
  connect).
- `connectWith` builds the effective params: base, then every JSON setting whose field is not locked,
  then on `.reconnect` the session's current database. TLS settings go through the same
  implication rules as `Options` (share one helper).
- `selectDatabase` and `connect db host` update the base, so they survive the next reconnect.
- Pure tests for the merge function (`applySettings(base, settings, locked, reason)`).

### 4. Show effective values, report errors

- The prompt (`\h`, `\u`, `\d`, `\p`), `\s`, the connect banner and `thysql complete` read the
  effective params.
- On a failed connect after a `{` fallback, print the fallback hint.
- `--auth-command` help text: "Run this shell command on every connect. It prints the password,
  or a JSON object of connection settings."

### 5. e2e tests (`tests/e2e/test_auth_command.py`)

Against both servers, with helper scripts in `self.home`:
- JSON with `user` and `password` for a user created by the fixtures.
- Config points at a wrong port; the JSON's `port` fixes it.
- `-u` on the command line wins over the JSON `user` (connect fails or shows the CLI user).
- Unknown key: connect fails with the message; `_meta` key is ignored.
- `{not json` used as the password, and the hint shows when that connect fails.
- Reconnect: kill the connection (as the existing reconnect tests do); the command runs again
  (`THYSQL_REASON=reconnect` in its log) and a database picked with `use` survives.
- TLS: `ssl-ca` from the JSON with the harness's TLS material; `\s` shows the cipher.
- `-C` connection file with `auth-command` printing JSON.

### 6. Docs

README authentication section: the JSON format, the key table, precedence, `_` keys, an
example helper. Update `docs/plans/connections-auth-completion.md`'s "Auth command output" row
to point at this plan.
