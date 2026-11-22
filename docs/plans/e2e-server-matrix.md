# Plan: e2e coverage across MySQL compatible servers

Extend thysql's real-server e2e tests from the existing MySQL 8.4 and MariaDB
11.4 pair to selectable server families and versions. Implement in phases:
preserve existing coverage, validate the abstraction with Percona Server, then
add unsharded Vitess and TiDB. Each phase should leave a runnable suite and
documented commands for the next agent.

## Current state and files to read

- `tests/e2e/harness.py`: `Server`, `start_servers`, `_start_one`, `_wait_ready`,
  `_seed`, TLS generation, Docker cleanup, and `E2ETestCase.each_server`.
- `tests/e2e/run.py`: accepts the built binary followed by unittest options;
  starts all servers before discovering tests.
- `tests/e2e/README.md`: local invocation, kept containers, fixture contract,
  password handling, and interactive-test synchronization rules.
- `.github/workflows/ci.yml`: one Ubuntu e2e job invokes `zig build e2e`;
  the harness starts both servers in that job.
- `build.zig`: inspect the e2e build step and argument forwarding before changing
  runner options.
- `tests/e2e/test_switch_connection.py`: explicitly requires the `mysql` and
  `mariadb` targets, and checks MariaDB's version string.
- `tests/e2e/test_query_timeout.py`: selects MySQL's timeout SQL/error tuple by
  `server.name == "mysql"`; every other name currently receives MariaDB's tuple.
- `tests/e2e/test_reconnect.py`, `test_auth_command.py`, and
  `test_reconnect_timeout.py` if present: inspect connection killing, credential
  changes, reconnect behavior, and expected errors.
- `tests/e2e/test_tls.py`: starts from MySQL TLS configuration and tests
  `SHOW STATUS LIKE 'Ssl_cipher'`.
- `tests/e2e/test_json_output.py` and `test_csv_output.py`: type metadata,
  geometry, zero padding, JSON representation, and exact output assertions.

At handoff, the working tree contains existing changes in `src/root.zig`,
`test_query_timeout.py`, and `test_reconnect_timeout.py`, plus unrelated
untracked files. Inspect the current status and preserve all existing work.
Do not assume those changes have been committed or that this list remains current.

## Design decisions

Keep the Python standard-library runner. Reuse existing process and PTY helpers.
Avoid introducing a new test framework or a general orchestration framework.

Separate three concerns:

1. **Target configuration:** stable target ID, family, pinned image/version,
   capabilities, and any narrow expected-behavior profile.
2. **Provisioning adapter:** start, readiness, fixture bootstrap, diagnostics,
   and cleanup. An adapter can own several containers or processes.
3. **Client endpoint:** host, port, database, and fixture identities used by tests.
   Provisioning must not assume this endpoint is the backend database itself.

Keep `connect_args(user)` and existing test helpers compatible where possible.
Separate family from target ID so another MySQL version or Percona target does
not accidentally take MariaDB branches. Use a small explicit capability set
and narrow helpers for actual differences; avoid a configurable expectation
language for every assertion.

Unsupported capabilities produce visible skips with reasons. Failure of a
declared capability, target startup, or fixture bootstrap fails the run.
Do not catch arbitrary SQL errors and reinterpret them as unsupported features.
Do not weaken precise assertions for the existing targets to accommodate a new one.

## Phase 1: selectable targets with unchanged baseline behavior

**Status: implemented.** `THYSQL_E2E_SERVERS` selects `mysql`, `mariadb`, or
both; unset retains the original pair. Selection errors are reported before
Docker is checked. Kept containers carry a fingerprint of the target image,
password environment variable, startup flags, and TLS mount source; stale
containers are removed and recreated. The cross-server switch class skips
with a reason unless both baseline targets are selected.

Replace the two hardcoded `_start_one` calls with target definitions for the
existing MySQL and MariaDB images. Add `THYSQL_E2E_SERVERS=mysql,mariadb` selection;
unset means the existing pair. Reject empty, unknown, or duplicate entries with
a useful error before starting containers. Preserve unittest option forwarding.

