# Handoff: connections, programmatic auth, macOS keychain, CLI completion

Four features, split into eight steps. Each step goes to a fresh Haiku agent. Do
the steps in order, because later steps build on earlier ones. Each step ends with
one or more commits and a green `zig build test` and `zig build e2e`.

## Rules for every step

- Read `README.md`, `tests/e2e/README.md`, and the files named in your step before
  you change anything. Follow the style of the code around you: doc comments on
  public items, unit `test` blocks at the bottom of the file, plain short messages.
- Only do your step. If you find something out of scope that is broken, write it
  in your final summary. Do not fix it.
- Run `zig build test` and `zig build e2e` before every commit. Both must pass. To
  iterate faster, run `THYSQL_E2E_KEEP=1 zig build e2e -- -k <pattern>`, then run the
  full suite once at the end.
- Passwords never go in argv: not in thysql's argv, not in test argv, not in a
  child process's argv. The `PasswordOnCommandLine` rule stays as it is.
- Commit message style follows `git log`: `area: what changed`, all lowercase,
  for example `connections: resolve -C names and default-conn`. End each message
  with the attribution line the session gives you.
- Do not edit `TODO.md` or this file. In your final summary, list what you did, the
  commits, and any open questions.

## Decisions already made

These were settled with the user. Do not revisit them.

| Topic | Decision |
|---|---|
| Shells | bash only for now, through `thysql completion bash`. The subcommand takes a shell name so that zsh and fish can be added later. |
| Server-backed completion | `thysql complete` connects without interaction, with a short connect timeout. If it would need a password prompt, or the connect fails, it prints no candidates and exits 0. |
| Precedence | my.cnf files < connection directory `config` files (root to leaf) < connection file < command-line flags. Later sources win. |
| Auth command output | The first line of stdout is the password. A trailing `\r\n` or `\n` is removed. |
| Auth command reruns | The command runs on every connect: the first connect, every reconnect after a lost connection, and the `connect` client command. Nothing is cached. |
| Keychain API | Security.framework, called from a small C shim. It is linked only for macOS targets. |
| Keychain naming | Service `thysql`, account = the connection name (for example `main/ro`). Manage items with `thysql keychain set\|delete\|status <conn>`. |
| Keychain e2e | Tests create a throwaway keychain with `security create-keychain`. `THYSQL_KEYCHAIN=<path>` points thysql at it. The tests are skipped when not on macOS. |

## Background: where things are

- `src/root.zig` `runREPL`: dispatches the `complete` subcommand, loads option
  files, parses options, prompts for a password, connects, and runs batch or REPL.
  `reconnectSession`, `connectCommand`, and `execReplStatement` handle reconnects.
- `src/option_file.zig`: reads my.cnf files and produces `[]Setting{name, value}`.
  `sameName` treats `-` and `_` as the same.
- `src/options.zig`: `specs` (one entry per flag; the help text is generated from
  it), `Options`, and `parseWithSettings(allocator, args, first, env, settings)`.
  Settings are applied in order, then args. Unknown setting names are ignored,
  because my.cnf is shared with other clients.
- `src/mysql.zig`: `DB.init(allocator, ConnectParams)`, `connect()`, `reconnect()`,
  `connectTo()`. The password lives in the connect params.
- `src/completion.zig`: today's `thysql complete -D<prefix>`. It lists databases.
  Step 7 replaces it.
- `tests/e2e/harness.py`: `run_thysql`, `Interactive`, `E2ETestCase`. The env is
  built from scratch with a temporary `HOME` and no `XDG_CONFIG_HOME`, so
  `$HOME/.config/thysql/connections` is private to each test.
- `tests/e2e/test_reconnect.py` shows how to drop a connection with `KILL` from a
  second client. Reuse that for the auth-command reconnect tests.

---

## Step 1: `--connect-timeout`

The groundwork for completion, which must not hang on an unreachable host.

- Add `--connect-timeout=#` (seconds, connection group), as in mysql. It is also
  read from option files as `connect-timeout` or `connect_timeout`. It defaults to
  0, which means the library default.
- Add it to `Mysql.ConnectParams` and set `MYSQL_OPT_CONNECT_TIMEOUT` in
  `connect()` when it is nonzero. Pass it through everywhere `DB.init` is called.
- Unit tests in `options.zig`: the flag, the option file setting, and a bad value
  giving `InvalidConnectTimeout` (add the error and its message).
