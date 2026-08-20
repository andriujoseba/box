# Contributing

This repository is governed by
[heavy-duty/ceremony](https://github.com/heavy-duty/ceremony). Agents read
[`.ceremony/AGENTS.md`](.ceremony/AGENTS.md) first, then the role file it
selects. The files under `.ceremony/` are machine-managed and must never be
edited in place.

Only triage mints issues. Everyone else opens or extends a discussion when
they find work outside an existing issue contract. Only humans merge.

## Review panel

The review panel is:

- `claude-bot-andresmgsl`
- `codex-bot-andresmgsl`
- `grok-bot-andresmgsl`
- `kimi-bot-andresmgsl`

Every PR needs a current-head verdict from the whole panel minus its author.
`dan-claude-bot` is triage-only and is never a reviewer. Draft PRs remain
invisible to the panel; when ready, request every eligible reviewer.

## Code and verification

- Bash executables use `set -euo pipefail`; test harnesses use `set -u`
  because they assert failing commands.
- Keep shellcheck clean. Run `bash test/cli.sh` and `bash test/release.sh`;
  CI also runs the Incus multi-user rehearsal.
- Match whole versions: `0.7.0` must never match `0.7.0-rc1`.
- Comments preserve the incident that bought a rule, including its issue
  number.

## Changelog

Every behavior-changing PR writes one file — `changelog.d/<issue>.md` —
carrying the exact prose that will be published, and nothing else. It does
**not** edit `CHANGELOG.md`; the release PR assembles the fragments into the
next section and consumes them. Distinct filenames never conflict, which is
the whole point: the shared `## Unreleased` anchor this replaced made two
open PRs a conflict by construction, and a rebase moves the head, so each
conflict cost a full review round.

This tree is `grouped` (the sentinel at `changelog.d/shape` says so), so a
fragment carries its own `### Added` / `### Changed` / `### Fixed` heading
above its bullets. Two rules bite on every entry, and the corpus is graded
whole — one bad file reds every PR opened after it: **at most 300
characters** per entry, and **exactly one terminal `(#N).` citation**. An
entry citing a cross-repo issue goes in `changelog.d/<repo>-<N>.md`.

Never replace or duplicate a shipped heading; the shared armed, monotonic
and assembled guards enforce every half of this rule.

## Releases

The release ceremony, merge and tag doors, version stamps, guard semantics,
and recovery paths are defined by
[heavy-duty/ceremony](https://github.com/heavy-duty/ceremony/blob/0.7.4/README.md).
Box pins the shared machinery and doctrine at `0.7.4`.

Box uses the `file` version backend and has no artifact hook: for this
pure-Bash tree, GitHub’s source tarball for the tag is the package, and
`install.sh` downloads exactly that. `VERSION`, `CHANGELOG.md`, and
`drills/<version>.md` remain box-owned release inputs.

### What a box drill proves

The box drill is the 87-probe VM isolation contract: it exercises the trust
boundary on real hardware. The lighter Incus container rehearsal in CI proves
the tier mechanics but cannot substitute for that boundary measurement. The
record format and operating procedure live in [drills/README.md](drills/README.md).

`drills/<version>.md` and [`drill/RUNS.md`](drill/RUNS.md) are deliberately
different artifacts. The former is per-release evidence read by the release
guard; the latter is the harness’s ongoing run log and lore. Updating one
never satisfies the purpose of the other.

The family drills are independent and may run in any order. Each pins the
same fixed candidate refs: rig’s drill uses the candidate box ref, while
box’s drill mints with the candidate rig ref. Static refs dissolve the
box↔rig runtime recursion; no repository needs to release first.

That gap from box#81 — released box templates defaulting `RIG_REF` to `main`,
so a later mint consumed a rig revision other than the one drilled — is
closed by box#150. An unset `RIG_REF` now resolves rig’s latest release at
mint, so the combination a user receives is a released box against a released
rig. A drill still pins both refs explicitly, because a candidate is a branch
on a fork and no release names it yet.

## Scope labels

- `scope:cli` — `bin/box`, the command surface
- `scope:installer` — `install.sh`, versioned installs, upgrade/uninstall
- `scope:host` — host setup, teardown, firewall, and isolation stack
- `scope:tiers` — grant/revoke and multi-user boundaries
- `scope:templates` — template and profile seeds
- `scope:drill` — rehearsals, doctor, and run evidence
