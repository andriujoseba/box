# Release management

This file describes the release-management pattern available to governed
repositories. Adoption is per repository and operator-ruled: a repository
without version epics is not out of compliance. A repo-local roadmap is the
map; each epic remains the source of truth for its own release. Where an older
repo-local description differs from this file, this file governs.

## The ladder

Represent each planned release with one version epic. The epic is the working
surface for that release: it states the goal, names the members, and records
the ordered waves as checklists. Keep the machine-readable progress checklist
under a heading matching `## Task list`, case-insensitively; the issue-flow
sweep reads task rows there until the next heading when it decides whether to
nudge triage about a completed epic. Other member or wave headings are not
completion inputs. That heading, its rows and the fence obey the same three
rules the membership record below does, in the same words (#349): the heading
and each row open on up to three leading spaces, four or more open nothing and
a leading tab counts as four; a task row is a checkbox row under any Markdown
list marker and only those — `-`, `*`, `+`, and 1 to 9 digits followed by `.`
or `)`; and no line inside a fenced code block is a heading or a row, so an
example task list quoted in a fence enrols nothing.

Keep a short repo-local roadmap beside the epics. The roadmap shows the whole
ladder and points to each working surface; it does not duplicate the live
member lists or ordering. A working surface can move when an epic becomes a
ledger; [The ledger pattern](#the-ledger-pattern) defines that transition
(#248).

## Release candidates

Release candidates extend one final-version window rather than opening
separate version epics. Their worked ladder is
`X.Y.Z-dev` → `X.Y.Z-rc1` → `X.Y.Z-rc2-dev` → `X.Y.Z-rc2` → … →
`X.Y.Z`. Each candidate is a tag-only cut: its ceremony PR changes the
version to the bare `X.Y.Z-rcN` and adds `drills/X.Y.Z-rcN.md`, but leaves
`CHANGELOG.md` and every fragment untouched. The release doors assemble the
surviving fragments into cumulative notes, publish the candidate with
`--prerelease`, and the merge door deterministically re-arms main as
`X.Y.Z-rc(N+1)-dev`. Repeat those steps for each candidate. Promotion to
`X.Y.Z` is the ordinary final ceremony: assemble and stamp the final section,
consume the fragments, publish the final release, and re-arm the next patch
development version (#322).

This path is fragment-mode only. Before opening an rc window, inspect the
first `## ` section of `CHANGELOG.md`: it must not be a stamped version that
matches `X.Y.Z-rcN` exactly. `changelog-armed` refuses that top section in
every mode and on every PR, while `changelog-monotonic` forbids deleting the
historical version heading. Stamp the next final section above it instead;
never delete the rc heading. That stamp is an ordinary ceremony PR, not a
migration exception. In legacy heading mode the ordinary
`## Unreleased` re-arm already puts a safe section above it. Fragment mode
refuses a surviving `## Unreleased`, so the next final cut is the adoption
door. Deeper rc headings are harmless history: the guard reads only the top
section. Spellings outside the declared `X.Y.Z-rcN` convention, such as
`-rc.1`, `-RC1`, or `-beta1`, are not rc stamps to `changelog-armed`;
`changelog-monotonic` still forbids deleting any version-shaped historical
heading (#322).

## Gates

Each version epic declares `Blocked by <predecessor>`. Special ordering — a
double gate or an out-of-chain gate — is written explicitly on that epic;
there is no hidden global schedule. The epic carries `epic` and the
repository's release label, with no queue label. Its `Blocked by` line is a
declaration a human reads: shipping closes the predecessor, then triage opens
the next window by hand as the first step of release-init. The issue-flow
sweep does not promote version epics; automating that gate would require a
separately specified change to its queue-category model.

The gate orders windows, not their contents. Members enter a release only by
decision during release-init. The double gate on
one member and an out-of-chain track are the two exception shapes, and each is
declared where it applies. (#248)

## The membership record

A release issue's `Blocked by` line answers the predecessor gate above and
nothing else. Which issues are *in* the release is a separate record on the
same issue, and the sweep reads it by heading (#343):

- the heading is literally `## Members`, matched case-insensitively, tolerant
  of any run of whitespace between the `##` and the word and of trailing
  whitespace after it, and the record runs to the next heading — the same
  shape `## Task list` already has, now in every particular (#349). The
  heading itself is bounded the way a row is: up to three leading spaces still
  open the record, four or more open nothing, a leading tab counting as four.
  The bound holds in both directions — an indented `## Gate` **closes** the
  record, so the parse never runs on into the next section and enrols its
  rows;
- no line inside a fenced code block is a heading, a terminator or a row, so
  an example record quoted in a fence enrols nothing. A fence delimiter is a
  run of backticks or tildes under the same three-space bound — four columns,
  a tab included, is an indented code block and not a fence — and it is closed
  by the next delimiter of the same character, so a tilde line does not close
  a backtick fence. Delimiter run length is not tracked, and an unclosed fence
  runs to the end of the body, which is what a reader sees too;
- one member per list row, under any Markdown list marker and only those:
  `-`, `*`, `+`, and 1 to 9 digits followed by `.` or `)` all open a row,
  because a row is whatever a reader sees as one — and a tenth digit opens
  nothing, CommonMark's ordered marker being at most nine digits, so
  `1234567890. #412` is narration and enrols no member. Indentation is bounded
  the same way: up to three spaces still open a row, four or more open nothing,
  a leading tab counting as four. The record is **flat** — one member per
  top-level row — and past that bound a line is not one: standing alone it is
  an indented code block, and under a row it is a sub-bullet annotating that
  member, and neither is a member itself. Below the bound it enrols, an
  indented row being the same bytes as a top-level one. The member is the
  row's first token after the list marker and an optional checkbox, and it is
  a bare local `#<number>`: `- #253` and `- [ ] #253` both enrol #253.
  Everything after that token is prose and contributes nothing, so a row is
  free to cite the PR that closed it, a sibling repository, or an issue it
  names as explicitly *not* a member;
- a row whose first token is anything else — a qualified `repo#N`, a number
  with punctuation attached, or ordinary prose — contributes no member. The
  parse stays silent rather than guessing;
- a qualified reference is never a member: a window is one repository's DAG,
  decided against one board read;
- a row naming the release issue itself contributes no member. The sink is
  never one of its own members;
- **there is no fallback to the gate.** A release issue with no members
  section enumerates no membership, is not a standing window, and draws no
  window flag. A repository whose epics predate this record gets silence,
  never a false flag, until its next release-init writes one.

Why a heading and not a marker phrase: the `Blocked by` parse unions every
occurrence of its marker and runs each clause to a sentence terminator, which
is the right error direction for a `blocked` issue and the wrong one for a
release body that is mostly narration *about* its members. Why the first token
and not every reference in the row: a real member row cites merged PRs, other
repositories and explicit non-members, and reading the whole row enrols all of
them.

The cost is named rather than hidden: a version epic maintains two lists — the
`## Members` record and the `## Task list` progress view — and triage writes
both in the same flip. The purchase is that the progress view stays a progress
view, prose-rich and free to carry several issues in one row or to omit a
member that is not in the build queue, while membership is a machine record
with exactly one shape.

## Release-init

The predecessor closing and clearing the next epic's declared gate is the
trigger, and today triage must notice it and open that window by hand.
[heavy-duty/ceremony#253](https://github.com/heavy-duty/ceremony/issues/253)
tracks the not-yet-shipped sweep announcement of that duty; do not treat the
announcement as present until the consumer's pin carries it. Triage runs five
steps:

1. Mint the epic's “to mint when this arc opens” list together with findings,
   deferred work, and discussion outcomes accumulated since the epic was
   written. Each member initially declares `Blocked by <the epic>`.
   **A member that arrives by re-opening a closed issue is re-pointed while it
   is still closed**: edit the closed issue's body so its declaration reads
   `Blocked by <the epic>`, verify the parse returns exactly the epic — a
   struck-through marker still parses, so the edit rewrites the old marker
   into non-parseable prose rather than striking it — and only then re-open
   it. The order is the rule: a re-opened issue carries the `blocked` label
   and the declaration it closed under, so a declaration naming only closed
   gates decides `ready` at the next sweep and admits a member the operator
   never blessed at step 4 (#325).
2. Graph hard `Blocked by` edges and same-file clusters on the epic.
3. Write the waves into the epic body as checklists in claim order, with a
   separate verification lane and the progress view under `## Task list`, and
   write the window's membership under `## Members` — release-init is where
   that record is first written, and until it exists no window stands.
4. Ask the operator to bless the order, then have triage open the first wave
   by applying the flip mechanics below. The operator's blessing is the one
   step this chain never automates.
5. Ship through the repository's cut process, close the epic, and treat that
   close as the trigger for the next window.

A wave plan's graph makes hard edges and shared-file contention visible before
builders enter the queue. (#248) If init finds no work worth minting, the
operator either folds the empty window into a later release or skips the
version, recording that ruling on the epic before closing it unshipped.

## One primary window, declared parallel tracks

Run one primary release window by default. A cut takes whatever has landed, so
interleaving unrelated windows blurs both the release story and the evidence
behind it. Gates open windows; they do not silently admit members, so builders
still see one deliberately ordered queue.

While a window stands — an open release-labeled issue whose membership record
holds at least one open member — its members form a DAG whose sink is the
release issue. Every member reaches that sink. Members declare only their
immediate predecessors; ordering edges live on members, while the sink records
membership only, in the record above and nowhere else; and the `ready` set is
exactly the graph's current sources. Every close
releases exactly its declared successors, and that whole set is concurrently
claimable: a member may have multiple successors, while the collision rule
already orders any that share a deliverable. Insertion re-points downstream
edges rather than merely appending membership at the sink. It follows that
every `ready` issue is a member. `epic` and `post-merge` issues are exempt
because neither is claimable (#292).

A member that lands `post-merge` releases nothing: that exemption is about
claimability, while a `post-merge` issue is still open and an open predecessor
holds its successors, so every successor declaring on it stays held and the
window stops advancing along that edge (#329).

**When a member reaches `post-merge` and any open declaration names it, triage
splits the remainder**: mint a fresh issue carrying the outstanding criteria
verbatim, naming its owner and its wake condition and citing the original, then
close the original on what it delivered. Triage owns this because only triage
mints issues and `post-merge` is its completion queue (#329).

**The release edge is the original's close, never the remainder's.** Each
successor's declaration names the original's number, so closing the new issue
releases nothing (#329).

**Split only when an open declaration names the issue.** The trigger is a check
rather than a judgement — run the blocker parse over every open `blocked` body
and see whether this number appears — because an issue that strands nothing is
`post-merge` working as intended (#329).

**Never close work out from under a builder.** Where the original is assigned,
`claimed`, or carrying an open PR, amend its body to hand the outstanding
criteria to the new issue and let its holder close it, so the release edge above
is reached without taking the work from them (#329).

**Do not instead teach the blocker parse that `post-merge` counts as landed.**
That promotes a successor while its predecessor still owes acceptance criteria,
inverts a parser whose deliberate error direction is to hold or flag a reference
it cannot read rather than release it, and needs label data a reference-state
lookup does not carry (#329).

The operator may declare a parallel track at init when its footprint is
disjoint from the primary window: another repository, another artifact, or
provably non-overlapping clusters. The declaration names the boundary and any
bridge work that must rejoin the primary. A repository whose app and artifact
are disjoint from the primary window forms a parallel track, while its bridge
work stays in the primary window. (#248)

## Flip mechanics

To admit a member, delete or rewrite its literal, parseable
`Blocked by <the epic>` declaration and swap `blocked` to `ready` in the same
edit. Markdown or HTML strikethrough is insufficient: the blocker parser reads
the raw marker text and still returns the reference. Never preserve history by
negating the marker phrase — the parser unions declarations even when prose
says they no longer apply. Preserve the history only after rewriting the
marker into non-parseable prose, then verify that the parser returns an empty
set for the release gate.

**The same flip adds the member's row to the release issue's membership
record.** That write is not bookkeeping to catch up on later: the record is
the only thing that makes the window stand, so a member flipped `ready`
without a row is, to the sweep, an unblocked non-member — the exact state the
window flag exists to report. Verify the flip by reading the record back and
finding the new member's row in it (#343).

Release membership is a decision, never a sweep default. Triage performs each
flip only after the operator blesses the wave; the issue-flow sweep may resolve
ordinary issue dependencies, but it does not choose a release's contents
(#248).

## The ledger pattern

When a release epic has become too crufty to remain a clear working surface,
create a replacement and treat the old epic as a ledger. Do not close the old
epic until every live member declaration points at the replacement and the
blocker parser verifies the new set. Closing early can release every member
that still names the old issue.

Re-point and parse-verify every member declaration before closing the old
epic; the old epic then remains the historical record while its replacement
is the working surface. (#248)
