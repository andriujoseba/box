# changelog.d/ — the next release's section, one fragment per issue

Machine-assembled by ceremony's `bin/changelog-assemble`
(heavy-duty/ceremony#112): every PR that changes behavior writes one file
here — `<issue>.md`, the exact prose that will be published, nothing else —
and the release PR folds them all into the next `## X.Y.Z — DATE` section of
`CHANGELOG.md`, consuming them. Distinct filenames never conflict, which is
this directory's whole reason to exist: the shared `## Unreleased` anchor
this replaced made two open PRs a `CHANGELOG.md` conflict by construction,
and a rebase moves the head, so each conflict cost a full review round.

This README is the marker that keeps the directory tracked when it holds no
fragments — `changelog-armed` refuses a tree without it; do not delete it.
The `shape` sentinel beside it declares the set's shape — `grouped` here, so
every fragment carries its own `### Added` / `### Changed` / `### Fixed`
heading and the assembler merges same-named groups across fragments in
canonical order (heavy-duty/ceremony#182).

Two rules bite on every fragment, and the corpus is graded whole — one bad
file reds every PR opened after it:

- **at most 300 characters per entry** (heavy-duty/ceremony#167), and
- **exactly one terminal `(#N).` citation** per entry
  (heavy-duty/ceremony#262).

An entry citing a cross-repo issue names the file `<repo>-<N>.md`.
