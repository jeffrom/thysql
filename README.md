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
