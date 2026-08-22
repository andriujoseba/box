#!/usr/bin/env bash
# drill.sh — end-to-end drill for box, against a real Incus.
#
#   ⚠ DESTRUCTIVE, AND MEANT TO BE. Run it on a THROWAWAY host you can format.
#     It installs Incus, rewrites the host's firewall rules, installs a systemd
#     unit, and creates and deletes instances. Never run it on a machine you care
#     about.
#
#   bash drill/drill.sh                  # asks first
#   bash drill/drill.sh --yes            # no prompt (CI, or you've read it)
#   bash drill/drill.sh --ref main       # drill a different branch of the repo
#   bash drill/drill.sh --keep-boxes     # leave the boxes up to poke at
#   DRILL_EXPECT=90 bash drill/drill.sh  # raise the floor (a whole number)
#   bash drill/drill.sh --emit-record drills/0.10.0.md    # write the record
#   bash drill/drill.sh --run-id drill-0.10.0-20260819-01 # share one ID
#
# The run is short unless it emits at least the expected number of verdicts:
# a phase that never executed used to report a clean sweep (#153). A skip that
# is legitimate prints a SKIP line and lowers the floor by exactly its probes.
#
# --emit-record <path> writes drills/README.md's six-item record with every
# field the harness already knows filled in (#152): the run ID, the host, the
# candidate refs and the SHAs they resolve to, the numbers against #153's
# floor, the wall clock, the findings and the isolation audit answers, all
# uncoloured (#154). It is a SKELETON — what
# a failure means for the release is a judgement a script must not fabricate,
# so the file says it is a draft until you edit that line out. --run-id (or
# DRILL_RUN_ID) pins the ID this release set's three records share; unset, it
# generates drill-<version>-<date>-01, and either way it is printed early
# enough to hand to whoever drills rig and cast.
#
# NO_COLOR (any value), or a stdout that is not a terminal, drops the ANSI.
# The summary exists to be piped somewhere; escape codes in a pasted record
# are noise, and every record before this one was transcribed past them.
#
# The phases, in the order they PRINT. The letter is the phase's ledger key and
# the bracketed number is how many verdicts a complete run of it owes (#153):
#   I. The installer's contract — the stack install.sh left, asserted before
#      anything else here touches it (#64).                                 [1]
#   A. Incus semantics — the assumptions box is built on, probed directly.
#      These were only ever verified against a stub.                        [8]
#   B. The box surface — the whole CLI, end to end, including the boundary. [45]
#   C. Isolation baseline — does the trust boundary actually hold?
#      (#15 section A)                                                      [9]
#   E. box expose — a deliberate loopback door, opened and shut (#55).      [7]
#   D. The isolation contract, STATED — not rehearsed. What it used to apply
#      live is shipped, so C tests the real stack and a run leaves no
#      D-phase mutations behind.                                           [0]
#   M. Migration — the pre-0.4.0 → box transition (host/migrate-host.sh).  [10]
#   T. Teardown — every box the drill minted is gone, and only those.       [1]
#
# Exit 0 = every check passed AND the run was not short of that floor (#153).
# The summary ends with the isolation audit answers; --emit-record carries them
# into the record, which is where they are read now (#154).
#
# The file is one long 'probe && ok "..." || no "..."'. ok/no always return 0, so
# the C-may-run-when-A-is-true trap SC2015 warns about cannot fire here.
# shellcheck disable=SC2015
#
# NOT -e: a failing check is data, not a crash. NOT pipefail: half the checks
# are 'refusal 2>&1 | grep -q text' where the refusal exits 1/2 BY DESIGN, and
# 'grep -q' SIGPIPEs the left side on early match — pipefail turned both into
# false FAILs on the first live run. The pipeline verdict must be grep's alone.
set -u

# >>> drill settings — extracted by test/cli.sh and DRIVEN, because every one of
# these has to survive the sg re-exec below and the only proof of that is running
# it. The rule the block embodies: --in-group carries no arguments through, so
# EVERY setting the second stage needs arrives as environment, and every one of
# them reads that environment HERE rather than being clobbered to a default the
# flag can no longer change.
REPO="${BOX_REPO:-heavy-duty/box}"
REF="${BOX_REF:-main}"
YES=0
# KEEP crossed the exec as a bare `KEEP=`, which this line then set to 0 before
# anything could read it: --keep-boxes was inert in the second stage — the whole
# stage — so the teardown phase always ran and the record could never say the run
# had been asked to keep its boxes (#152). It crosses as DRILL_KEEP now, like
# every other pin, because a bare KEEP in an operator's environment is not a
# request to change what the drill asserts.
KEEP="${DRILL_KEEP:-0}"
# The record's two settings survive the sg re-exec below as environment, not as
# flags. Both default empty; DRILL_RUN_ID unset means "generate one once the
# installed VERSION is known", which is not a decision this line can make yet.
RECORD="${DRILL_RECORD:-}"
RUN_ID="${DRILL_RUN_ID:-}"
SELF="$(readlink -f "$0")"

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    --keep-boxes) KEEP=1; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --emit-record) RECORD="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --in-group) shift; break ;;                       # internal: see below
    # The help IS the header block above, printed verbatim, so a line added
    # there must move this window with it — 18 → 23 for the five lines the
    # probe floor added, 23 → 39 for the sixteen the record added, 39 → 54 for
    # the phase list this window used to cut off in the middle of (#154). It
    # ended on "C. Isolation baseline" while the list ran to M, which is how a
    # tool asked directly for its phases answered with four of eight. The whole
    # list is inside the window now, and test/cli.sh asserts that by driving
    # --help against the ledger's own keys rather than against a fixed string.
    -h|--help) sed -n '2,54p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "drill: unknown option: $1" >&2; exit 2 ;;
  esac
done
# <<< drill settings

# >>> group re-exec — extracted by test/cli.sh and DRIVEN against a fake `sg`,
# because the only thing that can prove a quoting rule is executing it.
#
# `sg incus-admin -c <string>` hands its argument to a SHELL, so anything
# interpolated into that string is shell SOURCE and not data. This line used to
# read `DRILL_RECORD='$RECORD' … bash '$SELF'`, and an apostrophe — legal in a
# Unix pathname, legal in a run ID, and constrained by neither --emit-record nor
# --run-id nor --repo nor --ref — closed the quotes and reparsed the remainder as
# a command. It exited 127 forty minutes in, on the far side of the startup guard
# that exists to catch bad record paths early (#152).
#
# So nothing is interpolated. `sg` execs with the environment intact, which is
# how --in-group has always got its settings across; the -c string is now a fixed
# literal whose only expansion is the child shell's own "$DRILL_SELF". That also
# means it does not matter which shell `sg` picks out of /etc/passwd — there is
# no quoting in it to get wrong, and no printf %q whose $'…' output would need a
# bash on the other side.
#
# The clock MUST cross: the shell that writes the record is not the shell that
# started the run, so a $SECONDS-based duration would measure from this line
# rather than the drill's start.
reexec_in_group() {
  export IN_GROUP=1 \
         DRILL_OWNS_SETUP="$OWNS" \
         BOX_REPO="$REPO" \
         BOX_REF="$REF" \
         DRILL_KEEP="$KEEP" \
         DRILL_RECORD="$RECORD" \
         DRILL_RUN_ID="$RUN_ID" \
         DRILL_T0="$DRILL_T0" \
         DRILL_SELF="$SELF"
  # SC2016: not expanding here is the entire fix. "$DRILL_SELF" is expanded by
  # the shell sg starts, out of the environment exported above; expanding it in
  # THIS shell is what the apostrophe defect was.
  # shellcheck disable=SC2016
  exec sg incus-admin -c 'bash "$DRILL_SELF" --in-group'
}
# <<< group re-exec

# >>> drill verdicts — extracted by test/cli.sh together with the ledger and the
# summary below, so the run's EXIT PATH can be executed rather than grepped.
#
# The colour is resolved ONCE, here, and every verdict reads the result (#152).
# It used to be unconditional, in a script whose whole output exists to be read
# later: piping the summary to a file gave escape codes, and the operator then
# transcribed a record past them. NO_COLOR (the convention: set, any value,
# even empty) and a stdout that is not a terminal both mean plain. The variables
# stay defined either way, so nothing below has to ask a second time — which is
# what keeps this block self-contained enough for the harness to source.
if [ -n "${NO_COLOR+x}" ] || [ ! -t 1 ]; then
  C_G=''; C_R=''; C_Y=''; C_B=''; C_0=''
else
  C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
fi
pass=0; fail=0; findings=(); audit=()
ok()   { printf '  %sPASS%s  %s\n' "$C_G" "$C_0" "$*"; pass=$((pass + 1)); tally; }
no()   { printf '  %sFAIL%s  %s\n' "$C_R" "$C_0" "$*"; fail=$((fail + 1)); findings+=("FAIL: $*"); tally; }
note() { printf '  %sNOTE%s  %s\n' "$C_Y" "$C_0" "$*"; findings+=("NOTE: $*"); }
inf()  { printf '        %s\n' "$*"; }
phase(){ PHASE="$1"; shift; printf '\n%s══ %s%s\n' "$C_B" "$*" "$C_0"; }
aud()  { audit+=("$*"); }                       # a measurement, for the record
# <<< drill verdicts

# >>> probe ledger (#153) — test/cli.sh extracts this block verbatim; keep it
# self-contained (it may assume only `findings`, declared above).
#
# The drill used to count what it RAN and never how much it SHOULD have run, so
# a phase that never executed reported a clean sweep: "71 passed, 0 failed",
# exit 0, and nothing on the line to say twelve isolation probes never fired.
# That number does not stay in a terminal — it is transcribed into
# drills/<version>.md as the evidence a release was proven, and read months
# later by someone with no way to know the run was short. A drill that silently
# drills LESS code is the same defect as one that silently drills the WRONG
# code, which this script already refuses three hundred lines down.
#
# So every phase declares how many verdicts a COMPLETE run of it emits, ok/no
# tally against whichever phase is open, and the summary asserts the numbers as
# a FLOOR — a floor and not an equality, so adding a probe does not turn the
# commit that adds it red. Bumping the number below is part of adding one,
# which is also what finally gives CONTRIBUTING's "81-probe contract" and
# drills/README.md's worked ratio something that checks them. The header block
# above states each phase's count too, and 'test/cli.sh' asserts the two
# agree by INTEGER and not merely by phase key — #214 moved B from 51 to 45
# and left the header saying 51, which is the drift a key-only check reads as
# green.
#
# Phase keys are the letters the phase headers already use; '-' is a phase that
# emits no verdicts at all (install, host setup, the summary itself). A verdict
# emitted under '-' lands in the '?' bucket and is reported, because an
# unattributed probe means this table has drifted from the script.
PHASE_ORDER=(I A B C E D M T)
declare -A PHASE_EXPECT=(
  [I]=1     # install.sh left a complete host stack (#64)
  [A]=8     # A1–A6, A8, A9 — Incus semantics (A7 prints, it does not judge)
  [B]=45    # the box surface: dedicated seed/version 5 + blank 10 + #171 clone 3
            # + the drill box, its clone and the CLI contract 27. It was 51 until
            # #214 took the role axis out: the two per-role mints proved a payload
            # box no longer installs (6 probes), and the drill box's own two agent
            # probes became two seed-payload probes, which is a swap and not a cut.
  [C]=9     # C1–C7, plus archive-is-up and the peer clone
  [E]=7     # box expose: add, list, info, the door, per-port, remove, shut
  [D]=0     # D states the settled contract; it judges only a failed baseline
  [M]=10    # migration: legacy up, visible, refuse, re-home ×5, retire ×2
  [T]=1     # teardown: every box the drill minted is gone
)
declare -A PHASE_RAN=() PHASE_WAIVED=()
PHASE=-