Make kept-container names identify the target. Check a configuration fingerprint
covering image/version, startup flags, and TLS mounts before reuse; recreate
stale configurations. Preserve normal cleanup after partial startup failure,
test failure, SIGINT, and SIGTERM. Keep secrets out of command-line arguments
and diagnostics, following the existing harness policy.

Make the existing cross-server switch suite explicitly require the baseline
pair. When one target is selected, skip that suite with a clear reason rather
than raising a lookup error. Keep the original two-server behavior covered in
its own CI job when the matrix lands.

Acceptance:

- Unset selection runs the existing pair and retains their coverage.
- Selecting either target runs its applicable tests without requiring the other.
- Invalid selection fails before Docker resources are created.
- Existing keep/reseed behavior works, and stale configuration is detected.
- Interrupted or partially failed setup leaves no disposable resources behind.

Validation run for phase 1:

- `python3 -m py_compile tests/e2e/harness.py tests/e2e/run.py tests/e2e/test_switch_connection.py` — passed.
- Direct `selected_targets` checks — default order, each single target, and empty, trailing-empty, duplicate, and unknown values — passed.
- `THYSQL_E2E_SERVERS=unknown python3 tests/e2e/run.py /usr/bin/python3` — exited 2 with the selection error before Docker access.
- `zig build e2e` — passed against MySQL 8.4 and MariaDB 11.4: 245 tests, 0 failures, 118.252 seconds.
- `THYSQL_E2E_SERVERS=mysql python3 tests/e2e/run.py zig-out/bin/thysql` — passed: 234 tests, one expected switch-class skip, 64.783 seconds.
- `THYSQL_E2E_SERVERS=mariadb python3 tests/e2e/run.py zig-out/bin/thysql` — passed: 234 tests, one expected switch-class skip, 63.647 seconds.
- Two consecutive `THYSQL_E2E_KEEP=1 THYSQL_E2E_SERVERS=mysql python3 tests/e2e/run.py zig-out/bin/thysql -k test_fixture_values_round_trip` runs — each passed the focused test, confirming kept-container reuse and fixture reseeding. The temporary container was removed after validation.
- `git diff --check` — passed.

Parent review also fault-injected a stale fingerprint against a real kept
MySQL container and verified that its container ID changed. A bootstrap failure
after actual container startup removed its container and temporary TLS files.
Selection semantics and setup-failure cleanup passed independent mock checks.
A later parent review sent SIGTERM and SIGINT during registered container
startup; both removed the actual container and temporary TLS directory.
Readiness timeout was not fault-injected. No `zig
build test` was run because this phase changes only the Python E2E harness and
documentation.

## Phase 2: capabilities and fixture boundaries

**Status: implemented.** Targets now declare a family, an explicit capability
set, and a timeout behavior profile. Common portable fixtures are seeded
separately from optional extended-type/geometry and `ZEROFILL` groups; identity
provisioning runs through a separate function from fixture loading. Tests for
optional behavior report a skip subtest naming the target and capability.
MariaDB's invalid-JSON-text case is explicitly limited by the
`mariadb_json_text` capability. Timeout assertions use the target profile, and
a bundled-client streaming probe confirms that each timeout interrupts after
the first row has arrived.

Audit assumptions throughout `tests/e2e`, not just the files listed above.
Identify SQL administration, stored routines, multi-statements, metadata
queries, authentication, type metadata, TLS inspection, and error contracts.

Split the monolithic `SEED_SQL` into common data and optional fixture groups.
Common fixtures should cover simple tables, Unicode, NULLs, binary values,
and portable numeric/text types. Keep specialized groups for geometry, padded
numeric values, and other features where actual compatibility requires it.
Separate identity provisioning from data seeding: MySQL `CREATE USER` and
`GRANT` are not a universal way to provision a MySQL protocol endpoint.

Add an iteration helper that records unsupported cases individually as skipped
subtests, or an equivalent approach with clear per-target reporting. Check how
unittest reports skips before adopting the implementation. Never silently
filter targets out of a test. Keep MariaDB-specific JSON tests explicitly scoped.

Replace the timeout name branch with an explicit family/profile contract for
setup SQL, error code, and SQLSTATE. Check that each timeout fixture actually
produces the intended mid-result failure on each supported target; an error
before results begin does not cover that regression. Retain the existing
server-specific cases even if another target cannot exercise it.