- e2e (`test_connect.py`): `--connect-timeout=1` to `-h 10.255.255.1` fails within
  about 5 seconds with a connect error. Assert the elapsed time loosely (under 10s).

Commit: `options: --connect-timeout`.

## Step 2: connection files (parsing and resolution, no wiring yet)

Add a new module `src/connections.zig` with unit tests. Register its tests in
`build.zig` or `root.zig` the way the other modules are.

### Location

`$XDG_CONFIG_HOME/thysql/connections`. When `XDG_CONFIG_HOME` is unset or
empty, use `$HOME/.config/thysql/connections`.

### Layout

```
connections/
  config          # optional: defaults for every connection below
  local           # connection "local"
  main/
    config        # defaults for main/*, and default-conn
    ro            # connection "main/ro"
    write
    eu/
      config
      ro          # connection "main/eu/ro"
```

- A connection is a regular file. Its name is its path relative to the root,
  joined with `/`. Directories can be nested to any depth.
- `config` is a reserved file name in every directory. It is never a connection.
- Files and directories whose names start with `.` are ignored. This skips editor
  swap files and `.DS_Store`.

### File format (in the style of ghostty's config)

```
# comment
host = db.example.com
port = 3306
user = app_ro
database = app
keychain = true
ssl-ca = ~/certs/prod-ca.pem
```

- One `key = value` per line. Whitespace around the key and value is trimmed.
  Blank lines are allowed. A line whose first non-blank character is `#` is a
  comment. A `#` after a value is part of the value.
- The value may be wrapped in double quotes. The quotes are removed, and nothing
  inside them is unescaped.
- A bare `key` with no `=` is a boolean flag (`skip-ssl`), the same as in my.cnf.
- `key =` with an empty value resets the key to its default. The setting is
  passed through with the value `""`, as in my.cnf.
- A value that starts with `~/` gets `$HOME` expanded. Only path-valued keys get
  this: `ssl-ca`, `ssl-capath`, `ssl-cert`, `ssl-key`, `ssl-crl`, `ssl-crlpath`,
  `socket`, and `tee`.
- Keys are long option names. Compare them with `OptionFile.sameName`, so `-` and
  `_` are interchangeable. Valid keys are the connection-group and output-group
  `specs`, plus `execute`, `delimiter`, and `force`, plus the keys added by later
  steps (`auth-command`, `keychain`, `keychain-account`). `default-conn` is allowed
  only in a `config` file.
- An unknown key is an error, because these files belong to thysql, unlike my.cnf.
  The message gives the file path and line:
  `~/.config/thysql/connections/main/ro:4: unknown key "hots"`.
- `password = <value>` is an error:
  `passwords are not stored in connection files; use keychain = true or auth-command`.
  A bare `password` is allowed, and it means prompt.
- `help`, `version`, and the defaults-file options are not allowed. They are not
  in the valid key list.

### Resolution

`resolve(allocator, io, env, name) !Resolved`:

1. Reject names that are empty, absolute, contain `..` or `//`, or end in `config`
   (as a path component). Error: `invalid connection name "<name>"`.
2. If `<root>/<name>` is a directory, read `<root>/<name>/config`. Its
   `default-conn = x` names a connection relative to that directory. Resolve
   `<name>/x` again from step 2. Allow at most 8 hops, and report a cycle. If the
   directory has no `default-conn`, the error is
   `connection directory "main" has no default-conn; pick one of: dev, ro, write`.
3. If the path does not exist, the error is `no connection named "<name>"`. If a
   close match exists (same leaf name in another directory, or one edit away),
   add `did you mean "main/ro"?`. Keep this simple.
4. Collect settings in this order: the root `config`, each directory's `config`
   down to the file's own directory, then the connection file. `default-conn` is
   never a setting.
5. Return `Resolved{ name: []const u8 (the final resolved name, e.g. "main/ro"),
   settings: []const OptionFile.Setting, arena }`.

Also add `list(allocator, io, env) ![]Entry`. An `Entry` is a name and a kind,
`.connection` or `.directory`. Sort the entries by name. A directory entry is
included even without `default-conn`. Completion uses this in step 7.

### Unit tests

Use `std.testing.tmpDir`. Pass the root as a parameter, and put a thin wrapper
around it that computes the root from env. Cover: comments and quotes, a bare
boolean, an empty value, `~/` expansion, an unknown key with file:line, a password
value refused, nested `config` layering order, `default-conn` (including a nested
hop and a cycle), a missing name with a suggestion, invalid names, dotfiles
ignored, `list` output, and `XDG_CONFIG_HOME` versus `HOME`.