tally() {   # attribute a verdict to the open phase. ok/no must still return 0.
  case "$PHASE" in
    -|'') PHASE_RAN[?]=$(( ${PHASE_RAN[?]:-0} + 1 )) ;;
    *)    PHASE_RAN[$PHASE]=$(( ${PHASE_RAN[$PHASE]:-0} + 1 )) ;;
  esac
  return 0
}

# A legitimate skip DECREMENTS the expectation and SAYS SO on its own line, and
# lands in findings so it survives into the record. The expectation is never
# quietly tuned down to whatever the weakest run happens to produce — that is
# the failure this whole ledger exists to prevent, one level in.
skipped() {   # skipped <phase-key> <n> <why>
  local k="$1" n="$2"; shift 2
  PHASE_WAIVED[$k]=$(( ${PHASE_WAIVED[$k]:-0} + n ))
  # ${C_Y:-} and not "$C_Y": the colour belongs to the verdicts block above, and
  # this one's contract is that it assumes only `findings`. Sourced alone by the
  # harness it prints plain, which is what the harness wants anyway (#152).
  printf '  %sSKIP%s  %s\n' "${C_Y:-}" "${C_0:-}" "$*"
  findings+=("SKIP: $* [$k: $n probe(s) not expected this run]")
}

ledger_want() {   # what phase <k> owes THIS run, after declared skips
  local k="$1"
  printf '%s' "$(( ${PHASE_EXPECT[$k]:-0} - ${PHASE_WAIVED[$k]:-0} ))"
}

ledger_declared() {   # the table's own total — the "85" the docs quote
  local k t=0
  for k in "${PHASE_ORDER[@]}"; do t=$(( t + ${PHASE_EXPECT[$k]:-0} )); done
  printf '%s' "$t"
}

ledger_waived() {
  local k t=0
  for k in "${PHASE_ORDER[@]}"; do t=$(( t + ${PHASE_WAIVED[$k]:-0} )); done
  printf '%s' "$t"
}

# The floor for the whole run. DRILL_EXPECT is the operator's override of the
# table's total (raise it to demand more, never to excuse a short run); declared
# skips decrement whichever total is in force.
ledger_expected() {
  printf '%s' "$(( ${DRILL_EXPECT:-$(ledger_declared)} - $(ledger_waived) ))"
}

# A typo'd override must SAY it was a typo. DRILL_EXPECT=abc used to reach the
# arithmetic above and leak 'abc: unbound variable' into the summary, printing
# "1 of  expected probes" — it failed safe (the shortfall verdict does not
# depend on the total) but left the operator to infer the cause from a mangled
# line. Checked once at startup instead, where they can still fix it.
ledger_check_expect() {
  case "${DRILL_EXPECT:-0}" in
    *[!0-9]*)
      echo "drill: DRILL_EXPECT must be a whole number, got: ${DRILL_EXPECT}" >&2
      return 2 ;;
  esac
  return 0
}

ledger_short() {   # every phase that came up short, as ' K(got/want)'
  local k want got out=""
  for k in "${PHASE_ORDER[@]}"; do
    want="$(ledger_want "$k")"; got="${PHASE_RAN[$k]:-0}"
    [ "$got" -lt "$want" ] && out="$out $k($got/$want)"
  done
  printf '%s' "$out"
}

ledger_line() {   # the per-phase counts a single total can never make obvious
  local k out="" waived=0
  for k in "${PHASE_ORDER[@]}"; do
    out="$out  $k ${PHASE_RAN[$k]:-0}/$(ledger_want "$k")"
    waived=$(( waived + ${PHASE_WAIVED[$k]:-0} ))
  done
  [ "${PHASE_RAN[?]:-0}" -gt 0 ] && out="$out  ?${PHASE_RAN[?]} (unattributed — the ledger has drifted)"
  [ "$waived" -gt 0 ] && out="$out   [$waived waived by declared skips]"
  printf '  probes %s\n' "$out"
}
# <<< probe ledger

# >>> drill record (#152) — test/cli.sh extracts this block verbatim and drives
# it, so keep it self-contained: it may assume the verdict helpers and the probe
# ledger above it, and nothing else the script declares. Everything else it
# needs arrives as an argument or as one of the REC_* variables below.
#
# drills/README.md asks a record for six things, and this harness knew five of
# them all along while printing none in that shape. So every record was retyped
# by hand out of ANSI-coloured terminal output at the end of a forty-minute run,
# by someone who then had to reconstruct what the host had been. The sixth — the
# run ID that makes box's, rig's and cast's records reassemble into one picture —
# had no mechanism at all: it was invented at write-up time, independently, three
# times, and the odds the three matched were whatever memory was worth.
#
# The split is the whole design. record_collect() touches the world (uname,
# incus, /etc/os-release, the network) and record_write() touches nothing but
# the REC_* set, so the SHAPE of a record is drivable by a test on a host with
# no Incus, no drill and no network.
#
# What the harness must never write is prose. "Judged not release-blocking: it
# affects teardown residue on a host that is about to be wiped" is a judgement,
# and a generated file that reads like a finished one is worse than no file at
# all — it invites exactly the transcription-free confidence the last two
# waivers were written under. So the emitted record ends by saying it is a
# draft, in the rendered text and not in an HTML comment nobody sees.

record_version() {   # the VERSION of the tree the install actually landed
  local v
  v="$(cat "$HOME/.local/share/box/current/VERSION" 2>/dev/null)"
  printf '%s' "${v:-unknown}"
}

# drills/README.md: "The name must match the contents of VERSION exactly", and
# the ID carries that version so a record and its run cannot drift apart. The
# trailing -01 is a sequence for a second run on the same day; bump it by hand,
# or pass --run-id, which is what a coordinated release set does anyway.
record_run_id() {   # <version> <yyyymmdd> → drill-<version>-<date>-01
  printf 'drill-%s-%s-01' "$1" "$2"
}

# "Real hardware" is the claim the record makes, so name the hardware — and name
# the virtualisation too. A drill run inside a VM is not disqualified, but a
# record that does not say so lets a reader assume bare metal, and the boundary
# this drill measures is precisely the one nested virtualisation blurs.
record_host() {
  local kernel os cpu mem virt incus
  kernel="$(uname -sr 2>/dev/null)"; kernel="${kernel:-unknown kernel}"
  # shellcheck disable=SC1091  # a data file, present on every distro box targets
  os="$( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}" )"
  os="${os:-unknown OS}"
  cpu="$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null)"
  cpu="${cpu:-unknown CPU}"
  mem="$(awk '/^MemTotal:/ { printf "%.0f GB", $2 / 1048576 }' /proc/meminfo 2>/dev/null)"
  mem="${mem:-unknown RAM}"
  virt="$(systemd-detect-virt 2>/dev/null)"; virt="${virt:-unknown}"
  incus="$(incus --version 2>/dev/null)"; incus="${incus:-not installed}"
  printf '%s / %s, %s, kernel %s, Incus %s (virt: %s)' \
    "$cpu" "$mem" "$os" "$kernel" "$incus" "$virt"
}

# A ref without its SHA proves nothing later — the branch moves and the record
# stops naming a tree. git first because it costs no rate limit and answers for
# any ref; the GitHub API's `sha` media type second, because a drill host has
# curl by construction (it fetched install.sh with it) and may not have git.
# Both answers go through one validator: an error page and a rate-limit body are
# not SHAs, and 'unresolved' in the record is honest where a truncated HTML
# fragment would be a lie with a monospace font on.
record_sha() {   # <repo> <ref> → the seven-char commit, or 'unresolved'
  local repo="$1" ref="$2" sha=''
  # A ref that IS a commit resolves to itself; asking a remote to expand it
  # returns nothing, which is how a pinned drill used to record 'unresolved'.
  if [ "${#ref}" -eq 40 ] && [ -z "${ref//[0-9a-f]/}" ]; then
    printf '%s' "${ref:0:7}"; return 0
  fi
  # GIT_TERMINAL_PROMPT=0 and a timeout are not belt-and-braces: a repo name
  # that 404s (a typo'd --repo, a private fork) makes git ask for credentials
  # on the terminal, and an unattended drill would sit at that prompt forever —
  # forty minutes of work waiting on a username nobody is there to type.
  # An ANNOTATED tag resolves to the tag OBJECT: a 40-hex string that is a valid
  # object and not a tree anyone can check out — and the validator below cannot
  # tell, because it is hex. The commit lives on a SECOND ref, `refs/tags/<t>^{}`,
  # and ls-remote matches a pattern against the ref's tail component, so an exact
  # `<t>` selects the tag object ALONE. Asking for the peel is the only way to be
  # sent it; a peel-preferring reader over a `"$ref"`-only query prefers a line
  # that never arrives. Both patterns go out, the peeled answer wins where there
  # is one, and a branch or lightweight tag — which has no peeled ref — is
  # unaffected, because a pattern matching nothing changes no output.
  if command -v git >/dev/null 2>&1; then
    sha="$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true timeout -k 5 25 \
             git ls-remote "https://github.com/$repo" "$ref" "$ref^{}" 2>/dev/null \
           | awk '$2 ~ /\^\{\}$/ { peeled = substr($1, 1, 7); exit }
                  NR == 1       { first  = substr($1, 1, 7) }
                  END           { if (peeled != "") print peeled; else print first }')"
  fi
  if [ -z "$sha" ] && command -v curl >/dev/null 2>&1; then
    sha="$(curl -fsSL -m 20 -H 'Accept: application/vnd.github.sha' \
             "https://api.github.com/repos/$repo/commits/$ref" 2>/dev/null \
           | cut -c1-7)"
  fi
  case "$sha" in
    ''|*[!0-9a-f]*) printf 'unresolved' ;;
    *)              printf '%s' "$sha" ;;
  esac
}

# drills/README.md's worked example writes "41 minutes wall clock". $SECONDS
# cannot supply it: the drill re-execs itself into the incus-admin group and
# the shell that finishes is not the shell that started, so the clock is an
# epoch stamp carried across that exec (DRILL_T0).
record_wallclock() {   # <seconds> → the phrase, or an honest refusal to guess
  local s="${1:-}"
  case "$s" in
    ''|*[!0-9]*) printf 'wall clock not measured' ; return 0 ;;
  esac
  if [ "$s" -lt 60 ]; then printf 'under a minute wall clock'
  else printf '%s minutes wall clock' "$(( (s + 30) / 60 ))"; fi
}