Acceptance:

- Baseline tests retain their assertions and have no unexplained new skips.
- Specialized fixture incompatibility cannot prevent common tests from starting.
- Every skip identifies the target and unsupported capability.
- Setup failures and failures of supported behavior remain nonzero exits.

Validation run for phase 2:

- `python3 -m py_compile tests/e2e/harness.py tests/e2e/test_query_timeout.py tests/e2e/test_json_output.py tests/e2e/test_csv_output.py tests/e2e/test_reconnect.py tests/e2e/test_auth_command.py` — passed.
- Direct fixture-boundary checks with mocked SQL execution — passed: a target with no optional capabilities receives common fixtures only; a target with geometry and extended metadata receives the typed group but not `ZEROFILL`; identity SQL is invoked separately.
- Direct `unittest` capability-skip probe — passed: an unsupported subtest is skipped with both target ID and capability in its reason.
- `python3 tests/e2e/run.py zig-out/bin/thysql -k query_timeout -v` — passed against MySQL 8.4 and MariaDB 11.4: both timeout tests passed, and the server-client streaming probe saw row 1 before each profile's expected timeout error.
- `zig build e2e` — passed against MySQL 8.4 and MariaDB 11.4: 245 tests, 0 failures, 1 expected skip (`mysql` lacks the MariaDB-only `mariadb_json_text` capability), 115.538 seconds.
- `git diff --check` — passed.

The first full run exposed that thysql's batch renderer buffers incomplete
results, so asserting a partial rendered row there did not test server-side
streaming. The check now uses each image's bundled client with `--quick`; the
focused run and full suite passed with that direct protocol check.

Parent review added portable JSON/CSV checks for BIGINT, DECIMAL, date/time,
JSON, BIT, binary, Unicode, and NULL independently of the geometry fixture.
Those checks passed on both baseline servers and an actual MySQL target with
optional capabilities removed; the latter contained neither `typed` nor
`padded_values`. A synthetic reporting probe verified that unsupported cases
skip, supported failures fail, and subsequent targets still execute. Procedure
and trigger tests now require `stored_routines`; TLS status checks require
`tls_inspection`. The applicable baseline assertions remain unchanged.
`python3 tests/e2e/run.py zig-out/bin/thysql -k delimiter -k tls -k portable`
passed all 34 affected tests against both baseline servers after review fixes.

## Phase 3: Percona Server and additional versions

**Status: implemented.** The selectable `percona` target uses the MySQL-family
provisioning and timeout profile, `MYSQL_ROOT_PASSWORD`, and the image's
bundled `mysql` client. The pinned image is
`percona/percona-server:8.4.11-12`. Startup reports the target, configured
image, observed `SELECT VERSION()` result, family, and capabilities. The
existing target definition keeps server family separate from target ID, so
shared tests need no Percona-specific branches.

Image verification: `docker manifest inspect percona/percona-server:8.4.11-12`
found linux/amd64 and linux/arm64/v8 manifests. The local Docker engine reports
`linux/aarch64`; the image pull completed and the container ran natively. The
official image quickstart documents the tag and states that ARM64 can use the
same tag; the explicit `-arm64` form is also available. The official image
configuration documents `MYSQL_ROOT_PASSWORD`. The image's `mysql` client
successfully ran the TLS startup flags and readiness query.

Validation run for phase 3:

- `python3 -m py_compile tests/e2e/harness.py tests/e2e/run.py` — passed.
- Direct target selection checks — passed: unset and `mysql,mariadb` retain
  baseline order; `percona` resolves to the MySQL family.
- `THYSQL_E2E_SERVERS=percona python3 tests/e2e/run.py zig-out/bin/thysql` —
  passed against `percona/percona-server:8.4.11-12`, observed server version
  `8.4.11-12`: 236 tests, 0 failures, 2 expected skips (MariaDB-only JSON text
  behavior and the cross-server switch class, which requires both baseline
  targets), 67.280 seconds. Both batch and interactive timeout tests, TLS,
  stored routines, identity setup, and JSON/CSV output passed.
- `git diff --check` — passed.

