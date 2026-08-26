# .ceremony/ — the vendored doctrine mirror

Machine-managed by heavy-duty/ceremony's `actions/docs-sync`. Never edit
these files here: they are byte-identical copies of
[heavy-duty/ceremony](https://github.com/heavy-duty/ceremony) at this
repository's pinned ref, and CI re-diffs them on every PR — a hand edit
goes red. They are changed in heavy-duty/ceremony, through its own flow —
[Requesting a doctrine change](https://github.com/heavy-duty/ceremony/blob/main/docs/CONSUMERS.md#requesting-a-doctrine-change)
— and arrive here when the pin moves.

**If a rule here is what is blocking you** — it cannot express your case, it
contradicts another, it names no mechanism — that flow is the way out, and
using it is not optional politeness: a workaround written locally instead
governs this repo while nobody upstream can see it. Open a
[discussion](https://github.com/heavy-duty/ceremony/discussions) quoting the
rule at this repo's pin, and cite that discussion wherever the local
workaround lives. The fix arrives the way every doctrine change arrives —
when the pin moves.

The pin lives in `.github/workflows/release.yml` — the single
`uses: heavy-duty/ceremony/.github/workflows/release.yml@<ref>` line. One
pin governs machinery and doctrine alike: bump it and re-sync this mirror
in the same PR (`docs-sync --fix`, or let the red check on the bump PR say
what is stale).