Commit: `connections: parse and resolve connection files`.

## Step 3: `-C/--connection`

Wire step 2 into the CLI.

- Add a spec: `-C, --connection=name`, connection group. Help text:
  `Connect with a saved connection from ~/.config/thysql/connections.` Note that
  mysql's `-C` means `--compress`. thysql does not support `--compress`, and `-C`
  is taken on purpose.
- `-C` can appear anywhere on the command line. Pre-scan args (after the leading
  defaults options) for `-C x`, `-Cx`, `--connection x`, and `--connection=x`. If it
  appears more than once, the last one wins. The scan must respect options that
  take a value, so `-e "-C"` is not a connection. Use the spec table for that.
- In `runREPL` and in `completion.zig`, after `OptionFile.load`, resolve the
  connection and append its settings after `loaded.settings`, then call
  `parseWithSettings`. The `connection` id is a no-op in `apply`, because it was
  handled by the pre-scan.
- `--print-defaults` also prints the connection's settings, after the my.cnf ones,
  so you can see what a connection expands to.
- Keep the resolved connection name on `Options` (`connection: ?[]const u8`).
  The keychain step needs it.
- Add a prompt escape `\C` that shows the connection name, or nothing when there
  is none. Check `prompt.zig` first to make sure `\C` is unused there. If it is
  used, pick another letter and say which in your summary. Do not change the
  default prompt.
- Errors from resolution go to stderr, and thysql exits 1.

e2e: add `tests/e2e/test_connections.py`. Add a helper that writes files under
`self.home/.config/thysql/connections`. Use `MYSQL_PWD` in `env=` for the password,
since keychain and auth-command do not exist yet. Cases, run against each server:

- `-C local`, where the file has host, port, user, and database, runs
  `select database()` and prints `thysql_test`.
- Directory `config` defaults plus a connection file override: the file wins.
- `-C main` with `default-conn = ro` is the same as `-C main/ro`.
- A command-line flag beats the connection (`-C local -D information_schema`).
- my.cnf sets `database`, and the connection sets another database: the connection
  wins.
- `XDG_CONFIG_HOME` set to another directory is honored.
- Errors: unknown name (with suggestion), unknown key with file:line, password
  value refused, directory without `default-conn` (lists its children), a
  `default-conn` cycle.
- `--print-defaults -C local` shows the connection's settings.
- Interactive: `--prompt='\C> '` shows `local> `.

Commits: `options: -C/--connection` and `prompt: \C shows the connection name`.

## Step 4: password sources (refactor, no new behavior)

Today the password is a string in `Options` plus `prompt_password`. Replace them
with one source, so that step 5 (auth command) and step 6 (keychain) slot in, and
so reconnect can fetch a fresh password.

- In `options.zig`:
  ```zig
  pub const PasswordSource = union(enum) {
      literal: []const u8,   // MYSQL_PWD, my.cnf password=, or "" for none
      prompt,                // -p, or a bare password in a file
      command: []const u8,   // step 5
      keychain: []const u8,  // step 6: the account
  };
  ```
  `Options.password_source` replaces `password` and `prompt_password`. The last
  source set wins, which matches the existing precedence tests. Keep every
  existing unit test passing, and update only their field access.
- Add a new module `src/password.zig` with
  `pub fn fetch(allocator, io, source, ctx: FetchContext) !Secret`. `FetchContext`
  has `interactive: bool` (stdin is a tty), the stderr writer, and the connect
  params needed by step 5's env vars. `Secret` owns the bytes, and its `deinit`
  zeroes them with `std.crypto.secureZero` before freeing. For `.literal`, fetch
  copies the value. For `.prompt`, it calls the existing `readHiddenLine` (move it
  here from `root.zig`). It returns `error.NeedsPrompt` when not interactive. The
  `.command` and `.keychain` cases return `error.Unsupported` for now.
- `Mysql.DB` must re-fetch on every connect. Give `DB` an optional provider:
  ```zig
  pub const PasswordProvider = struct {
      ctx: *anyopaque,
      fetchFn: *const fn (ctx: *anyopaque) anyerror!Password.Secret,
  };
  ```
  `connect()` (initial, `reconnect`, and `connectTo`) calls it when it is set, uses
  the secret for `mysql_real_connect`, and frees it right after. Do not keep the
  password in `DB` when a provider is set. Without a provider, behavior is
  unchanged.