Parent review added `DEFAULT_TARGETS = ("mysql", "mariadb")` and verified the
exact default list, not just its first two entries. New registry entries remain
opt-in. Explicit Percona selection and its MySQL timeout profile also passed
independent checks.

The baseline pair was not rerun because the change adds a selectable target
and startup reporting; it does not alter baseline target definitions or
shared test assertions. No application/build code changed.

Acceptance:

- Percona runs the applicable suite independently with no MariaDB timeout SQL.
- The MySQL-family target/profile split supports another pinned version as a
  target definition without branching generic test bodies.
- The README contains tested local commands for the new targets.

## Phase 4: unsharded Vitess

**Status: implemented.** The opt-in `vitess` target runs one unsharded
`thysql_test` keyspace through VTGate. It uses the official vttestserver image
as its pinned base plus a small custom VTCombo launcher. The launcher is built
from Vitess commit `93926dba3020bedc0817b18933b5132fa59d3f1d`, which matches the
image's reported `25.0.0-SNAPSHOT` revision, and registers Vitess's native
static authentication provider before running the upstream VTCombo CLI. The
image overrides the VTCombo binary that vttestserver starts, changes its
forced `mysql-auth-server-impl=none` to `static`, enables the documented KILL
statement option, and configures VTGate's TLS certificate and key. No auth
proxy or backend SQL route is used for client assertions.

The base is pinned as
`vitess/vttestserver@sha256:82e96c43027f338593ad09447cb4433228a8cd69ced3d8d5583a2fe79892a34d`;
it reports `vtcombo 25.0.0-SNAPSHOT`, Git revision
`93926dba3020bedc0817b18933b5132fa59d3f1d-dirty`, built with Go 1.27.4 for
linux/amd64. The launcher build pins
`golang:1.27.4-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea`.
The builder runs on the host architecture and cross-compiles the launcher.
On ARM64 Docker hosts the runtime uses explicit linux/amd64 emulation.
The image is built automatically when `vitess` is selected, or
manually with the README command.

The adapter creates a static credential file for the throwaway root, password,
no-password, and auth-command users; readiness and fixture seeding query the
published VTGate MySQL listener at `PORT + 3` in the `thysql_test` keyspace.
The common and optional typed/geometry/`ZEROFILL` fixtures load through VTGate.
Client TLS is between thysql and VTGate; thysql's status command reports the
negotiated client cipher, strict verification with the generated CA succeeds,
and the wrong CA fails. The target has a separate `vitess` family and declares
only capabilities verified against this setup.

The final full Vitess-selected run executed 236 tests with 0 failures and 21
visible skips (57.923 seconds). Typed CSV/JSON output, geometry metadata, and
`ZEROFILL` were enabled after their fixtures and four focused output tests
passed through VTGate. Correct and incorrect password tests, query/batch/
interactive paths, completion, multi-statement scripts, and CA verification
passed. The skips are limited to:

- `connection_kill` (5 cases): with `--allow-kill-statement`, `KILL
  CONNECTION_ID()` returned `ERROR 1094 (HY000): Unknown thread id`; the VTGate
  client ID and the kill target are not interchangeable in this configuration.
- `query_timeout` (2 cases): these assert a timeout interrupting a streamed
  result; Vitess documents that its query timeout mechanisms do not affect
  streaming queries.
- `stored_routines` (4 cases): Vitess does not support `CREATE PROCEDURE`
  through VTGate; delimiter-only coverage still runs.
- `sql_warnings` (4 cases): `CAST('x' AS SIGNED)` produced no warning through
  VTGate, so server warning output cannot satisfy these warning assertions.
- `status_runtime_fields` (2 cases): VTGate's client status output omits the
  uptime and thread-count fields asserted by these checks.
- `latin1_wire_bytes` (2 cases): VTGate returns the Latin1 fixture as UTF-8,
  so byte-preservation assertions specific to direct MySQL are not applicable.
- One MariaDB-only JSON behavior case and one cross-server switch class that
  requires the baseline pair.

Validation:

- `docker build --platform linux/amd64 -f tests/e2e/vitess/Dockerfile -t
  thysql-vitess-e2e:25.0.0-93926dba-e2 tests/e2e/vitess` — passed.
- `THYSQL_E2E_SERVERS=vitess python3 tests/e2e/run.py zig-out/bin/thysql -k
  every_type -k zerofill` — passed: 4 tests.
