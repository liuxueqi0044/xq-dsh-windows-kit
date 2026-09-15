# Upstream CLI contract evidence

Observed source revision: `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e` (`dsh-v0.1.1-rc.2`), repository `deepseek-ai/deepseek-harness`. This is source inspection only; no downloaded package code was run.

## Web listener

`packages/bundle/web-app/src/startup.ts:51-53` declares `--host <host>`, `--no-open`, and `--port <port>`. Lines 74-75 explicitly reject `--host 0.0.0.0` and direct users to `127.0.0.1`. The web bundle's profile patch is composed before a user profile and `--patch` overlays (`packages/bundle/web-app/cordis.patch.yml:1-5`); therefore the launcher must pass explicit `--host 127.0.0.1 --port 3080 --no-open` and independently re-check the listener. SUP-014: **PASS (source contract)**.

## Configuration and permission policy

`packages/bundle/base/cordis.patch.yml:172-191` defines the `sandbox-policy` row. Its mode is `process.env.DSH_PERMISSION_MODE ?? 'workspace-write'` (line 175), and the approval policy is `never` only for `danger-full-access`, otherwise `ask` (line 191). Thus the real configuration input is environment variable `DSH_PERMISSION_MODE`; `workspace-write` results in `ask`. The launcher must set `DSH_PERMISSION_MODE=workspace-write` explicitly, rather than rely on this default. SUP-015: **PASS (source contract)**.

## Profile overlays and telemetry

The effective layer order is bundle → profile → home → `--patch` overlays (`apps/cli/src/profile-boot.ts:121-151`). `DSH_TELEMETRY_DISABLED` adds the final telemetry-disable patch (lines 168-170). A safe launch therefore supplies its security overlay as `--patch` and sets a non-empty `DSH_TELEMETRY_DISABLED`.

## `dump-config` write behavior

`apps/cli/src/dump-config.ts:30-31` invokes `prepareProfile`; `apps/cli/src/profile-boot.ts:98` defines that preparation. It can create/initialize the profile root when absent. `dump-config` is consequently **not strictly read-only** and must never be used by a checker or diagnostic process against a user profile without an explicit approved write boundary. This is a proven behavior, not `UNKNOWN`.

## Remaining unknowns and limits

The npm version metadata did not expose `gitHead`; npm provenance binding was also not observed. Their statuses are `UNAVAILABLE`, not proof that the tarball is cryptographically bound to the Git commit. The source contract still requires Windows integration evidence for actual resolved output and listener behavior before release.
