# The drill

An end-to-end rehearsal of box against a **real** Incus: install the CLI the way
a user does, assert the stack the installer left, mint boxes, drive the whole
surface, measure whether the isolation actually holds, open and shut a
deliberate door with `box expose`, walk the pre-0.4.0 migration, and tear
everything down. It ends with a probe count graded against a declared floor,
and — with `--emit-record` — the release record for
[`drills/<version>.md`](../drills/README.md).

> ⚠ **It rearranges the host it runs on.** Incus, a systemd unit, a network, an
> ACL, a profile, rewritten firewall rules — and, to drill migration, a
> faithful *legacy* stack (`claudenet` on 10.87, the `claude-dev` profile)
> built and then retired. **Run it on a machine you can format** — a spare
> server, a cloud VM you'll destroy, a VM on your laptop. Not your workstation.

```sh
git clone https://github.com/heavy-duty/box && cd box
bash drill/drill.sh --yes      # run and forget; omit --yes to be asked first
```

Exit 0 means every check passed **and** the run was not short — a phase that
never executed used to report a clean sweep, and does not any more (#153).
Roughly 20–40 minutes, most of it cold boxes.

Boxes it creates and deletes by name: `drill`, `clone`, `archive`, `peer`,
`tpl`, `legacybox`, plus the throwaway `cbprobe`, `cbcopy`,
`cbnotours` and `payroll` probes. The per-role `codex` and `grok` mints went
with #214: they proved a payload box no longer installs. It refuses to touch any other instance,
including an operator's own boxes on a shared host.

## Flags and settings

| flag / variable | what it does |
|---|---|
| `--yes`, `-y` | skip the consent prompt (CI, or you've read the header) |
| `--repo <owner/repo>`, `--ref <ref>` | drill a fork or a branch rather than `heavy-duty/box@main` |
| `--keep-boxes` | leave the boxes up to poke at; the teardown probe is then a **declared skip** and the floor drops by exactly its one probe |
| `--emit-record <path>` | write the release record skeleton (#152) |
| `--run-id <id>` | pin the ID box's, rig's and cast's records for one release share; unset, it generates `drill-<version>-<date>-01` and prints it early |
| `DRILL_EXPECT=<n>` | raise the probe floor above the table's own total; a non-numeric value is refused before the host is touched |
| `DRILL_OWNS_SETUP=1` | opt out of the installer's automatic host setup and let the drill sequence it; phase I is then a declared skip, because `install.sh`'s own contract (#64) is what it asserts |
| `NO_COLOR` | drop the ANSI, as does any stdout that is not a terminal — a record is pasted at least as often as it is read |

`--help` prints the script's own header block. That block **is** the help text
(`sed -n '2,54p' "$0"`), so a line added above it moves the window: keep the
two together. `test/cli.sh` checks both halves of that — the window still covers
the whole phase list, and the range quoted here and in `CONTRIBUTING.md` is the
range the script runs, read out of the script rather than trusted.

On a host with less than 20GiB of RAM the drill exports `BOX_MEMORY=3GiB
BOX_CPU=2` and says so — `--size medium`'s own 8GiB/4cpu is then what was *not*
drilled.

## What it checks

The script prints **eight ledgered phases**, in this order, plus unkeyed
sections (the install, the host setup, the summary, the audit answers) that
emit no verdicts. Each phase declares how many verdicts a complete run of it
emits; the table below is that declaration, and the summary grades the run
against it as a floor. **81 probes** total.

**What a box drill proves is what box owns**: that a mint comes up, at the size
it was asked for, on the shared placement contract and behind the real trust
boundary; that snapshot, restore, clone, export, import and rename do what they
say; that the multi-user tier holds; and that teardown leaves the host as it
found it. It does **not** prove that a box becomes an agent, or a server, or
anything else — box provisions and manages VMs and does not converge them
(#214), so a drill that asserted a converged guest would be asserting somebody
else's contract.

| | phase | probes |
|---|---|---|
| **I** | **The installer's contract.** `install.sh` runs the host setup itself (#64), so the drill asserts what it left — `boxnet`, the `box-isolate` ACL, the `box-net` profile, the nft bridge drop — *before* anything else on the host mutates the stack. Skipped, declared, under `DRILL_OWNS_SETUP=1`. | 1 |
| **A** | **Incus semantics.** The assumptions box is built on, probed directly: that `incus config get <inst> user.box` returns `1` (this is on the path of *every* box command — if it lies, everything fails closed); that the `user.box=1` list filter selects our instances and excludes an untagged one; that `--columns nstS` gives four clean CSV fields; that the state column reads `RUNNING`; that `incus rename` really does refuse a running instance; that snapshot-list's first CSV field is the label; that an **unset** config key reads as empty with exit 0 (#15 B4); and that `incus copy` **preserves `user.*` keys** (#15 B2 — the whole template-metadata design in #17 rests on it). | 8 |
| **B** | **The box surface.** Version, the empty-host message, templates and the key allowlist that stops one naming a network, mint, list, info, snapshot, clone-from-a-snapshot-of-a-renamed-box, the `--from` clone honouring `--cpu`/`--memory`/`--disk` (#171), rename (running must refuse, stopped must work), the escape hatch and its isolation warning, the `rm` confirmation guard, and the CLI contract (typo'd command, typo'd flag, `list <box>`). **The boundary** gets its own treatment: the drill launches an instance box did *not* mint, aims `down`, `rm` and the escape hatch at it, and requires all three to refuse — and the instance to still be standing afterwards. | 45 |
| **C** | **Isolation baseline (#15 section A).** From inside a real box: public egress works; the box cannot reach a listener on the host's gateway; RFC1918 is dropped; a **sibling box is unreachable** (a listener runs on the peer so "refused" — the packet arrived — cannot masquerade as "dropped"); DNS does not enumerate the sibling; IPv6 is off; and the host cannot connect **into** a box. | 9 |
| **E** | **`box expose` — a deliberate loopback door (#55).** A listener is started inside a box and the port exposed: the host's loopback must reach it, `expose --list` and `box info` must say the box has a hole in it, a **non**-exposed port must still be dropped (the feature is per-port, never a global ingress opening), and `--remove` must shut the door. | 7 |
| **D** | **The isolation contract, stated.** Not a rehearsal — see below. It judges only one thing: if phase C's baseline box could not reach the internet at all, it says out loud that every isolation result above is suspect rather than a pass. | 0 |
| **M** | **Migration — the pre-0.4.0 → box transition.** A faithful legacy stack is built (`claudenet`/10.87, `claude-dev`, a box wearing the old `user.claudebox` tag), then `host/migrate-host.sh` must re-home it with its identity intact — re-tagged, mapped to its user, moved onto `boxnet`, resolving on its new leg — and `--retire-legacy` must **refuse** while a legacy box remains and succeed once none does. | 10 |
| **T** | **Teardown.** Every box the drill minted is gone — and only those; a pre-existing operator box is left alone rather than counted as a failure. Skipped, declared, under `--keep-boxes`. | 1 |

### Phase D is a statement now, not a rehearsal

D used to apply #16's proposed hardening live and watch what broke, because
nobody knew whether it would work. That question is settled and the answers
ship in `setup-host.sh` and `box-firewall.sh`, so **phase C tests the real
stack** and D only restates what the rehearsal established:

- `@internal` is **rejected** as an ACL destination on a bridge network, so the
  sibling drop is an nftables bridge-family rule rather than an ACL rule. It
  has to be: an L3 ACL never sees frames switched between two ports of one
  bridge, which is why box→box was wide open while the ACL looked airtight.
- `dns.mode=none` closes the enumeration leak and public egress survives it. It
  is **shipped**, so it is part of the stack rather than a mutation a run
  leaves behind.
- `security.ipv4_filtering` breaks the box (dockerd comes up but cannot pull or
  run a container). **Vetoed — not shipped.**

So a finished or aborted run leaves **no D-phase mutations**: nothing to revert,
and `--keep-boxes` leaves you boxes on the ordinary shipped stack. What an old
run can still leave is the vetoed NIC filtering from the rehearsal era; the
drill detects it on the way in and reverts it, and `doctor.sh --fix` does the
same.

## The probe floor (#153)

The drill used to count what it **ran** and never how much it **should** have
run, so a phase that never executed reported a clean sweep — "71 passed, 0
failed", exit 0, and nothing on the line to say twelve isolation probes never
fired. That number is transcribed into `drills/<version>.md` as the evidence a
release was proven, and read months later by someone with no way to know the
run was short.

So the summary prints a per-phase line, grades the total as a **floor**, and
leaves non-zero when the run comes up short. A floor and not an equality:
adding a probe does not red the commit that adds it — but bumping
`PHASE_EXPECT` is part of adding one, and `test/cli.sh` extracts that table and
drives its arithmetic on a host with no Incus at all. A **legitimate** skip
prints a `SKIP` line, lowers the expectation by exactly its probes, and lands
in the record; the floor is never quietly tuned down to whatever the weakest
run happened to produce.

## The release record (#152)

```sh
bash drill/drill.sh --yes --emit-record drills/0.10.0.md
```

writes [`drills/README.md`](../drills/README.md)'s six-item record with every
field the harness already knows filled in: the run ID, the host (CPU, RAM, OS,
kernel, Incus version, and whether it was itself virtualised), the candidate
refs **and the SHAs they resolve to**, the invocation that reproduces the run,
the numbers against the floor, the wall clock, the findings, and the isolation
audit answers. Everything else in this file used to be retyped by hand out of
ANSI-coloured terminal output at the end of a forty-minute run.

What it emits is a **skeleton**: it says so in its own last paragraph, and that
paragraph is deleted by whoever writes what the findings *mean* for the
release. A generated file that reads like a finished one is worse than no file
at all. It refuses to overwrite a record that already exists, because the
judgement calls in one are the part no rerun can reproduce.

## The audit answers

Phases A, C and E record measurements — sibling reachability, the DNS
enumeration leak, IPv6, inbound, `incus copy`'s treatment of `user.*` — as
`aud` lines, printed as their own block at the end of the run and carried into
the emitted record. They were originally addressed to the
[#15 audit](https://github.com/heavy-duty/box/issues/15), which is complete;
the mechanism outlived the addressee, and the record is where those answers go
now.

They are answers rather than verdicts: "A4 dns enumeration: LEAKS" is data
about the host in front of you, and whether it is a *failure* is what the
`ok`/`no` beside it decides.

## What it does not check

Anything a converger puts on a box. Since #214 box installs no agent, so there
is no agent CLI for the drill to find and no agent login to rehearse — both are
downstream of a convergence box does not perform. What the drill asserts is the
seed's *own* payload (`tmux`, `shellcheck`), which is what box can still be held
to. Converging a box, and authenticating what you converged, are yours.

If the host has no `/dev/kvm`, box falls back to container mode. The drill
still runs, but it declares the VM probe it did not run and says loudly that
**the VM trust boundary was not validated** rather than passing quietly on a
weaker one.

## Why it exists

box's tests shim `incus`, and CI's rehearsal runs in containers. Both are
worth having — `test/cli.sh` drives the CLI's every branch, and the
multi-user rehearsal below runs on every PR — but the interesting failures
here are not in the bash. They are in what Incus actually does, and in what a
*virtual machine* boundary does, which is exactly what a shim stubs out and
gets wrong and what a container cannot demonstrate at all. The drill runs the
real thing, on real hardware, and that is the only place the trust boundary
this project sells is ever actually measured.

## Something wrong with the host?

`bash drill/doctor.sh` — it reports whether the host is fit to mint boxes and
to drill (the nested-box trap of #80, the network, `dns.mode`, the profile's
NIC keys, the ACL, the firewall drop, the storage pool, the bridge ports as the
*kernel* sees them, leftover boxes, the host resolver, and whether a box can
still resolve DNS). `--fix` converges what an aborted run left behind:
restoring `dns.mode=none`, unsetting the vetoed NIC filtering keys, removing
the `@internal` ACL rule, deleting leftover drill boxes. Users reach the same
script as `box doctor`.

**Iterating on the drill?** Read [RUNS.md](RUNS.md) first — it is the run log:
what the audit has answered so far, the bugs the drill has found in box, the
traps this script has already fallen into (every one cost a run), how to
diagnose a stall, and how to run a single probe by hand instead of paying for a
whole run. It is a different artifact from `drills/<version>.md`: that one is
per-release evidence read by the release guard, this one is the harness's
ongoing log, and updating one never satisfies the purpose of the other.

## The multi-user rehearsal (`multiuser.sh`)

The restricted tier (#74) has its own rehearsal — the drill proves one
operator's host; this proves a *shared* one:

```sh
sudo BOX_MULTIUSER_REHEARSAL=1 bash drill/multiuser.sh --yes
```

Root only, opt-in twice (it creates system users and edits the group
database). It creates two throwaway users, grants them the tier through the
real `box grant`, mints real boxes as them, and measures — from inside those
boxes — that each user is confined to their own project (a), the full
lifecycle works (b), no cross-user visibility (c), names don't collide (d),
`expose`/`setup-host`/`doctor` answer honestly at the tier (e/f), the boxes
ride `boxnet` under the full isolation contract including the cross-user
sibling drop (g), the private-bridge escape hatches are closed (h), the grant
survives an incus-user restart (k), `revoke --purge` erases one user
without touching the other (l), and the fleet word `all` stops at the tier
boundary (p) — one user's `box down all` acts on their own box and leaves the
other's RUNNING, and an admin's stops the admin's own box in `default` while
reaching into no `user-<uid>` project, all read back from the admin socket
rather than off box's own output. Everything it makes, it deletes.

Criterion (p) is here rather than only in `test/cli.sh` because of what the
two can prove. The unit drive shims Incus, so it can show box acts on exactly
the set the daemon hands it; only a real two-user daemon can show what that
set *is* for a restricted caller. `all` was the first verb whose blast radius
is a set, so the boundary (c) measures for reading is measured again for
writing (#179). It mints one box of the admin's own before the admin probe,
because every other mint in the file belongs to a rehearsal user: with an
empty `default`, root's `all` would enumerate nothing and leave both user
projects untouched for the trivial reason that it did nothing — the absence of
an action passing for a scoped one.

`--container` skips VM mints (CI runs it this way on every PR — the tier's
semantics are instance-type-independent); on real hardware run it bare so the
boxes are VMs. `--keep` leaves the users and boxes up for inspection.