- `THYSQL_E2E_SERVERS=vitess python3 tests/e2e/run.py zig-out/bin/thysql` —
  passed: 236 tests, 0 failures, 21 expected skips, 57.923 seconds. TLS cipher
  checks use thysql's client status output; all TLS tests ran and passed.
- `THYSQL_E2E_SERVERS=mysql,mariadb python3 tests/e2e/run.py
  zig-out/bin/thysql` — passed: 247 tests, 0 failures, 1 expected MariaDB-only
  skip, 115.846 seconds.
- Python compilation, `gofmt`, target registry/default tuple checks, and
  `git diff --check` passed.

Parent review independently passed the final Vitess run (236 tests, 21 skips,
58.478 seconds), all 16 TLS/socket-related tests on Vitess, and two consecutive
kept-container runs with portable output tests. Both runs reused the same
container ID and reseeded successfully. Image builds use Docker caching on
every selection so launcher edits take effect; kept-container fingerprints
include the built image ID, keyspace, listener port, and fixture identities.
Owned tables are reset before reseeding. Containers are registered for cleanup
before Docker startup, covering interruption during the create/start call.
The final 11 TLS tests also passed against both baseline servers.

The pinned image is a Vitess 25.0 development snapshot despite the older
vttestserver documentation path used during initial research; the actual image
metadata was checked and this plan records the runtime version. The local ARM64
run used explicit amd64 emulation. The exact baseline pair remains the default.

Use the documented `vttestserver` test environment, pinned to a verified image
or reproducible build. Start with one unsharded keyspace. Expose **VTGate's
MySQL listener** to thysql; connecting directly to its backend MySQL would not
test Vitess compatibility.

Implement the adapter's lifecycle, readiness, keyspace/schema bootstrap, VTGate
authentication configuration, client-facing TLS, logs, and cleanup. Provision
fixture identities through VTGate's supported authentication mechanism. Keep
backend administrative access inside the adapter rather than routing common
tests around VTGate. Readiness must confirm the client listener can query the
intended keyspace after bootstrap.

Run common client tests first, then enable capabilities supported by the pinned
version. Investigate session variables, metadata/completion, multi-statements,
`CURRENT_USER`, connection IDs, `KILL`, reconnects, and error reporting. Treat
these as verification questions, not assumed incompatibilities. TLS tests must
verify the client-to-VTGate connection; backend TLS status is insufficient.

Acceptance:

- Common query, batch, interactive, output-format, and completion tests connect
  through VTGate and run where supported.
- Correct and incorrect password cases exercise real configured authentication.
- Unsupported specialized cases are named skips with documented reasons.
- Startup failures include useful component logs and clean up owned resources.

Sharded routing, resharding, and failover topology tests are later work.

## Phase 5: TiDB

**Status: implemented.** `tidb` pins the multi-architecture TiDB 8.5.3 image
`pingcap/tidb@sha256:00f015520ce91734c3fbec720f23448e790e691655c7e181544a620872a00c61`.
The observed version is `8.0.11-TiDB-v8.5.3`; the image runs natively on ARM64.
The adapter starts a single UniStore instance at an isolated container-local
path, with a random localhost host port. This is a client protocol test
configuration and does not exercise a production TiKV/PD topology.

Native TLS is configured through a generated TOML file. An initialization SQL
file establishes the throwaway root password before authenticated readiness.
The image has no SQL client, so administrative SQL and streaming probes use
an independent MariaDB client container in TiDB's network namespace. The
thysql binary remains the client under test, rather than provisioning itself.
The helper uses the configured MariaDB target image and is removed on exit.
TiDB's uppercase `INFORMATION_SCHEMA` metadata is an explicit endpoint profile;
the database-completion test uses that spelling while retaining its exact
prompt and success assertions.

Validation:

- `THYSQL_E2E_SERVERS=tidb python3 tests/e2e/run.py zig-out/bin/thysql` passed:
  236 tests, 0 failures, 12 visible skips, 61.063 seconds.
- All client TLS checks, authentication, KILL-based reconnect and credential
  changes, warnings, status fields, latin1 bytes, completion, and portable
  JSON/CSV types execute and pass.