- `runREPL` builds the provider from `options.password_source`. A `.prompt` source
  prompts once, at startup, as it does today. Keep that secret in memory for
  reconnects. Do not re-prompt on reconnect: mysql.cc does not, and a re-prompt in
  the middle of a query would be surprising. Only `.command` and `.keychain`
  re-fetch.
- The existing message for `-p` with stdin not a tty stays exactly the same. Map
  `NeedsPrompt` to it.

Run all e2e tests. Nothing should change. Commit: `password: one password source, fetched on every connect`.

## Step 5: `--auth-command`

- Add a spec: `--auth-command=command`, connection group. Help text:
  `Run this shell command to get the password, on every connect and reconnect.`
  Also add the connection-file and my.cnf key `auth-command`. It sets
  `password_source = .command`.
- `password.fetch` for `.command`:
  - Run `/bin/sh -c <command>`. stdin and stderr are inherited, so an SSO helper
    can prompt or open a browser and print progress. stdout is captured, up to
    64 KiB.
  - Pass the context in the environment, not in argv: `THYSQL_HOST`,
    `THYSQL_PORT`, `THYSQL_USER`, `THYSQL_DATABASE`, `THYSQL_SOCKET`, and
    `THYSQL_CONNECTION` (empty when there is no `-C`). Add `THYSQL_REASON`, which is
    `connect`, `reconnect`, or `complete`. This lets one script cover many
    connections, for example
    `aws rds generate-db-auth-token --hostname "$THYSQL_HOST" --port "$THYSQL_PORT" --username "$THYSQL_USER"`.
  - Exit 0: the password is the first line of stdout, with a trailing `\r?\n`
    removed. Empty stdout is an error: `auth command printed no password`.
  - A nonzero exit or a signal is an error: `auth command failed with exit status 3`
    or `auth command killed by signal 15`. The command's stderr was inherited, so
    the user has already seen it. Do not capture or repeat it.
  - With `ctx.timeout_ms` set (completion only, in step 7), kill the command after
    the timeout and return `error.Timeout`. No timeout otherwise, because SSO can
    wait on a browser.
  - Zero the captured stdout buffer after copying out the password.
- Reconnect: the provider from step 4 already re-fetches, with
  `THYSQL_REASON=reconnect`. Make sure the "No connection. Trying to reconnect..."
  path prints the auth-command error and then mysql.cc's usual failure message if
  the command fails.
- Batch mode and `-e` use it for the first connect too.

e2e `tests/e2e/test_auth_command.py`. Write helper scripts into `self.home`:

- A script that prints the root password from a file: `-e "select current_user()"`
  works. Assert that the password never appears in thysql's stdout or stderr.
- The script writes `$THYSQL_REASON $THYSQL_HOST $THYSQL_PORT $THYSQL_USER
  $THYSQL_CONNECTION` to a log file. Assert the log contents for a plain flag run
  and for a `-C` run (the `auth-command` key in a connection file).
- Reconnect: start interactive with `--skip-ssl` (see `test_reconnect.py`), kill
  the connection from another client, and run a statement. The log now has
  `connect` then `reconnect`, and the statement succeeds. Also change the password
  file between the connects, so the second connect really used the fresh output:
  `ALTER USER` a dedicated test user, and add that user to `SEED_SQL`.
- The `connect` client command re-runs the script.
- A script that exits 3 gives exit 1 and `exit status 3`. A script that prints
  nothing gives `printed no password`. A script that prints a wrong password gives
  the server's access-denied error.
- A command-line flag beats a connection file: `-p` after `-C` that has
  `auth-command` prompts instead (interactive test, type the password).

Commit: `auth: --auth-command runs on every connect`.

## Step 6: macOS keychain

### Native code

