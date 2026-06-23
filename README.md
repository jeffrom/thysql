# thysql

tql -u root -h 127.0.0.1 -p

## dependencies

<!-- zig 0.15.2 -->
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