- Three kept-container runs, including stopping and restarting the container,
  reused its ID and passed portable JSON/CSV checks after each reseed.
- Direct probes confirmed geometry DDL rejection, unpadded output `42`/`1.5`
  despite accepted padding syntax, and stored-procedure rejection.
- An independent streaming client confirmed that the deadline error is 3024 /
  HY000 but this fixture yields no partial row, even with initial chunk size 1.
  The two existing mid-result timeout regressions remain explicit skips.
- The remaining skips are the two full geometry fixture checks, two padded
  output checks, four stored-routine cases, MariaDB-only invalid JSON text,
  and the single-target cross-server prerequisite. Common types remain covered.

The metadata-aware completion regression also passed unchanged on the
MySQL/MariaDB baseline pair. Python compilation and `git diff --check` passed.

Add a pinned, documented standalone test configuration using the smallest
supported deployment suitable for these client tests. Verify its startup,
readiness, SQL identity provisioning, TLS options, and architecture support.
An embedded/test storage configuration, if chosen, must be identified in the
README; it does not establish production cluster behavior.

TiDB's compatibility documentation lists geometry, `ZEROFILL`, and floating
point display precision as unsupported. Confirm this against the selected
version, omit unsupported fixture groups, and retain common type/output tests.
Verify timeout, session, connection-killing, and reconnect behavior separately
before enabling those capabilities.

Acceptance:

- Common fixtures load without unsupported DDL.
- Applicable tests run independently against TiDB; specialized omissions appear
  in the coverage summary.
- The README documents the test deployment and its limits.

## Phase 6: CI matrix and reporting

**Status: implemented locally; remote CI not run.** Required CI now runs the
MySQL, MariaDB, and Percona targets as independent Ubuntu matrix jobs with
`fail-fast: false`, plus a dedicated `mysql,mariadb` switch job. Vitess and
TiDB are in a separate manual experimental workflow. The local default remains
exactly `mysql,mariadb`.

The three required target refs use verified multi-architecture index digests:
MySQL 8.4 (`sha256:a81d043930e51745522bd5c430961cf8286f0a23f0a9a2a6e0108f7ea71b0902`),
MariaDB 11.4 (`sha256:a8992b5e5404d11e03c54a31d0c1bdea3fd116d283aa6d1a627551f29045309b`),
and Percona Server 8.4.11-12
(`sha256:e95917e6dc1242a773e35a1d93f2ede275c9b48eab4354c446d64cefe6bb79be`).
Registry inspection confirmed linux/amd64 and linux/arm64/v8 for all three.
Update procedure and CI layout are documented in `tests/e2e/README.md`.

`run.py` now reports target-attributed subtest cases once per target and test,
including nested subtests; target failures/skips remain distinct from global
client cases and baseline-pair prerequisite skips. Startup/readiness/bootstrap
errors have a separate label. Failed runs collect the last 100 log lines, capped at 12,000 characters
per target after credential redaction and before teardown; CI uploads these
files as artifacts. Reporting unit tests cover failed outcomes, skip
attribution, nested cases, pair prerequisites, setup labeling, and redaction.

Validation run for phase 6:

- `docker buildx imagetools inspect mysql:8.4`, `mariadb:11.4`, and
  `percona/percona-server:8.4.11-12` — passed; captured index digests and
  confirmed amd64 and ARM64 manifests. The existing TiDB target remains pinned
  by its already-configured digest.
- `python3 -m unittest discover -s tests -p 'test_e2e_reporting.py' -v` —
  passed: 10 tests executing real unittest suites and lifecycle callbacks.
- `python3 -m py_compile tests/e2e/reporting.py tests/e2e/run.py
  tests/e2e/harness.py tests/test_e2e_reporting.py` — passed.
- `THYSQL_E2E_SERVERS=mysql,mariadb python3 tests/e2e/run.py
  zig-out/bin/thysql -k portable` — passed against MySQL 8.4.13 and MariaDB
  11.4.13: 2 target cases passed per server; summary attribution matched.
- `git diff --check` — passed.
- Parent review corrected real capability-skip attribution, preserved global
  errors after targeted subtests, and retained full unittest option forwarding.
  A fixture-failure regression verifies diagnostics precede cleanup even before
  a server reaches the active list. Pair prerequisites have their own bucket.
