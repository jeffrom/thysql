# Vendored dependencies

Git submodules are pinned to the exact commits listed here. Update them
deliberately; do not float them to a branch.

| Path | Upstream | Tag | Commit | Used for |
|------|----------|-----|--------|----------|
| `deps/mariadb-connector-c` | https://github.com/MariaDB/mariadb-connector-c | v3.4.9-12 | e938a0d6 | MySQL/MariaDB client library |
| `deps/antlr4` | https://github.com/antlr/antlr4 | 4.13.2 | cc82115a | ANTLR4 C++ runtime (`runtime/Cpp/runtime/src` only) |
| `deps/antlr4-c3` | https://github.com/mike-lischke/antlr4-c3 | v3.4.3 | 067385d5 | Code completion core (`ports/cpp/source/antlr4-c3` only) |

Submodules were fetched shallowly (`--depth 1`) at the tag above.
`git submodule update --init --depth 1 deps/antlr4 deps/antlr4-c3` restores them.