# Refuse a bad record path BEFORE the drill starts formatting a host, exactly as
# the DRILL_EXPECT guard does: an operator who typo'd it must find out now, not
# in the summary forty minutes on.
#
# The overwrite refusal is the load-bearing half. The emitted file is a skeleton
# the operator then writes prose into, and that edited file is the release
# evidence the gate reads. A second run pointed at the same path would silently
# eat those judgements, so it does not get to: remove the file or name another.
record_check_path() {   # <path> — empty path means no record was asked for
  local path="$1" dir
  [ -n "$path" ] || return 0
  case "$path" in */*) dir="${path%/*}" ;; *) dir='.' ;; esac
  [ -d "$dir" ]  || { echo "drill: --emit-record: no such directory: $dir" >&2; return 2; }
  [ -w "$dir" ]  || { echo "drill: --emit-record: not writable: $dir" >&2; return 2; }
  if [ -s "$path" ]; then
    echo "drill: --emit-record: $path already exists and is not empty." >&2
    echo "  A record is edited by hand after it is emitted, so overwriting one" >&2
    echo "  destroys the judgement calls that make it evidence. Remove it, or" >&2
    echo "  emit somewhere else and merge the two by hand." >&2
    return 2
  fi
  return 0
}

# drill_stamp() lived here (#150): one key off a box's mint stamp, used to read
# back WHICH converger the mint had installed into the guest. #214 removed both
# the installation and the stamp, and it was that function's only caller — a
# reader with nothing to read is not a helper, it is a place for the question
# to come back.

# Fill the REC_* set from the world. Every field is ${...:-} against itself, so
# a caller (the test, or an operator scripting around this) can pin any one of
# them and have the rest collected around it.
record_collect() {   # <box-repo> <box-ref> <keep-boxes:0|1>
  local prefix='' inv
  REC_VERSION="${REC_VERSION:-$(record_version)}"
  REC_DATE="${REC_DATE:-$(date -I 2>/dev/null)}"
  REC_RUN_ID="${REC_RUN_ID:-$(record_run_id "$REC_VERSION" "${REC_DATE//-/}")}"
  REC_HOST="${REC_HOST:-$(record_host)}"
  REC_BOX_REPO="${REC_BOX_REPO:-$1}"
  REC_BOX_REF="${REC_BOX_REF:-$2}"
  REC_BOX_SHA="${REC_BOX_SHA:-$(record_sha "$REC_BOX_REPO" "$REC_BOX_REF")}"
  # ONE candidate ref, box's own (#214). The record used to carry a second —
  # the converger the mint installed into every guest, read off the mint's own
  # stamp — because box pinned it and a drill has to name what it drilled.
  # Box installs nothing into a guest now, so there is no second ref, no stamp
  # to read it off, and nothing here to fall back to. The shared RUN ID stays:
  # it is a cross-repo record convention that lets box's, rig's and cast's
  # records reassemble into one picture, and it never was a dependency.
  REC_ELAPSED="${REC_ELAPSED:-}"
  if [ -z "$REC_ELAPSED" ] && [ -n "${DRILL_T0:-}" ]; then
    REC_ELAPSED="$(( $(date +%s) - DRILL_T0 ))"
  fi
  # The command that reproduces this run, env pins included — the flags alone
  # would name a different drill than the one that ran. The converger pin is
  # gone from this prefix with the thing it pinned (#214): box reads no such
  # variable at mint, so carrying one here would name an environment that
  # changes nothing and read as a dependency box no longer has.
  [ -n "${DRILL_EXPECT:-}" ] && prefix="${prefix}DRILL_EXPECT=$DRILL_EXPECT "
  inv="${prefix}bash drill/drill.sh --repo $1 --ref $2"
  [ "$3" = 1 ] && inv="$inv --keep-boxes"
  REC_INVOCATION="${REC_INVOCATION:-$inv}"
  return 0
}

# The backticks below are MARKDOWN, in single-quoted printf formats whose only
# expansions are %s. SC2016 reads them as command substitutions that will not
# expand, which is exactly right and exactly not the point.
# shellcheck disable=SC2016
record_write() {   # <path> — composes the REC_* set and the ledger into a record
  local path="$1"
  {
    printf '# Release drill — %s\n\n' "$REC_VERSION"
    printf -- '- **Run ID:** `%s`\n' "$REC_RUN_ID"
    printf -- '- **Host:** %s\n' "$REC_HOST"
    printf -- '- **Date:** %s\n' "$REC_DATE"
    printf -- '- **Candidate refs:**\n'
    printf -- '  - box `%s` @ `%s` (%s)\n' "$REC_BOX_REF" "$REC_BOX_SHA" "$REC_BOX_REPO"
    printf '\n## What ran\n\n'
    printf '`%s`\n\n' "$REC_INVOCATION"
    # The denominator is the FLOOR, never pass+fail. #153 is the whole reason:
    # a run that emitted 76 of 85 and failed none is not "76/76 passed", and a
    # record carrying that fraction is the exact artifact that issue exists to
    # stop being written. Declared skips are subtracted and named below.
    # Two facts, not a fraction: DRILL_EXPECT can raise the floor ABOVE the
    # table's own total, and "90 of the 85 declared" reads like an error where
    # it is the operator deliberately demanding more than the table admits.
    printf 'Probe floor: %s expected this run; the table declares %s.\n\n' \
      "$(ledger_expected)" "$(ledger_declared)"
    printf '```\n%s\n```\n' "$(ledger_line)"
    printf '\n## Result\n\n'
    printf '**%s/%s passed, %s failed.** %s.\n\n' \
      "$pass" "$(ledger_expected)" "$fail" "$(record_wallclock "$REC_ELAPSED")"
    # SKIP lines land here beside FAIL and NOTE, each carrying its own prefix,
    # so a phase that did not run is recorded as skipped and is never mistaken
    # for one that passed.
    if [ "${#findings[@]}" -gt 0 ]; then
      printf -- '- %s\n' "${findings[@]}"
    else
      printf -- '- Nothing to report: no FAIL, no NOTE, no declared skip.\n'
    fi
    # The audit answers, in the record rather than only on a terminal. They were
    # printed for a human to paste into an issue that is now closed, in a repo
    # that has been renamed, while the record they belong in was being written
    # forty lines away — the same retyping-from-ANSI defect this emitter exists
    # to close, one field further in (#152, #154).
    #
    # Their own section and NOT more findings, for two reasons. They are
    # measurements, not verdicts: "A4 dns enumeration: LEAKS" is a fact about
    # the host, and whether it is a failure is what the ok/no beside it already
    # decided. And folding them into `findings` would mean the list is never
    # empty on a real run, retiring the "Nothing to report" line that is the
    # only way a record says a clean run was clean.
    if [ "${#audit[@]}" -gt 0 ]; then
      printf '\n## Audit answers\n\n'
      printf 'What the isolation probes measured, uninterpreted.\n\n'
      printf -- '- %s\n' "${audit[@]}"
    fi
    printf '\n> **Draft — a generated skeleton, not yet a record.** Every field\n'
    printf '> above is what the harness observed. What each finding MEANS for\n'
    printf '> the release is a judgement it must not fabricate: write that, then\n'
    printf '> delete this paragraph (#152).\n'
  } > "$path"
}
# <<< drill record

ledger_check_expect || exit 2
record_check_path "$RECORD" || exit 2

wait_box() {   # poll until exec answers (the VM agent can take a while), ~4 min
  # 2 min was too short: run 17's legacy box came up AFTER the window closed —
  # the drill called it dead and then every migration check on it passed.
  local b="$1" _i
  for _i in $(seq 1 120); do
    box exec "$b" -- true >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Read from inside a box WITHOUT ever hanging the drill.
#
# Two traps, both hit for real:
#   · 'box exec' crosses a login-user shell boundary. Fine for a person,
#     needless machinery for a probe.
#   · $( ) waits for stdout to CLOSE, not for the command to exit. A grandchild
#     inheriting the exec session's stdout keeps the substitution open forever,
#     and 'timeout' does not save you: it kills the wrapper, not the holder of
#     the pipe. Run 4 hung 10+ minutes on exactly this.
# So: talk to 'incus exec' directly, pin stdin to /dev/null, land the output in
# a file (never a pipe), and hard-kill on timeout.
in_box() {
  local b="$1"; shift
  local out; out="$(mktemp)"
  timeout -k 5 20 incus exec "$b" -- "$@" >"$out" 2>/dev/null </dev/null
  local rc=$?
  cat "$out"; rm -f "$out"
  return "$rc"
}

# The box's address ON BOXNET. Three ways to get this wrong, all of them hit:
#   · 'incus list' name filters are NOT regexes ("^b$" silently matches nothing)
#   · its CSV quotes a multi-address box across lines
#   · and the interface is NOT called eth0. The PROFILE names the device eth0,
#     but inside a VM guest predictable naming renames it enp5s0. Six runs of
#     A3 "not probed" were this, not the network.
# So: read it from inside the box, and select by SUBNET (what boxnet hands
# out — read off the network, never hardcoded: BOX_SUBNET moves it, #80)
# rather than by interface name — docker0 (172.17.x) is the decoy, and the
# NIC's name is the guest's business, not ours.
boxnet_gw() { incus network get boxnet ipv4.address 2>/dev/null | cut -d/ -f1; }
boxnet_ip() {
  local b="$1" ip _i pfx
  pfx="$(boxnet_gw)"; pfx="${pfx%.*}."
  for _i in $(seq 1 15); do
    ip="$(in_box "$b" ip -4 -o addr show scope global \
          | awk -v p="$pfx" '{ for (i = 1; i < NF; i++) if ($i == "inet" && index($(i+1), p) == 1) { split($(i+1), a, "/"); print a[1]; exit } }')"
    [ -n "$ip" ] && { printf '%s\n' "$ip"; return 0; }
    sleep 2
  done
  return 1
}

# The probe. Its verdict comes from curl's MESSAGE, never from its exit code.
#
# curl exit 7 is "failed to connect" — and it covers BOTH of these:
#   · "Connection refused"  → a RST came back. The packet ARRIVED. Reachable.
#   · "Could not connect to server" / "No route to host" → nothing came back at
#     all. The frame went nowhere. ISOLATED.
# Opposite conclusions, one exit code. The drill mapped 7 → "it arrived" and so
# reported a WORKING boundary as a broken one, run after run, while the kernel
# had 'isolated on' the bridge ports the whole time. A refusal is instant; an
# unreachable host burns the timeout. The words say which; the number cannot.
#
# Never hangs: incus exec directly (no login shell), stdin pinned, output landed
# in a file rather than a pipe, hard kill on timeout.
box_probe() {   # box_probe <box> <url> [timeout] → reachable | refused | dropped
  local b="$1" url="$2" t="${3:-5}" out rc msg
  out="$(mktemp)"
  timeout -k 5 $((t + 15)) incus exec "$b" -- curl -sS -m "$t" -o /dev/null "$url" \
    >/dev/null 2>"$out" </dev/null
  rc=$?
  msg="$(cat "$out")"; rm -f "$out"
  if [ "$rc" -eq 0 ]; then echo reachable; return; fi
  case "$msg" in
    *"Connection refused"*) echo refused ;;   # it ARRIVED, and was rejected
    *)                      echo dropped ;;   # nothing came back
  esac
}

box_pings() {   # box_pings <box> <ip> → 0 if it answers ICMP
  timeout -k 5 20 incus exec "$1" -- ping -c1 -W2 "$2" >/dev/null 2>&1 </dev/null
}

# Mint with a heartbeat. box new's own narration lands in the log; a dot every
# 5s on the drill's terminal proves the run is ALIVE — a silent multi-minute
# mint is indistinguishable from a wedge, and that ambiguity has cost whole
# evenings. The log line says where to watch the real progress.
mint_box() {   # mint_box <log> <box-new args...> → box new's exit code
  local log="$1"; shift
  inf "watch it live in another terminal:  tail -f $log"
  box new "$@" >"$log" 2>&1 </dev/null &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do printf '.'; sleep 5; done
  printf '\n'
  wait "$pid"
}

# --- stage 1: consent, install, then re-enter inside the incus-admin group ---
if [ "${IN_GROUP:-0}" != 1 ]; then
  if [ "$YES" -ne 1 ]; then
    cat <<EOF
This will, ON THIS HOST ($(hostname)):
  · install Incus and a systemd unit
  · create a network (boxnet), an ACL, and a profile
  · rewrite firewall rules (nft or UFW, and Docker's DOCKER-USER chain)
  · create and destroy instances named: drill, clone, archive, peer, payroll, cbprobe, cbcopy, tpl, codex, grok, legacybox
  · build a faithful legacy stack (claudenet/10.87, claude-dev) to drill migration
Only do this on a machine you can format.
EOF
    [ -t 0 ] || { echo "drill: no TTY to confirm on — pass --yes if you mean it." >&2; exit 2; }
    printf 'Continue? [y/N] '
    read -r reply
    case "$reply" in y|Y|yes) ;; *) echo "stopped."; exit 1 ;; esac
  fi

  # The wall clock starts HERE, after the consent prompt, and is an epoch stamp
  # rather than $SECONDS: this shell is about to exec itself into the
  # incus-admin group, and $SECONDS restarts at zero in the shell that actually
  # finishes the run (#152). Operator think-time at the prompt is not the
  # drill's duration, which is why the stamp is taken below it and not above.
  DRILL_T0="$(date +%s)"

  phase - "Installing box ($REPO@$REF)"

  # Sudo, up front and out loud. Later calls run unattended, and a password
  # prompt swallowed by a '-qq' redirect looks exactly like a hang. This now
  # has to precede the install too: install.sh runs the host setup itself, so
  # the first thing needing root is no longer further down — it is inside the
  # very next command.
  sudo -v || { echo "drill: need sudo (the host setup installs packages and firewall rules)"; exit 1; }

  # Pre-setup observations must be READ BEFORE install.sh, because install.sh
  # is now what runs setup-host. Read after it and setup has already had its
  # chance to act, so the observation says nothing.
  # setup-host.sh installs nftables itself when neither nft nor UFW exists
  # (a stock Debian 13 cloud image ships neither). This is a tripwire: if it
  # fires, that fix regressed.
  fw_absent_pre=0
  if ! command -v nft >/dev/null 2>&1 && ! command -v ufw >/dev/null 2>&1; then
    fw_absent_pre=1
  fi

  # DRILL_OWNS_SETUP=1 opts out of the installer's automatic setup and puts the
  # drill back in charge of sequencing it (install, then clean, then converge).
  # The DEFAULT deliberately does not: a drill that runs setup-host itself right
  # after installing cannot tell you whether install.sh did its job, because the
  # drill's own call would build the stack either way. The default path exercises
  # what a user actually runs, and asserts the result in-group below.
  OWNS="${DRILL_OWNS_SETUP:-0}"
  if [ "$OWNS" = 1 ]; then
    export BOX_SKIP_SETUP_HOST=1
  fi

  # The installer converges when a version is already installed (0.7.0's
  # versioned layout: re-running the same version is a no-op, and an upgrade
  # lands side-by-side without flipping under boxes). The drill re-proves a
  # tree from SCRATCH every run — a fresh host, not a converged one — so it
  # removes the whole install root and symlink first.
  rm -rf "$HOME/.local/share/box" "$HOME/.local/bin/box"

  # The installer prompts (install? set up host?) and reads /dev/tty. The drill
  # runs unattended with no tty, so it answers yes to everything via BOX_YES.
  # OWNS still suppresses the setup prompt via BOX_SKIP_SETUP_HOST above.
  export BOX_YES=1

  BOX_REPO="$REPO" BOX_REF="$REF" \
    bash -c "$(curl -fsSL "https://raw.githubusercontent.com/$REPO/$REF/install.sh")" \
    || { echo "install failed"; exit 1; }
  export PATH="$HOME/.local/bin:$PATH"

  # ASSERT WHAT LANDED — never trust that the install obeyed us.
  # This has bitten twice: once on a lagged CDN tarball, once when a STALE local
  # drill.sh passed the retired CLAUDEBOX_* env vars to a 0.5.0 install.sh that
  # reads BOX_* — the vars were ignored, main was installed, and the run drilled
  # the wrong tree while reporting success. A drill that silently drills the
  # wrong code is worse than one that fails.
  got="$(cat "$HOME/.local/share/box/current/INSTALLED_FROM" 2>/dev/null || echo '<unknown>')"
  if [ "$got" != "$REPO@$REF" ]; then
    echo "drill: FATAL — asked to install $REPO@$REF, but the tree says '$got'." >&2
    echo "  Your local drill.sh is probably STALE (pre-0.5.0 it passed CLAUDEBOX_*," >&2
    echo "  which today's install.sh ignores, so it fell back to main). Fix:" >&2
    echo "    git fetch origin && git checkout <the branch you mean> && git pull" >&2
    echo "  then re-run this drill." >&2
    exit 1
  fi
  inf "installed tree confirms: $got"

  # The run ID is resolved HERE and not at the end, because its whole purpose is
  # to be handed to whoever drills rig and cast — and they need it while their
  # runs are still ahead of them, not after this one finishes forty minutes
  # later. It needs the installed VERSION, which is why it cannot be resolved
  # any earlier than this line (#152).
  if [ -z "$RUN_ID" ]; then
    RUN_ID="$(record_run_id "$(record_version)" "$(date +%Y%m%d)")"
  fi
  inf "run ID: $RUN_ID   ← rig's and cast's records for this release use this exact string"
  [ -n "$RECORD" ] && inf "record will be written to: $RECORD"

  phase - "Host setup (Incus, boxnet, ACL, profile, firewall)"
  if [ "$fw_absent_pre" = 1 ]; then
    note "neither nft nor ufw present pre-setup — setup-host.sh must install nftables itself (it fixed this once; watch that it still does)"
  fi

  # apt's lock is held by apt-daily / unattended-upgrades on a fresh cloud
  # image, and 'apt-get -qq >/dev/null' waits for it in COMPLETE SILENCE —
  # which is how run 5 looked stuck for minutes right after this header.
  # Say what we are waiting for, and give up rather than hang forever.
  if ! command -v incus >/dev/null 2>&1; then
    inf "installing incus (waiting for the apt lock if a background upgrade holds it)…"
    if ! sudo DEBIAN_FRONTEND=noninteractive timeout 600 \
           apt-get -o DPkg::Lock::Timeout=300 install -y incus; then
      echo "drill: 'apt-get install incus' failed or timed out." >&2
      echo "  a background apt job usually holds the lock. check with:" >&2
      echo "    sudo fuser -v /var/lib/dpkg/lock-frontend" >&2
      echo "    systemctl status unattended-upgrades apt-daily.service" >&2
      exit 1
    fi
  else
    inf "incus already installed — skipping apt"
  fi

  # No setup-host call here any more. It used to run a full "first pass" that
  # the comment described as "may only add you to incus-admin" — behaviour that
  # no longer exists (setup-host converges in one run now, #63) and that, since
  # install.sh runs setup itself (#64), was simply the stack being built a
  # second time before the drill had asserted the first.
  if [ "$OWNS" = 1 ]; then
    # We opted out of the installer's setup, so nobody has joined us to the
    # group yet. usermod ONLY: the stack build waits until after the clean
    # below, which is the entire reason for owning the sequence.
    inf "DRILL_OWNS_SETUP=1 — the drill owns the host setup"
    id -nG | grep -qw incus-admin || sudo usermod -aG incus-admin "$USER"
  else
    inf "install.sh ran the host setup — asserting what it left, in-group, next"
  fi
  # setup-host's own sg re-exec was a CHILD of install.sh; this shell's
  # credentials are untouched, so we still have to enter the group ourselves —
  # once, for the remainder of the drill.
  inf "re-entering inside the incus-admin group…"
  reexec_in_group
fi

export PATH="$HOME/.local/bin:$PATH"

# PROVE THE INSTALLER'S CONTRACT (#64) — first, before the clean or anything
# else on this host mutates the stack, and before the drill runs setup-host
# itself further down. That ordering is the whole point: the old flow ran
# setup-host immediately after installing, so the stack existed by the drill's
# own hand and the run passed identically whether or not install.sh had done a
# thing. This is read-only, so it is safe with a previous run's boxes still
# attached.
if [ "${DRILL_OWNS_SETUP:-0}" != 1 ]; then
  phase I "Asserting the stack that install.sh built"
  missing=""
  incus network show boxnet        >/dev/null 2>&1 || missing="$missing boxnet"
  incus network acl show box-isolate >/dev/null 2>&1 || missing="$missing box-isolate"
  incus profile show box-net       >/dev/null 2>&1 || missing="$missing box-net"
  # Last thing setup-host does, so it doubles as "it ran to the end".
  sudo nft list table bridge box   >/dev/null 2>&1 || missing="$missing nft-bridge-box"
  if [ -n "$missing" ]; then
    echo "drill: FATAL — install.sh reported success but left an INCOMPLETE stack:$missing" >&2
    echo "  install.sh is supposed to run the host setup itself (#64), and setup-host" >&2
    echo "  is supposed to converge in one run (#63). One of those did not happen." >&2
    echo "  reproduce with the output visible:" >&2
    echo "    ~/.local/share/box/current/host/setup-host.sh" >&2
    echo "  or hand setup back to the drill:  DRILL_OWNS_SETUP=1 $SELF" >&2
    exit 1
  fi
  ok "install.sh left a complete host stack (boxnet, box-isolate, box-net, nft bridge drop) — no second setup needed"
else
  skipped I 1 "DRILL_OWNS_SETUP=1 — the drill built the stack itself, so install.sh's own contract (#64) was NOT asserted this run"
fi

# CLEAN BEFORE SETUP, not after. setup-host.sh reconfigures the network's ACLs,
# and a previous run's boxes are still ATTACHED to that network — 'incus network
# set' then has to push the change onto every live NIC, which is how run 6
# stalled. An aborted run also leaves the D-phase mutations (dns.mode=none, NIC
# filtering) in place, so setup would be converging against a moving target.
# Take the boxes down and revert the mutations FIRST; then the host is a
# clean-ish slate and setup-host is the no-op it should be.
# A host still carrying a previous run's phase-D mutations mints boxes with no
# DNS, and then reports the resulting breakage as a finding. Refuse to run.
# NOTE: dns.mode=none is now part of the SHIPPED stack (it closes the sibling
# DNS-enumeration leak), so it is no longer "dirt" from a rehearsal — do not
# revert it. Only the vetoed NIC filtering counts as leftover.
dirty=""
for p in box-net claude-dev; do
  [ -n "$(incus profile device get "$p" eth0 security.ipv4_filtering 2>/dev/null)" ] && dirty="$dirty $p:ipv4_filtering"
  [ -n "$(incus profile device get "$p" eth0 security.mac_filtering 2>/dev/null)" ] && dirty="$dirty $p:mac_filtering"
done
if [ -n "$dirty" ]; then
  note "this host carries the VETOED NIC filtering from an old rehearsal:$dirty — reverting"
  for p in box-net claude-dev; do
    incus profile device unset "$p" eth0 security.mac_filtering >/dev/null 2>&1
    incus profile device unset "$p" eth0 security.ipv4_filtering >/dev/null 2>&1
  done
fi

inf "clearing anything a previous run left behind…"
# One name at a time — 'incus delete -f a b c' aborts at the first MISSING name,
# which is how run 2 inherited run 1's boxes and cascaded five false FAILs.
for n in drill clone archive peer payroll cbprobe cbcopy cbnotours tpl codex grok legacybox; do
  timeout -k 5 60 incus delete -f "$n" >/dev/null 2>&1
done
if incus network show boxnet >/dev/null 2>&1; then
  timeout -k 5 30 incus network unset boxnet dns.mode >/dev/null 2>&1
fi
for p in box-net claude-dev; do
  if incus profile show "$p" >/dev/null 2>&1; then
    timeout -k 5 30 incus profile device unset "$p" eth0 security.mac_filtering >/dev/null 2>&1
    timeout -k 5 30 incus profile device unset "$p" eth0 security.ipv4_filtering >/dev/null 2>&1
  fi
done
left="$(incus list --format csv --columns n 2>/dev/null | tr '\n' ' ')"
[ -n "$left" ] && inf "instances still on this host (not ours, left alone): $left"

# This call stays, and it is NOT the install's setup repeated for its own sake:
# the clean above deliberately unsets dns.mode, which is part of the SHIPPED
# stack, and drops a previous run's phase-D mutations. Something has to put the
# host back together afterwards, and setup-host is that something — this is the
# "converge against a clean slate" the block above is ordered for. On the
# default path the install's setup has already been asserted, so what this
# proves is idempotency: a second run over a cleaned host is a no-op that
# restores the stack rather than a fresh build.
inf "running setup-host.sh (post-clean convergence: restores dns.mode and any reverted mutations)…"
if ! timeout -k 10 300 ~/.local/share/box/current/host/setup-host.sh; then
  echo "drill: setup-host.sh failed or timed out (>5 min)." >&2
  echo "  it should take seconds on a host that already has incus. usual causes:" >&2
  echo "    · instances still attached to boxnet while its ACLs are reconfigured" >&2
  echo "        incus list" >&2
  echo "    · the firewall unit not completing" >&2
  echo "        systemctl status box-firewall.service --no-pager" >&2
  echo "    · the incus daemon wedged by an earlier aborted run" >&2
  echo "        systemctl status incus --no-pager; journalctl -u incus -n 30 --no-pager" >&2
  exit 1
fi
inf "host setup complete"

# A real server has room for the medium role resources (8GiB/4cpu), and
# drilling the real numbers is worth more than drilling shrunken ones. Only
# shrink if we must. Since 0.4.0 resources are per-box, stamped from the
# seed at mint — a profile edit no longer reaches them; the supported
# override is the BOX_* environment, which every 'box new' below inherits.
ram="$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)"
if [ "$ram" -lt 20 ]; then
  export BOX_MEMORY=3GiB BOX_CPU=2
  note "host has ${ram}GiB RAM — minting at 3GiB/2cpu via BOX_MEMORY/BOX_CPU (the medium role's 8GiB/4cpu is what was NOT drilled)"
else
  inf "host has ${ram}GiB RAM — drilling the medium role resources (8GiB/4cpu) unchanged"
fi

KVM=0; [ -e /dev/kvm ] && KVM=1
[ "$KVM" = 1 ] && inf "/dev/kvm present — boxes will be VMs (the real trust boundary)" \
               || note "NO /dev/kvm on this host — box will fall back to CONTAINER mode, so this run does NOT validate the VM trust boundary"

# ===========================================================================
phase A "A. Incus semantics — the assumptions box is built on"
# ===========================================================================
incus launch images:debian/13 cbprobe --config user.box=1 >/dev/null 2>&1
incus launch images:debian/13 cbnotours >/dev/null 2>&1      # untagged: not ours
sleep 3

# A1 — the tag read. #13 puts this on the path of EVERY box command.
t="$(incus config get cbprobe user.box 2>&1)"
[ "$t" = "1" ] && ok "config get user.box → '1'" \
               || no "config get user.box → '$t' (expected '1'; every box command would fail closed)"

# A2 — the list filter, and that it EXCLUDES an instance we didn't mint
f="$(incus list user.box=1 --format csv --columns nstS 2>&1)"
if echo "$f" | grep -q '^cbprobe,' && ! echo "$f" | grep -q '^cbnotours,'; then
  ok "list filter user.box=1 selects ours, excludes theirs"
else
  no "list filter user.box=1 is wrong — got: $(echo "$f" | tr '\n' ' ')"
fi

# A3 — four fields, no commas/newlines to mangle the awk table
n="$(echo "$f" | grep '^cbprobe,' | awk -F, '{print NF}')"
[ "$n" = 4 ] && ok "--columns nstS → 4 clean CSV fields" || no "--columns nstS → $n fields (the list table would garble)"

# A4 — the state string require_stopped compares against
s="$(incus list cbprobe --format csv --columns s 2>&1 | head -1)"
[ "$s" = RUNNING ] && ok "state column → 'RUNNING'" || no "state column → '$s' (require_stopped compares against RUNNING/STOPPED)"

# A5 — does rename REFUSE a running instance? #13's precondition bets it does.
if r="$(incus rename cbprobe cbprobe2 2>&1)"; then
  no "incus renamed a RUNNING instance — #13's 'stopped' precondition is unnecessary (merely conservative)"
  incus rename cbprobe2 cbprobe >/dev/null 2>&1
else
  ok "incus refuses to rename a running instance → $(echo "$r" | head -1 | cut -c1-60)"
fi

# A6 — snapshot list CSV: 'info' reads field 1 as the label
incus snapshot create cbprobe authed >/dev/null 2>&1
s1="$(incus snapshot list cbprobe --format csv 2>&1 | head -1)"
[ "$(echo "$s1" | cut -d, -f1)" = authed ] && ok "snapshot list csv → field 1 is the label" \
                                           || no "snapshot list csv field 1 ≠ label — got: $s1"

# A7 — the IPv4 column. #9 assumes it can be quoted/multi-line, hence fetching it apart.
inf "ipv4 column raw: $(incus list cbprobe --format csv --columns 4 2>&1 | tr '\n' '|')"

# A8 — unset config keys read as EMPTY with exit 0 (#15 B4). The '|| echo root'
# fallback #12 first proposed could never fire if so; #17's lookup depends on this.
u="$(incus config get cbprobe user.never-set 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$u" ]; then
  ok "config get on an unset key → empty string, exit 0"
  aud "B4 config-get unset key: empty + exit 0 — #17 fallbacks must use \${var:-}, never ||"
else
  note "config get on an unset key → rc=$rc out='$u' (not the documented empty+0 — #17's lookup adapts)"
  aud "B4 config-get unset key: rc=$rc out='$u'"
  skipped A 1 "A8 recorded an observation, not a verdict — incus did not answer the documented empty+0"
fi

# A9 — 'incus copy' preserves user.* keys (#15 B2). #17's whole metadata design:
# a clone must still know what it is without consulting the template.
incus config set cbprobe user.box.user claude 2>/dev/null
incus stop -f cbprobe >/dev/null 2>&1
incus copy cbprobe cbcopy >/dev/null 2>&1
c="$(incus config get cbcopy user.box.user 2>/dev/null)"
if [ "$c" = claude ]; then
  ok "incus copy preserves user.* keys (a clone knows what it is)"
  aud "B2 copy preserves user.*: YES — #17's metadata-stamp design holds"
else
  no "incus copy DROPPED user.* keys (got '$c') — #17's metadata design fails without them"
  aud "B2 copy preserves user.*: NO — #17 blocked as designed"
fi
incus delete -f cbcopy >/dev/null 2>&1

incus delete -f cbprobe cbnotours >/dev/null 2>&1

# ===========================================================================
phase B "B. The box surface"
# ===========================================================================
# Compare against the installed tree's VERSION file, not a hardcoded number —
# a pinned literal here would fail the drill on every release.
expected="$(cat "$HOME/.local/share/box/current/VERSION" 2>/dev/null || echo '?')"
v="$(box --version 2>&1)"
case "$v" in *"$expected"*) ok "box --version → $v" ;; *) no "version mismatch: CLI says '$v', VERSION file says '$expected'" ;; esac

# The drill must not require an empty host: operator boxes tagged
# user.box=1 (or the legacy tag) are legitimate tenants, and the teardown below deliberately
# refuses to touch them. The empty-host message is only TESTABLE when the host
# is actually empty — on a shared host, skip it instead of failing it.
tenants="$({ incus list user.box=1 --format csv --columns n 2>/dev/null
             incus list user.claudebox=1 --format csv --columns n 2>/dev/null; } | sort -u | tr '\n' ' ')"
if [ -n "${tenants% }" ]; then
  skipped B 1 "host already has boxes (${tenants% }) — the empty-host message is not testable on a shared host"
else
  box list >/dev/null 2>&1 && box list 2>&1 | grep -q 'no boxes yet' \
    && ok "empty host: 'no boxes yet', exit 0" || no "empty-host message wrong"
fi

# --- templates: the mint surface is itself a surface to test ----------------
tpl_missing=""
box templates 2>/dev/null | grep -q '^  staging-box' || tpl_missing=" staging-box"
[ -z "$tpl_missing" ] && ok "templates: lists the dedicated staging-box seed" \
                      || no "templates listing is missing:$tpl_missing"
box new --name tpl --template nosuch 2>&1 | grep -q 'no such template' \
  && ok "unknown template refused, points at 'box templates'" || no "an unknown template was not refused"
# The one rule that keeps templates honest: no key can name a network. Plant a
# bad template in the installed tree (the drill owns this host), expect the
# parser to reject it BY NAME, remove it.
badt="$HOME/.local/share/box/current/templates/cbdrill-bad"
mkdir -p "$badt" && printf 'BOX_IMAGE="x"\nBOX_USER="y"\nBOX_NETWORK="lan"\n' >"$badt/box.env" && : >"$badt/user-data.yaml"
box new --name tpl --template cbdrill-bad 2>&1 | grep -q "unknown key 'BOX_NETWORK'" \
  && ok "a template cannot name a network — BOX_NETWORK rejected by name" \
  || no "a box.env key outside the allowlist was ACCEPTED — a template could weaken isolation"
rm -rf "$badt"

# Inline resource flags: honored on a mint, and — since #171 — on a clone too.
# The mint proof rides the blank box below, and because this drill exports
# BOX_CPU/BOX_MEMORY on small hosts, it is also the precedence proof
# (flag > env > size > seed/default). The CLONE proof rides that same box a few
# lines later, once there is a real source to copy: it needs one, which is why
# it is not here.
#
# What used to be here was #57's proof of the opposite — that --from REFUSED
# --cpu, on the premise that a clone carries its source's resources. #171's
# retitle overturned that premise (the override rides 'incus copy', applied
# before the volume is created), so the refusal is gone and the probe went with
# it. It could stand here at all only because the refusal fired before box
# touched incus, which made '--from nowhere' a usable source; nothing about
# that trick survives the ruling, so this is a re-point and not a string swap.

printf '\n  minting a blank box (the generic seed, no role auto-run)…\n'
t0=$SECONDS
if mint_box /tmp/mint-tpl.log --name tpl --cpu 1 --memory 1GiB; then
  ok "box new --name tpl, no --template  ($((SECONDS - t0))s)"
  tt="$(incus config get tpl user.box.template 2>/dev/null)"
  [ "$tt" = tenant ] && ok "the default path uses the generic seed (user.box.template=tenant)" \
                     || no "default seed is '${tt:-<unset>}' — expected tenant"
  rc="$(incus config get tpl limits.cpu 2>/dev/null)/$(incus config get tpl limits.memory 2>/dev/null)"
  [ "$rc" = "1/1GiB" ] && ok "inline --cpu/--memory landed (limits = $rc, beating BOX_* env)" \
                       || no "inline resource flags did not land — limits are $rc, expected 1/1GiB"
  [ "$(incus config get tpl user.box.user 2>/dev/null)" = dev ] \
    && ok "template user stamped on the instance (user.box.user=dev)" || no "user.box.user not stamped"
  incus config show tpl 2>/dev/null | grep -q '^- box-net' \
    && ok "blank box launched with the box-net profile — same placement contract" \
    || no "blank box is NOT on box-net — a template picked its own placement?!"
  u="$(timeout -k 5 30 box exec tpl -- whoami </dev/null 2>/dev/null | tr -d '[:space:]')"
  [ "$u" = dev ] && ok "exec lands in the template's user ($u) — nothing hardcodes claude" \
                 || no "exec landed in '${u:-<nothing>}', expected dev"
  timeout -k 5 30 box exec tpl -- sh -lc 'command -v claude' </dev/null >/dev/null 2>&1 \
    && no "the blank box has claude installed — 'blank' is not blank" \
    || ok "blank box has no claude — nobody home, as designed"
  box_pings tpl 1.1.1.1 && ok "blank box reaches the internet (same egress as any template)" \
                        || no "blank box has NO egress — isolation parity broken"
  in_box tpl getent hosts deb.debian.org >/dev/null 2>&1 \
    && ok "blank box resolves public names (pinned resolver serves every template)" \
    || no "blank box cannot resolve — DNS parity broken"
  # --- the clone half of #171 D1, on a real daemon -------------------------
  # tpl was minted at --cpu 1 --memory 1GiB above, so it is a source whose
  # sizing is KNOWN, and a clone of it with --cpu 2 measures the one thing no
  # shim can: that the override reaches the volume incus actually creates. This
  # is also D6's read-back proved live — every figure below is read off the
  # daemon, not echoed from what box was asked for.
  #
  # Stopped first: box's clone path copies the instance itself (it stops
  # nothing on your behalf), and the drill's other clones dodge this by copying
  # a SNAPSHOT. This one wants the live instance's config, so it stops it.
  # tpl is finished with by here — the removal is the next line but one.
  incus stop -f tpl >/dev/null 2>&1
  # Deliberately NOT wrapped in 'if mint_box; then …probes… else no; fi', which
  # is the shape above: that arm runs a different NUMBER of probes depending on
  # the outcome, and PHASE_EXPECT is a count. Read the config unconditionally
  # instead — a clone that never came up answers '<unset>' and reds both probes
  # for the right reason, and the ledger still balances.
  mint_box /tmp/mint-cbcopy.log --name cbcopy --from tpl --cpu 2 \
    || inf "clone tail: $(tail -3 /tmp/mint-cbcopy.log | tr '\n' ' ')"
  cc="$(incus config get cbcopy limits.cpu 2>/dev/null)"
  [ "$cc" = 2 ] && ok "--cpu rides a CLONE: the copy came up at 2, not the source's 1 (#171 D1)" \
                || no "--cpu did not ride the copy — the clone's limits.cpu is '${cc:-<unset>}', expected 2"
  # The other half of D1, and the state D6 was ruled for: a flag NOT passed
  # contributes no override, so memory is still whatever the source had. A
  # clone that is PARTLY overridden is the case no intent-side value knows and
  # the read-back line exists to say out loud.
  cm="$(incus config get cbcopy limits.memory 2>/dev/null)"
  [ "$cm" = 1GiB ] && ok "...and a flag not passed keeps the source's value (memory = $cm) — a partly overridden clone (#171 D1/D6)" \
                   || no "the clone's memory is '${cm:-<unset>}', expected the source's 1GiB"
  box rm cbcopy --force >/dev/null 2>&1 || incus delete -f cbcopy >/dev/null 2>&1
  # D2/D3 fail-closed, on the arm that needs no VM. box refuses --disk when it
  # cannot read what root device the source has, BEFORE the copy, and creates
  # nothing. The other entrance to D3 — a VM source whose root comes from a
  # profile — cannot be reached from box's own surface at all: every VM mint
  # attaches '--device root,size=' (bin/box), so no box box mints lacks a root
  # device of its own. Making one would mean an 'incus init --empty --vm' on a
  # host this drill does not require to have KVM, so the probe takes the
  # entrance that is always there.
  cbout="$(box new --name cbcopy --from nowhere --disk 20GiB </dev/null 2>&1 || true)"
  if printf '%s\n' "$cbout" | grep -q 'could not be read' && ! incus info cbcopy >/dev/null 2>&1; then
    ok "--disk refuses a source box cannot read, before the copy, creating nothing (#171 D2/D3)"
  else
    no "--disk on an unreadable source did not fail closed (or left an instance behind) — said: $(printf '%s' "$cbout" | head -2 | tr '\n' ' ')"
  fi
  box rm tpl --force >/dev/null 2>&1 && ok "blank box removed" || no "could not remove the blank box"
else
  no "blank mint FAILED — tail: $(tail -3 /tmp/mint-tpl.log | tr '\n' ' ')"
  # Tear the stuck box down — a failed mint that lingers starves the next one.
  timeout -k 5 60 incus delete -f tpl >/dev/null 2>&1
fi

# The per-role mints lived here (#159): one cold mint each for codex and grok,
# proving that role's own payload — the CLI installs, lands on the
# non-interactive exec PATH, and answers --version. #214 removed the role axis
# and with it box's claim to install anything, so there is no payload of box's
# left to prove and no --role to pass. The generic mechanic those mints rode
# on (metadata, placement, user, isolation parity) is proven by the blank mint
# above and by the drill box below, which is now the same blank shape.

printf '\n  minting the drill box (cold)…\n'
t0=$SECONDS
if mint_box /tmp/mint-drill.log --name drill --size medium; then
  ok "box new --name drill --size medium  ($((SECONDS - t0))s)"
else
  no "box new FAILED — tail: $(tail -3 /tmp/mint-drill.log | tr '\n' ' ')"
  timeout -k 5 60 incus delete -f drill >/dev/null 2>&1
  echo; echo "── cannot continue without a box"; printf '  %s\n' "${findings[@]}"; exit 1
fi

typ="$(box list | awk '$1 == "drill" { print $3 }')"
if [ "$KVM" = 1 ]; then
  [ "$typ" = VM ] && ok "the box is a VM — the trust boundary is real" \
                  || no "the box is '$typ' but /dev/kvm exists — it should have been a VM"
else
  note "the box is '$typ' (no /dev/kvm on this host)"
  skipped B 1 "no /dev/kvm — the box is a container, so 'is it a VM?' has no verdict and the VM trust boundary was NOT validated"
fi

box info drill | grep -q '^IPV4' && ok "info shows an IPv4" || no "info has no IPV4 row"
box info drill | grep -q 'SNAPSHOTS  (none)' && ok "info: no snapshots yet, offers to take one" || no "info snapshot-empty state wrong"

# The agent-payload probes lived here: 'claude --version' and 'gh --version'
# inside the drill box, with a PATH diagnosis behind them. Both asked whether
# what box installed had landed, and box installs neither any more (#214) — a
# blank box is SUPPOSED to answer no, and the blank mint above already probes
# that directly ("blank box has no claude — nobody home, as designed"). What
# the tenant seed itself ships is the thin floor, so probe THAT instead: it is
# box's own payload, and the one the seed can still be held to.
box exec drill -- tmux -V >/dev/null 2>&1 \
  && ok "tmux is installed in the box — 'box tmux' has something to run (#65)" \
  || no "'tmux -V' failed inside the box — the seed's own payload did not land"
box exec drill -- shellcheck --version >/dev/null 2>&1 \
  && ok "the seed's unprivileged toolchain landed (shellcheck, #177 decision 3)" \
  || no "'shellcheck --version' failed inside the box — the seed's toolchain did not land"

# --- the snapshot → clone workflow, which is the whole point of the tool ---
box snapshot drill authed 2>&1 | grep -q authed && ok "snapshot drill authed" || no "snapshot failed"
box info drill | grep -q 'authed' && ok "info lists the snapshot label" || no "info does not show the label"
box info drill | grep -q -- '--from drill/authed' && ok "info prints the --from line to clone it" || no "info lacks the --from hint"

# --- the boundary: an instance box did NOT mint ----------------------
incus launch images:debian/13 payroll >/dev/null 2>&1   # somebody else's instance
sleep 2
box down payroll 2>&1 | grep -q 'no such box' && ok "boundary: 'down' refuses an untagged instance" || no "boundary: 'down' touched an instance box didn't mint!"
box rm payroll --force 2>&1 | grep -q 'no such box' && ok "boundary: 'rm' refuses an untagged instance" || no "boundary: 'rm' would DELETE a foreign instance!"
box incus payroll -- config show 2>&1 | grep -q 'no such box' && ok "boundary: the escape hatch refuses it too" || no "boundary: the hatch reached a foreign instance!"
incus list payroll --format csv --columns ns | grep -q '^payroll,RUNNING' && ok "…and payroll is still running, untouched" || no "payroll was harmed — the boundary leaked"
incus delete -f payroll >/dev/null 2>&1

# --- rename, and its precondition -----------------------------------------
box rename drill archive 2>&1 | grep -qi 'RUNNING' && ok "rename refuses a running box, and says how to fix it" || no "rename did not refuse a running box"
box down drill >/dev/null 2>&1 && ok "down drill" || no "down failed"
box rename drill archive 2>&1 | grep -q 'renamed drill to archive' && ok "rename drill → archive (stopped)" || no "rename failed on a stopped box"
box list | grep -q '^archive' && ok "list shows the new name" || no "list still shows the old name"
box info archive | grep -q authed && ok "the snapshot followed the rename" || no "snapshot lost across the rename"

# --- clone from a snapshot of a renamed box --------------------------------
printf '\n  cloning from the snapshot…\n'
if mint_box /tmp/mint-clone.log --name clone --from archive/authed; then
  ok "new --from archive/authed (clone of a snapshot of a renamed box)"
  box exec clone -- true >/dev/null 2>&1 && ok "the clone is alive and enterable" || no "the clone is not enterable"
else
  no "clone FAILED — tail: $(tail -3 /tmp/mint-clone.log | tr '\n' ' ')"
fi

# --- the escape hatch ------------------------------------------------------
box incus archive -- config show 2>/dev/null | grep -q 'user.box' && ok "hatch: 'incus archive -- config show', instance appended" || no "hatch passthrough failed"
h="$(box incus archive -- config device add {} scratch disk source=/tmp path=/mnt/scratch 2>&1)"
echo "$h" | grep -q 'isolation stack' && ok "hatch warns when a command can break isolation" || no "hatch did not warn on a device add"
box incus archive -- config device remove {} scratch >/dev/null 2>&1

# --- rm, and the guard that did not used to exist --------------------------
box rm clone </dev/null 2>&1 | grep -q 'refusing' && ok "rm with no TTY and no --force refuses (exit 2)" || no "rm destroyed a box with no confirmation!"
box rm clone --force 2>&1 | grep -q 'removed' && ok "rm --force removes the clone" || no "rm --force failed"

# --- the CLI contract ------------------------------------------------------
box lst 2>&1 | grep -q "did you mean 'list'" && ok "typo → did-you-mean, exit 2" || no "unknown command not suggested"
box list archive 2>&1 | grep -q 'box info archive' && ok "'list <box>' points at info" || no "'list <box>' does not point at info"
box snapshot archive --labl x 2>&1 | grep -q 'unknown option' && ok "typo'd flag rejected (not swallowed as a label)" || no "unknown flag was swallowed"

# ===========================================================================
phase C "C. Isolation baseline — does the boundary actually hold? (#15 section A)"
# ===========================================================================
box start archive >/dev/null 2>&1
wait_box archive && ok "archive is back up (agent answering)" \
                 || no "archive did not come back within 2 min of start"

# Sibling isolation needs a sibling. Clone from the snapshot — fast, no cold mint.
printf '\n  cloning a peer for the sibling probes…\n'
if mint_box /tmp/mint-peer.log --name peer --from archive/authed && wait_box peer; then
  ok "peer minted from archive/authed and answering"
else
  no "peer clone failed or never answered — tail: $(tail -3 /tmp/mint-peer.log | tr '\n' ' ')"
fi

# C1 — public egress (#15 A1; resolving the hostname also proves A5, gateway DNS)
BASELINE_OK=1
if [ "$(box_probe archive https://api.github.com 20)" = reachable ]; then
  ok "box reaches the public internet (and gateway DNS resolves public names)"
  aud "A1/A5 egress + public DNS: PASS"
else
  BASELINE_OK=0
  no "box cannot reach the internet (a box that can't is useless)"
  aud "A1/A5 egress: FAIL"
fi

# C2 — box → host (#15 A2). The host DOES listen on the gateway: dnsmasq is on
# :53 by design (that carve-out is what makes egress DNS work). So probe a port
# nothing serves and read refused-vs-dropped — refused would mean the box's
# packet reached the host's stack, which is the thing the firewall must prevent.
# (No background listener: one less process to leak, one less way to wedge.)
gw="$(boxnet_gw)"
hv="$(box_probe archive "http://$gw:8099")"
case "$hv" in
  reachable|refused)
    no "THE BOX'S PACKETS REACH THE HOST on $gw:8099 [$hv] — the firewall rules are not holding"
    aud "A2 box→host: FAIL — $hv (the packet reached the host's stack)" ;;
  dropped)
    ok "box → host is blocked (no path to the machine's sockets)"
    aud "A2 box→host: dropped" ;;
  # Unreachable today: box_probe answers reachable|refused|dropped and nothing
  # else. The arm is pre-existing insurance for the day it grows a fourth
  # outcome; the `skipped` is here so that day costs the ledger nothing rather
  # than silently shortening C by one. Not live wiring — read it as a seatbelt.
  *)
    note "box→host probe inconclusive ($hv)"
    aud "A2 box→host: INCONCLUSIVE ($hv)"
    skipped C 1 "C2 box→host was inconclusive ($hv) — no verdict on the firewall" ;;
esac

# C3 — RFC1918 (#15 A2)
case "$(box_probe archive http://192.168.1.1)" in
  reachable|refused)
    no "box REACHED a private-range address — the ACL is not dropping RFC1918"
    aud "A2 RFC1918: FAIL" ;;
  *)
    ok "box → RFC1918 is dropped by the ACL"
    aud "A2 RFC1918: dropped" ;;
esac

# C4 — SIBLING isolation (#15 A3): the central claim of #12, and the one probe
# three runs failed to fire. NO listener on the peer, deliberately — a closed
# port answers the question just as well (refused = the packet arrived), and
# the listener was what kept wedging the run. Ping corroborates: if the two
# disagree, say so rather than pick one.
PEER_IP="$(boxnet_ip peer)"
ARCH_IP_PRE="$(boxnet_ip archive)"
if [ -n "$PEER_IP" ] && [ "$PEER_IP" = "$ARCH_IP_PRE" ]; then
  # Guard, because this actually happened: a clone inherited its source's
  # machine-id, hence its DHCP lease, hence its ADDRESS. Probing "archive →
  # peer" was archive probing itself, and would have reported a cheerful
  # "reachable" as a sibling-isolation failure. Never let A3 answer this.
  no "archive and peer hold the SAME address ($PEER_IP) — the clone did not get its own identity; A3 cannot be probed"
  aud "A3 sibling: NOT PROBED — clone/source IP collision (see the clone-identity fix)"
elif [ -n "$PEER_IP" ]; then
  inf "probing archive ($ARCH_IP_PRE) → peer ($PEER_IP): a REFUSAL means it arrived; silence means it was dropped"
  v="$(box_probe archive "http://$PEER_IP:8088")"
  box_pings archive "$PEER_IP"; png=$?

  if [ "$v" = reachable ] || [ "$v" = refused ]; then
    no "BOX A REACHES BOX B ($PEER_IP) — sibling isolation does NOT hold [tcp: $v]"
    aud "A3 sibling: FAIL — tcp $v (the packet arrived)"
  elif [ "$png" -eq 0 ]; then
    no "TCP to box B goes nowhere, but it ANSWERS ICMP — sibling isolation is only partial"
    aud "A3 sibling: PARTIAL — tcp dropped, ping replies"
  else
    ok "box A cannot reach box B: TCP goes nowhere, ICMP unanswered"
    aud "A3 sibling: BLOCKED — tcp dropped + no icmp reply (security.port_isolation)"
  fi
else
  no "could not read peer's boxnet address — the sibling probe never ran"
  aud "A3 sibling: NOT PROBED (no boxnet address on peer)"
fi

# C5 — DNS enumeration (#15 A4). Now a CONTRACT, not an observation: setup-host
# sets dns.mode=none precisely so a box cannot enumerate its siblings.
e1="$(in_box archive getent hosts peer)"
e2="$(in_box archive getent hosts peer.incus)"
if [ -n "$e1$e2" ]; then
  no "a box can still RESOLVE its sibling ($(printf '%s' "$e1$e2" | head -1 | cut -c1-40)) — dns.mode=none is not holding"
  aud "A4 dns enumeration: LEAKS — the fix is not in effect"
else
  ok "a box cannot resolve its sibling's name (no DNS enumeration)"
  aud "A4 dns enumeration: blocked (dns.mode=none)"
fi

# C6 — IPv6 off (#15 A6): every ACL rule is IPv4-only; off is the only cover.
[ "$(incus network get boxnet ipv6.address 2>/dev/null)" = none ] \
  && { ok "boxnet ipv6.address = none (the IPv4-only ACLs have no uncovered path)"; aud "A6 ipv6: none, as contract requires"; } \
  || { no "boxnet has IPv6 enabled — and not one ACL rule covers IPv6"; aud "A6 ipv6: ENABLED and uncovered"; }

# C7 — inbound, host → box (#15 A7): the ACL's default ingress drop. Same
# listener-free logic, run from the host this time.
ARCH_IP="$(boxnet_ip archive)"
if [ -n "$ARCH_IP" ]; then
  hmsg="$(curl -sS -m 5 -o /dev/null "http://$ARCH_IP:8087" 2>&1)"; hrc=$?
  if [ "$hrc" -eq 0 ]; then hv=reachable
  elif printf '%s' "$hmsg" | grep -q 'Connection refused'; then hv=refused
  else hv=dropped
  fi
  case "$hv" in
    reachable|refused)
      no "the HOST's packets REACH the box ($ARCH_IP) — the default ingress drop is not holding [$hv]"
      aud "A7 inbound host→box: FAIL — $hv (the packet arrived)" ;;
    dropped)
      ok "host → box is dropped (entry is 'incus exec' only, as designed)"
      aud "A7 inbound host→box: dropped" ;;
    # Unreachable today, same as C2's: the if/elif/else above covers exactly the
    # three values box_probe returns. Seatbelt, not live wiring — the `skipped`
    # keeps the ledger honest if that ever stops being true.
    *)
      note "inbound probe inconclusive ($hv)"
      aud "A7 inbound host→box: INCONCLUSIVE ($hv)"
      skipped C 1 "C7 host→box was inconclusive ($hv) — no verdict on the ingress drop" ;;
  esac
else
  no "could not read archive's boxnet address — the inbound probe never ran"
  aud "A7 inbound host→box: NOT PROBED"
fi

# ===========================================================================
phase E "E. box expose — a deliberate loopback door (#55)"
# ===========================================================================
# archive is a running box. Start a DETACHED listener on 0.0.0.0 inside it,
# expose the port, and prove the door works from the HOST's loopback. Then
# prove removing it closes the door, and that a NON-exposed port still obeys
# the ingress drop — the feature must not globally weaken A7.
#
# python3, not node (#214). The listener used to be four lines of node,
# available because the box had been converged into an agent box; box converges
# nothing now, so this phase would have died on a missing interpreter. python3
# is on the guest unconditionally — cloud-init is written in it, so a cloud
# image that boots has it — and 'http.server' serves the response body out of
# a file, which is what the probe below greps for.
EP=8091; EHP=18091
srv="$(mktemp)"
printf 'box-expose-ok\n' >"$srv"
if incus file push "$srv" archive/tmp/expose-www/index.html --create-dirs >/dev/null 2>&1; then
  rm -f "$srv"
  # Detached: setsid + all fds redirected so 'incus exec' returns at once and
  # nothing holds its stdout (trap 2/3). The listener outlives the exec.
  timeout -k 5 20 incus exec archive -- sh -c "setsid python3 -m http.server $EP --bind 0.0.0.0 --directory /tmp/expose-www >/tmp/srv.log 2>&1 </dev/null &" </dev/null
  sleep 3
  xlog="$(mktemp)"
  if box expose archive "$EP" "$EHP" >"$xlog" 2>&1; then
    ok "box expose archive $EP $EHP — the device was added"
    box expose archive --list 2>/dev/null | grep -q "$EP" \
      && ok "expose --list shows the open door" || no "expose --list does not show the exposure"
    box info archive 2>/dev/null | grep -qi "$EP" \
      && ok "box info surfaces the exposure (a box with a hole says so)" \
      || { note "box info does not mention the exposure (nice-to-have)"
           skipped E 1 "box info does not surface the exposure — recorded as a NOTE, so E owes one verdict less"; }
    # THE test: does the host's loopback reach the box's server?
    sleep 2
    if curl -sS -m 6 "http://127.0.0.1:$EHP" 2>/dev/null | grep -q box-expose-ok; then
      ok "127.0.0.1:$EHP reaches the box's server — the door WORKS"
    else
      no "127.0.0.1:$EHP does NOT reach the box — the proxy/ACL mechanism needs work (#55)"
      inf "srv.log inside the box: $(in_box archive cat /tmp/srv.log 2>/dev/null | tail -2 | tr '\n' ' ')"
    fi
    # A NON-exposed port must still be dropped — the feature is per-port, not a
    # global ingress opening.
    nemsg="$(curl -sS -m 5 -o /dev/null "http://$ARCH_IP:9099" 2>&1)"
    printf '%s' "$nemsg" | grep -q 'Connection refused' \
      && no "a non-exposed port answered on the box — expose opened ingress too wide" \
      || ok "a non-exposed port is still dropped — expose is per-port, A7 survives"
    # Close it, and confirm the door shuts.
    box expose archive --remove "$EP" >/dev/null 2>&1 && ok "box expose --remove closed the device" || no "expose --remove failed"
    sleep 2
    curl -sS -m 5 -o /dev/null "http://127.0.0.1:$EHP" 2>/dev/null \
      && no "the host still reaches the box after --remove — the door did not shut" \
      || ok "after --remove, 127.0.0.1:$EHP is dead — the door shut"
  else
    no "box expose failed to add the device"
    inf "what box and incus actually said:"
    sed 's/^/          /' "$xlog" 2>/dev/null
    rm -f "$srv" 2>/dev/null
  fi
  rm -f "$xlog" 2>/dev/null
  timeout -k 5 15 incus exec archive -- pkill -f 'http.server' </dev/null >/dev/null 2>&1
else
  rm -f "$srv"
  no "could not push the test server into archive — expose phase did not run"
fi

# ===========================================================================
phase D "D. The isolation contract, stated"
# ===========================================================================
# Phase D used to REHEARSE the hardening on a throwaway host, because nobody
# knew whether it would work. That question is settled: the hardening now ships
# in setup-host.sh and box-firewall.sh, so phase C tests the real thing
# and there is nothing left to rehearse. What the rehearsal established, kept
# here so it is not re-litigated:
#
#   · @internal is REJECTED as an ACL destination on a bridge network
#     ("Unsupported nftables subject") — so the sibling drop is an nftables
#     bridge-family rule, not an ACL rule. It has to be: an L3 ACL never sees
#     frames switched between two ports of one bridge, which is why box→box was
#     wide open while the ACL looked airtight.
#   · dns.mode=none closes the enumeration leak and public egress survives it.
#   · security.ipv4_filtering BREAKS the box's networking (dockerd comes up but
#     cannot pull or run a container). VETOED — it is not in the shipped stack.
#
inf "@internal: unsupported on bridge ACLs ⇒ the sibling drop is an nft bridge rule"
inf "dns.mode=none: shipped (closes DNS enumeration, egress unaffected)"
inf "security.ipv4_filtering: VETOED — it breaks the box. Not shipped."
inf "the contract is now tested in phase C against the real stack, not rehearsed"

# The lesson that cost the most: a verdict measured on a broken box is not a
# verdict. Run 7 reported "L2 filtering BREAKS the box" from a box whose network
# was already dead, and #16 was nearly redesigned around it. If the baseline
# failed, say plainly that phase C's isolation results cannot be trusted.
if [ "$BASELINE_OK" -ne 1 ]; then
  no "the box could not reach the internet AT ALL — every isolation result above is suspect, not a pass"
  inf "a boundary that 'holds' on a box with no network holds nothing. fix the baseline, re-run."
  inf "start with:  bash drill/doctor.sh"
fi

# ===========================================================================
phase M "M. Migration — the pre-0.4.0 → box transition (host/migrate-host.sh)"
# ===========================================================================
# A fresh host has no legacy stack, so build a faithful one: claudenet on the
# OLD subnet, a claude-dev profile pinned to it, and a box tagged with the OLD
# tag on the OLD network — exactly what a pre-0.4.0 host carries. Then prove
# migrate-host.sh moves it onto the new stack with its identity intact, and
# retires the legacy stack only once it is empty.
MIG="$HOME/.local/share/box/current/host/migrate-host.sh"
if [ ! -f "$MIG" ]; then
  no "migrate-host.sh not installed — cannot drill the transition"
else
  inf "building a faithful legacy stack (claudenet/10.87 + claude-dev)…"
  incus network show claudenet >/dev/null 2>&1 || incus network create claudenet \
    ipv4.address=10.87.0.1/24 ipv4.nat=true ipv6.address=none >/dev/null 2>&1
  if ! incus profile show claude-dev >/dev/null 2>&1; then
    incus profile create claude-dev >/dev/null 2>&1
    incus profile device add claude-dev root disk pool=default path=/ >/dev/null 2>&1
    incus profile device add claude-dev eth0 nic network=claudenet name=eth0 \
      security.port_isolation=true >/dev/null 2>&1
  fi
  # A minimal legacy box: no template payload, just boots and networks on the
  # old stack, wearing the old tag. This is what migrate has to move.
  printf '\n  minting a faithful legacy box on the old stack…\n'
  # The legacy box must carry a 'claude' user, because that is what a real
  # pre-0.4.0 box had — and box_user() maps the legacy tag to it. Without the
  # user, 'box exec' (sudo -u claude) can never answer and wait_box fails
  # forever on a box that is perfectly healthy. Run 17/18 lost a FAIL to this.
  if mint_legacy=$(incus launch images:debian/13/cloud legacybox --profile claude-dev \
       --config user.claudebox=1 --vm --device root,size=20GiB \
       --config security.secureboot=false \
       --config cloud-init.user-data="$(printf '#cloud-config\nusers:\n  - name: claude\n    shell: /bin/bash\n    sudo: "ALL=(ALL) NOPASSWD:ALL"\n    lock_passwd: true\n')" 2>&1); then
    wait_box legacybox && ok "legacy box up on the old stack (claudenet, user.claudebox=1)" \
                       || no "legacy box never came up — cannot drill migration"
    box list 2>/dev/null | grep -q '^legacybox' \
      && ok "box list shows the legacy box (dual-tag matching)" || no "legacy box invisible to 'box list'"

    # Retire must REFUSE while a legacy box exists.
    bash "$MIG" --retire-legacy 2>&1 | grep -qi 'legacy boxes still exist' \
      && ok "retire-legacy refuses while a legacy box remains" \
      || no "retire-legacy did NOT refuse with a legacy box present — it would strip an in-use stack"

    # Re-home it.
    printf '  re-homing the legacy box…\n'
    bash "$MIG" --box legacybox 2>&1 | sed 's/^/        /'
    [ "$(incus config get legacybox user.box 2>/dev/null)" = 1 ] \
      && ok "migrate: legacy box now tagged user.box=1" || no "migrate: user.box tag not set"
    [ "$(incus config get legacybox user.box.user 2>/dev/null)" = claude ] \
      && ok "migrate: legacy box mapped to the claude user" || no "migrate: user.box.user not claude"
    incus config show legacybox 2>/dev/null | grep -q '^- box-net' \
      && ok "migrate: legacy box reassigned to box-net (the new placement contract)" \
      || no "migrate: legacy box is NOT on box-net"
    lip="$(boxnet_ip legacybox)"
    [ -n "$lip" ] && ok "migrate: legacy box got a boxnet address ($lip) — network move landed" \
                  || no "migrate: legacy box has no boxnet address — the move did not take"
    in_box legacybox getent hosts deb.debian.org >/dev/null 2>&1 \
      && ok "migrate: re-homed box resolves + reaches the internet on its new leg" \
      || no "migrate: re-homed box cannot resolve on boxnet"

    # No legacy boxes remain → retire must now SUCCEED and leave nothing.
    printf '  retiring the (now empty) legacy stack…\n'
    bash "$MIG" --retire-legacy 2>&1 | sed 's/^/        /'
    incus network show claudenet >/dev/null 2>&1 \
      && no "retire-legacy left claudenet behind" || ok "retire-legacy removed claudenet"
    incus profile show claude-dev >/dev/null 2>&1 \
      && no "retire-legacy left claude-dev behind" || ok "retire-legacy removed claude-dev"

    box rm legacybox --force >/dev/null 2>&1
  else
    no "could not launch the legacy box: $(printf '%s' "$mint_legacy" | tail -1)"
  fi
fi

# ===========================================================================
if [ "$KEEP" = 1 ]; then
  phase - "Boxes left up (--keep-boxes)"
  box list
  # This line used to warn that "the D-phase mutations (dns.mode=none, NIC
  # filtering) are still applied". D stopped mutating anything when the
  # hardening shipped — dns.mode=none is part of the stack setup-host builds,
  # and the NIC filtering was vetoed and never shipped — so the warning was
  # spending an operator's caution on a phantom, on a script whose header says
  # run it on a machine you can format (#154).
  inf "note: they ride the ordinary shipped stack — the drill leaves no mutations of its own"
  skipped T 1 "--keep-boxes — the boxes stay up on purpose, so teardown is not asserted this run"
else
  phase T "T. Teardown — every box the drill minted is gone"
  # every name the drill can have left, whatever branch a partial run took
  for n in drill clone archive peer tpl codex grok legacybox; do box rm "$n" --force >/dev/null 2>&1; done
  # Assert OUR boxes are gone — not that the host is empty. The rm loop above
  # already embodies the discipline (only names the drill minted); demanding
  # 'no boxes yet' here would flag any pre-existing operator box as a failure.
  leftover="$(box list 2>/dev/null | grep -E '^(drill|clone|archive|peer|tpl|codex|grok)([[:space:]]|$)' || true)"
  [ -z "$leftover" ] && ok "teardown: every box the drill minted is gone" \
                     || no "a drill box survived teardown: $(printf '%s' "$leftover" | awk '{print $1}' | tr '\n' ' ')"
fi

# >>> ledger summary (#153) — test/cli.sh extracts this block verbatim, down to
# and INCLUDING the exit gate at the end of the file, and executes it. Grepping
# for the shortfall verdict proves only that the line is written; #153's whole
# criterion is an EXIT STATUS, so the exit status is what has to be driven. Keep
# the block self-contained: it may assume the verdict helpers, the ledger and
# the record block above it — all three are extracted alongside it — plus the
# four settings the record needs from the command line: RECORD, REPO, REF, KEEP.
phase - "Summary"
# Everything the floor grades on is read BEFORE the floor's own verdict, which
# would otherwise count itself: the shortfall FAIL lands under phase '-' and so
# in the '?' bucket, deliberately, and the per-phase line is already printed by
# the time it fires. What it does move is `fail`, which is the point — a short
# run leaves here non-zero.
expected="$(ledger_expected)"
ran=$(( pass + fail ))
short="$(ledger_short)"
ledger_line
if [ "$ran" -lt "$expected" ] || [ -n "$short" ]; then
  # "never ran" is the common road here, not the only one: a block that failed
  # early emits its one `no` and leaves the rest of its phase unasserted, which
  # is short too. The verdict names both rather than diagnosing the wrong one.
  no "the drill ran SHORT: $ran of $expected expected probes${short:+ — short in:$short} — a phase, or a block that depends on one, never ran, or failed before emitting the rest. This is not a clean sweep, whatever the pass count says (#153)."
fi
printf '  %s/%s passed, %s failed\n' "$pass" "$expected" "$fail"
if [ "${#findings[@]}" -gt 0 ]; then
  echo
  printf '  %s\n' "${findings[@]}"
fi

# This block was headed "paste this block into heavy-duty/claudebox#15" — an
# issue that is complete, in a repo that has been renamed. The mechanism outlived
# its addressee, and it is worth keeping: these are the closest thing the harness
# has to structured output. So it is retargeted rather than deleted, at the one
# reader it has left — the record, which --emit-record now carries them into, two
# lines below (#154).
if [ "${#audit[@]}" -gt 0 ]; then
  phase - "Isolation audit answers — the measurements, as the record carries them"
  printf '  %s\n' "${audit[@]}"
fi

# The record, last, so it carries the shortfall verdict above it — a record
# emitted before that `no` fires would report a clean sweep on a short run,
# which is the defect #153 closed and this must not reopen (#152).
#
# It cannot move the exit status, and that is deliberate rather than incidental:
# the status is the floor's verdict on the DRILL, and a full disk has no opinion
# about whether the trust boundary held. The path was already checked writable
# before the run started, so reaching the failure branch here means something
# changed underfoot — loud on stderr, in the findings, and never silent.
if [ -n "${RECORD:-}" ]; then
  REC_RUN_ID="${REC_RUN_ID:-${RUN_ID:-}}"
  record_collect "$REPO" "$REF" "$KEEP"
  if record_write "$RECORD"; then
    echo
    inf "record written: $RECORD"
    inf "it is a SKELETON — write what the findings mean for the release, then delete its draft line."
    inf "run ID $REC_RUN_ID goes in rig's and cast's records for this release too."
  else
    echo "drill: FAILED to write the record to $RECORD" >&2
    note "the record could not be written to $RECORD — the numbers above are the only copy"
  fi
fi

echo
inf "this host still has Incus, boxnet, the ACL, the profile and the firewall rules"
# It used to add "(plus, unless re-run: dns.mode=none and NIC filtering from the
# D phase)" — residue from a rehearsal that no longer runs. dns.mode=none is the
# shipped stack's, not the drill's, and the NIC filtering was vetoed (#154).
inf "— the shipped stack, as setup-host.sh leaves it; the drill adds nothing of its own."
inf "to undo:  box uninstall --purge-host   (or ~/.local/share/box/current/host/teardown-host.sh)"
[ "$fail" -eq 0 ]
# <<< ledger summary