- A real MySQL bootstrap fault produced a redacted `mysql.log` artifact and
  removed its actual container and TLS directory. Diagnostic collection errors
  cannot replace the original test/setup failure.
- Both changed workflows passed `rhysd/actionlint`. The experimental workflow
  uses the selected input directly; the switch job runs only switch tests.
- Final integrated command:
  `THYSQL_E2E_SERVERS=mysql,mariadb,percona,vitess,tidb python3 tests/e2e/run.py zig-out/bin/thysql`
  passed all 247 methods in 239.939 seconds, with 33 expected skip events and
  no failures. Per-target method/target-pair counts are below; repeated
  command variants are deduplicated, so these show 31 skipped pairs rather
  than 33 individual unittest skip events. All 44 global/client cases passed,
  and the baseline-pair prerequisite was satisfied.

  | Target | Passed pairs | Failed pairs | Skipped pairs |
  | --- | ---: | ---: | ---: |
  | MySQL | 202 | 0 | 1 |
  | MariaDB | 203 | 0 | 0 |
  | Percona | 202 | 0 | 1 |
  | Vitess | 185 | 0 | 18 |
  | TiDB | 192 | 0 | 11 |

  All disposable containers and TLS files were cleaned up. The pre-existing
  kept MariaDB container was preserved.
- GitHub Actions was not run from this environment. Experimental targets remain
  manual pending CI validation; no remote CI result is claimed.

Run each selected target in an independent Ubuntu job with `fail-fast: false`.
Retain a dedicated `mysql,mariadb` job for cross-server switching. Keep local
defaults unchanged. Pin CI image versions or digests and document updating them.
Check ARM64 image availability for local macOS use; make any required emulation
explicit rather than assuming CI images run natively everywhere.

Start new targets as an explicit experimental matrix or separate workflow while
fixing compatibility failures. Promote them to required coverage after their
applicable suite is green. Avoid blanket `continue-on-error` on established jobs.
Use measured runtime to decide whether additional versions belong on every PR
or a scheduled/manual extended matrix.

Print selected target IDs, image references, observed versions, and capabilities.
Summarize passes, failures, and skips by target, with startup failure distinct
from test failure. Preserve diagnostics on CI failure and redact credentials.
Keep output bounded and cleanup reliable.

Acceptance:

- Each target's failure is independently attributable and fails its required job.
- Cross-server tests still run with both baseline servers available.
- Published coverage distinguishes unsupported skips from executed passing tests.

## Validation and delivery

For each phase, run the affected e2e selection, then the baseline pair when
shared harness behavior changes. Exercise meaningful failure paths: invalid
selection, failed readiness/bootstrap, interrupted setup, stale kept-container
configuration, and unsupported-capability reporting. Add small harness unit
tests only where they protect nontrivial selection, configuration, or reporting
logic; use real server runs to establish protocol compatibility.

Run `zig build test` if application/build code changes or repository requirements
call for it. A harness-only change primarily needs the e2e checks above. Record
exact commands, target versions, results, skipped capabilities, and blockers in
the implementation handoff. Do not claim a target is supported from startup or
`SELECT 1` alone.

Keep commits or PRs aligned to phases. Update `tests/e2e/README.md` with each
usable phase, and update this plan with completed work and remaining decisions.
Keep application changes limited to demonstrated client compatibility defects
with focused regression coverage.

## Reference documentation

Verify instructions against the selected versions before implementing adapters.

- [Percona Server container quickstart](https://docs.percona.com/percona-server/8.4/quickstart-docker.html)
- [Vitess test container](https://vitess.io/docs/24.0/get-started/vttestserver-docker-image/)
- [VTGate authentication](https://vitess.io/docs/faq/advanced-configuration/authentication/how-do-i-set-up-mysql-authentication-in-vitess/)
- [TiDB MySQL compatibility](https://docs.pingcap.com/tidb/stable/mysql-compatibility/)

External managed endpoints and proxy products can follow once these adapters
are stable. An external-endpoint mode needs separate explicit provisioning
ownership and disposable databases; the current destructive reseed SQL must
never be pointed at an arbitrary existing database.