- Add `src/keychain/keychain_darwin.c` and `keychain.h`, a small C API with no
  CoreFoundation types in the header:
  ```c
  // All return 0 on success, 1 for not found, and -OSStatus on other errors.
  int thysql_keychain_get(const char *keychain_path /* NULL = default search list */,
                          const char *service, const char *account,
                          char **out_password, size_t *out_len);   // free with thysql_keychain_free
  int thysql_keychain_set(const char *keychain_path, const char *service,
                          const char *account, const char *password, size_t len); // add or update
  int thysql_keychain_delete(const char *keychain_path, const char *service, const char *account);
  void thysql_keychain_free(char *password, size_t len);  // zeroes, then frees
  char *thysql_keychain_error_message(int status);        // SecCopyErrorMessageString, caller frees
  ```
  Use `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, and `SecItemDelete`
  with `kSecClassGenericPassword`, `kSecAttrService`, and `kSecAttrAccount`. When
  `keychain_path` is set, open it with `SecKeychainOpen`. Pass it as
  `kSecMatchSearchList` (an array with one element) for get and delete, and as
  `kSecUseKeychain` for add. These APIs are deprecated but still work, and they are
  the only way to target a custom keychain file. Silence the deprecation warnings
  for this file only.
- `build.zig`: compile the C file and link `Security` and `CoreFoundation` only
  when `target.result.os.tag == .macos`. Look at how the existing macOS branch in
  `build.zig` (around the `os.tag` switch) finds the SDK.
- `src/keychain.zig`: a Zig wrapper with `get`, `set`, and `delete` returning
  Zig errors (`error.NotFound`, `error.KeychainFailed` with a message written to a
  writer), and the `Secret` type from step 4. On other OSes, every function returns
  `error.Unsupported`, and the message is `the keychain is only supported on macOS`.
  Use `builtin.os.tag`. Do not `@cImport` the header on other OSes.
- The keychain path is `THYSQL_KEYCHAIN` from env when it is set and non-empty.
  Otherwise it is NULL (the default search list).

### Options

- Connection-file and my.cnf keys `keychain` (bool) and `keychain-account`
  (string), plus the flags `--keychain` and `--keychain-account=name`. Setting
  either one sets `password_source = .keychain(account)`.
- The account is `keychain-account` when it is given. Otherwise it is the resolved
  connection name (`main/ro`, also when `-C main` resolved through `default-conn`).
  Without either: `keychain needs -C or --keychain-account`.

### Fetching

- `password.fetch` for `.keychain` gets service `thysql` and the account.
- Not found and interactive: print
  `No keychain password for "main/ro"; store one with: thysql keychain set main/ro`,
  then fall back to a hidden prompt. Not found and not interactive: exit 1 with the
  same hint, without the prompt.
- The REPL re-fetches on reconnect through the provider, as with the auth command.

### Subcommand `thysql keychain`

- `thysql keychain set <conn>`: prompt `Password for main/ro: ` with hidden input
  (reuse `readHiddenLine`). If stdin is not a tty, read one line from stdin
  instead, so scripts and tests can pipe it in. Add or update the item. Print
  `Saved password for "main/ro" in the keychain.`
- `thysql keychain delete <conn>`: delete the item, or report
  `no keychain password for "main/ro"` and exit 1.
- `thysql keychain status <conn>`: print `stored` and exit 0, or `not stored` and
  exit 1. It never prints the password.
- `<conn>` goes through connection resolution, so `main` becomes `main/ro`. The
  connection does not need `keychain = true` set. An account with no connection
  file is accepted with `--account=name` instead of `<conn>`, for use with
  `--keychain-account`.
- Dispatch it from `runREPL` next to `complete`. Add both subcommands, and
  `completion`, to the usage text.

### e2e `tests/e2e/test_keychain.py`

Skip the whole class unless `sys.platform == "darwin"` and `/usr/bin/security`
exists.

- `setUp`: `security create-keychain -p test <tmp>/thysql-e2e.keychain-db`,
  `security unlock-keychain -p test <path>`, and
  `security set-keychain-settings <path>` (this turns off auto-lock). Do not add it
  to the user's search list. In cleanup: `security delete-keychain <path>`. Pass
  `THYSQL_KEYCHAIN=<path>` in every `env=`.
- `thysql keychain set main/ro`, with the password piped on stdin. Then `status` is
  `stored`, and `security find-generic-password -s thysql -a main/ro <path>` finds
  it. Check that it finds the item, not the password value.
- `-C main` (with `default-conn = ro` and `keychain = true`) runs `-e "select 1"`
  without `MYSQL_PWD`.
- `--keychain-account` without `-C`.
- A missing item in batch mode: exit 1, with the hint text.
- A missing item interactive: the hint shows, then the prompt, and typing the
  password connects.
- `delete`, then `status`: `not stored`, exit 1.
- Updating an existing item with `set` replaces the password, and the next
  connect uses it.
- Without `THYSQL_KEYCHAIN`, nothing in the tests touches the login keychain.
  Review your tests to make sure every invocation passes the env var.

Note for the summary: the first read of an item after a rebuild may show a
macOS "thysql wants to use the keychain" dialog for items in the login keychain,
because an ad-hoc signature changes with each build. Items created by the same
binary in a test keychain do not hit this. Mention this in the README section.

Commits: `keychain: Security.framework shim`, `keychain: password source and --keychain`, `keychain: thysql keychain set/delete/status`.

## Step 7: `thysql complete`, the completion engine

Replace `src/completion.zig` with a general engine. This is the protocol every
shell script uses.

### Protocol

```
thysql complete -- <word0> <word1> ... <wordN>
```

- The words are the command line as the shell split it. `word0` is the program
  name. `wordN` is the word being completed, which may be empty. Nothing after the
  cursor is passed.
- Output: zero or more candidates, one per line, then a last line `:<directive>`.
  The directive is a decimal bitmask:
  - `1` nospace: do not add a space after the candidate (for example `--ssl-ca=`
    or a directory `main/`).
  - `2` files: the shell should also do its own filename completion of the
    current value.
  - `4` dirs: the shell should do directory-name completion of the current value.
- Each candidate replaces the whole current word, including any `--opt=` or `-X`
  prefix that the user typed. The engine filters by prefix. Sort candidates and
  remove duplicates. Database names keep server order.
- Exit status is always 0, and stderr is empty unless `THYSQL_COMPLETE_DEBUG=1`.
  With debug on, print why nothing was offered (connect failed, needs prompt, and
  so on).
- The old `thysql complete -D<prefix>` form goes away. Update the one e2e test
  that uses it (`test_option_files.py`
  `test_complete_connects_with_settings_from_the_option_file`) to the new
  protocol.

### What it completes

Parse `word1..wordN-1` with the spec table to learn the context: which option is
waiting for a value, which subcommand is active, and how many positionals there
are. Cases:

| Context | Candidates |
|---|---|
| word1, no subcommand yet, word starts with nothing or a letter | subcommands `complete`, `completion`, `keychain`, plus databases (as for a positional) |
| `-` or `--...` | every long option (`--host`, `--ssl-ca=` with nospace for `.required` options), and short options when the word is `-` or `-X` |
| `--protocol=`, or `--protocol` followed by a value | `tcp`, `socket` |
| boolean-valued options (`--ssl-verify-server-cert=`) | `0`, `1` |
| `--ssl-ca`, `--ssl-cert`, `--ssl-key`, `--ssl-crl`, `--tee`, `--socket`, `--defaults-file`, `--defaults-extra-file` | no candidates, directive files (2) |
| `--ssl-capath`, `--ssl-crlpath` | directive dirs (4) |
| `-C`, `--connection`, `-Cpre`, `--connection=pre` | `connections.list`: connections, and directories as `main/` with nospace. A directory that has `default-conn` is also offered as `main`. |
| `-D`, `--database`, `-Dpre`, `--database=pre`, the first positional | databases from the server (below) |
| `--auth-command` | directive files |
| `completion` subcommand | `bash` |
| `keychain` subcommand | `set`, `delete`, `status`, then connection names |
| anything else (`-h`, `-u`, `-e`, `--prompt`, ...) | nothing, directive 0 |

Mirror how the user typed the option: `-Dthy` gives `-Dthydb`, `--database=thy`
gives `--database=thydb`, and `-D thy` gives `thydb`.

### Server-backed candidates

- Build the options from the partial command line the same way `runREPL` does:
  leading defaults options, my.cnf, `-C`, then the flags in `word1..wordN-1`.
  Ignore incomplete or unknown flags instead of failing.
- Connect timeout: `--connect-timeout` when given, else 2 seconds.
- Password sources: `.literal` is used as is. `.command` runs with
  `THYSQL_REASON=complete`, stdin from `/dev/null`, and a 5-second timeout.
  `.keychain` reads without falling back to a prompt. `.prompt` means no candidates.
- Keep the existing `renderDatabaseCompletions` logic for the query and the prefix
  filter.

### Tests

- Unit tests (no server) for the context parser and for each row of the table,
  including the `=` and attached-value forms, `--` handling, and an option that
  takes a value swallowing the next word (`-e -D` is not a database context).
- e2e `tests/e2e/test_cli_complete.py`:
  - flags: `--ss` lists `--ssl`, `--ssl-ca=`, and the rest, with directive `:1` or
    `:0` as appropriate.
  - `--protocol=` gives `--protocol=socket` and `--protocol=tcp`.
  - `--ssl-ca=` gives directive `:2`.
  - connections: a temp tree, `-C ma` gives `main/` and `main`. `-C main/` gives
    `main/ro` and `main/write`.
  - databases, per server: `-h .. -P .. -u root -D thysql_t` with `MYSQL_PWD`
    gives `thysql_test`. The same with `--database=thysql_t` gives
    `--database=thysql_test`, and with `-Dthysql_t` gives `-Dthysql_test`.
  - databases through `-C` with `auth-command` (step 5), and on macOS through the
    keychain (skip elsewhere; reuse the step 6 temp keychain helper by moving it
    into `harness.py`).
  - a `-p` (prompt) source gives no candidates, exit 0, empty stderr.
  - an unreachable host (`-h 10.255.255.1`) returns within about 4 seconds with no
    candidates.
  - `keychain s` gives `set` and `status`. `completion ` gives `bash`.

Commits: `complete: completion protocol and option-aware engine`, `complete: connection and database candidates`.

## Step 8: `thysql completion bash`

- `thysql completion bash` prints a bash script to stdout. It is embedded with
  `@embedFile` from `src/completion/thysql.bash`. An unknown shell gives
  `unsupported shell "zsh"; supported: bash` and exit 1. Structure the code so
  that adding zsh is one more embedded file and one more table entry.
- The script must work on macOS's `/bin/bash` 3.2: no `mapfile`, no associative
  arrays, and no `${var,,}`. It must not depend on the bash-completion package,
  but it may use `_get_comp_words_by_ref -n =:` when that function exists.
- What it does:
  1. Rebuild the words up to the cursor, undoing bash's split on `=` and `:` from
     `COMP_WORDBREAKS`, so `--database=thy` is one word.
  2. Run `thysql complete -- "${words[@]}"` (use the command name the user typed,
     `${COMP_WORDS[0]}`, so `./zig-out/bin/thysql` works). Capture its output and
     split it on newlines.
  3. Take the last line as the directive. If bash split the current word on `=`
     or `:`, strip the part before the split from each candidate (the cobra
     `__ltrim_colon_completions` approach).
  4. nospace: `compopt -o nospace` (guard with `type compopt`). Files: append
     `compgen -f -- "$cur_value"`. Dirs: `compgen -d`. Here `$cur_value` is the
     part after `=` or after the attached short option.
  5. `complete -o default -F _thysql thysql`. Do not use `-o default` when the
     engine returned candidates. Use the directive.
- README: install instructions,
  `thysql completion bash > ~/.local/share/bash-completion/completions/thysql`,
  or `eval "$(thysql completion bash)"` in `~/.bashrc`.

e2e `tests/e2e/test_bash_completion.py`. These tests are deterministic and need
no pty. Run `bash --norc --noprofile -c '<driver>'`, where the driver sources the
script and sets `COMP_WORDS`, `COMP_CWORD`, `COMP_LINE`, and `COMP_POINT` the way
bash would for a given line (including the `=` split: `--database=thy` becomes
`--database`, `=`, `thy`), calls `_thysql`, and prints `COMPREPLY` one per line.
Put the thysql binary first on `PATH`. Cases: a flag prefix, `--protocol=`
(`socket` and `tcp` after stripping), `-C ma`, `-D thysql_t` against each server,
`--database=thysql_t`, `--ssl-ca=` with a temp file present in cwd, and
`completion b`. Run them with whatever `bash` is on PATH, and also with
`/bin/bash` when it exists and is version 3.

Commit: `completion: thysql completion bash`.

## Step 9: docs

- README: a "Connections" section (layout, format, precedence, `default-conn`,
  `\C`), "Authentication" (`-p`, MYSQL_PWD, `--auth-command` with an RDS IAM example
  and the env vars, keychain with the subcommands and the rebuild-dialog note), and
  "Shell completion".
- Make sure `thysql --help` lists every new flag and the three subcommands.

Commit: `readme: connections, auth command, keychain, shell completion`.

## Out of scope (list for later, do not build)

- zsh and fish scripts (the protocol is already shell-neutral).
- `--enable-cleartext-plugin`, which RDS IAM tokens need with MySQL's
  `mysql_clear_password`. This is likely the first thing users of `--auth-command`
  hit. It is a small follow-up.
- `connect -C name` inside the REPL, and completing connection names there.
- A Linux secret-service backend.
- A `thysql connections` subcommand to list and edit connections.

---

## Step 10: `\C` switches connections in the REPL, with tab completion

Added after steps 1-9 landed. The user asked for `\C` to change connections and to
tab-complete connection names. mysql uses `\C` for `charset`; thysql does not have
`charset`, so `\C` is free. The `\C` prompt escape from step 3 is unrelated and stays.

### Command

- Add `Kind.connection` in `src/client_command.zig`: the backslash form `\C` and the
  word form `connection`, both taking an argument. Add a help line:
  `connection (\C) Switch to a saved connection. With no name, list them.` Check that the
  lexer now styles `\C` as a client command (`isShortChar`).
- `\C name`:
  1. Resolve `name` with `connections.zig`, as `-C` does, including `default-conn`.
  2. Build fresh options: the my.cnf settings that were loaded at startup, then the new
     connection's settings, then the startup command line **minus every connection-group
     flag** (host, port, user, password, socket, protocol, database, ssl/tls flags,
     auth-command, keychain flags, and -C itself). Keep `--connect-timeout` and
     `--reconnect`/`--skip-reconnect` from the command line. Otherwise a startup `-h` would
     override every connection you switch to. Keep what `runREPL` needs for this (the
     loaded option-file settings and the args) alive for the whole session.
  3. Build a new `Password.Supplier` from the new options. A `.prompt` source prompts now,
     as at startup. In batch input that needs a prompt: the usual error, no switch.
  4. Open the new connection. On any failure (resolve, password, connect), print the error
     and keep the old connection, the old supplier, and the old connection name. Nothing
     changes.
  5. On success, close the old connection and switch everything over: `DB`, the supplier
     (later reconnects after a lost connection use the new one), `Repl.connection` (the
     `\C` prompt escape), and the prompt's user, host, port, and database. Print
     `Connected to "main/ro".` and then the same connection info that `connect` prints.
     Reload the names when auto-rehash is on, and refresh the parser (`syntax.refresh`),
     since the server version may differ.
- `\C` with no name lists the connections, one per line, in `connections.list` order,
  with `* ` before the current one and two spaces before the others. Directories are shown
  as `main/` (recurse into them, so every connection is listed by its full name). If there
  are no connections, print where they would go:
  `No connections in ~/.config/thysql/connections.`
- It works in batch input too, as `connect` does.

### Tab completion

- In `src/readline.zig`, when the line is `\C ` or `connection ` (any case for the word
  form) followed by a partial name, and the cursor is in that argument, offer connection
  names instead of SQL candidates. Share the code that `src/completion.zig` uses for `-C`
  (move it into `connections.zig` if that is the natural home): connections, directories
  as `main/` with no space after, and a directory with `default-conn` also as `main`.
- The word here is everything after the whitespace that follows the command, so `/`, `-`
  and `.` are part of it. `\C main/r<TAB>` gives `main/ro`.
- Pending multi-line SQL input is not a `\C` context; only a line that starts with the
  command is.

### Tests

- Unit tests: `client_command.parse` for `\C`, `\C name`, `connection name`; the readline
  context detection for `\C ma|`, `connection main/|`, and `select \C|` (not a context);
  the option rebuild (startup `-h x` is dropped, startup `--connect-timeout` is kept).
- e2e, in a new `tests/e2e/test_switch_connection.py`. Write two connection files, one per
  server (`servers()` gives both), each with `auth-command` pointing at a script that prints
  the root password, so no `MYSQL_PWD` is needed. Cases:
  - start with `-C my` (MySQL), `\C maria`, then `select version()` shows MariaDB, and the
    prompt `--prompt='\C> '` shows `maria> `.
  - names reload: after the switch, tab-completing a table that exists only on the new
    server works (create it in the test on that server with root, and drop it in cleanup).
  - the startup `-h`/`-P` flags do not leak: start with `-C my -h 127.0.0.1 -P <mysql port>`,
    `\C maria` still reaches MariaDB.
  - `\C nope` prints `no connection named "nope"` and the session stays on the old server.
  - `\C` with a connection whose auth command fails keeps the old session.
  - `\C` alone lists the connections with `*` on the current one.
  - after a switch, kill the connection from another client; the reconnect goes to the
    new server and runs its auth command (log `THYSQL_REASON` and `THYSQL_CONNECTION`).
  - tab completion: `\C ma<TAB>` completes `maria`, and with a `main/` directory present,
    `\C main/<TAB>` lists or completes its connections.
  - word form: `connection maria` works.
- README: document `\C` / `connection` next to the other client commands and in the
  connections section.

Commits: `client: \C switches to a saved connection`, `readline: complete connection names after \C`, `readme: \C`.
