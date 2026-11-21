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

## Phase 2: capabilities and fixture boundaries

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

## Phase 3: Percona Server and additional versions

Add a pinned Percona Server target using the MySQL-family provisioning path.
Verify its bundled client, root-password environment variable, TLS flags,
architecture support, and readiness behavior against the selected image.
Use it to expose assumptions that incorrectly equate target ID with family.

Support adding a second version as another target definition without adding
conditionals to generic test bodies. Select supported versions deliberately;
do not expand to every historical release. Record the actual server version
in run output, alongside the configured image reference.

Acceptance:

- Percona runs the applicable suite independently with no MariaDB timeout SQL.
- Adding another MySQL-family version requires configuration and only justified
  compatibility exceptions.
- The README contains tested local commands for the new targets.

## Phase 4: unsharded Vitess

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
