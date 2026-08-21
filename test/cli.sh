#!/usr/bin/env bash
# Dependency-free CLI assertions for box. Run: bash test/cli.sh
#
# Runnable by a NON-root user with NO Incus installed — that is the whole point.
# Anything that needs a real incus daemon (every lifecycle command) is proven the
# way rig proves its root-only paths: source the pure function and drive it against
# a fixture, or grep the load-bearing line so a deleted guard cannot ship green.
# Deliberately no `set -e` — the harness asserts on failing commands.
set -u
# BOX_YES is this family's documented automation switch, so an operator's CI
# wrapper may well export it. Checks that drive a destructive script for real
# would then take the CONSENT arm instead of the refusal they are asserting —
# turning this suite into `box uninstall --purge-host` on the host it runs on.
# Individual call sites use `env -u BOX_YES`; this is the belt to that braces,
# so the header's "runnable anywhere" promise cannot be broken by one export.
unset BOX_YES
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0

# check <desc> <want_exit> <want_substr> <cmd...>
# Runs cmd, asserts exit code and (if non-empty) that combined output
# contains want_substr.
check() {
  local desc="$1" want="$2" substr="$3"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $desc — exit $rc, wanted $want"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  if [ -n "$substr" ] && ! printf '%s' "$out" | grep -qF -e "$substr"; then
    echo "FAIL: $desc — output missing '$substr'"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  echo "ok: $desc"; PASS=$((PASS + 1))
}

BOX="$ROOT/bin/box"

# ---------------------------------------------------------------------------
# The CLI contract: dispatch, help, usage errors. No incus needed — these all
# resolve before any daemon call. Exit codes are box's own (0 ok / 1 wrong /
# 2 you-asked-wrong), read straight from bin/box and confirmed by running it.
# ---------------------------------------------------------------------------
# box with no args is 'help' (cmd="${1:-help}"), which prints the general usage
# and exits 0 — NOT rig's exit-2 bare-usage. Assert box's actual contract.
check "no args → general help, exit 0"        0 "USAGE"            "$BOX"
check "no args help names the command form"   0 "box <command>"   "$BOX"
check "--help exits 0"                         0 "USAGE"            "$BOX" --help
check "-h exits 0"                             0 "USAGE"            "$BOX" -h
check "help exits 0"                           0 "USAGE"            "$BOX" help
check "help <command> → that command's usage"  0 "usage: box new"  "$BOX" help new
check "--version exits 0"                       0 "box"             "$BOX" --version
# Unknown command is a usage error (2), and it says so — the suggester may add a
# 'did you mean', but the stem is stable.
check "unknown command exits 2"                2 "unknown command" "$BOX" frobnicate
check "unknown command points at help"         2 "box help"        "$BOX" zzzzzz
# Options before the command are the classic mistake; box names the fix.
check "option before command exits 2"          2 "options come after the command" "$BOX" --json list
# A missing required positional is a usage error carrying that command's synopsis.
check "new without --name exits 2"             2 "usage: box new"    "$BOX" new
check "shell without a box exits 2"            2 "usage: box shell"  "$BOX" shell
check "root without a box exits 2"             2 "usage: box root"   "$BOX" root
check "restore without arg2 needs a box first" 2 "usage: box restore" "$BOX" restore
# An unknown flag is refused, not swallowed as a positional (the --labl bug).
check "unknown flag on list exits 2"           2 "unknown option"   "$BOX" list --nope
# A flag that needs a value and gets none.
check "--name with no value exits 2"           2 "--name needs a value" "$BOX" new --name
# #159's hard cut is resolved before the Incus preflight, so every retired
# spelling teaches the runtime-role form even on a machine with no daemon.
check "new: --template blank hard-cuts to the argumentless blank mint (#159)" 2 \
  "omit --template" "$BOX" new --name work --template blank
for retired in claude-box codex-box grok-box kimi-box; do
  check "new: --template $retired hard-cuts to --role (#159)" 2 \
    "--role $retired --size medium" "$BOX" new --name work --template "$retired"
done
check "new: malformed runtime roles fail before Incus (#159)" 2 \
  "--role must be a plain rig role name" "$BOX" new --name work --role 'bad role'
check "new: --user belongs to a runtime role (#159)" 2 \
  "--user requires --role" "$BOX" new --name work --user dev
check "new: --from refuses a fresh runtime role (#159)" 2 \
  "tenant role rides along" "$BOX" new --name copy --from work --role kimi-box
check "new: --template and --role are mutually exclusive (#159)" 2 \
  "choose different mint paths" "$BOX" new --name work --template staging-box --role kimi-box
check "new: an unknown named size is refused (#159)" 2 \
  "--size must be small, medium, or large" "$BOX" new --name work --size huge
check "help new: publishes the large size row (#159)" 0 "large       8    16GiB  120GiB" \
  "$BOX" help new

# ---------------------------------------------------------------------------
# box exec — preserve command argv across the login-environment boundary
# (#169). `sudo -i <command...>` joins argv into one shell string; its escaped
# newline becomes a continuation, so a multi-line body can fuse into a
# different valid command and still return 0. Drive cmd_exec through a fake
# incus boundary that validates the wrapper shape and then executes it. This
# test therefore fails against the old -i implementation before trusting the
# marker files.
# ---------------------------------------------------------------------------
EXECFN="$(mktemp)"
grep '^cmd_exec()' "$BOX" > "$EXECFN"
check "box exec: cmd_exec extracted (guards the grep)" 0 "exec \"\$@\"" cat "$EXECFN"
check "box exec: extracted function is valid bash" 0 "" bash -n "$EXECFN"
check "box exec: command argv never rides sudo -i" 1 "" grep -q -- ' -i ' "$EXECFN"

exec_fixture() { # exec_fixture <command> [arg...]
  bash -c '
    set -e
    . "$0"
    box_user() { printf "%s\n" fixture-user; }
    incus() {
      [ "$1" = exec ] && [ "$2" = fixture ] && [ "$3" = -- ]
      shift 3
      [ "$1" = sudo ] && [ "$2" = -u ] && [ "$3" = fixture-user ] &&
        [ "$4" = -H ]
      shift 4
      "$@"
    }
    inst=fixture
    args=(fixture "$@")
    cmd_exec
  ' "$EXECFN" "$@"
}

EXEC_STATE="$(mktemp -d)"
exec_body="set -euo pipefail
touch '$EXEC_STATE/step-one'
touch '$EXEC_STATE/step-two'"
check "box exec: silent-success multiline body executes each statement" 0 "" \
  exec_fixture bash -lc "$exec_body"
check "box exec: multiline step one was not fused into set argv" 0 "" \
  test -f "$EXEC_STATE/step-one"
check "box exec: multiline step two was not fused into set argv" 0 "" \
  test -f "$EXEC_STATE/step-two"
check "box exec: plain argv remains separate" 0 "one argument" \
  exec_fixture printf '%s\n' "one argument"
rm -rf "$EXEC_STATE"
rm -f "$EXECFN"

# ---------------------------------------------------------------------------
# A shim `id` on PATH: lets us drive install.sh's DEST branch with a canned uid +
# group output, exactly the way rig drives assert_runner_repo against fixtures.
# ---------------------------------------------------------------------------
SHIMDIR="$(mktemp -d)"
cat > "$SHIMDIR/id" <<'SHIM'
#!/usr/bin/env bash
# Fake `id`: -u prints $FAKE_UID, -nG prints $FAKE_GROUPS. Just enough for
# install.sh's DEST branch, which only ever asks these two.
case "${1:-}" in
  -u)  printf '%s\n' "${FAKE_UID:-1000}" ;;
  -nG) printf '%s\n' "${FAKE_GROUPS:-}" ;;
  *)   exit 0 ;;
esac
SHIM
chmod +x "$SHIMDIR/id"

# ---------------------------------------------------------------------------
# install.sh — #71 global/root install. bash -n first, then drive the actual
# DEST/BINDIR branch with the shim id (the functional proof the contract asks
# for), then grep the root-only pieces that a daemon-free run cannot exercise.
# ---------------------------------------------------------------------------
check "install.sh is valid bash" 0 "" bash -n "$ROOT/install.sh"
# Extract EXACTLY the DEST/BINDIR if/else/fi (the first `id -u -eq 0` block) and
# print what it resolved — the same "run the pure block in isolation" trick rig
# uses for its embedded dump script. Fail closed: a mangled extraction is caught
# by the /opt/box grep below before any resolution is trusted.
DBLOCK="$(mktemp)"
awk '/id -u.*-eq 0/{f=1} f{print} f&&/^fi$/{exit}' "$ROOT/install.sh" > "$DBLOCK"
# The $DEST/$BINDIR here are LITERAL text appended into the extracted block — they
# must expand when that block RUNS, not when this printf writes it. Hence single
# quotes; SC2016 is the intent.
# shellcheck disable=SC2016
printf '\nprintf "DEST=%%s BINDIR=%%s\\n" "$DEST" "$BINDIR"\n' >> "$DBLOCK"
check "install.sh: DEST block extracted (guards the awk)" 0 "/opt/box" cat "$DBLOCK"
check "install.sh: the extracted DEST block is valid bash" 0 "" bash -n "$DBLOCK"

dest() { # dest <uid> [extra env assignments...] — resolve DEST/BINDIR
  local uid="$1"; shift
  FAKE_UID="$uid" HOME=/home/tester PATH="$SHIMDIR:$PATH" env "$@" bash "$DBLOCK"
}
# Root: the global path — a system tree other users can read (#71).
check "install.sh: root → DEST=/opt/box"           0 "DEST=/opt/box"          dest 0
check "install.sh: root → BINDIR=/usr/local/bin"   0 "BINDIR=/usr/local/bin"  dest 0
# Non-root: unchanged, the solo path.
check "install.sh: non-root → DEST=\$HOME/.local"  0 "DEST=/home/tester/.local/share/box" dest 1000
check "install.sh: non-root → BINDIR=\$HOME/.local" 0 "BINDIR=/home/tester/.local/bin"    dest 1000
# BOX_HOME / BOX_BIN still win on BOTH branches — the scripting override.
check "install.sh: BOX_HOME overrides the root default" 0 "DEST=/srv/box"     dest 0    BOX_HOME=/srv/box
check "install.sh: BOX_BIN overrides the root default"  0 "BINDIR=/srv/bin"    dest 0    BOX_BIN=/srv/bin
check "install.sh: BOX_HOME overrides the non-root default" 0 "DEST=/srv/box"  dest 1000 BOX_HOME=/srv/box
rm -f "$DBLOCK"
# The root-only world-readable chmod (#71): the tree is EXECUTED by other users,
# so root must open read+traverse. Grep it, and that it is root-guarded so the
# per-user install stays byte-identical to before.
# $DEST is a LITERAL in the grep pattern (install.sh's own variable) — single
# quotes intended.
# shellcheck disable=SC2016
check "install.sh: root makes the tree world-readable (a+rX)" 0 "" \
  grep -qF 'chmod -R a+rX "$DEST"' "$ROOT/install.sh"
check "install.sh: the a+rX is root-guarded" 0 "" \
  bash -c 'grep -B2 "chmod -R a+rX" "'"$ROOT"'/install.sh" | grep -q "id -u.*-eq 0"'
# #66's flow, preserved: confirm-before-download, and no-op if already installed.
check "install.sh: still confirms before downloading (#66)" 0 "" \
  grep -qF 'confirm "Install box from' "$ROOT/install.sh"
check "install.sh: still no-ops on an existing install (#66)" 0 "" \
  grep -qF 'already installed' "$ROOT/install.sh"

# ---------------------------------------------------------------------------
# Templates — DYNAMIC over templates/*/ (#68): the loop discovers every
# template directory, so a new template cannot ship without passing these (the
# old hardcoded blank/claude/codex/grok list let exactly that happen). The
# box.env parse is proven against the REAL allowlist: load_template is
# extracted from bin/box and DRIVEN against each template — the same
# source-the-pure-function trick install.sh's DEST block and box_tier get
# below — so an unknown key, a missing BOX_IMAGE/BOX_USER, or a line that is
# not KEY="value" fails HERE, not at mint time on a host.
# ---------------------------------------------------------------------------
TPLFN="$(mktemp)"
awk '/^load_template\(\) \{/,/^\}/' "$ROOT/bin/box" > "$TPLFN"
check "load_template: extracted from bin/box (guards the awk)" 0 "unknown key" cat "$TPLFN"
check "load_template: the extracted function is valid bash"    0 "" bash -n "$TPLFN"

# tpl <root> <template> — run the real parser against <root>/templates/, print
# what it resolved. $0 carries the extracted-function file into the subshell.
tpl() {
  root="$1" bash -c '
    die() { echo "box: $*" >&2; exit 1; }
    . "$0"; load_template "$1"
    printf "IMAGE=%s USER=%s REQUIRE_VM=%s NO_FALLBACK=%s AUTOSTART=%s ROLE=%s\n" \
      "$T_IMAGE" "$T_USER" "$T_REQUIRE_VM" "$T_NO_CONTAINER_FALLBACK" \
      "$T_AUTOSTART" "$T_BOOTSTRAP_ROLE"
  ' "$TPLFN" "$2"
}

# The allowlist itself is load-bearing: a template must not be able to grow a
# network key, and the required keys must still be required. Fixture-driven,
# against a throwaway root — exactly the dies a green parse cannot prove.
EVILROOT="$(mktemp -d)"; mkdir -p "$EVILROOT/templates/evil"
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="dev"\nBOX_NETWORK="lan"\n' \
  > "$EVILROOT/templates/evil/box.env"
check "load_template: an unknown key dies (no template grows a network)" 1 "unknown key" \
  tpl "$EVILROOT" evil
printf 'BOX_USER="dev"\n' > "$EVILROOT/templates/evil/box.env"
check "load_template: a missing BOX_IMAGE dies" 1 "required" tpl "$EVILROOT" evil
# The boot demands' green path, kept as a fixture even now that staging sets
# them in-tree: fixtures survive a template rename, and a deleted case arm
# must fail HERE, through the real parser, not at first use on a host.
mkdir -p "$EVILROOT/templates/server"
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="ops"\nBOX_REQUIRE_VM="1"\nBOX_AUTOSTART="1"\n' \
  > "$EVILROOT/templates/server/box.env"
check "load_template: REQUIRE_VM and AUTOSTART round-trip (accepted + surfaced)" \
  0 "REQUIRE_VM=1 NO_FALLBACK= AUTOSTART=1" tpl "$EVILROOT" server
# The softer demand is independently parsed. Keeping it a second boolean key
# means a typo cannot quietly degrade into an unpinned template (#175).
mkdir -p "$EVILROOT/templates/tenant-vm-default"
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="dev"\nBOX_NO_CONTAINER_FALLBACK="1"\n' \
  > "$EVILROOT/templates/tenant-vm-default/box.env"
check "load_template: NO_CONTAINER_FALLBACK round-trips (accepted + surfaced)" \
  0 "REQUIRE_VM= NO_FALLBACK=1" tpl "$EVILROOT" tenant-vm-default
# BOX_BOOTSTRAP_ROLE (#81): accepted and surfaced through the real parser —
# and the value is a rig role NAME, nothing more. It is handed to
# 'incus exec … rig bootstrap <role>' at mint, so anything shell-shaped in
# it must die at parse time, on the host, before a guest exists.
mkdir -p "$EVILROOT/templates/tenant"
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="claude"\nBOX_BOOTSTRAP_ROLE="claude"\n' \
  > "$EVILROOT/templates/tenant/box.env"
check "load_template: BOX_BOOTSTRAP_ROLE round-trips (accepted + surfaced)" \
  0 "ROLE=claude" tpl "$EVILROOT" tenant
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="claude"\nBOX_BOOTSTRAP_ROLE="claude; rm -rf /"\n' \
  > "$EVILROOT/templates/tenant/box.env"
check "load_template: a shell-shaped BOX_BOOTSTRAP_ROLE dies at the gate" \
  1 "not a sane role name" tpl "$EVILROOT" tenant
rm -rf "$EVILROOT"

# ---------------------------------------------------------------------------
# render_userdata (#81) — the seed's ONE substitution, driven for real: the
# rig pin point. RIG_REPO defaults to heavy-duty/rig and RIG_REF to rig's
# LATEST RELEASE, resolved at mint off the releases/latest redirect (#150);
# RIG_REPO/RIG_REF override at mint (how a rig branch under review reaches a
# guest); and a hostile value — the tokens land inside a runcmd shell line —
# dies on the host before touching the YAML. bash's =~ anchors the WHOLE
# string, so a multi-line value cannot sneak one clean line past it (the
# line-oriented grep -q failure mode).
#
# A shim curl serves canned redirects, the same way test/release.sh drives
# install.sh's own channel probe: the suite must never depend on github.com
# being up, or on which rig release is latest the day it runs.
# ---------------------------------------------------------------------------
RIGSHIM="$(mktemp -d)"
cat > "$RIGSHIM/curl" <<'SHIM'
#!/usr/bin/env bash
# Fake curl for the rig pin probe. FAKE_REDIRECT is what GitHub's
# releases/latest answers with; FAKE_CURL_RC makes the request itself fail;
# FAKE_CURL_LOG records every URL asked for, which is how "how many probes
# did one mint make?" becomes an assertion.
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output|-w|--write-out|-m|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ -n "${FAKE_CURL_LOG:-}" ] && printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
case "$url" in
  */releases/latest)
    [ "${FAKE_CURL_RC:-0}" -eq 0 ] || exit "${FAKE_CURL_RC}"
    printf '%s' "${FAKE_REDIRECT-}"; exit 0 ;;
  *) exit 22 ;;
esac
SHIM
chmod +x "$RIGSHIM/curl"

RUFN="$(mktemp)"
# The pin's DEFAULTS live in rig_repo/rig_ref and the resolution behind them in
# rig_latest_release/rig_pin_resolve (#150) — extract them alongside the
# function that reads them, or the extracted copy silently renders an empty
# repo and every assertion below goes green against nothing. The count guards
# the extraction the way it always has: four helpers, four definitions.
{ grep -cE '^rig_(repo|ref|latest_release|pin_resolve)\(\)' "$ROOT/bin/box" | grep -qx 4 || echo 'die "the rig pin helpers moved — this extraction is stale"'
  grep -E '^rig_(repo|ref)\(\)' "$ROOT/bin/box"
  awk '/^rig_latest_release\(\) \{/,/^\}/' "$ROOT/bin/box"
  awk '/^rig_pin_resolve\(\) \{/,/^\}/' "$ROOT/bin/box"
  awk '/^render_userdata\(\) \{/,/^\}/' "$ROOT/bin/box"; } > "$RUFN"
check "render_userdata: extracted from bin/box (guards the awk)" 0 "RIG_REPO" cat "$RUFN"
check "render_userdata: the pin's defaults came with it (guards the grep)" 0 "heavy-duty/rig" cat "$RUFN"
check "render_userdata: the pin's RESOLUTION came with it too (#150)" 0 "releases/latest" cat "$RUFN"
check "render_userdata: the extracted function is valid bash"    0 "" bash -n "$RUFN"
# Two probes for two channels — box's own in install.sh (#83) and rig's here
# (#150) — and they are the same trick, so they must stay the same trick. Not
# byte-identical (this one takes the repo as an argument and time-boxes the
# request), so what is asserted is the pair of facts a rewrite of either would
# break: the redirect they read, and the tag shape they accept from it.
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "the rig pin probe reads the same redirect install.sh does (#83, #150)" 0 "" \
  bash -c 'for f in "$@"; do grep -q "releases/latest\"" "$f" || exit 1
             grep -q "\*/releases/tag/?\*" "$f" || exit 1; done' _ "$ROOT/install.sh" "$RUFN"

SEED="$(mktemp)"
printf '#cloud-config\nusers:\n  - name: "@BOX_USER@"\nruncmd:\n  - curl -fsSL https://raw.githubusercontent.com/@RIG_REPO@/@RIG_REF@/install.sh | RIG_REPO="@RIG_REPO@" RIG_REF="@RIG_REF@" bash\n' > "$SEED"
# A synthetic seed that installs no rig. It carries no token, so it needs no
# pin and must therefore need no NETWORK either (#150).
NORIG="$(mktemp)"
printf '#cloud-config\npackages:\n  - tmux\n' > "$NORIG"
RIGLOGF="$(mktemp)"
SEEDFILE="$SEED"   # which fixture rud renders; the no-token case swaps it
# shellcheck disable=SC2016  # $0/$1 expand in the child shell, by design
rud() { # rud [VAR=val ...] — render the fixture seed through the real function
  : > "$RIGLOGF"
  env T_USER=fixture FAKE_REDIRECT="https://github.com/heavy-duty/rig/releases/tag/9.9.9" \
      FAKE_CURL_LOG="$RIGLOGF" PATH="$RIGSHIM:$PATH" "$@" \
      bash -c 'die() { echo "box: $*" >&2; exit 1; }; . "$0"; render_userdata "$1"' "$RUFN" "$SEEDFILE"
}
# The default is the LATEST RELEASE, not main: a released box that converged
# its guests against rig's development tip shipped a combination nobody
# drilled, which is the whole of #150.
check "render_userdata: the default pin is rig's LATEST RELEASE (#150)" 0 \
  "githubusercontent.com/heavy-duty/rig/9.9.9/install.sh" rud
check "render_userdata: ...and it reached the installer's own env too (#150)" 0 \
  'RIG_REPO="heavy-duty/rig" RIG_REF="9.9.9"' rud
check "render_userdata: ...and it was read off the releases/latest redirect (#150)" 0 \
  "https://github.com/heavy-duty/rig/releases/latest" cat "$RIGLOGF"
# The dev channel survives as an explicit opt-in — and asks the network
# nothing, because there is nothing left to resolve.
check "render_userdata: RIG_REF=main is still the dev channel, explicitly (#150)" 0 \
  "githubusercontent.com/heavy-duty/rig/main/install.sh" rud RIG_REF=main
check "render_userdata: ...and an explicit ref probes nothing (#150)" 1 "" \
  grep -q . "$RIGLOGF"
check "render_userdata: RIG_REPO/RIG_REF override at mint" 0 "dan-claude-bot/rig/feat/bootstrap-roles/install.sh" \
  rud RIG_REPO=dan-claude-bot/rig RIG_REF=feat/bootstrap-roles
check "render_userdata: the runtime user reaches cloud-init (#159)" 0 \
  'name: "custom"' rud T_USER=custom RIG_REF=main
# The probe follows the repo, so a fork's own releases are what a fork's seeds
# get — one default, not a hardcoded heavy-duty/rig channel.
rud RIG_REPO=you/rig >/dev/null 2>&1
check "render_userdata: an overridden RIG_REPO is the repo the probe asks (#150)" 0 \
  "https://github.com/you/rig/releases/latest" cat "$RIGLOGF"
# A seed with no pin token needs no pin: it must render untouched AND ask the
# network nothing. 'blank' mints on a host that cannot reach github.com.
SEEDFILE="$NORIG"
check "render_userdata: a seed with no pin token renders untouched (#150)" 0 "packages:" rud
check "render_userdata: ...and never probes for a pin it will not use (#150)" 1 "" \
  grep -q . "$RIGLOGF"
SEEDFILE="$SEED"
# Failing to resolve is LOUD. Falling back to main would reintroduce the exact
# defect, quietly, on the one host where the probe could not run.
check "render_userdata: an unresolvable pin dies rather than falling back (#150)" 1 \
  "could not resolve rig's latest release" rud FAKE_CURL_RC=6
check "render_userdata: ...and a repo with no releases dies the same way (#150)" 1 \
  "could not resolve rig's latest release" \
  rud FAKE_REDIRECT=https://github.com/heavy-duty/rig/releases
check "render_userdata: ...naming both escape hatches, so the operator can move" 1 \
  "RIG_REF=main" rud FAKE_CURL_RC=6
# The resolved tag is untrusted input — it arrives off an HTTP redirect header
# — so it meets the same allowlist an operator's RIG_REF does.
check "render_userdata: a hostile RESOLVED tag dies on the host too (#150)" 1 "RIG_REF" \
  rud 'FAKE_REDIRECT=https://github.com/heavy-duty/rig/releases/tag/v1"; rm -rf /; "'
# shellcheck disable=SC2016  # $0/$1 expand in the child shells, by design
check "render_userdata: no token survives the render" 1 "" \
  bash -c 'env T_USER=fixture FAKE_REDIRECT="https://github.com/heavy-duty/rig/releases/tag/9.9.9" PATH="$3:$PATH" bash -c "die() { echo box: \$*; exit 1; }; . \"\$0\"; render_userdata \"\$1\"" "$1" "$2" | grep -qE "@(RIG|BOX)_"' _ "$RUFN" "$SEED" "$RIGSHIM"
check "render_userdata: a shell-shaped RIG_REPO dies on the host" 1 "RIG_REPO" \
  rud 'RIG_REPO=evil"; rm -rf /; "/rig'
check "render_userdata: a spaced RIG_REF dies on the host" 1 "RIG_REF" \
  rud 'RIG_REF=main plus junk'
check "render_userdata: a newline-smuggled RIG_REPO dies (whole-string anchor)" 1 "RIG_REPO" \
  rud "RIG_REPO=$(printf 'a/b\nevil')"

# The one generic seed renders into two measured shapes (#159): agent-class
# when a role is present, and today's blank when it is absent. Drive both
# through the real renderer, then make every assertion against what cloud-init
# receives rather than against source-only sentinel blocks.
ROLESEED="$(mktemp)"; BLANKSEED="$(mktemp)"
SEEDFILE="$ROOT/templates/tenant/user-data.yaml"
rud T_USER=claude T_BOOTSTRAP_ROLE=claude-box RIG_REF=main > "$ROLESEED"
rud T_USER=dev T_BOOTSTRAP_ROLE= RIG_REF=main > "$BLANKSEED"
check "render_userdata: role sentinels never reach cloud-init (#159)" 1 "" \
  grep -q '^# box-.*-only-' "$ROLESEED"
check "render_userdata: blank sentinels never reach cloud-init (#159)" 1 "" \
  grep -q '^# box-.*-only-' "$BLANKSEED"
check "generic seed: role tenant has no sudoers entry (#177, #159)" 1 "" \
  grep -qE '^[[:space:]]*sudo:' "$ROLESEED"
check "generic seed: blank tenant keeps sudo (#177, #159)" 0 "" \
  grep -qE '^[[:space:]]*sudo: "ALL=\(ALL\) NOPASSWD:ALL"$' "$BLANKSEED"
check "generic seed: blank omits the agent toolchain (#177, #159)" 1 "" \
  grep -qE '^[[:space:]]*-[[:space:]]+(python3-venv|shellcheck)$' "$BLANKSEED"
check "generic seed: blank omits the /tmp cap and swap (#178, #159)" 1 "" \
  grep -qE 'tmp\.mount|swapfile' "$BLANKSEED"
check "generic seed: blank still preinstalls rig (#159 ruling)" 0 "" \
  grep -q 'heavy-duty/rig/main/install.sh' "$BLANKSEED"
rm -f "$RUFN" "$SEED" "$NORIG" "$RIGLOGF"

# YAML well-formedness needs python3 + pyyaml; the CI runner has both. Skip
# gracefully (never silently) where they are missing.
HAVE_YAML=0
command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null && HAVE_YAML=1

for d in "$ROOT"/templates/*/; do
  t="$(basename "$d")"
  # The parse itself asserts the allowlist AND the required keys (the driven
  # function dies without BOX_IMAGE/BOX_USER); the greps pin both keys to the
  # FILE, so neither can quietly become an inherited default.
  check "template '$t': box.env parses against the real allowlist" 0 "USER=" tpl "$ROOT" "$t"
  check "template '$t': box.env sets BOX_IMAGE" 0 "" grep -q '^BOX_IMAGE=' "$d/box.env"
  check "template '$t': box.env sets BOX_USER"  0 "" grep -q '^BOX_USER='  "$d/box.env"
  # #175: every shipped seed defaults to the VM trust boundary. Discovery is
  # deliberate: a new template that forgets the pin must fail this same loop.
  check "template '$t': declares one of the two no-fallback demands (#175)" \
    0 "" grep -Eq '^BOX_(REQUIRE_VM|NO_CONTAINER_FALLBACK)="1"$' "$d/box.env"
  # cloud-init is passed to Incus verbatim (modulo the two rig pin tokens),
  # so it must exist, declare itself, and be well-formed — a mint is far too
  # late to learn about a typo.
  check "template '$t': user-data.yaml exists" 0 "" test -f "$d/user-data.yaml"
  # shellcheck disable=SC2016  # $1 expands in the child shell, by design
  check "template '$t': user-data.yaml begins with #cloud-config" 0 "" \
    bash -c 'head -1 "$1" | grep -qx "#cloud-config"' _ "$d/user-data.yaml"
  if [ "$HAVE_YAML" = 1 ]; then
    check "template '$t': user-data.yaml is well-formed YAML" 0 "" \
      python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$d/user-data.yaml"
  else
    echo "skip: template '$t' YAML well-formedness (no python3+pyyaml here; CI has both)"
  fi
  # #177: the tenant is UNPRIVILEGED, and the default is no sudoers entry at
  # all. Root was never the confidentiality boundary — the agent runs AS the
  # tenant — but it forecloses every in-guest control one might later add and
  # lets a box rewrite the evidence of its own contents; the operator path is
  # 'box root', which authorizes host-side and needs no sudoers entry (#176).
  # The two exceptions are NAMED here rather than inferred, so a new template
  # that ships a sudo line goes red in this loop until someone puts it on the
  # list deliberately — the same fail-closed shape as the absence block below.
  case "$t" in
    staging-box)
      # Self-converging fleet guests keep root: their tenant's own first act
      # is 'sudo rig runner install' or 'sudo rig bootstrap workload-server'.
      # Agents lose root, self-converging guests keep it — two traits, two
      # answers, and #175's BOX_REQUIRE_VM is the one meant to be inherited.
      check "template '$t': keeps NOPASSWD sudo — a self-converging seed (#177)" 0 "" \
        grep -qE '^[[:space:]]*sudo: "ALL=\(ALL\) NOPASSWD:ALL"$' "$d/user-data.yaml" ;;
    tenant)
      # The source contains both alternatives; the driven ROLESEED above is
      # the effective agent shape and is what must be unprivileged.
      check "template 'tenant': rendered role has NO sudoers entry (#177, #159)" 1 "" \
        grep -qE '^[[:space:]]*sudo:' "$ROLESEED" ;;
    *)
      # shellcheck disable=SC2016  # $1 expands in the child shell, by design
      check "template '$t': the tenant has NO sudoers entry (#177)" 1 "" \
        bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qE "^[[:space:]]*sudo:"' _ "$d/user-data.yaml" ;;
  esac
  # #177 decision 6: where a seed keeps sudo it is ALL or nothing. A partial
  # allowlist ('NOPASSWD: /usr/bin/apt-get') reintroduces most of the risk —
  # apt alone installs a package that owns the box — while feeling safer,
  # which is the worst combination. So the only permitted value is the full
  # one, in any template, and the grep runs over EFFECTIVE lines because the
  # comments above it name the shape they refuse.
  # shellcheck disable=SC2016  # $1 expands in the child shell, by design
  check "template '$t': a sudoers entry is ALL or nothing (#177)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -E "^[[:space:]]*sudo:" \
               | grep -qvE "^[[:space:]]*sudo: \"ALL=\(ALL\) NOPASSWD:ALL\"$"' _ "$d/user-data.yaml"
  # The half of the seed's user block that #177 did NOT change: no password
  # login, in every template. Dropping sudo while leaving the account
  # unlocked would trade one door for another.
  check "template '$t': the tenant password stays locked (#177)" 0 "" \
    grep -qE '^[[:space:]]*lock_passwd: true$' "$d/user-data.yaml"
  # #65: 'box tmux' runs 'tmux new-session' INSIDE the box, so every
  # template's package list must carry tmux or the verb dies inside.
  check "template '$t': installs tmux (#65)" 0 "" \
    grep -qE '^[[:space:]]*-[[:space:]]+tmux$' "$d/user-data.yaml"
  # #174: host suspend can leave a guest hours adrift. Every discovered
  # template therefore installs chrony, gives it an unlimited post-start
  # step window, and explicitly leaves the service enabled and running.
  check "template '$t': installs chrony (#174)" 0 "" \
    grep -qE '^[[:space:]]*-[[:space:]]+chrony$' "$d/user-data.yaml"
  check "template '$t': writes the chrony step drop-in (#174)" 0 "" \
    grep -qE '^[[:space:]]*-[[:space:]]+path:[[:space:]]+/etc/chrony/conf\.d/box-makestep\.conf$' "$d/user-data.yaml"
  check "template '$t': permits steps after every update (#174)" 0 "" \
    grep -qE '^[[:space:]]+makestep[[:space:]]+1\.0[[:space:]]+-1$' "$d/user-data.yaml"
  check "template '$t': enables chrony (#174)" 0 "" \
    grep -qE '^[[:space:]]*-[[:space:]]+systemctl enable chrony$' "$d/user-data.yaml"
  check "template '$t': starts chrony on clock-owning VM guests (#174)" 0 "" \
    grep -qE '^[[:space:]]*-[[:space:]]+systemd-detect-virt --quiet --container \|\| systemctl start chrony$' "$d/user-data.yaml"
  # #178: /tmp is RAM and systemd's stock tmp.mount sizes it at 50% of it, so
  # scratch and the agent's working set compete for the same BOX_MEMORY — and
  # raising that line raises the scratch ceiling with it, which is why the cap
  # has to be a fixed figure and not a smaller share. Measured live: a
  # claude-box at 8GiB carried a 3.9GB /tmp, and heavy-duty/incubator#214 lost
  # a test suite to ENOSPC on it against scratch left by earlier sessions.
  # Scoped to the AGENT seeds by the issue's own deliverables, and named
  # fail-closed in the same shape as the sudo block above: the exceptions are
  # listed, so a fifth agent seed inherits the requirement without an edit and
  # a fleet guest that grows a cap goes red until someone lists it deliberately.
  case "$t" in
    blank|staging-box)
      # Self-converging fleet guests. A workload server's /tmp at 1GiB is a
      # decision #178 did not make, and swap on a guest that is not running
      # untrusted agent code is a different question; assert the ABSENCE so
      # the scoping is pinned rather than merely true today.
      # shellcheck disable=SC2016  # $1 expands in the child shell, by design
      check "template '$t': no /tmp cap and no swapfile — a fleet guest, outside #178" 1 "" \
        bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qE "tmp\.mount|swapfile"' _ "$d/user-data.yaml" ;;
    *)
      check "template '$t': writes the /tmp size drop-in (#178)" 0 "" \
        grep -qE '^[[:space:]]*-[[:space:]]+path:[[:space:]]+/etc/systemd/system/tmp\.mount\.d/box-size\.conf$' "$d/user-data.yaml"
      check "template '$t': caps /tmp at a fixed 1GiB (#178)" 0 "" \
        grep -qE '^[[:space:]]+Options=.*,size=1G,' "$d/user-data.yaml"
      # The cap is DECOUPLED from BOX_MEMORY, which is the whole of #178: a
      # percentage here would restore the coupling while looking like a fix.
      # shellcheck disable=SC2016  # $1 expands in the child shell, by design
      check "template '$t': the /tmp cap is a figure, not a share of BOX_MEMORY (#178)" 1 "" \
        bash -c 'grep -E "^[[:space:]]+Options=" "$1" | grep -q "size=[0-9]*%"' _ "$d/user-data.yaml"
      # A systemd drop-in REPLACES Options= rather than merging into it, so a
      # rewrite that forgets a flag silently unhardens /tmp — mode=1777 is what
      # makes it a shared scratch directory at all, and nosuid/nodev are the
      # reason a world-writable one is safe. Asserted per flag, so a later size
      # change touches only the check above.
      for o in mode=1777 strictatime nosuid nodev nr_inodes=1m; do
        check "template '$t': the /tmp drop-in keeps stock '$o' (Options= is replaced, #178)" 0 "" \
          grep -qE "^[[:space:]]+Options=(.*,)?$o(,|\$)" "$d/user-data.yaml"
      done
      # The drop-in is read at the next boot; the remount is what makes the cap
      # true on the mint boot, and it resizes a live tmpfs in place rather than
      # unmounting /tmp under cloud-init and the rig installer.
      check "template '$t': applies the /tmp cap on the mint boot too (#178)" 0 "" \
        grep -qE '^[[:space:]]*-[[:space:]]+test "\$\(findmnt -no FSTYPE /tmp\)" != tmpfs \|\| mount -o remount,size=1G /tmp$' "$d/user-data.yaml"
      # #178 D2: no swap means every spike is a hard OOM-kill with no grace
      # period. Four greps, because the four halves fail independently — a
      # swapfile that is not made, not sized, not activated at boot, or made
      # in a container that cannot swapon at all.
      # shellcheck disable=SC2016  # $1 expands in the child shell, by design
      check "template '$t': provisions a 4GiB swapfile (#178)" 0 "" \
        bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qF "fallocate -l 4G /swapfile"' _ "$d/user-data.yaml"
      # shellcheck disable=SC2016
      check "template '$t': the swapfile is formatted and activated (#178)" 0 "" \
        bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qF "mkswap /swapfile" &&
                 grep -v "^[[:space:]]*#" "$1" | grep -qF "swapon /swapfile"' _ "$d/user-data.yaml"
      # shellcheck disable=SC2016
      check "template '$t': the swapfile survives a reboot (fstab, #178)" 0 "" \
        bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qF "/swapfile none swap sw 0 0"' _ "$d/user-data.yaml"
      # Guarded for chrony's reason, not a different one: a container shares
      # the host's swap and cannot swapon at all, so an unguarded seed writes
      # 4GiB of nothing into every container mint — CI's own rehearsal
      # included — and adds an fstab line that fails at every boot.
      # shellcheck disable=SC2016
      check "template '$t': swap provisioning is container-guarded (#174's guard, #178)" 0 "" \
        bash -c 'grep -v "^[[:space:]]*#" "$1" |
                 grep -qF "! systemd-detect-virt --quiet --container && [ ! -e /swapfile ]"' _ "$d/user-data.yaml"
      # #178 D3: the fact belongs next to the line that causes it. box.env
      # already carries a long explanatory header; this asserts it names both
      # halves and cites the incident, per CONTRIBUTING's comment rule.
      # shellcheck disable=SC2016
      check "template '$t': box.env states the /tmp and swap shape it causes (#178)" 0 "" \
        bash -c 'grep -qE "^#.*/tmp" "$1" && grep -qE "^#.*swap" "$1" && grep -qF "#178" "$1"' _ "$d/box.env" ;;
  esac
  # Static seeds duplicate BOX_USER into cloud-init. The generic tenant seed
  # instead carries exactly the token render_userdata replaces at mint.
  if [ "$t" = tenant ]; then
    check "template 'tenant': cloud-init carries the runtime user token (#159)" 0 "" \
      grep -qE '^[[:space:]]*-[[:space:]]+name:[[:space:]]+"@BOX_USER@"$' "$d/user-data.yaml"
  else
    tuser="$(tpl "$ROOT" "$t" | sed -n 's/.*USER=\([^ ]*\).*/\1/p')"
    check "template '$t': user-data.yaml creates BOX_USER ('$tuser')" 0 "" \
      grep -qE "^[[:space:]]*-[[:space:]]+name:[[:space:]]+$tuser\$" "$d/user-data.yaml"
  fi

  # ------------------------------------------------------------------------
  # The thin-template contract (#81), both halves per template:
  #
  # THE SEED — a template that names a tenant role (BOX_BOOTSTRAP_ROLE) must
  # preinstall rig carrying BOTH pin tokens, on the installer URL and on the
  # installer's own env, or the pin is a half-truth: a mint would fetch one
  # ref's installer and install another ref's tree.
  # ------------------------------------------------------------------------
  trole="$(tpl "$ROOT" "$t" | sed -n 's/.*ROLE=\([^ ]*\).*/\1/p')"
  if [ -n "$trole" ] || [ "$t" = tenant ]; then
    check "template '$t': the seed installs rig (role '$trole')" 0 "" \
      grep -q 'install.sh' "$d/user-data.yaml"
    # shellcheck disable=SC2016  # $1 expands in the child shell, by design
    check "template '$t': the rig install carries the @RIG_REPO@ pin token" 0 "" \
      bash -c 'grep "install.sh" "$1" | grep -q "@RIG_REPO@/@RIG_REF@"' _ "$d/user-data.yaml"
    # shellcheck disable=SC2016
    check "template '$t': the pin reaches the installer's env too" 0 "" \
      bash -c 'grep "install.sh" "$1" | grep -q "RIG_REPO=\"@RIG_REPO@\" RIG_REF=\"@RIG_REF@\""' _ "$d/user-data.yaml"
    # HOME=/root: a scar found live — cloud-init's runcmd has no $HOME and
    # rig's installer (set -u) dies on it (rig#39). The pin must survive
    # every seed rewrite.
    # shellcheck disable=SC2016
    check "template '$t': the rig install pins HOME=/root (runcmd has no \$HOME)" 0 "" \
      bash -c 'grep "install.sh" "$1" | grep -q "HOME=/root "' _ "$d/user-data.yaml"
  fi
  # ------------------------------------------------------------------------
  # THE ABSENCE — no tenant content in ANY template, ever again. Everything a
  # box becomes lives in rig's roles (rig#31); a template that grows an agent
  # CLI, docker, node, a tailnet join or a context-file heredoc is the
  # regression this suite exists to refuse. Greps run over EFFECTIVE
  # cloud-init lines (comments may name what they refuse — #69's idiom), and
  # they fail CLOSED: the want-exit is 1, so re-adding any of it goes red.
  # ------------------------------------------------------------------------
  # shellcheck disable=SC2016  # $1 expands in the child shell, by design
  check "template '$t': no agent CLI install (rig's job, rig#31)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qiE "claude\.ai|x\.ai|@openai|npm|nodesource|nodejs"' _ "$d/user-data.yaml"
  # shellcheck disable=SC2016
  check "template '$t': no docker (rig's job, rig#31)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qi docker' _ "$d/user-data.yaml"
  # shellcheck disable=SC2016
  check "template '$t': nothing that joins or admits (no tailscale/authkey/ssh)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qiE "tailscale|authkey|ssh"' _ "$d/user-data.yaml"
  # shellcheck disable=SC2016
  check "template '$t': no context file (the #80 guard lives in rig's roles)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qiE "CLAUDE\.md|AGENTS\.md"' _ "$d/user-data.yaml"
done

# The staging seed's boot demands are part of its contract (#68/#69): the VM
# is its trust boundary (its guest runs docker, via rig) and a server returns
# from a host reboot without an operator. Pinned to the FILE so neither can
# quietly vanish in a rewrite.
check "staging-box: demands VM mode (BOX_REQUIRE_VM=1)" 0 "" \
  grep -qx 'BOX_REQUIRE_VM="1"' "$ROOT/templates/staging-box/box.env"
check "staging-box: demands autostart (BOX_AUTOSTART=1)" 0 "" \
  grep -qx 'BOX_AUTOSTART="1"' "$ROOT/templates/staging-box/box.env"
check "staging-box: the tenant role is 'staging-box'" 0 "ROLE=staging-box" tpl "$ROOT" staging-box
check "staging-box: the seed user is rig's default for the role ('ops')" 0 "USER=ops" tpl "$ROOT" staging-box
# #175's five softer declarations are pinned separately from the discovery
# guard above: the loop catches a future unpinned seed, while this catches one
# of today's seeds accidentally inheriting staging-box's stronger policy.
check "tenant: permits only an explicit container override (BOX_NO_CONTAINER_FALLBACK=1)" \
  0 "" grep -qx 'BOX_NO_CONTAINER_FALLBACK="1"' "$ROOT/templates/tenant/box.env"
# The single runtime tenant seed carries the unprivileged agent tool floor;
# adding another rig role must not add another box directory (#159).
for p in python3-venv shellcheck; do
  check "tenant: ships '$p' — an unprivileged role cannot apt-install it (#177)" 0 "" \
    grep -qE "^[[:space:]]*-[[:space:]]+$p\$" "$ROOT/templates/tenant/user-data.yaml"
done
for retired in claude-box codex-box grok-box kimi-box; do
  check "templates: retired '$retired' seed is deleted (#159)" 1 "" \
    test -e "$ROOT/templates/$retired"
done
check "templates: retired 'blank' seed is deleted (#159)" 1 "" \
  test -e "$ROOT/templates/blank"

rm -f "$TPLFN" "$ROLESEED" "$BLANKSEED"

# The keys' cmd_new half, grepped the way the expose guard is (line order —
# a daemon-free run cannot mint). Both refusals must read the EFFECTIVE mode,
# i.e. come after pick_mode: refusing on a template key alone would refuse
# valid VM mints, and a guard deleted in a refactor must not ship green.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the REQUIRE_VM refusal orders after pick_mode" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  pick="$(printf "%s\n" "$fn" | grep -n "pick_mode"    | head -1 | cut -d: -f1)"
  guard="$(printf "%s\n" "$fn" | grep -n "T_REQUIRE_VM" | head -1 | cut -d: -f1)"
  [ -n "$pick" ] && [ -n "$guard" ] && [ "$pick" -lt "$guard" ]'
# Order is necessary, not sufficient: the policy call must receive $m, the
# effective pick_mode result, rather than the raw requested mode.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the template policy receives both demands and effective mode (\$m)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "template_mode_allowed" \
    | grep -qF "\"\$T_REQUIRE_VM\" \"\$T_NO_CONTAINER_FALLBACK\" \"\$m\" \"\$mode\""'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the soft KVM-less refusal names KVM and the explicit weaker override (#175)" \
  0 "" bash -c '
  line="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep "defaults to the VM boundary")"
  printf "%s\n" "$line" | grep -q -- "--container" &&
    printf "%s\n" "$line" | grep -q "weaker isolation"'
# #68 is byte-for-byte behavior, not merely an equivalent refusal. Pin both
# messages so #175 cannot advertise an override staging-box does not permit.
check "new: REQUIRE_VM keeps the explicit-container refusal wording (#68)" 0 "" \
  grep -Fq "usage_error \"template '\$t' requires VM mode — it will not mint as a container (drop --container)\"" "$ROOT/bin/box"
check "new: REQUIRE_VM keeps the KVM-less refusal wording (#68)" 0 "" \
  grep -Fq "die \"template '\$t' requires VM mode and this host has no /dev/kvm — mint it on a KVM-capable host (or via --remote)\"" "$ROOT/bin/box"
check "new: boot.autostart is stamped under the T_AUTOSTART guard" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -F "boot.autostart=true" | grep -q "T_AUTOSTART"'

# Drive mode selection with a stubbed host predicate: the suite must cover
# both KVM answers regardless of the machine it happens to run on (#175).
PICKFN="$(mktemp)"
sed -n '/^pick_mode() {/,/^}/p' "$ROOT/bin/box" > "$PICKFN"
pick_mode_case() {
  bash -c '
    . "$0"
    mode="$1"; remote="$2"
    if [ "$3" = yes ]; then
      host_has_kvm() { return 0; }
    else
      host_has_kvm() { return 1; }
    fi
    pick_mode
  ' "$PICKFN" "$@"
}
check "pick_mode: automatic mode chooses VM when KVM is present (#175)" \
  0 "vm" pick_mode_case auto "" yes
check "pick_mode: automatic mode falls back when KVM is absent (#175)" \
  0 "container" pick_mode_case auto "" no
check "pick_mode: explicit --container survives a KVM-less host (#175)" \
  0 "container" pick_mode_case container "" no
check "pick_mode: explicit --vm survives a KVM-less host (#175)" \
  0 "vm" pick_mode_case vm "" no
check "pick_mode: a remote mint remains VM mode without local KVM (#175)" \
  0 "vm" pick_mode_case auto "remote:" no
rm -f "$PICKFN"

# Drive the template policy separately from mode selection. Composed with the
# discovery assertion above, this simulates the required KVM-less paths for
# every shipped template without trusting the runner's hardware (#175).
POLICYFN="$(mktemp)"
sed -n '/^template_mode_allowed() {/,/^}/p' "$ROOT/bin/box" > "$POLICYFN"
template_mode_case() { bash -c '. "$0"; template_mode_allowed "$@"' "$POLICYFN" "$@"; }
check "template mode: REQUIRE_VM refuses an automatic container fallback (#68)" \
  1 "" template_mode_case 1 "" container auto
check "template mode: REQUIRE_VM permits a VM (#175)" \
  0 "" template_mode_case 1 "" vm auto
check "template mode: REQUIRE_VM refuses explicit --container on either host shape (#68)" \
  1 "" template_mode_case 1 "" container container
check "template mode: NO_CONTAINER_FALLBACK refuses an automatic fallback (#175)" \
  1 "" template_mode_case "" 1 container auto
check "template mode: NO_CONTAINER_FALLBACK permits a VM (#175)" \
  0 "" template_mode_case "" 1 vm auto
check "template mode: NO_CONTAINER_FALLBACK permits explicit --container (#175)" \
  0 "" template_mode_case "" 1 container container
check "template mode: REQUIRE_VM wins when both keys are set (#175)" \
  1 "" template_mode_case 1 1 container container
check "template mode: an unpinned template keeps the ordinary fallback" \
  0 "" template_mode_case "" "" container auto
rm -f "$POLICYFN"

# Compose the real selector and policy for the host/request matrix. The two
# explicit staging cases look redundant only after the host fact is discarded;
# keeping both pins criterion 8 to KVM-present and KVM-less hosts separately.
MATRIXFN="$(mktemp)"
sed -n '/^pick_mode() {/,/^}/p' "$ROOT/bin/box" > "$MATRIXFN"
sed -n '/^template_mode_allowed() {/,/^}/p' "$ROOT/bin/box" >> "$MATRIXFN"
template_request_case() { # require no-fallback requested remote has-kvm
  bash -c '
    . "$0"
    require_vm="$1"; no_fallback="$2"; mode="$3"; remote="$4"
    if [ "$5" = yes ]; then
      host_has_kvm() { return 0; }
    else
      host_has_kvm() { return 1; }
    fi
    effective="$(pick_mode)"
    template_mode_allowed "$require_vm" "$no_fallback" "$effective" "$mode"
  ' "$MATRIXFN" "$@"
}
check "staging policy: --container is refused on a KVM-capable host (#68, #175)" \
  1 "" template_request_case 1 "" container "" yes
check "staging policy: --container is refused on a KVM-less host (#68, #175)" \
  1 "" template_request_case 1 "" container "" no
check "staging policy: an automatic KVM-less mint is refused (#68, #175)" \
  1 "" template_request_case 1 "" auto "" no
check "agent policy: an automatic KVM-less mint is refused (#175)" \
  1 "" template_request_case "" 1 auto "" no
check "agent policy: explicit --container succeeds on a KVM-less host (#175)" \
  0 "" template_request_case "" 1 container "" no
check "agent policy: an automatic mint uses a VM when KVM exists (#175)" \
  0 "" template_request_case "" 1 auto "" yes
rm -f "$MATRIXFN"

# The auto-run half of #81, grepped the same way (a daemon-free run cannot
# mint). The seed reaches Incus through render_userdata — the pin point — not
# through a raw cat; and the tenant convergence must order AFTER the
# cloud-init wait (rig is installed by the seed's runcmd, so exec'ing the
# role before cloud-init settles would race its own installer) and sit under
# the T_BOOTSTRAP_ROLE guard (blank must never auto-run anything).
check "new: cloud-init user-data goes through render_userdata (the rig pin)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -F "cloud-init.user-data" | grep -q "render_userdata"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the tenant auto-run orders after the cloud-init wait" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  wait="$(printf "%s\n" "$fn" | grep -n "cloud-init status --wait" | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "incus exec.*rig bootstrap" | head -1 | cut -d: -f1)"
  [ -n "$wait" ] && [ -n "$run" ] && [ "$wait" -lt "$run" ]'
check "new: the auto-run sits under the T_BOOTSTRAP_ROLE guard" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -B2 "incus exec .* rig bootstrap" | grep -q "T_BOOTSTRAP_ROLE"'
check "new: a failed tenant role names the re-run (the role converges)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -q "box root .*rig bootstrap"'
# ...and names it through the ROOT path. Since #177 the agent tenants have no
# sudoers entry, so a hint of the old shape ('box shell' then 'sudo rig
# bootstrap <role>') was a recovery path that died on exactly the boxes it was
# printed for. 'box root' needs no sudoers entry (#176) and is right for all
# six templates. Pinned per-token so the staging tailnet-join hint below —
# 'sudo rig bootstrap workload-server', a tenant that KEPT sudo — is untouched
# by this assertion.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "new: the re-run hint does not assume tenant sudo (#177)" 1 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -q "sudo rig bootstrap \$T_BOOTSTRAP_ROLE"'

# The launch phase, narrated and time-boxed (#93) — grepped the way the other
# mint-path guards are (a daemon-free run cannot mint). Twice in the
# 2026-07-19 release drill the child 'incus launch' wedged silently before
# the create was even accepted, once for 56 minutes. The narration must order
# BEFORE the launch call (a wedge after the line is visible at a glance; a
# wedge before it is the old silent hang), the call itself must sit under
# 'timeout -k' with the BOX_LAUNCH_TIMEOUT override and pinned stdin (RUNS.md
# trap 13: bare 'timeout N' cannot kill an incus call that owns a TTY), and
# the budget's failure must be LOUD — no server-side operation, the measured
# retry-succeeds hint, and the doctor as the next move.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the launch narration orders before incus launch (#93)" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  say="$(printf "%s\n" "$fn" | grep -n "launching instance" | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "timeout -k.*incus launch" | head -1 | cut -d: -f1)"
  [ -n "$say" ] && [ -n "$run" ] && [ "$say" -lt "$run" ]'
check "new: incus launch is time-boxed (timeout -k on the budget)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "timeout -k" | grep "budget" | grep -q "incus launch"'
check "new: the budget is BOX_LAUNCH_TIMEOUT, default 600s (the BOX_CPU knob shape)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "budget=" | grep -q "BOX_LAUNCH_TIMEOUT:-600"'
check "new: the launch pins stdin (RUNS.md trap 13)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -F "extra[@]" | grep -qF "</dev/null"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the wedge failure is loud — retry hint, the doctor, and #93" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  printf "%s\n" "$fn" | grep -A6 "WEDGED" | grep -q "observed to succeed" &&
  printf "%s\n" "$fn" | grep -q "box doctor" &&
  printf "%s\n" "$fn" | grep "did not finish inside" | grep -q "#93"'
# timeout proves only that the CLIENT overran the budget: launch is
# create-then-start, so a slow launch may have REGISTERED the instance and a
# blind "never created, retry" would send the operator into 'Instance already
# exists' (#94 round-1, all three reviewers). The timeout path must probe the
# instance, tell the two stories apart, and best-effort delete either way so
# the retry advice is safe in both worlds.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the timeout path probes before claiming never-created (#94 r1)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "incus info" | grep -q "\$instance"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the timeout path best-effort deletes, so retry is always clean" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "incus delete --force" | grep -q "|| true"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the overran-but-registered branch says so (not the wedge story)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "OVERRAN" | grep -q "budget"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: BOX_LAUNCH_TIMEOUT is documented in box help new" 0 "" bash -c '
  "'"$ROOT"'/bin/box" help new | grep "BOX_LAUNCH_TIMEOUT" | grep -q 600'
# staging-box's creds-holding join stays OPERATOR-run: cmd_new may print it as
# a next step, but no template and no code path auto-runs "rig bootstrap
# workload-server" — the one absence that keeps box creds-free end to end.
check "new: the workload join is printed, never exec'd" 1 "" bash -c '
  grep "rig bootstrap workload-server" "'"$ROOT"'/bin/box" | grep -q "incus exec"'
check "templates: no template names a creds-holding role" 1 "" bash -c '
  grep -h "^BOX_BOOTSTRAP_ROLE=" "'"$ROOT"'"/templates/*/box.env | grep -qE "workload|host|custom"'

# ---------------------------------------------------------------------------
# The 'pristine' mark (#104, child of heavy-duty/rig#62). The whole feature is
# a MOMENT: the guest after cloud-init and before rig converges anything. Get
# the position wrong by one step and the mark is a lie — a 'pristine' taken
# after 'rig bootstrap' is a converged box wearing the wrong label, and
# nothing at runtime would ever say so. So the position is pinned by line
# order, the way the other mint-path guards are (a daemon-free run cannot
# mint), and the policy half is DRIVEN against a stubbed incus.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "pristine: the mark is taken in the fresh-mint branch" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "snapshot_pristine \"\$instance\""'
# AFTER cloud-init: before it, the guest is mid-install and the mark is not
# pristine Debian, it is a half-provisioned one.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "pristine: the mark orders AFTER the cloud-init wait" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  wait="$(printf "%s\n" "$fn" | grep -n "cloud-init status --wait" | head -1 | cut -d: -f1)"
  snap="$(printf "%s\n" "$fn" | grep -n "snapshot_pristine " | head -1 | cut -d: -f1)"
  [ -n "$wait" ] && [ -n "$snap" ] && [ "$wait" -lt "$snap" ]'
# BEFORE the rig hook: this is the assertion the whole issue rests on.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "pristine: the mark orders BEFORE the rig bootstrap hook (the moment)" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  snap="$(printf "%s\n" "$fn" | grep -n "snapshot_pristine " | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "incus exec.*rig bootstrap.*\$T_BOOTSTRAP_ROLE" | head -1 | cut -d: -f1)"
  [ -n "$snap" ] && [ -n "$run" ] && [ "$snap" -lt "$run" ]'
# NOT under the T_BOOTSTRAP_ROLE guard: a blank box has no rig hook but has
# the same pristine moment, and "box restore <box> pristine" must mean one
# thing on every box box mints.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "pristine: the mark is unconditional, not gated on a tenant role" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  snap="$(printf "%s\n" "$fn" | grep -n "snapshot_pristine " | head -1 | cut -d: -f1)"
  guard="$(printf "%s\n" "$fn" | grep -n "if \[ -n \"\$T_BOOTSTRAP_ROLE\" \]" | head -1 | cut -d: -f1)"
  [ -n "$snap" ] && [ -n "$guard" ] && [ "$snap" -lt "$guard" ]'

# THE CLONE TRAP. --from skips cloud-init and the rig hook entirely, so the
# pristine moment never happens on that path. A mark taken there would be
# "whatever the source was" — converged, worked-in — wearing a label that
# promises pristine Debian, which is strictly worse than no mark. Pin the
# ABSENCE: extract the clone branch alone (up to its 'else') and assert
# nothing in it takes the mark.
CLONEBR="$(mktemp)"
awk '/if \[ -n "\$from" \]; then/,/^  else$/' "$ROOT/bin/box" > "$CLONEBR"
check "pristine: the clone branch extracted from bin/box (guards the awk)" 0 "incus copy" cat "$CLONEBR"
check "pristine: a --from clone takes NO mark of its own (the correctness trap)" 1 "" \
  grep -q "snapshot_pristine" "$CLONEBR"
check "pristine: nothing on the clone path creates a snapshot at all" 1 "" \
  grep -q "incus snapshot create" "$CLONEBR"
# Inheritance is the other half of the decision, and it must be SAID: a clone
# of a box carries the source's snapshots (a real pristine among them), a
# clone of a snapshot carries none. Silence there sends the operator to
# 'box info' to find out which world they are in.
check "pristine: the clone narrates whether a pristine rode along" 0 "" \
  grep -q "no 'pristine' mark here" "$CLONEBR"
# ...and it reads the snapshot list CAPTURE-FIRST (#124's class). Piping a
# multi-line incus writer into an early-exit reader lets the reader close the
# pipe, SIGPIPE incus, and hand pipefail a 141 — which on THIS line reads as
# "no pristine" and narrates the wrong inheritance shape on a clone that has
# one. Pin the shape, not the instance spelling: no 'incus snapshot list'
# feeding grep/head/sed/awk/read directly.
check "pristine: the clone's inheritance read is capture-first, not a piped early-exit reader" 1 "" \
  grep -Eq 'incus snapshot list[^|]*\| *(grep|head|sed|awk|read)' "$CLONEBR"
rm -f "$CLONEBR"

# The policy half, DRIVEN not grepped: extract storage_driver +
# snapshot_pristine and run them against a stubbed incus, so every branch is
# actually executed on a host with no daemon.
PRISFN="$(mktemp)"
awk '/^storage_driver\(\) \{/,/^\}/;/^snapshot_mark\(\) \{/,/^\}/;/^snapshot_pristine\(\) \{/,/^\}/' "$ROOT/bin/box" > "$PRISFN"
check "pristine: the functions extracted from bin/box (guards the awk)" 0 "BOX_SNAPSHOT_PRISTINE" cat "$PRISFN"
check "pristine: the extracted functions are valid bash" 0 "" bash -n "$PRISFN"

# storage_driver's probes must survive a REFUSAL, and not by accident. Today
# command substitution strips errexit, so a failing probe falls through to the
# fallback; add 'shopt -s inherit_errexit' to bin/box — the robustness tweak
# #107 describes sailing through review — and under pipefail that same refusal
# becomes a fatal abort mid-mint, inside the function whose contract is NEVER
# fatal. Drive it with inherit_errexit ON and a tier that refuses both probes:
# the function must return empty (the unreadable-pool case) and the caller
# must still be alive afterwards.
driver_under_inherit_errexit() {
  # shellcheck disable=SC2016  # the body is the stub's source, expanded by the
  # inner bash, never by this shell.
  env PRISFN="$PRISFN" bash -c '
    set -euo pipefail
    shopt -s inherit_errexit
    incus() {
      case "$*" in
        "profile device get box-net root pool") printf "boxpool\n" ;;
        *) printf "incus: not authorized\n" >&2; return 1 ;;
      esac
    }
    . "$PRISFN"
    d="$(storage_driver)"
    printf "SURVIVED driver=[%s]\n" "$d"
  ' 2>&1
}
check "pristine: a refused storage probe is an answer, not a fatal (survives inherit_errexit)" 0 "SURVIVED driver=[]" \
  driver_under_inherit_errexit

# pris <driver> [env...] — drive snapshot_pristine against a fake pool of
# <driver>. 'none' makes both probes answer nothing (the unreadable-pool
# case). Every incus call the function can make is stubbed and echoed, so the
# assertions read the real control flow, not a mock's opinion of it.
pris() { # pris <driver> <instance> [VAR=VAL...]
  local driver="$1" instance="$2"; shift 2
  # shellcheck disable=SC2016  # the body is the stub's source, expanded by the
  # inner bash from the environment 'env' sets up — never by this shell.
  env "$@" DRIVER="$driver" INSTANCE="$instance" PRISFN="$PRISFN" bash -c '
    incus() {
      case "$*" in
        "profile device get box-net root pool") printf "boxpool\n" ;;
        "storage show boxpool")
          [ "$DRIVER" = none ] && return 1
          printf "name: boxpool\ndriver: %s\n" "$DRIVER" ;;
        "storage list --format csv")
          [ "$DRIVER" = none ] && return 1
          printf "boxpool,%s,,0,CREATED\n" "$DRIVER" ;;
        "snapshot create inst-x pristine") printf "STUB: snapshot created\n" ;;
        "snapshot create fail-x pristine") printf "STUB: incus refused\n" >&2; return 1 ;;
        *) printf "STUB: unexpected incus call: %s\n" "$*" >&2; return 1 ;;
      esac
    }
    . "$PRISFN"
    snapshot_pristine "$INSTANCE" boxname
  ' 2>&1
}
# The absence assertions need a command 'check' can run, not a pipeline.
pris_took_mark() { pris "$@" | grep -q "STUB: snapshot created"; }
check "pristine: btrfs (the designed backend) takes the mark" 0 "STUB: snapshot created" \
  pris btrfs inst-x
check "pristine: btrfs names the restore command for the operator" 0 "box restore boxname pristine" \
  pris btrfs inst-x
# The 'dir' fallback (host/setup-host.sh:294) has no CoW: the mark would be a
# full multi-GB copy of the root on EVERY mint. Skip — and LOUDLY, naming the
# by-hand command, because a silent skip teaches an operator to expect a mark
# that is not there.
check "pristine: a 'dir' pool SKIPS the mark (no CoW — it would be a full copy)" 0 "NOT taking" \
  pris dir inst-x
check "pristine: the dir skip is loud and names the by-hand command" 0 "box snapshot boxname pristine" \
  pris dir inst-x
check "pristine: the dir skip never reaches incus snapshot create" 1 "" \
  pris_took_mark dir inst-x
# Neither probe answers (an unusual host, or a tier that cannot read the
# pool). The two mistakes are not symmetric — a mark taken on 'dir' wastes
# disk the operator can see and delete, a mark NOT taken is the moment gone
# for good. So proceed, and say what was assumed.
check "pristine: an unreadable pool takes the mark anyway (the asymmetry)" 0 "STUB: snapshot created" \
  pris none inst-x
check "pristine: ...and says what it assumed rather than pretending it knew" 0 "could not read the storage driver" \
  pris none inst-x
# The escape hatch is an environment knob (the BOX_LAUNCH_TIMEOUT shape), not
# another flag on 'new'.
check "pristine: BOX_SNAPSHOT_PRISTINE=0 skips it anywhere" 0 "BOX_SNAPSHOT_PRISTINE=0" \
  pris btrfs inst-x BOX_SNAPSHOT_PRISTINE=0
check "pristine: the opt-out never reaches incus snapshot create" 1 "" \
  pris_took_mark btrfs inst-x BOX_SNAPSHOT_PRISTINE=0
# A failed snapshot must NOT fail the mint. The mark is an undo, not the
# mint's product: a mint that worked must not be failed by a checkpoint that
# didn't.
check "pristine: a failed snapshot warns and returns 0 (never fails a good mint)" 0 "WARNING" \
  pris btrfs fail-x
rm -f "$PRISFN"

# The durability caveat, pinned in the help text: a snapshot dies with its
# box, so nothing box says may let anyone read 'pristine' as a backup (#104's
# closing note; 'box export' is the durable path).
check "pristine: 'box help snapshot' refuses to sell snapshots as backups" 0 "not a backup" \
  bash -c '"'"$ROOT"'/bin/box" help snapshot'
check "pristine: 'box help restore' documents the mark and its off-box blind spot" 0 "off-box" \
  bash -c '"'"$ROOT"'/bin/box" help restore'
check "pristine: 'box help new' documents the mark and the opt-out" 0 "BOX_SNAPSHOT_PRISTINE" \
  bash -c '"'"$ROOT"'/bin/box" help new'

# ---------------------------------------------------------------------------
# The 'bootstrapped' mark (#130, the deferred half of #104). Where 'pristine'
# marks a MOMENT every fresh mint has, this marks an EVENT: a rig hook box ran
# and WATCHED SUCCEED. So the two load-bearing facts are opposite in shape —
# 'pristine' is pinned as unconditional, this one is pinned as gated, and the
# gate is what keeps the label from asserting a convergence that never
# happened. Position and gating are pinned by line order (a daemon-free run
# cannot mint); the policy half is DRIVEN against a stubbed incus, exactly as
# the pristine block above drives it.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "bootstrapped: the mark is taken in the fresh-mint branch" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "snapshot_bootstrapped \"\$instance\""'
# AFTER the hook: a mark taken before it would be 'pristine' under a name that
# claims convergence — the same lie #104 refused on the clone path.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "bootstrapped: the mark orders AFTER the rig bootstrap hook" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  run="$(printf "%s\n" "$fn" | grep -Fn "rig bootstrap \"\$T_BOOTSTRAP_ROLE\" --user \"\$T_USER\"" | head -1 | cut -d: -f1)"
  snap="$(printf "%s\n" "$fn" | grep -n "snapshot_bootstrapped " | head -1 | cut -d: -f1)"
  [ -n "$run" ] && [ -n "$snap" ] && [ "$run" -lt "$snap" ]'
# GATED on T_BOOTSTRAP_ROLE — the blank-template asymmetry, chosen. A hookless
# box has no convergence to mark; marking one anyway would either duplicate
# 'pristine' byte for byte at twice the disk cost or assert an event that did
# not happen. This is the exact inverse of the pristine guard above, and both
# must hold at once.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "bootstrapped: the mark IS gated on a tenant role (the blank asymmetry)" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  guard="$(printf "%s\n" "$fn" | grep -n "if \[ -n \"\$T_BOOTSTRAP_ROLE\" \]" | head -1 | cut -d: -f1)"
  snap="$(printf "%s\n" "$fn" | grep -n "snapshot_bootstrapped " | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$snap" ] && [ "$guard" -lt "$snap" ]'
# NOT after a FAILED hook. The failure branch ends in a 'die', so the mark is
# unreachable from it — pinned by asserting the mark sits after that die, i.e.
# on the far side of a branch that never returns.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "bootstrapped: a FAILED hook dies before ever reaching the mark" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  d="$(printf "%s\n" "$fn" | grep -n "die \"the tenant role did not converge" | head -1 | cut -d: -f1)"
  snap="$(printf "%s\n" "$fn" | grep -n "snapshot_bootstrapped " | head -1 | cut -d: -f1)"
  [ -n "$d" ] && [ -n "$snap" ] && [ "$d" -lt "$snap" ]'
# ...and the operator is HANDED the command at the one moment they are
# looking. This is the answer to the sharpest objection in #130: the mark is
# absent exactly on the boxes whose convergence needed intervention, so the
# failure path must name the by-hand command rather than leave a silent hole.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "bootstrapped: the hook-failure message hands over the by-hand command" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -q "box snapshot \$name bootstrapped"'
# The clone branch takes neither mark. Reuses #104's extraction shape.
CLONEBR2="$(mktemp)"
awk '/if \[ -n "\$from" \]; then/,/^  else$/' "$ROOT/bin/box" > "$CLONEBR2"
check "bootstrapped: the clone branch extracted from bin/box (guards the awk)" 0 "incus copy" cat "$CLONEBR2"
check "bootstrapped: a --from clone takes no 'bootstrapped' either" 1 "" \
  grep -q "snapshot_bootstrapped" "$CLONEBR2"
rm -f "$CLONEBR2"

# The never-fatal contract lives ONCE. Two marks share one policy function on
# purpose: the failure handling is the part that must not be got subtly
# different in two places. If a future change copy-pastes the policy instead of
# calling it, this bites. (The other create is cmd_snapshot's, the by-hand
# verb, which is deliberately fatal — an explicit 'box snapshot' that fails
# must fail.)
check "bootstrapped: exactly one auto-mark policy — 'incus snapshot create' twice in bin/box" 0 "2" \
  bash -c 'grep -c "incus snapshot create" "'"$ROOT"'/bin/box"'

# The policy half, DRIVEN. Same stub shape as pris() above, one label over.
BOOTFN="$(mktemp)"
awk '/^storage_driver\(\) \{/,/^\}/;/^snapshot_mark\(\) \{/,/^\}/;/^mark_taken\(\)/;/^snapshot_bootstrapped\(\) \{/,/^\}/' \
  "$ROOT/bin/box" > "$BOOTFN"
check "bootstrapped: the functions extracted from bin/box (guards the awk)" 0 "snapshot_bootstrapped" cat "$BOOTFN"
check "bootstrapped: the extracted functions are valid bash" 0 "" bash -n "$BOOTFN"

boot() { # boot <driver> <instance> [VAR=VAL...]
  local driver="$1" instance="$2"; shift 2
  # shellcheck disable=SC2016  # the body is the stub's source, expanded by the
  # inner bash from the environment 'env' sets up — never by this shell.
  env "$@" DRIVER="$driver" INSTANCE="$instance" BOOTFN="$BOOTFN" bash -c '
    incus() {
      case "$*" in
        "profile device get box-net root pool") printf "boxpool\n" ;;
        "storage show boxpool")
          [ "$DRIVER" = none ] && return 1
          printf "name: boxpool\ndriver: %s\n" "$DRIVER" ;;
        "storage list --format csv")
          [ "$DRIVER" = none ] && return 1
          printf "boxpool,%s,,0,CREATED\n" "$DRIVER" ;;
        "snapshot create inst-x bootstrapped") printf "STUB: snapshot created\n" ;;
        "snapshot create fail-x bootstrapped") printf "STUB: incus refused\n" >&2; return 1 ;;
        *) printf "STUB: unexpected incus call: %s\n" "$*" >&2; return 1 ;;
      esac
    }
    . "$BOOTFN"
    snapshot_bootstrapped "$INSTANCE" boxname
  ' 2>&1
}
boot_took_mark() { boot "$@" | grep -q "STUB: snapshot created"; }
check "bootstrapped: btrfs (the designed backend) takes the mark" 0 "STUB: snapshot created" \
  boot btrfs inst-x
check "bootstrapped: btrfs names the restore command for the operator" 0 "box restore boxname bootstrapped" \
  boot btrfs inst-x
# The 'dir' skip, and with two marks the disk objection is twice the size: a
# CoW-less host must not be asked to pay for one full root copy per mint, let
# alone two. Same refusal, same loudness, same by-hand command.
check "bootstrapped: a 'dir' pool SKIPS the mark (no CoW — it would be a full copy)" 0 "NOT taking" \
  boot dir inst-x
check "bootstrapped: the dir skip is loud and names the by-hand command" 0 "box snapshot boxname bootstrapped" \
  boot dir inst-x
check "bootstrapped: the dir skip never reaches incus snapshot create" 1 "" \
  boot_took_mark dir inst-x
check "bootstrapped: an unreadable pool takes the mark anyway (the asymmetry)" 0 "STUB: snapshot created" \
  boot none inst-x
check "bootstrapped: ...and says what it assumed rather than pretending it knew" 0 "could not read the storage driver" \
  boot none inst-x
check "bootstrapped: BOX_SNAPSHOT_BOOTSTRAPPED=0 skips it anywhere" 0 "BOX_SNAPSHOT_BOOTSTRAPPED=0" \
  boot btrfs inst-x BOX_SNAPSHOT_BOOTSTRAPPED=0
check "bootstrapped: the opt-out never reaches incus snapshot create" 1 "" \
  boot_took_mark btrfs inst-x BOX_SNAPSHOT_BOOTSTRAPPED=0
# The opt-out knob name is DERIVED from the label, so the message can never
# drift from the variable an operator actually has to set — and one label's
# knob must not silently disable the other's.
check "bootstrapped: the opt-out is a per-label knob — PRISTINE=0 does not silence it" 0 "" \
  boot_took_mark btrfs inst-x BOX_SNAPSHOT_PRISTINE=0
check "bootstrapped: a failed snapshot warns and returns 0 (never fails a good mint)" 0 "WARNING" \
  boot btrfs fail-x

# --- only offer a rollback that EXISTS -------------------------------------
# The never-fatal contract means snapshot_mark returns 0 whether it took the
# mark, skipped it, or was refused — so the exit status cannot answer "is
# there something to restore?" and any message offering one must ask 'marks'.
# Driven per path rather than asserted once: the three no-mark paths fail
# differently and a single case would let the other two regress silently.
took() { # took <driver> <label> [VAR=VAL...] — did THIS run create the mark?
  local driver="$1" label="$2"; shift 2
  # shellcheck disable=SC2016  # the body is the stub's source, expanded by the
  # inner bash from the environment 'env' sets up — never by this shell.
  env "$@" DRIVER="$driver" LABEL="$label" BOOTFN="$BOOTFN" bash -c '
    incus() {
      case "$*" in
        "profile device get box-net root pool") printf "boxpool\n" ;;
        "storage show boxpool")
          [ "$DRIVER" = none ] && return 1
          printf "name: boxpool\ndriver: %s\n" "$DRIVER" ;;
        "storage list --format csv")
          [ "$DRIVER" = none ] && return 1
          printf "boxpool,%s,,0,CREATED\n" "$DRIVER" ;;
        "snapshot create fail-x "*) return 1 ;;
        "snapshot create "*) printf "STUB: snapshot created\n" ;;
        *) return 1 ;;
      esac
    }
    marks=""
    . "$BOOTFN"
    snapshot_mark "$INSTANCE_X" boxname "$LABEL" "${ENABLED:-1}" "some state" >/dev/null 2>&1
    mark_taken "$LABEL" && echo TAKEN || echo ABSENT
  ' 2>&1
}
check "rollback: a mark that WAS created is remembered" 0 "TAKEN" \
  took btrfs pristine INSTANCE_X=inst-x
check "rollback: a 'dir' skip is NOT remembered (no CoW, no mark)" 0 "ABSENT" \
  took dir pristine INSTANCE_X=inst-x
check "rollback: the opt-out knob is NOT remembered" 0 "ABSENT" \
  took btrfs pristine INSTANCE_X=inst-x ENABLED=0
check "rollback: a REFUSED create is not remembered (incus said no)" 0 "ABSENT" \
  took btrfs pristine INSTANCE_X=fail-x
# One label's mark must not answer for another's.
check "rollback: marks do not bleed between labels" 0 "ABSENT" \
  bash -c 'marks=" bootstrapped "; . "'"$BOOTFN"'"; mark_taken pristine && echo TAKEN || echo ABSENT'
# The call site itself, pinned statically: the hook-failure message offers the
# restore only under the guard. On a 'dir' host EVERY hook failure reaches this
# line with no pristine mark, so an unconditional offer is a copy-pasteable
# command that errors at the one moment the operator is standing there.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "rollback: the hook-failure restore offer is GATED on the mark existing" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -B12 "box restore \$name pristine. is still there" \
    | grep -q "if mark_taken pristine; then"'
rm -f "$BOOTFN"

# The label is one-directional and the docs must say so: its PRESENCE means the
# hook converged untouched, its ABSENCE means nothing at all. Without that
# sentence a missing mark reads as "unconverged", which is exactly the false
# coverage #130 warns about.
check "bootstrapped: 'box help restore' refuses to let absence imply anything" 0 "absence proves NOTHING" \
  bash -c '"'"$ROOT"'/bin/box" help restore'
check "bootstrapped: 'box help restore' repeats the off-box blind spot for it too" 0 "cannot undo anything" \
  bash -c '"'"$ROOT"'/bin/box" help restore'
check "bootstrapped: 'box help new' documents the mark and the opt-out" 0 "BOX_SNAPSHOT_BOOTSTRAPPED" \
  bash -c '"'"$ROOT"'/bin/box" help new'
check "bootstrapped: 'box help snapshot' names the by-hand fallback" 0 "box snapshot work bootstrapped" \
  bash -c '"'"$ROOT"'/bin/box" help snapshot'

# ---------------------------------------------------------------------------
# The restricted tier (#74). box_tier() is the decision the whole tier hangs
# on, so it is DRIVEN, not grepped: extracted from bin/box, sourced, and run
# against a shim id for every case — including the one that bites (a user in
# BOTH groups is admin: membership wins at the socket, and the function must
# not substring-match 'incus' inside 'incus-admin').
# ---------------------------------------------------------------------------
TIERFN="$(mktemp)"
awk '/^box_tier\(\) \{/,/^\}/' "$ROOT/bin/box" > "$TIERFN"
check "box_tier: extracted from bin/box (guards the awk)" 0 "incus-admin" cat "$TIERFN"
check "box_tier: the extracted function is valid bash"    0 "" bash -n "$TIERFN"

tier() { # tier <uid> <groups...>
  local uid="$1"; shift
  FAKE_UID="$uid" FAKE_GROUPS="$*" PATH="$SHIMDIR:$PATH" \
    bash -c ". '$TIERFN'; box_tier"
}
check "box_tier: uid 0 → admin"                    0 "admin"      tier 0
check "box_tier: incus-admin → admin"              0 "admin"      tier 1000 "users incus-admin"
check "box_tier: incus only → restricted"          0 "restricted" tier 1000 "users incus"
check "box_tier: both groups → admin (membership wins at the socket)" \
                                                    0 "admin"      tier 1000 "users incus incus-admin"
check "box_tier: neither → none"                   0 "none"       tier 1000 "users dialout"
rm -f "$TIERFN"

# setup-host.sh must decide the tier BEFORE any install tree exists, so it
# carries its own copy — and a drifted copy is two tiers pretending to be one.
# Byte-identical, asserted.
BINFN="$(mktemp)"; HOSTFN="$(mktemp)"
awk '/^box_tier\(\) \{/,/^\}/' "$ROOT/bin/box"            > "$BINFN"
awk '/^box_tier\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$HOSTFN"
check "box_tier: bin/box and setup-host.sh copies are byte-identical" 0 "" \
  diff "$BINFN" "$HOSTFN"
rm -f "$BINFN" "$HOSTFN"

# The tier scripts parse and refuse bad usage without a daemon — drive them.
check "grant: no argument is a usage error"      2 "usage: box grant"  bash "$ROOT/host/grant-user.sh"
check "grant: a flag is not a user"              2 "usage: box grant"  bash "$ROOT/host/grant-user.sh" --frob
check "revoke: no argument is a usage error"     2 "usage: box revoke" bash "$ROOT/host/revoke-user.sh"
check "revoke: two users is a usage error"       2 "usage: box revoke" bash "$ROOT/host/revoke-user.sh" a b
check "box grant with no user exits 2 (via the CLI table)"  2 "usage: box grant"  "$BOX" grant
check "box revoke with no user exits 2 (via the CLI table)" 2 "usage: box revoke" "$BOX" revoke
check "help grant names the hardened network" 0 "boxnet" "$BOX" help grant
check "help revoke names --purge"             0 "purge"  "$BOX" help revoke

# The help is the PRE-RUN CONTRACT: an operator reads it to decide whether to
# run the command at all, so it must not promise a mutation that will not
# happen (or deny one that will). Round 1 of #101 changed what grant/revoke
# mutate for an incus-admin member and left this prose describing the
# superseded design — these pins are why that cannot happen silently again.
# Both directions: the current sentence must be present, and the superseded
# one must be gone.
check "help grant: the admin member's group step is a real add, not a no-op" \
  0 "like anyone else" "$BOX" help grant
check "help revoke: a bare revoke of a granted admin member is 'partial:'" \
  0 "partial:" "$BOX" help revoke
check "help grant no longer calls the admin group step a no-op" 0 "" \
  bash -c '! "'"$BOX"'" help grant | grep -q "reported no-op"'
check "help revoke no longer claims there is no membership to drop" 0 "" \
  bash -c '! "'"$BOX"'" help revoke | grep -q "no membership to drop"'

# Load-bearing lines a daemon-free run cannot exercise — grepped so a deleted
# guard cannot ship green (the house test discipline).
# The expose guard must fire before ANY incus call in cmd_expose: line order.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "expose: the restricted guard precedes the first incus call" 0 "" bash -c '
  fn="$(awk "/^cmd_expose\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  guard="$(printf "%s\n" "$fn" | grep -n "box_tier" | head -1 | cut -d: -f1)"
  first="$(printf "%s\n" "$fn" | grep -n "incus config" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$first" ] && [ "$guard" -lt "$first" ]'
# cmd_new refuses before minting when the placement contract is absent, and
# the message is tier-aware (a restricted user is sent to 'box grant', not
# to setup-host they cannot run). The pre-flight lives in require_stack()
# since #70 gave it a second caller (import lands on the same contract), so
# assert both halves: the helper holds the probe, and cmd_new calls it.
check "require_stack: probes the box-net profile" 0 "" bash -c '
  awk "/^require_stack\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "incus profile show box-net"'
check "require_stack: the restricted fix names box grant" 0 "" bash -c '
  awk "/^require_stack\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "box grant"'
check "new: pre-flights the stack (require_stack)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "require_stack"'
# grant converges to boxnet and ONLY boxnet — "boxnet,incusbr" would keep the
# unhardened private bridge one --network flag away (the #74 measured hole).
check "grant: narrows access to boxnet alone" 0 "" \
  grep -qE 'restricted\.networks\.access boxnet($| )' "$ROOT/host/grant-user.sh"
check "grant: never grants the private bridge" 1 "" \
  grep -qE 'networks\.access[^#]*incusbr' "$ROOT/host/grant-user.sh"
check "grant: allows snapshots (the clone workflow)" 0 "" \
  grep -qF 'restricted.snapshots allow' "$ROOT/host/grant-user.sh"
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "grant: installs the SHIPPED profile into the project" 0 "" \
  grep -qF 'profile edit box-net < "$here/profiles/box-net.yaml"' "$ROOT/host/grant-user.sh"
check "grant: unpins the private-bridge eth0 from the default profile" 0 "" \
  grep -qF 'profile device remove default eth0' "$ROOT/host/grant-user.sh"
check "grant: an incus-admin member is provisioned, not refused (#99)" 1 "" \
  grep -qF 'there is nothing tighter to grant' "$ROOT/host/grant-user.sh"
check "revoke: group removal is the lockout" 0 "" \
  grep -qF 'gpasswd -d' "$ROOT/host/revoke-user.sh"
# Group membership is read at login: purge must terminate live sessions (a
# stale-group process could recreate the project unhardened AFTER the purge),
# and a bare revoke must say the socket survives in held sessions.
check "revoke: purge terminates live sessions first" 0 "" \
  grep -qF 'loginctl terminate-user' "$ROOT/host/revoke-user.sh"
check "revoke: purge refuses under unkillable sessions" 0 "" \
  grep -qF 'refusing to purge under them' "$ROOT/host/revoke-user.sh"
check "revoke: bare revoke warns about held sessions" 0 "" \
  grep -qF 'live sessions' "$ROOT/host/revoke-user.sh"
check "revoke: the purge asserts the certificate's absence too" 0 "" \
  bash -c 'awk "/Assert absence/,0" "'"$ROOT"'/host/revoke-user.sh" | grep -q "config trust list"'
# A failed grant must not leave a half-granted user: if THIS run added the
# group, the exit path takes it back (and the trap disarms only on success).
check "grant: backs out its own group-add on failure" 0 "" \
  grep -qF 'trap backout EXIT' "$ROOT/host/grant-user.sh"
check "grant: the back-out disarms on success" 0 "" \
  grep -qF 'trap - EXIT' "$ROOT/host/grant-user.sh"
# The backout must VERIFY the removal and scream when it cannot — an
# unverified rollback printing a security guarantee is the review's A2.
check "grant: the backout verifies against the group database" 0 "" \
  bash -c 'awk "/^backout\(\) \{/,/^\}/" "'"$ROOT"'/host/grant-user.sh" | grep -q "id -nG"'
check "grant: an unverifiable rollback screams" 0 "" \
  grep -qF 'ROLLBACK INCOMPLETE' "$ROOT/host/grant-user.sh"
check "grant: a failed re-grant warns the pre-existing member is untouched" 0 "" \
  grep -qF 'still holding socket access' "$ROOT/host/grant-user.sh"
check "grant: the mid-grant login window is named" 0 "" \
  bash -c 'awk "/^backout\(\) \{/,/^\}/" "'"$ROOT"'/host/grant-user.sh" | grep -q "loginctl terminate-user"'
# The scoped guarantee (raw --network boxnet) is measured, not prose:
check "rehearsal: measures the raw boxnet attach (criterion m)" 0 "" \
  grep -qF -- '--network boxnet' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "rehearsal: injects grant failures (criterion n)" 0 "" \
  grep -qF 'grant-user.sh" "$U3"' "$ROOT/drill/multiuser.sh"
# Criterion o is the real-Incus half of #101: the shim cannot model an EACCES
# on the user socket, so the admin-only grant is measured where the socket has
# a real owning group. Pinned so it cannot quietly leave the rehearsal.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "rehearsal: grants an incus-admin-ONLY member on real Incus (criterion o)" 0 "" \
  grep -qF 'usermod -aG incus-admin "$U5"' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # ditto
check "rehearsal: ...and opens the user socket as them, not just the daemon" 0 "" \
  grep -qF 'INCUS_SOCKET="$sockdir/unix.socket.user"' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "revoke: purge deletes instances one at a time" 0 "" \
  grep -qF 'delete -f "$inst"' "$ROOT/host/revoke-user.sh"
check "revoke: purge removes the trust-store certificate" 0 "" \
  grep -qF 'config trust remove' "$ROOT/host/revoke-user.sh"

# ---------------------------------------------------------------------------
# #99: an incus-admin member is PROVISIONED, not refused. The distinction the
# old refusal missed is permission (the 'incus' group — theirs already, and
# stronger) versus provisioning (the user-<uid> project, the boxnet narrowing,
# snapshots, backups, the box-net profile — theirs not at all). Grepping the
# new prose would prove only that the prose exists, so both tier scripts are
# DRIVEN end to end under shims, the same seam setup-host is driven through:
# every incus and sudo call is logged, and the assertions are made against
# those logs — what the run did, not what the source says it would do.
# ---------------------------------------------------------------------------
GSHIM="$(mktemp -d)"; W99="$(mktemp -d)"
cat > "$GSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the driven grant/revoke: logs every call, answers the
# existence probes from FAKE_*, and models the two state changes the scripts
# depend on — the project appearing after the incus-user touch, and
# disappearing after a purge deletes it.
[ -n "${FAKE_INCUS_LOG:-}" ] && printf 'incus %s\n' "$*" >> "$FAKE_INCUS_LOG"
case "$*" in *"profile edit"*) cat >/dev/null ;; esac
case "$*" in
  "network show boxnet")  [ -n "${FAKE_HAVE_BOXNET:-}" ] || exit 1 ;;
  "project show "*)
    [ -e "$FAKE_STATE/deleted" ] && exit 1
    if [ -n "${FAKE_PROJECT_LAZY:-}" ]; then
      # Lazy creation: absent on the first look, present afterwards — i.e.
      # the touch worked. n counts the looks this run has taken.
      n=0; [ -e "$FAKE_STATE/looks" ] && n="$(cat "$FAKE_STATE/looks")"
      printf '%s\n' "$((n + 1))" > "$FAKE_STATE/looks"
      [ "$n" -ge 1 ] || exit 1
    else
      [ -n "${FAKE_HAVE_PROJECT:-}" ] || exit 1
    fi ;;
  "project delete "*) : > "$FAKE_STATE/deleted" ;;
  *"restricted.networks.access"*)
    [ -z "${FAKE_FAIL_NARROW:-}" ] || { echo 'Instance "old" is on incusbr-1000' >&2; exit 1; } ;;
  *"network show "*) exit 1 ;;   # the private bridge: never there in these runs
esac
exit 0
SHIM
cat > "$GSHIM/sudo" <<'SHIM'
#!/usr/bin/env bash
# Fake sudo: logs and swallows — EXCEPT 'sudo test', which is run for real.
# Both scripts route filesystem probes through it on purpose (/var/lib/incus
# is not traversable by a non-root admin, so an unprivileged stat lies), and
# both directions matter here: revoke's absence assert must see incus-user's
# state directory as genuinely absent on a clean machine, and grant's socket
# check must see the shimmed unix.socket.user as genuinely present.
[ -n "${FAKE_SUDO_LOG:-}" ] && printf 'sudo %s\n' "$*" >> "$FAKE_SUDO_LOG"
case "${1:-}" in test) shift; test "$@"; exit $? ;; esac
exit 0
SHIM
printf '#!/usr/bin/env bash\nexit 0\n'                > "$GSHIM/getent"
printf '#!/usr/bin/env bash\nexit 0\n'                > "$GSHIM/systemctl"
printf '#!/usr/bin/env bash\nexit 1\n'                > "$GSHIM/pgrep"
chmod +x "$GSHIM/incus" "$GSHIM/sudo" "$GSHIM/getent" "$GSHIM/systemctl" "$GSHIM/pgrep"

# The pinned incus-user socket. box grant resolves it through INCUS_DIR (the
# client's own first choice), so a directory here is the whole seam.
mkdir -p "$W99/incusdir"; : > "$W99/incusdir/unix.socket.user"

rungrant() { # rungrant <groups> <state-dir> [VAR=val ...] — the real grant, shimmed
  local groups="$1" state="$2"; shift 2
  mkdir -p "$state"
  env FAKE_UID=1000 FAKE_GROUPS="$groups" FAKE_STATE="$state" \
      FAKE_HAVE_BOXNET=1 FAKE_PROJECT_LAZY=1 INCUS_DIR="$W99/incusdir" \
      FAKE_INCUS_LOG="$state/incus.log" FAKE_SUDO_LOG="$state/sudo.log" \
      PATH="$GSHIM:$SHIMDIR:$PATH" "$@" bash "$ROOT/host/grant-user.sh" dev1
}

# --- the admin member: full convergence, no group change, honest caveat -----
A="$W99/admin"
check "grant: an incus-admin member CONVERGES (exit 0, no refusal)" 0 "granted:" \
  rungrant "users incus-admin" "$A"
check "grant: ...and the group step is a real convergence, named as one" 0 "added dev1 to 'incus'" \
  rungrant "users incus-admin" "$W99/a2"
check "grant: ...saying WHY (the socket is a file, group 'incus', not a privilege)" 0 "mode 0660" \
  rungrant "users incus-admin" "$W99/a2b"
check "grant: ...the caveat calls it a default placement, not a confinement" 0 "DEFAULT PLACEMENT" \
  rungrant "users incus-admin" "$W99/a3"
check "grant: ...and names the group that has to go for it to bind" 0 "gpasswd -d dev1 incus-admin" \
  rungrant "users incus-admin" "$W99/a4"
# The logs: what the run actually did to the machine.
# #101's decision, pinned at the seam that broke: an incus-admin member IS
# usermod'ed into 'incus'. It buys them no API privilege they lack — but
# incus-user's socket is a FILE, group 'incus' mode 0660, and without the
# membership the pinned touch below takes EACCES, the '|| true' eats it, and
# the grant dies blaming a healthy incus-user. The shim cannot model that
# EACCES (it ignores INCUS_SOCKET and permissions entirely), so the decision
# is pinned here and MEASURED on real Incus in drill/multiuser.sh criterion o.
check "grant: the admin member IS added to 'incus' — the user socket's group (#101)" 0 "" \
  grep -qF 'usermod -aG incus dev1' "$A/sudo.log"
check "grant: their project is still narrowed to boxnet" 0 "" \
  grep -qF 'project set user-1000 restricted.networks.access boxnet' "$A/incus.log"
check "grant: their project still gets snapshots" 0 "" \
  grep -qF 'project set user-1000 restricted.snapshots allow' "$A/incus.log"
check "grant: their project still gets backups" 0 "" \
  grep -qF 'project set user-1000 restricted.backups allow' "$A/incus.log"
check "grant: box-net is still installed INTO their project" 0 "" \
  grep -qF -- '--project user-1000 profile edit box-net' "$A/incus.log"
# The socket pin (#99's teeth): incus's client takes the DAEMON socket when it
# is writable, and only falls back to unix.socket.user when it is not — so for
# an incus-admin member an unpinned touch never reaches incus-user at all, and
# the project it was supposed to create never appears.
check "grant: the touch is pinned at incus-user's socket (the admin socket would win)" 0 "" \
  grep -qF "INCUS_SOCKET=$W99/incusdir/unix.socket.user" "$A/sudo.log"
check "grant: the user-side proof names their project (an unqualified show proves nothing)" 0 "" \
  grep -qF -- '--project user-1000 profile show box-net' "$A/sudo.log"
# The socket existence probe rides $SUDO, like revoke's: /var/lib/incus is not
# traversable by a non-root admin, and a bare [ -e ] there false-fails into an
# exit that blames incus-user for a socket that is present (#101 review).
check "grant: the socket probe goes through sudo, not a bare [ -e ]" 0 "" \
  grep -qF "test -e $W99/incusdir/unix.socket.user" "$A/sudo.log"

# --- the restricted user: unchanged, and unpinned ---------------------------
R="$W99/restricted"
check "grant: a plain user is still added to 'incus'" 0 "added dev1 to 'incus'" \
  rungrant "users" "$R"
check "grant: ...via usermod (the log, not the prose)" 0 "" \
  grep -qF 'usermod -aG incus dev1' "$R/sudo.log"
check "grant: ...and their client is left to its own socket fallback" 1 "" \
  grep -qF 'INCUS_SOCKET' "$R/sudo.log"

# --- the failure path: what this run added comes back, and says what didn't --
F="$W99/failed"
check "grant: a failed grant for an admin member exits 1" 1 "FAILED" \
  rungrant "users incus-admin" "$F" FAKE_FAIL_NARROW=1
check "grant: ...says their admin socket was neither granted nor removed here" 1 "neither granted nor removed" \
  rungrant "users incus-admin" "$W99/f2" FAKE_FAIL_NARROW=1
# The membership IS this run's now, so the backout IS its business (#101).
check "grant: ...and DOES roll the 'incus' membership back (this run added it)" 0 "" \
  grep -qF 'gpasswd -d dev1 incus' "$F/sudo.log"
check "grant: ...while refusing to call that rollback a lockout" 1 "closed incus-user's socket, NOT" \
  rungrant "users incus-admin" "$W99/f3" FAKE_FAIL_NARROW=1

# --- revoke, the mirror: it cannot take what it never gave ------------------
# BOX_YES=1 throughout: --purge is destructive and refuses without a terminal
# to confirm on, and this suite has none. It changes nothing for a bare revoke.
runrevoke() { # runrevoke <groups> <state-dir> [script args...]
  local groups="$1" state="$2"; shift 2
  mkdir -p "$state"
  env FAKE_UID=1000 FAKE_GROUPS="$groups" FAKE_STATE="$state" BOX_YES=1 \
      FAKE_HAVE_PROJECT=1 FAKE_INCUS_LOG="$state/incus.log" FAKE_SUDO_LOG="$state/sudo.log" \
      PATH="$GSHIM:$SHIMDIR:$PATH" bash "$ROOT/host/revoke-user.sh" dev1 "$@"
}
# The granted admin member is in BOTH groups — that is what 'box grant' leaves
# behind now (#101) — so revoke has a real membership to take back. It takes
# it, and still refuses to call the result a lockout: 'incus-admin' holds the
# daemon and is not this script's to remove.
GRANTED="users incus incus-admin"
V="$W99/revoke"
check "revoke: a bare revoke of a granted admin member is 'partial', not 'revoked'" 0 "partial:" \
  runrevoke "$GRANTED" "$V"
check "revoke: ...and refuses to call it a lockout" 0 "is NOT locked out" \
  runrevoke "$GRANTED" "$W99/v2"
check "revoke: ...naming the group that would actually lock them out" 0 "gpasswd -d dev1 incus-admin" \
  runrevoke "$GRANTED" "$W99/v3"
# The mirror of grant's flip: there IS a privileged call now, and it is the
# membership grant added — asserted against the log, not the prose.
check "revoke: ...having actually dropped the 'incus' membership (the log)" 0 "" \
  grep -qF 'gpasswd -d dev1 incus' "$V/sudo.log"
check "revoke: ...calling that key incus-user's, not their daemon access" 0 "NOT their daemon access" \
  runrevoke "$GRANTED" "$W99/v4"
# An admin member who was never granted: nothing to take, and it still says so
# rather than reporting a revocation it did not perform.
N="$W99/revoke-ungranted"
check "revoke: an UNgranted admin member is still a named no-op" 0 "no-op:" \
  runrevoke "users incus-admin" "$N"
check "revoke: ...saying their access is incus-admin's, untouched here" 0 "which this does not touch" \
  runrevoke "users incus-admin" "$W99/n2"
# Absence of the LOG, not of a line in it: an ungranted admin member's bare
# revoke makes no privileged call whatsoever, so the file is never created.
check "revoke: ...having made NO privileged call at all (no membership to drop)" 1 "" \
  test -e "$N/sudo.log"
P="$W99/purge"
check "revoke --purge: still unmakes the provisioning" 0 "purged:" \
  runrevoke "$GRANTED" "$P" --purge
check "revoke --purge: ...and refuses to call an admin member 'out'" 0 "is NOT out" \
  runrevoke "$GRANTED" "$W99/p2" --purge
check "revoke --purge: ...the project really was deleted (the log, not the summary)" 0 "" \
  grep -qF 'project delete user-1000' "$P/incus.log"
rm -rf "$GSHIM" "$W99"
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "setup-host: the restricted gate precedes the sudo resolution" 0 "" bash -c '
  gate="$(grep -n "restricted tier" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  sudo="$(grep -n "^elif command -v sudo" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  [ -n "$gate" ] && [ -n "$sudo" ] && [ "$gate" -lt "$sudo" ]'
check "setup-host: enables incus-user.socket for the tier" 0 "" \
  grep -qF 'incus-user.socket' "$ROOT/host/setup-host.sh"
check "doctor: honors BOX_TIER" 0 "" \
  grep -qF 'BOX_TIER' "$ROOT/drill/doctor.sh"
check "box exports BOX_TIER to the doctor" 0 "" \
  grep -qF 'export BOX_TIER' "$ROOT/bin/box"
# 'box restore' must speak incus 6 ('snapshot restore'); bare 'incus restore'
# does not exist and the verb was broken for everyone until #74's rehearsal hit it.
check "restore: dispatches 'incus snapshot restore'" 0 "" \
  grep -qF '^incus:snapshot restore^' "$ROOT/bin/box"

# ---------------------------------------------------------------------------
# The confirm gate (#105) — DRIVEN, not grepped.
#
# Until #105 the only coverage restore had was the two argument-validation
# checks above: neither ever reached dispatch, so the verb spent four releases
# handing a running box straight to 'incus snapshot restore' with no prompt
# and no --force, and nothing in this suite could have noticed. Both halves of
# the gate are now exercised against a fake incus that logs what it was asked
# to do — refusing must leave the log EMPTY (an assertion about an absence is
# the only way to prove a gate held), and --force must produce the restore.
#
# Stdin is closed on every run on purpose: confirm() branches on '[ -t 0 ]',
# and a suite run from a terminal would otherwise inherit one and sit there
# waiting for a human to type 'y'.
# ---------------------------------------------------------------------------
CSHIM="$(mktemp -d)"; CWORK="$(mktemp -d)"
cat > "$CSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the destructive-path drive. Logs every call, and answers the
# one probe resolve_box makes so a box called 'work' exists and is ours.
[ -n "${FAKE_INCUS_LOG:-}" ] && printf 'incus %s\n' "$*" >> "$FAKE_INCUS_LOG"
case "$*" in
  "config get work user.box") echo 1 ;;
  "exec work -- bash -l")
    if [ "${FAKE_ROOT_STOPPED:-0}" = 1 ]; then
      echo "Error: Instance is not running" >&2
      exit 1
    fi ;;
  "config get "*)             exit 1 ;;
esac
exit 0
SHIM
chmod +x "$CSHIM/incus"

runbox() {  # runbox <logfile> <args...> — the real box, shimmed, no TTY
  local log="$1" rc; shift
  : > "$log"
  # Output is kept in <log>.out as well as replayed, so a check can assert on
  # what the run PRINTED after the fact — check() swallows the output of a run
  # it passes, and the "the prompt does not say 'delete'" assertion is exactly
  # that: a claim about text from a run that already passed on its exit code.
  env FAKE_INCUS_LOG="$log" PATH="$CSHIM:$PATH" "$BOX" "$@" </dev/null >"$log.out" 2>&1
  rc=$?
  cat "$log.out"
  return "$rc"
}

# --- root: a named host-authorized path that never depends on guest sudo ----
ROOTLOG="$CWORK/root.log"
check "root: help explains Incus-socket authorization" 0 "Authorization comes from the host's" \
  "$BOX" help root
check "root: help says guest sudo is not required" 0 "does not use or require sudo" \
  "$BOX" help root
check "root: dispatches a root login shell" 0 "" runbox "$ROOTLOG" root work
check "root: reaches Incus directly as root, without guest sudo" 0 "" \
  grep -qFx 'incus exec work -- bash -l' "$ROOTLOG"
check "root: a nonexistent box fails through the shared box guard" 1 "no such box" \
  runbox "$CWORK/root-missing.log" root missing
root_stopped() { FAKE_ROOT_STOPPED=1 runbox "$CWORK/root-stopped.log" root work; }
check "root: a stopped box preserves Incus's failure" 1 "Instance is not running" \
  root_stopped
# shellcheck disable=SC2016  # $inst and the command substitution are literal bin/box source.
check "root: shell implementation remains the tenant-user contract" 0 "" \
  grep -qFx 'cmd_shell() { incus exec "$inst" -- sudo -u "$(box_user "$inst")" -i; }' "$BOX"
check "root: live rehearsal removes the tenant sudoers entry" 0 "" \
  grep -qF 'box root precondition:' "$ROOT/drill/multiuser.sh"
check "root: live rehearsal measures tenant and root entry identities" 0 "" \
  grep -qF 'entry identities after removing' "$ROOT/drill/multiuser.sh"
check "root: live rehearsal refuses a foreign root shell" 0 "" \
  grep -qF 'cannot box root' "$ROOT/drill/multiuser.sh"

# --- restore: the gate refuses, and nothing is destroyed --------------------
RLOG="$CWORK/restore.log"
check "restore: refuses without --force when there is no terminal (#105)" \
  2 "refusing to roll work back to snapshot 'authed'" \
  runbox "$RLOG" restore work authed
# The exact no-TTY wording, pinned. This is the regression test for the CI
# failure this PR produced: the multi-user rehearsal drives restore unattended
# on real Incus, took this refusal, and recorded '(b) restore failed' — a
# 40-minute job catching what a 15-second suite should have. box refuses
# rather than assuming consent, and it says which of the two ways out applies.
check "restore: ...and the refusal names the missing terminal, not a bad usage (#105)" \
  2 "no terminal to confirm on" \
  runbox "$CWORK/r-tty.log" restore work authed
# The load-bearing assertion: the refusal actually PREVENTED the rollback.
# 'grep -q' on an absence, so an empty log passes and a logged restore fails.
check "restore: ...and the refusal reached incus with no restore (#105)" 1 "" \
  grep -qF 'snapshot restore' "$RLOG"
# The prompt must name the SNAPSHOT and the loss, not rm's wording. This is
# the entire point of making the prompt row-driven: adding the 'confirm' token
# alone would have asked the operator to confirm deleting the box.
check "restore: the prompt names what is lost, not a deletion (#105)" \
  2 "discard everything in the box since it was taken" \
  runbox "$CWORK/r2.log" restore work authed
check "restore: the prompt does NOT offer to delete the box (#105)" 1 "" \
  grep -qF 'delete work' "$CWORK/r2.log.out"

# --- restore: --force is the way through, and it still restores -------------
FLOG="$CWORK/force.log"
check "restore --force: skips the prompt and restores (#105)" 0 "restored work to authed" \
  runbox "$FLOG" restore work authed --force
check "restore --force: ...and incus was really asked for the rollback (#105)" 0 "" \
  grep -qF 'incus snapshot restore work authed' "$FLOG"

# --- rm: its wording is unchanged, and its gate still holds -----------------
# #105 moved the prompt out of the dispatch line and into the rows. rm's text
# was the string that lived there, so it is pinned verbatim: a refactor that
# rewords the ONE verb that already asked correctly is a regression.
MLOG="$CWORK/rm.log"
check "rm: still refuses without --force, in its own words (#105 refactor)" \
  2 "refusing to delete work and all its snapshots" \
  runbox "$MLOG" rm work
check "rm: ...and nothing was deleted" 1 "" grep -qF 'delete' "$MLOG"
check "rm --force: still deletes" 0 "removed work" runbox "$CWORK/rmf.log" rm work --force
check "rm --force: ...via 'incus delete -f'" 0 "" \
  grep -qF 'incus delete -f work' "$CWORK/rmf.log"

# --- the table invariant: a confirm row must carry its own words ------------
# Fail-closed on the shape itself, so a future 'confirm' row cannot ship with
# an empty prompt field and inherit whatever the dispatch happens to say.
# shellcheck disable=SC2016  # $3/$7/$1 are awk's fields, not the shell's
check "table: every 'confirm' row supplies a prompt (#105)" 0 "" \
  awk -F'^' '
    /^CMDS=\(/ { in_t = 1; next }
    in_t && /^\)/ { exit }
    in_t && /^  "/ && $3 ~ /(^|,)confirm(,|$)/ {
      seen = 1
      if (NF < 7) { print "row for " $1 " is marked confirm with no prompt field"; bad = 1; next }
      p = $7; sub(/"$/, "", p)
      if (p == "") { print "row for " $1 " has an empty confirm prompt"; bad = 1 }
    }
    END { if (!seen) { print "no confirm rows found — the pin is not reading the table"; bad = 1 }
          exit (bad ? 1 : 0) }
  ' "$ROOT/bin/box"
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "dispatch: the confirm prompt comes from the row, not a constant (#105)" 0 "" \
  grep -qF 'confirm "$(fill "$cnf" "$inst")"' "$ROOT/bin/box"
# The rehearsal drives restore unattended on real Incus, so it must consent
# EXPLICITLY — the gate is only real if the one automated caller had to change.
# Pinned here because the rehearsal itself needs a daemon and this suite has none.
check "rehearsal: the unattended restore passes --force (#105)" 0 "" \
  grep -qF 'box restore mine s1 --force' "$ROOT/drill/multiuser.sh"
# --- the three answers a human can give — DRIVEN ON A REAL PTY (#111) -------
# Everything above stops at the no-TTY refusal, because confirm() branches on
# '[ -t 0 ]' and this suite has no terminal. So the interactive half — 'y',
# 'n', and Ctrl-D — had never been executed here at all, which is precisely
# how #111 survived: an unguarded 'read' returns non-zero on EOF, 'set -e'
# ends the run before the 'case', and the abort happens in total silence.
#
# 'script' from util-linux gives the child a pty, so box takes the interactive
# branch for real and reads the answer we write to the master side. This does
# NOT hang a suite run from a terminal: script's own stdin is a file or
# /dev/null on every run below, never the developer's tty, so the answer (or
# the EOF) is always already waiting.
if command -v script >/dev/null 2>&1 && script --version 2>/dev/null | grep -q util-linux; then
  PWORK="$(mktemp -d)"; PLOG="$PWORK/pty.log"
  printf 'y\n' > "$PWORK/yes"; printf 'n\n' > "$PWORK/no"
  # Invoked through a file so 'script -c' needs no quoting of its own; the log
  # path and the shim PATH ride the environment script hands to the child.
  cat > "$PWORK/run" <<RUNNER
#!/usr/bin/env bash
exec env PATH="$CSHIM:\$PATH" "$BOX" rm work
RUNNER
  chmod +x "$PWORK/run"
  ptybox() {  # ptybox <answers-file> — 'box rm work' on a pty, answered
    : > "$PLOG"
    FAKE_INCUS_LOG="$PLOG" script -qec "$PWORK/run" /dev/null < "$1"
  }
  # The load-bearing assertion is the MESSAGE, not the exit code: before the
  # fix Ctrl-D also exited 1, just without ever saying why. Asserting on the
  # code alone would pass against the bug.
  check "rm: Ctrl-D at the prompt aborts OUT LOUD, not in silence (#111)" \
    1 "aborted." ptybox /dev/null
  check "rm: ...and the Ctrl-D abort really deleted nothing (#111)" 1 "" \
    grep -qF 'incus delete' "$PLOG"
  check "rm: 'n' at the prompt aborts (#111)" 1 "aborted." ptybox "$PWORK/no"
  check "rm: ...and 'n' really deleted nothing (#111)" 1 "" \
    grep -qF 'incus delete' "$PLOG"
  # The accept path, so the pty rig is proven to be able to reach the work —
  # three checks that can only ever refuse would pass against a box that
  # refuses everything.
  check "rm: 'y' at the prompt goes through (#111)" 0 "removed work" \
    ptybox "$PWORK/yes"
  check "rm: ...and 'y' really reached 'incus delete -f' (#111)" 0 "" \
    grep -qF 'incus delete -f work' "$PLOG"
  rm -rf "$PWORK"
else
  echo "skip: the interactive confirm answers (no util-linux 'script' here; CI has it)"
fi

# --- the sweep: no prompt-shaped 'read' under 'set -e' may go unguarded (#111)
# The pty checks above prove the two 'bin/box' gates. This proves the CLASS,
# repo-wide, and it exists because the class is exactly what the first pass at
# #111 missed: 'host/revoke-user.sh' and 'host/teardown-host.sh' carried the
# identical defect and survived, because nothing here was looking for the shape.
#
# The shape: a 'read' at the start of a statement, fed from the script's own
# stdin (so a human, or an EOF), inside a file that turns on errexit. On EOF
# 'read' returns non-zero and 'set -e' ends the run BEFORE the 'case' that was
# going to name the abort — the tool goes mute at the moment it asked.
#
# What is deliberately NOT flagged, because it is not the shape:
#   · 'while IFS= read -r' loops — fed by a redirect at 'done', and a non-zero
#     read is how the loop is supposed to end;
#   · '<<<' herestring reads — fed from a string, never from a human;
#   · files without errexit ('drill/wipe.sh', 'drill/drill.sh',
#     'drill/multiuser.sh' run under 'set -u' only, wipe.sh documents why), where
#     EOF simply falls through to the '*)' arm and aborts out loud on its own.
# A guard is any '||' on the read's own line: '|| die', '|| reply=""',
# '|| { echo …; exit 1; }' — the spelling is each script's to choose, the
# guard is not.
eof_guard_sweep() {
  local f n line bad=0 files
  # dotglob alongside globstar for the same reason CI's shellcheck step carries
  # it (#116): globstar descends, but a glob does not MATCH a dot-prefixed name,
  # so this sweep skipped '.github/scripts/*.sh' — the release path — exactly as
  # the linter did. Those three set errexit, so they are in scope for this class
  # by construction; today none of them reads at all, which is why widening the
  # set is a no-op on current code rather than a bug fix.
  files="$(cd "$ROOT" && shopt -s globstar dotglob && printf '%s\n' bin/* ./**/*.sh | sed 's|^\./||' | sort -u)"
  while IFS= read -r f; do
    [ -f "$ROOT/$f" ] || continue
    grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e' "$ROOT/$f" || continue
    while IFS=: read -r n line; do
      case "$line" in
        *'<<<'*) continue ;;   # herestring, not a prompt
        *'||'*)  continue ;;   # guarded — the whole point
      esac
      echo "$f:$n: prompt-shaped 'read' under 'set -e' with no '||' guard:$line"
      bad=1
    done < <(grep -nE '^[[:space:]]*(IFS=[^[:space:]]+[[:space:]]+)?read([[:space:]]|$)' "$ROOT/$f")
  done <<<"$files"
  return "$bad"
}
check "no prompt-shaped 'read' under 'set -e' goes unguarded, repo-wide (#111)" \
  0 "" eof_guard_sweep

rm -rf "$CSHIM" "$CWORK"

# ---------------------------------------------------------------------------
# export / import (#70) — a box's state that survives the box and the host.
# Usage errors and the pure pre-incus refusals are DRIVEN; every daemon-gated
# invariant is grep-guarded or line-order-asserted (fail-closed: an empty
# grep is a FAIL, so a deleted guard cannot ship green).
# ---------------------------------------------------------------------------
check "export without a box exits 2"           2 "usage: box export" "$BOX" export
check "export of an unknown box exits 1"       1 "no such box"       "$BOX" export nosuchbox
check "import without a file exits 2"          2 "usage: box import" "$BOX" import
check "import of a missing file exits 1"       1 "no such file"      "$BOX" import /nope/nothing.tar.gz
check "import --name with no value exits 2"    2 "--name needs a value" "$BOX" import x.tar.gz --name
# A file that is not an export artifact is named as such, before any incus
# call — pure (tar + awk), so it is driven, not grepped.
NOTATARBALL="$(mktemp)"; echo "not a tarball" > "$NOTATARBALL"
check "import: a non-artifact file is refused" 1 "not an incus/box export" "$BOX" import "$NOTATARBALL"
rm -f "$NOTATARBALL"
check "help export names the credential risk"  0 "CREDENTIAL"        "$BOX" help export
check "help import names the re-stamping"      0 "user.box=1"        "$BOX" help import
# Export refuses a running box — require_stopped fires BEFORE incus export
# (line order inside cmd_export, fail-closed on either grep missing).
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "export: requires the box stopped, before exporting" 0 "" bash -c '
  fn="$(awk "/^cmd_export\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  guard="$(printf "%s\n" "$fn" | grep -n "require_stopped" | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "incus export" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$run" ] && [ "$guard" -lt "$run" ]'
# Snapshots ride along by default; --instance-only is the explicit opt-out.
check "export: snapshots included unless --instance-only" 0 "" bash -c '
  awk "/^cmd_export\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q -- "--instance-only"'
# The credential SHOUT (#70's scrub-or-shout decision: box shouts).
check "export: shouts that the file is a credential" 0 "" bash -c '
  awk "/^cmd_export\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "treat the file itself as a credential"'
# Import re-stamps the boundary tag onto the current stack.
check "import: re-stamps user.box=1" 0 "" bash -c '
  awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "user.box=1"'
# The name-collision guard fires BEFORE incus import — the resolve_box
# boundary from the other side: never occupy an existing instance's name.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "import: the collision guard precedes the import" 0 "" bash -c '
  fn="$(awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  guard="$(printf "%s\n" "$fn" | grep -n "already exists" | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "incus import" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$run" ] && [ "$guard" -lt "$run" ]'
# Import lands on the placement contract: same pre-flight as a mint.
check "import: pre-flights the stack (require_stack)" 0 "" bash -c '
  awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "require_stack"'
# The artifact's MAC comes back verbatim, and a re-import beside a sibling
# collides at start (measured live: "MAC address already defined on another
# NIC") — the hwaddr unset must precede the start. Line order, fail-closed.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "import: regenerates the NIC MAC before the start" 0 "" bash -c '
  fn="$(awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  mac="$(printf "%s\n" "$fn" | grep -n "hwaddr" | head -1 | cut -d: -f1)"
  start="$(printf "%s\n" "$fn" | grep -n "incus start" | head -1 | cut -d: -f1)"
  [ -n "$mac" ] && [ -n "$start" ] && [ "$mac" -lt "$start" ]'
# reset_identity runs AFTER the imported box is started — the clone trust
# boundary (machine-id → DHCP lease), line-order-asserted, fail-closed.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "import: reset_identity follows the start" 0 "" bash -c '
  fn="$(awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  start="$(printf "%s\n" "$fn" | grep -n "incus start" | head -1 | cut -d: -f1)"
  reset="$(printf "%s\n" "$fn" | grep -n "reset_identity" | head -1 | cut -d: -f1)"
  [ -n "$start" ] && [ -n "$reset" ] && [ "$start" -lt "$reset" ]'
# The restricted tier can export: grant converges restricted.backups (the
# backup API is what 'incus export' rides; blocked by default — #70).
check "grant: allows backups (the export workflow)" 0 "" \
  grep -qF 'restricted.backups allow' "$ROOT/host/grant-user.sh"

# ---------------------------------------------------------------------------
# The mint stamp (#103) — DRIVEN on both halves, write and read.
#
# There is no host-side per-box store: the Incus instance config IS the
# database, so the only proof that a fact survives the mint is the argument
# list box hands 'incus launch'. A fake incus logs every call verbatim and
# answers just enough for cmd_new and cmd_info to run to completion with no
# daemon anywhere — the same trick the confirm-gate drive uses above.
#
# The read half matters as much as the write half, and legacy boxes most of
# all: every box minted before this stamp existed carries none of these keys,
# and a box outlives the release that minted it. 'incus config get' on an
# unset key prints EMPTY and exits 0 (audit B4), so "no stamp" and "daemon
# said no" arrive identically — 'box info' must render both as a box with
# blanks, never as an error.
# ---------------------------------------------------------------------------
MSHIM="$(mktemp -d)"; MWORK="$(mktemp -d)"
cat > "$MSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the mint-stamp drive. Knobs, all optional:
#   FAKE_BASE_IMAGE  what 'config get <i> volatile.base_image' resolves to;
#                    empty = incus does not know it (the degraded mint)
#   FAKE_CFG         a file of "<key> <value>" lines answering 'config get'
#   FAKE_ROW         the csv row 'list --columns nstS' returns
#   FAKE_TYPE        what 'list --columns t' returns — the instance type the
#                    #171 disk refusal branches on; empty = incus did not say
#   FAKE_SHOW        what 'config show <ref>' returns — the source's devices,
#                    which decide whether --disk can ride the copy (#171)
#   FAKE_SHOW_RC     the STATUS 'config show' exits with, default 0. Separate
#                    from FAKE_SHOW because the pair that matters is stdout
#                    that looks fine and a status that does not: a read box
#                    must not believe (#171 D2, review round 1)
#   FAKE_ROOT_SIZE   what 'config device get <i> root size' returns; empty =
#                    no per-instance root override (the container answer)
# The launch carries a whole cloud-init seed, so the call is logged with its
# newlines flattened — an assertion about "the launch line" must see one line.
printf 'incus %s\n' "$*" | tr '\n' ' ' >> "$FAKE_INCUS_LOG"
printf '\n' >> "$FAKE_INCUS_LOG"
case "$*" in
  exec\ *\ --\ rig\ bootstrap\ *)
    if [ "${FAKE_BOOTSTRAP_FAIL:-0}" = 1 ]; then
      echo "unknown tenant role: synthetic-box" >&2
      exit 2
    fi ;;
  *volatile.base_image) printf '%s\n' "${FAKE_BASE_IMAGE-}" ;;
  # Both 'config get <i> <key>' and its --expanded form (#171 reads what the
  # instance will RUN with, profiles included) — the key is the last word
  # either way, so one arm answers both.
  "config get "*)
    [ -n "${FAKE_CFG:-}" ] || exit 0
    key="$*"; key="${key##* }"
    awk -v k="$key" '$1 == k { $1 = ""; sub(/^ /, ""); print }' "$FAKE_CFG" ;;
  "config device get "*) printf '%s\n' "${FAKE_ROOT_SIZE-}" ;;
  "config show "*)       printf '%s\n' "${FAKE_SHOW-}"; exit "${FAKE_SHOW_RC:-0}" ;;
  *"--columns nstS") printf '%s\n' "${FAKE_ROW-}" ;;
  *"--columns t")    printf '%s\n' "${FAKE_TYPE-}" ;;
  *"--columns 4")    echo '10.1.2.3 (enp5s0)' ;;
esac
exit 0
SHIM
chmod +x "$MSHIM/incus"

export FAKE_BASE_IMAGE=deadbeefcafe0123456789   # what the alias resolves to
# The rig pin resolves off the network now (#150), so the mint drive carries
# the same shim curl the render_userdata drive does — a suite that reached
# github.com would be a suite that fails when github.com is down, and would
# assert against whichever rig release happened to be latest that morning.
# Every mint logs its probes to $log.curl, which is how "exactly one probe per
# mint" and "no probe at all for a seed with no pin" become assertions.
export FAKE_REDIRECT="https://github.com/heavy-duty/rig/releases/tag/9.9.9"
# The one host fact box_id() reads (#181), made to fail on demand: a shim 'cat'
# that refuses ONLY the kernel's uuid file and execs the real one for every
# other path. A blanket refusal would break box_version() — which reads VERSION
# through cat — and fail the mint for a reason that is not the one under test.
# Prepended to PATH via SHIM_PREFIX, so the degraded runs share every other
# knob with the ordinary ones.
NOUUID="$(mktemp -d)"
cat > "$NOUUID/cat" <<'SHIM'
#!/usr/bin/env bash
[ "${1:-}" = /proc/sys/kernel/random/uuid ] && exit 1
for real in /bin/cat /usr/bin/cat; do [ -x "$real" ] && exec "$real" "$@"; done
exit 127
SHIM
chmod +x "$NOUUID/cat"

mintbox() {  # mintbox <logfile> <args...> — the real box, shimmed, no TTY
  local log="$1"; shift
  : > "$log"; : > "$log.curl"
  env FAKE_INCUS_LOG="$log" FAKE_CURL_LOG="$log.curl" \
      PATH="${SHIM_PREFIX:+$SHIM_PREFIX:}$MSHIM:$RIGSHIM:$PATH" \
      "$BOX" "$@" </dev/null >"$log.out" 2>&1
  local rc=$?
  cat "$log.out"
  return "$rc"
}
# The launch line, isolated: every assertion below is about ONE incus call, and
# grepping the whole log would let a key stamped by some other call pass.
launchline() { grep -m1 '^incus launch ' "$1"; }
# launch_has/restamp_has <log> <ere> — a matcher per surface, so the ABSENCE
# assertions (a key that must not be stamped) are a plain non-zero exit rather
# than a nest of quoting.
launch_has()  { launchline "$1" | grep -qE "$2"; }
restamp_has() { grep -F 'config set' "$1" | grep -qE "$2"; }

# --- the write half: a fresh mint ------------------------------------------
MLOG="$MWORK/mint.log"
check "mint: a shimmed 'box new' runs to completion" 0 "ready" \
  mintbox "$MLOG" new --name w1 --role claude-box --container
# Each key on its own check: a single grep for the whole block would go green
# on a partial stamp, and "which fact was dropped" is the useful failure.
check "mint: stamps the schema — the stamp's SHAPE, not the box version (#103)" \
  0 "user.box.schema=1" launchline "$MLOG"
check "mint: stamps the box version that minted it (#103)" \
  0 "user.box.version=$(cat "$ROOT/VERSION")" launchline "$MLOG"
check "mint: stamps the base image ALIAS asked for (#103)" \
  0 "user.box.image=images:debian/13/cloud" launchline "$MLOG"
check "mint: stamps the mode it minted as (#103)" \
  0 "user.box.mode=container" launchline "$MLOG"
# The demand, not just the outcome: TYPE already says CT afterwards, but only
# the mint knew whether a container was ASKED for or fallen back into.
check "mint: stamps the mode that was ASKED, not only the outcome (#103)" \
  0 "user.box.mode.asked=container" launchline "$MLOG"
check "mint: stamps the rig role box will auto-run (#103)" \
  0 "user.box.role=claude-box" launchline "$MLOG"
check "mint: runtime role defaults to the small cpu row (#159)" 0 "" \
  launch_has "$MLOG" 'limits\.cpu=2'
check "mint: runtime role defaults to the small memory row (#159)" 0 "" \
  launch_has "$MLOG" 'limits\.memory=2GiB'
check "mint: the role-derived user reaches cloud-init (#159)" 0 "" \
  launch_has "$MLOG" 'name: "claude"'
check "mint: the role-derived user reaches rig bootstrap (#159)" 0 "" \
  grep -qE '^incus exec w1 -- rig bootstrap claude-box --user claude *$' "$MLOG"
check "mint: stamps which rig converged it — repo (#103)" \
  0 "user.box.rig.repo=heavy-duty/rig" launchline "$MLOG"
# The ref is the RESOLVED release, not main (#150). The stamp is the only
# record of which rig a box was handed, so it has to name the one that was.
check "mint: stamps which rig converged it — the RESOLVED ref (#103, #150)" \
  0 "user.box.rig.ref=9.9.9" launchline "$MLOG"
# ONE probe for the whole mint. Two readers ask for the pin — this stamp and
# the seed on the same launch line — and both ask inside a command
# substitution, so a resolution that lived in either would be discarded with
# its subshell and the other would probe again. Two probes can straddle a rig
# release and stamp a ref the seed did not install; the count is what proves
# the resolution happened in the parent.
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "mint: resolves the pin exactly ONCE, in the parent shell (#150)" 0 "1" \
  bash -c 'grep -c "releases/latest" "$1"' _ "$MLOG.curl"
# ...and the seed on that same line carries the same answer the stamp does.
check "mint: ...and the seed it shipped carries that same resolved ref (#150)" 0 "" \
  launch_has "$MLOG" 'heavy-duty/rig/9\.9\.9/install\.sh'
check "mint: stamps the origin (#103)" 0 "user.box.origin=mint" launchline "$MLOG"

# The public size table and its two higher precedence rungs, driven through a
# real shimmed mint. VM mode makes the disk device visible on the launch argv.
MEDIUMLOG="$MWORK/medium-size.log"
RIG_REF=main mintbox "$MEDIUMLOG" new --name medium --role claude-box --size medium --vm >/dev/null 2>&1
check "mint size: medium resolves to 4 cpu (#159)" 0 "" \
  launch_has "$MEDIUMLOG" 'limits\.cpu=4'
check "mint size: medium resolves to 8GiB memory (#159)" 0 "" \
  launch_has "$MEDIUMLOG" 'limits\.memory=8GiB'
check "mint size: medium resolves to a 60GiB disk (#159)" 0 "" \
  launch_has "$MEDIUMLOG" 'root,size=60GiB'
LARGELOG="$MWORK/large-size.log"
RIG_REF=main mintbox "$LARGELOG" new --name large --role claude-box --size large --vm >/dev/null 2>&1
check "mint size: large resolves to 8 cpu (#159)" 0 "" \
  launch_has "$LARGELOG" 'limits\.cpu=8'
check "mint size: large resolves to 16GiB memory (#159)" 0 "" \
  launch_has "$LARGELOG" 'limits\.memory=16GiB'
check "mint size: large resolves to a 120GiB disk (#159)" 0 "" \
  launch_has "$LARGELOG" 'root,size=120GiB'
FLAGBEATS="$MWORK/flag-beats-size.log"
RIG_REF=main mintbox "$FLAGBEATS" new --name flagbeats --role claude-box \
  --size medium --cpu 2 --container >/dev/null 2>&1
check "mint size: --cpu beats --size medium (#159)" 0 "" \
  launch_has "$FLAGBEATS" 'limits\.cpu=2'
ENVBEATS="$MWORK/env-beats-size.log"
BOX_CPU=1 RIG_REF=main mintbox "$ENVBEATS" new --name envbeats --role claude-box \
  --size medium --container >/dev/null 2>&1
check "mint size: BOX_CPU beats --size medium (#159)" 0 "" \
  launch_has "$ENVBEATS" 'limits\.cpu=1'

# A role that did not exist when this box tree was built takes the same generic
# path. The arbitrary name is intentionally absent from bin/box and templates/.
FUTURELOG="$MWORK/future-role.log"
RIG_REF=main mintbox "$FUTURELOG" new --name future --role synthetic-box \
  --user builder --container >/dev/null 2>&1
check "mint: a post-build rig role needs zero box registry change (#159)" 0 "" \
  launch_has "$FUTURELOG" 'user\.box\.role=synthetic-box'
check "mint: --user reaches the instance stamp (#159)" 0 "" \
  launch_has "$FUTURELOG" 'user\.box\.user=builder'
check "mint: --user reaches cloud-init (#159)" 0 "" \
  launch_has "$FUTURELOG" 'name: "builder"'
check "mint: --user is forwarded to rig bootstrap (#159)" 0 "" \
  grep -qE '^incus exec future -- rig bootstrap synthetic-box --user builder *$' "$FUTURELOG"
check "mint: the synthetic role is not hardcoded in box or a seed (#159)" 1 "" \
  grep -Rqs synthetic-box "$ROOT/bin" "$ROOT/templates"

unknown_role_mint() {
  FAKE_BOOTSTRAP_FAIL=1 RIG_REF=main \
    mintbox "$MWORK/unknown-role.log" new --name unknown --role synthetic-box --container
}
check "mint: rig's unknown-role refusal is surfaced (#159)" 1 \
  "unknown tenant role: synthetic-box" unknown_role_mint
check "mint: an incomplete unknown-role box prints its cleanup (#159)" 1 \
  "box rm unknown" unknown_role_mint

# --- the identity (#181) ----------------------------------------------------
# The SHAPE, not merely the presence: a hostname, the box's own name or a
# counter would all satisfy a bare "is set", and none of them is stable across
# the rename this key exists for. The assertion is stricter than box_id()'s own
# parser on purpose — the parser accepts any well-formed UUID because its job
# is to refuse garbage, while what the kernel actually hands out is a v4, and
# a source that quietly stopped being one is worth a red.
check "mint: stamps a stable identity — a v4 UUID (#181)" 0 "" \
  launch_has "$MLOG" 'user\.box\.id=[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
# Drawn on the HOST, and the function that draws it never speaks to a guest.
# That is the whole argument against /etc/machine-id: a guest-side identity is
# unreadable while the box is stopped, absent until first boot, and writable by
# the agents the box runs.
check "mint: the id comes from the host kernel (#181)" 0 "" \
  grep -qF '/proc/sys/kernel/random/uuid' "$ROOT/bin/box"
box_id_never_asks_the_guest() {
  ! awk '/^box_id\(\) \{/,/^\}/' "$ROOT/bin/box" | grep -q 'incus'
}
check "mint: ...and box_id() never asks the box for it (#181)" 0 "" \
  box_id_never_asks_the_guest
# An id every box shares is not an identity. Two mints, two ids.
MLOG2="$MWORK/mint2.log"
check "mint: a second mint runs to completion" 0 "ready" \
  mintbox "$MLOG2" new --name w1b --role claude-box --container
stamped_id() { launchline "$1" | grep -oE 'user\.box\.id=[0-9a-f-]+' | head -1 | cut -d= -f2; }
mint_ids_differ() {
  local a b; a="$(stamped_id "$1")"; b="$(stamped_id "$2")"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]
}
check "mint: two boxes minted on one host get DIFFERENT ids (#181)" 0 "" \
  mint_ids_differ "$MLOG" "$MLOG2"
# A host that cannot answer gets no id — never a dead mint over a metadata
# key, and never an empty 'user.box.id=' that a config grep would find. This is
# the same absence every box minted before #181 carries, and every reader
# already tolerates it.
export SHIM_PREFIX="$NOUUID"
NOIDLOG="$MWORK/noid.log"
check "mint: a host with no UUID source still mints (#181)" 0 "ready" \
  mintbox "$NOIDLOG" new --name w7 --role claude-box --container
check "mint: ...and says out loud that this box has no stable id (#181)" 0 "no stable id" \
  mintbox "$NOIDLOG" new --name w7 --role claude-box --container
check "mint: ...stamping no id at all, rather than an empty key (#181)" 1 "" \
  launch_has "$NOIDLOG" 'user\.box\.id'
unset SHIM_PREFIX
# The timestamp's SHAPE, so a local-time or seconds-since-epoch spelling fails
# here: UTC ISO 8601, which is the only form that sorts and travels.
check "mint: stamps the mint time as UTC ISO 8601 (#103)" 0 "" \
  launch_has "$MLOG" 'user\.box\.created=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
# The existing three keys are UNTOUCHED — the stamp extends the namespace, it
# does not rewrite it, and box_user()/the login hint read two of them.
check "mint: the pre-existing boundary tag still rides the same line" \
  0 "user.box=1" launchline "$MLOG"
check "mint: stamps the generic tenant seed selected at runtime (#159)" \
  0 "user.box.template=tenant" launchline "$MLOG"
check "mint: the pre-existing user stamp is untouched" \
  0 "user.box.user=claude" launchline "$MLOG"
# Deliberately NOT stamped. limits.* already hold cpu/memory and a duplicate
# drifts the first time someone edits a limit by hand; a container's disk does
# not exist (its root rides the pool); and the tier is a fact about whoever is
# ASKING. Absence assertions, so a well-meant addition has to argue here first.
check "mint: does NOT duplicate cpu into the user.box namespace (#103)" 1 "" \
  launch_has "$MLOG" 'user\.box\.cpu'
check "mint: does NOT duplicate memory into the user.box namespace (#103)" 1 "" \
  launch_has "$MLOG" 'user\.box\.memory'
check "mint: does NOT stamp a disk — a container's does not exist (#103)" 1 "" \
  launch_has "$MLOG" 'user\.box\.disk'
check "mint: does NOT stamp the tier — it describes the asker, not the box (#103)" 1 "" \
  launch_has "$MLOG" 'user\.box\.tier'

# --- the resolved fingerprint: the alias is not a reproducible fact ---------
# $T_IMAGE is an unpinned alias on a moving remote. Incus resolves it during
# the launch and records what it landed on; box reads that back and pins it.
check "mint: pins the RESOLVED image fingerprint after the launch (#103)" 0 "" \
  grep -qF "config set w1 user.box.image.fingerprint=$FAKE_BASE_IMAGE" "$MLOG"
check "mint: ...and it is a SECOND call, not something the launch could know" 1 "" \
  launch_has "$MLOG" 'image\.fingerprint'
# The load-bearing half of that design: a box that exists and boots must never
# be failed over a provenance field. With no fingerprint to be had, the mint
# still succeeds and the alias stands alone as the honest partial answer.
NOFP="$MWORK/nofp.log"
FAKE_BASE_IMAGE=""   # exported above; incus does not know what the alias resolved to
check "mint: an unknowable fingerprint does not fail the mint (#103)" 0 "ready" \
  mintbox "$NOFP" new --name w4 --container
check "mint: ...and it stamped no empty fingerprint key either (#103)" 1 "" \
  grep -q 'image.fingerprint' "$NOFP"
FAKE_BASE_IMAGE=deadbeefcafe0123456789

# --- blank and role shapes share the generic seed and rig preinstall --------
# The #159 ruling keeps the rig pin in both shapes; only the role auto-run and
# agent-class additions are conditional. The stamp therefore records the rig
# installed into an argumentless blank, while the role key remains absent.
check "mint: argumentless blank stamps the preinstalled rig repo (#103, #159)" 0 "" \
  launch_has "$NOFP" 'user\.box\.rig\.repo=heavy-duty/rig'
check "mint: argumentless blank stamps the resolved rig ref (#103, #159)" 0 "" \
  launch_has "$NOFP" 'user\.box\.rig\.ref=9.9.9'
check "mint: ...and no role either — blank names none (#103)" 1 "" \
  launch_has "$NOFP" 'user\.box\.role'
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "mint: argumentless blank resolves its shared rig pin once (#150, #159)" 0 "1" \
  bash -c 'grep -c "releases/latest" "$1"' _ "$NOFP.curl"

# --- the rig pin has ONE definition, and both readers get the same answer ---
# The seed substitutes it and the stamp records it. Two spellings of the same
# default would eventually disagree, and a stamp that disagrees with the seed
# it shipped alongside is worse than no stamp. Driven through the environment
# override, so the two are compared on a value neither can have hardcoded.
RIGLOG="$MWORK/rig.log"
export RIG_REPO=someone/rig RIG_REF=probe-ref
mintbox "$RIGLOG" new --name w5 --role claude-box --container >/dev/null 2>&1
unset RIG_REPO RIG_REF
check "mint: the rig pin override reaches the STAMP (#103)" 0 "" \
  launch_has "$RIGLOG" 'user\.box\.rig\.repo=someone/rig'
check "mint: ...both halves of it (#103)" 0 "" \
  launch_has "$RIGLOG" 'user\.box\.rig\.ref=probe-ref'
check "mint: ...and the SEED it shipped with carries the same pin (#103)" 0 "" \
  launch_has "$RIGLOG" 'someone/rig/probe-ref'
check "mint: ...and a pinned mint resolves nothing, so it probes nothing (#150)" 1 "" \
  grep -q . "$RIGLOG.curl"

# --- a pin that cannot be resolved ends the mint ----------------------------
# The sharp edge of resolving a default at mint: the probe can fail. Falling
# back to main would reintroduce #150's defect quietly, on the one host where
# nobody would look — and a die() inside the launch line's own command
# substitution would exit a SUBSHELL and let incus launch a box seeded with
# nothing. So the mint must die, before the launch, saying what to pass.
NORESOLVE="$MWORK/noresolve.log"
export FAKE_CURL_RC=6
check "mint: an unresolvable rig pin FAILS the mint (#150)" 1 "could not resolve rig's latest release" \
  mintbox "$NORESOLVE" new --name w6 --role claude-box --container
unset FAKE_CURL_RC
check "mint: ...and nothing was launched — the refusal came first (#150)" 1 "" \
  grep -q '^incus launch ' "$NORESOLVE"

# --- the clone: the sharpest edge of the whole stamp ------------------------
# 'incus copy' carries every user.* key forward (audit B2) — which is what
# makes a clone know its template for free, and is exactly why the stamp
# cannot ride along untouched. An inherited stamp does not go stale, it goes
# FALSE: the clone would claim a mint time it was not present for, by a box
# version that never saw it.
CLONELOG="$MWORK/clone.log"
check "clone: a shimmed 'box new --from' runs to completion" 0 "cloned" \
  mintbox "$CLONELOG" new --name w2 --from work/authed
check "clone: re-stamps the origin as a clone, not a mint (#103)" 0 "" \
  grep -qF 'user.box.origin=clone' "$CLONELOG"
check "clone: names the source it was taken from — one hop (#103)" 0 "" \
  grep -qF 'user.box.origin.from=work/authed' "$CLONELOG"
check "clone: re-stamps the box version that made THIS instance (#103)" 0 "" \
  grep -qF "user.box.version=$(cat "$ROOT/VERSION")" "$CLONELOG"
check "clone: re-stamps a fresh created time (#103)" 0 "" \
  grep -qE 'user\.box\.created=[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$CLONELOG"
# The other half of the decision, and the reason it is a decision at all: the
# LINEAGE keys are left alone on purpose. The clone's disk genuinely came from
# that image, that template, that user, that role — re-stamping them from the
# cloning process's own template lookup would be the actual lie, and would
# break the login hint that reads user.box.template off the instance.
check "clone: does NOT re-stamp the template — it is inherited lineage (#103)" 1 "" \
  restamp_has "$CLONELOG" 'user\.box\.template'
check "clone: does NOT re-stamp the user — box_user() reads the source's (#103)" 1 "" \
  restamp_has "$CLONELOG" 'user\.box\.user'
check "clone: does NOT re-stamp the image — the disk really came from it (#103)" 1 "" \
  restamp_has "$CLONELOG" 'user\.box\.image'
check "clone: does NOT re-stamp the role — the source's rig converged it (#103)" 1 "" \
  restamp_has "$CLONELOG" 'user\.box\.role'
# The third column, and the one review found: 'mode.asked' is neither lineage
# nor re-stampable. It is a mint-event fact whose asker was the SOURCE's
# operator, and a clone refuses --vm/--container, so nobody was asked anything
# here. It is CLEARED — there is no true value to give it.
check "clone: clears the inherited mode.asked — nobody asked THIS box (#103)" 0 "" \
  grep -qF 'config unset w2 user.box.mode.asked' "$CLONELOG"
check "clone: ...and does not re-stamp it with a fabricated answer (#103)" 1 "" \
  restamp_has "$CLONELOG" 'user\.box\.mode\.asked'
# Cleared, never set-to-empty: an empty value is still a key on the instance.
check "clone: clears it rather than setting it empty (#103)" 1 "" \
  grep -qE 'config set .*user\.box\.mode\.asked=($|[[:space:]])' "$CLONELOG"
# Order: the re-stamp lands on the copied instance BEFORE it is started, so a
# clone is never observable wearing its source's provenance. Fail-closed — an
# absent line makes the arithmetic fail, not pass.
restamp_precedes_start() {
  local set start
  set="$(grep -n 'config set .* user.box.origin=clone' "$1" | head -1 | cut -d: -f1)"
  start="$(grep -n '^incus start ' "$1" | head -1 | cut -d: -f1)"
  [ -n "$set" ] && [ -n "$start" ] && [ "$set" -lt "$start" ]
}
check "clone: the re-stamp precedes the start (#103)" 0 "" \
  restamp_precedes_start "$CLONELOG"
# The clear rides the same rule for the same reason: a clone must never be
# observable — not for one moment, not to 'box info' — wearing an 'asked' its
# operator never gave. Fail-closed the same way.
clear_precedes_start() {
  local unset_ln start
  unset_ln="$(grep -n 'config unset .* user.box.mode.asked' "$1" | head -1 | cut -d: -f1)"
  start="$(grep -n '^incus start ' "$1" | head -1 | cut -d: -f1)"
  [ -n "$unset_ln" ] && [ -n "$start" ] && [ "$unset_ln" -lt "$start" ]
}
check "clone: the mode.asked clear precedes the start too (#103)" 0 "" \
  clear_precedes_start "$CLONELOG"

# The identity is the sharpest case of the sharpest edge (#181). Every OTHER
# inherited key is either lineage that stays true or a fact box re-stamps;
# an inherited id is a clone asserting it IS its source, to every reader that
# trusts the id to mean one box.
check "clone: re-stamps a fresh id — a clone is a different box (#181)" 0 "" \
  restamp_has "$CLONELOG" 'user\.box\.id=[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
restamp_id() { grep -F 'config set' "$1" | grep -oE 'user\.box\.id=[0-9a-f-]+' | head -1 | cut -d= -f2; }
clone_id_is_its_own() {
  local c m; c="$(restamp_id "$CLONELOG")"; m="$(stamped_id "$MLOG")"
  [ -n "$c" ] && [ "$c" != "$m" ]
}
check "clone: ...and not a constant this build hands every box (#181)" 0 "" \
  clone_id_is_its_own
# It rides the SAME 'config set' as origin=clone, so the ordering assertion
# above covers it: the clone is never observable, not for a moment, wearing
# its source's identity.
check "clone: the id lands on the same pre-start re-stamp as the origin (#181)" 0 "" \
  restamp_precedes_start "$CLONELOG"
# The degraded clone is the one case where doing nothing is wrong. No id can be
# drawn, and 'incus copy' has already carried the source's in — so it is UNSET,
# the same call mode.asked gets, for a stronger reason: a false identity is
# worse than none.
export SHIM_PREFIX="$NOUUID"
NOIDCLONE="$MWORK/noid-clone.log"
check "clone: a host with no UUID source still clones (#181)" 0 "cloned" \
  mintbox "$NOIDCLONE" new --name w8 --from work/authed
check "clone: ...and UNSETS the id it inherited from the source (#181)" 0 "" \
  grep -qF 'config unset w8 user.box.id' "$NOIDCLONE"
check "clone: ...rather than letting it claim to BE its source (#181)" 1 "" \
  restamp_has "$NOIDCLONE" 'user\.box\.id'
check "clone: ...and says out loud that this clone has no stable id (#181)" 0 "no stable id" \
  mintbox "$NOIDCLONE" new --name w8 --from work/authed
# Before the start, like every other identity write on this path. Fail-closed:
# an absent line makes the arithmetic fail, not pass.
id_unset_precedes_start() {
  local u s
  u="$(grep -n 'config unset .* user.box.id' "$1" | head -1 | cut -d: -f1)"
  s="$(grep -n '^incus start ' "$1" | head -1 | cut -d: -f1)"
  [ -n "$u" ] && [ -n "$s" ] && [ "$u" -lt "$s" ]
}
check "clone: the inherited-id clear precedes the start (#181)" 0 "" \
  id_unset_precedes_start "$NOIDCLONE"
unset SHIM_PREFIX
# ...and the ordinary clone does NOT unset it: it was re-stamped, and an unset
# landing after the set would leave the clone with no identity at all.
check "clone: an ordinary clone never unsets the id it just re-stamped (#181)" 1 "" \
  grep -qE 'config unset .* user\.box\.id' "$CLONELOG"

# --- a clone's SIZING: the flags that ride the copy, and the silent case ----
# Two halves of one defect (#171). The flags were refused on --from on #57's
# premise that honouring them meant a post-hoc resize; they do not — 'incus
# copy' takes -c/-d and the root override is applied before the volume is
# created, so nothing is ever resized. And the refusal only ever fired if the
# flags were PASSED: drop them and the box came up sized by its source or its
# template with nothing saying what that size was — true of the fresh mint as
# much as the clone, which is why D6 narrates both.
#
# What box prints is DRIVEN, never matched. The issue's own proposed message
# read 'box incus <box> -- config set limits.cpu 2', which cmd_incus turns
# into 'incus config set limits.cpu 2 <inst>' — the instance in the value's
# place, because it is appended when no {} appears. A text assertion would
# have shipped that verbatim.
#
# A source with its own root device, which is what box's VM mints produce.
LOCALROOT="$MWORK/localroot.yaml"
cat > "$LOCALROOT" <<'YAML'
architecture: x86_64
config:
  limits.cpu: "4"
  limits.memory: 8GiB
devices:
  root:
    path: /
    pool: default
    size: 60GiB
    type: disk
name: work
YAML
# ...and one whose root comes from the profile: the case copy.go cannot serve.
PROFROOT="$MWORK/profroot.yaml"
cat > "$PROFROOT" <<'YAML'
architecture: x86_64
config:
  limits.cpu: "4"
devices:
  eth0:
    name: eth0
    type: nic
name: work
YAML

copyline() { grep -m1 '^incus copy ' "$1"; }
SIZELOG="$MWORK/size.log"
FAKE_SHOW="$(cat "$LOCALROOT")"; export FAKE_SHOW
check "clone sizing: --from WITH the size flags now mints (#171 D1)" 0 "cloned" \
  mintbox "$SIZELOG" new --name w9 --from work --cpu 2 --memory 4GiB --disk 20GiB
# The whole mechanism on one line: the override rides the copy, so the volume
# is created at the size asked for. A second call fixing it up afterwards would
# be the post-hoc resize #57 ruled out, and is not this.
check "clone sizing: the cpu override rides the copy (#171 D1)" 0 "-c limits.cpu=2" \
  copyline "$SIZELOG"
check "clone sizing: the memory override rides the copy (#171 D1)" 0 "-c limits.memory=4GiB" \
  copyline "$SIZELOG"
check "clone sizing: the root size rides it as a DEVICE override (#171 D1)" \
  0 "-d root,size=20GiB" copyline "$SIZELOG"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone sizing: ...in ONE copy call, not a copy and a fix-up (#171 D1)" 0 "1" \
  bash -c 'grep -c "^incus copy " "$1"' _ "$SIZELOG"
check "clone sizing: ...and nothing resizes it afterwards (#57, #171 D1)" 1 "" \
  restamp_has "$SIZELOG" 'limits\.'
# -s beside -d root,size= silently DROPS the sizing: applyStoragePool's
# fallback rebuilds the root device as {type, path, pool} and discards the
# size. box passes no pool flag today and this is what stops one arriving.
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone sizing: the copy argv never carries -s/--storage (#171 D2)" 1 "" \
  bash -c 'grep -m1 "^incus copy " "$1" | grep -qE " (-s|--storage) "' _ "$SIZELOG"
# Only a flag actually passed contributes an argument.
SIZELOG2="$MWORK/size-cpu.log"
check "clone sizing: one flag, one override (#171 D1)" 0 "cloned" \
  mintbox "$SIZELOG2" new --name w9 --from work --cpu 2
check "clone sizing: ...the cpu override is there (#171 D1)" 0 "-c limits.cpu=2" \
  copyline "$SIZELOG2"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone sizing: ...and no memory the caller never asked for (#171 D1)" 1 "" \
  bash -c 'grep -m1 "^incus copy " "$1" | grep -qF "limits.memory"' _ "$SIZELOG2"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone sizing: ...and no root device the caller never asked for (#171 D1)" 1 "" \
  bash -c 'grep -m1 "^incus copy " "$1" | grep -qF "root,size"' _ "$SIZELOG2"
# A plain clone is untouched by all of it: no flags, no overrides.
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone sizing: a flagless clone passes no overrides at all (#171 D1)" 1 "" \
  bash -c 'grep -m1 "^incus copy " "$1" | grep -qE " -[cd] "' _ "$CLONELOG"

# The pre-flight (D2). incus's copy.go does not merge a -d override onto a
# profile-inherited device the way create.go does — it installs the override AS
# the device, so a profile-rooted source would be copied with a root of 'size'
# and nothing else: no type, no path, not a root disk at all.
check "clone sizing: box reads the source's OWN devices (#171 D2)" 0 "" \
  grep -qE '^incus config show work *$' "$SIZELOG"
check "clone sizing: ...never --expanded, which folds the profile back in (#171 D2)" 1 "" \
  grep -qF 'config show --expanded' "$SIZELOG"
# D3: die BEFORE the copy. Not a warning-and-proceed — the caller asked for a
# 20GiB clone, and handing them the source's size with a note beside it is the
# silent wrong-sizing this issue opened on.
SIZELOG3="$MWORK/size-profroot.log"
FAKE_SHOW="$(cat "$PROFROOT")"; export FAKE_SHOW
check "clone sizing: a profile-rooted VM source DIES, exit 1 (#171 D3)" \
  1 "no root device of its own" \
  mintbox "$SIZELOG3" new --name w9 --from work --cpu 2 --disk 20GiB
# Asserted on the shim's record, not on the message: a message that says
# nothing was created, while the copy ran, is the failure mode #160 named.
check "clone sizing: ...and NO copy ran at all (#171 D3)" 1 "" \
  grep -q '^incus copy ' "$SIZELOG3"
check "clone sizing: ...it says nothing was created (#171 D3)" \
  0 "NOTHING WAS CREATED" cat "$SIZELOG3.out"
check "clone sizing: ...and that --cpu/--memory went nowhere either (#171 D3)" \
  0 "were not applied" cat "$SIZELOG3.out"
check "clone sizing: ...names the condition it refused on (#171 D3)" \
  0 "comes from a profile" cat "$SIZELOG3.out"
check "clone sizing: ...and offers the two measured routes (#171 D3)" \
  0 "drop --disk" cat "$SIZELOG3.out"
check "clone sizing: ...the second being a fresh mint (#171 D3)" \
  0 "mint fresh with --disk" cat "$SIZELOG3.out"
# The house rule, asserted the way #160's wall asserts it: ANCHORED. A line
# that begins 'incus ' or 'box ' reads as a command to run, and the verb that
# would fix the source is triage's inference off the copy.go divergence — a
# route nobody here has watched work. Naming a mechanism mid-sentence is fine;
# the anchor is exactly what draws that line.
no_command_lines() {   # no_command_lines <output-file>
  ! sed 's/^box: *//' "$1" | grep -qE '^(incus|box) '
}
check "clone sizing: the refusal prints NO runnable line, anchored (#171 D3)" 0 "" \
  no_command_lines "$SIZELOG3.out"
# ...and specifically not the override verb, which is the one it must not hand
# out however it is phrased.
check "clone sizing: ...and never the unwatched override verb (#171 D3)" 1 "" \
  grep -qF 'config device override' "$SIZELOG3.out"
# Not forceable, unlike #160's wall: --force cannot buy a device that is not a
# root disk, so there is no door through this one.
SIZELOG4="$MWORK/size-forced.log"
check "clone sizing: --force does NOT buy past it (#171 D3)" \
  1 "no root device of its own" \
  mintbox "$SIZELOG4" new --name w9 --from work --disk 20GiB --force
check "clone sizing: ...and forced or not, no copy ran (#171 D3)" 1 "" \
  grep -q '^incus copy ' "$SIZELOG4"
# D4: container mode keeps the answer it has had since #57 — note, no -d, and
# the copy PROCEEDS. The difference from D3 is principled: here the flag is
# categorically inapplicable, there it is merely unservable for this source.
SIZELOG5="$MWORK/size-ct.log"
export FAKE_TYPE=CONTAINER
check "clone sizing: a container source fires the note and CLONES (#171 D4)" \
  0 "--disk applies to VM mode only" \
  mintbox "$SIZELOG5" new --name w9 --from work --cpu 2 --disk 20GiB
check "clone sizing: ...the copy really ran (#171 D4)" 0 "" \
  grep -q '^incus copy ' "$SIZELOG5"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone sizing: ...carrying no -d, because there is no size to set (#171 D4)" 1 "" \
  bash -c 'grep -m1 "^incus copy " "$1" | grep -qF "root,size"' _ "$SIZELOG5"
check "clone sizing: ...while --cpu still rides it (#171 D4)" 0 "-c limits.cpu=2" \
  copyline "$SIZELOG5"
unset FAKE_TYPE
# Fail CLOSED on an unreadable source: no answer is not a yes. A false negative
# costs a refusal and a rerun; a false positive writes a non-root-disk device
# onto a fresh clone.
SIZELOG6="$MWORK/size-blind.log"
export FAKE_SHOW=""
check "clone sizing: an unreadable source refuses rather than guessing (#171 D2)" \
  1 "could not be read" \
  mintbox "$SIZELOG6" new --name w9 --from work --disk 20GiB
check "clone sizing: ...and no copy ran on the blind read either (#171 D2)" 1 "" \
  grep -q '^incus copy ' "$SIZELOG6"
# The one the pre-flight is FOR, and the one an earlier cut of this branch got
# wrong: stdout that parses as a local root device, and a STATUS that says the
# read failed. 'config show || true' discards the status and then believes the
# bytes — which attaches -d root,size= to a copy from a source box never
# actually read, the exact false positive D2 exists to prevent. The stanza here
# is the GOOD one, so nothing but the status can be what refuses it.
SIZELOG8="$MWORK/size-readfail.log"
FAKE_SHOW="$(cat "$LOCALROOT")"; export FAKE_SHOW
export FAKE_SHOW_RC=1
check "clone sizing: a FAILED read refuses, however good its stdout looked (#171 D2)" \
  1 "could not be read" \
  mintbox "$SIZELOG8" new --name w9 --from work --cpu 2 --disk 20GiB
check "clone sizing: ...and NO copy ran at all (#171 D2)" 1 "" \
  grep -q '^incus copy ' "$SIZELOG8"
# Belt and braces on the thing that actually breaks: the argv, not the prose.
# A helper that failed open would put this on the copy line.
check "clone sizing: ...so no -d rode a copy box never read (#171 D2)" 1 "" \
  grep -qF 'root,size=20GiB' "$SIZELOG8"
unset FAKE_SHOW_RC
# The cause line is the ONE thing that varies between the two refusals, and it
# varies because box knows the difference. A profile is what box saw; it is not
# what box says when it saw nothing.
check "clone sizing: an unread source is not blamed on a profile (#171 D3)" 1 "" \
  grep -qF 'comes from a profile' "$SIZELOG8.out"
check "clone sizing: ...and the profile-rooted source still is (#171 D3)" 0 \
  "comes from a profile" cat "$SIZELOG3.out"
# Everything else D3 was ruled to carry is identical on both arms — the
# situation is identical, only the cause differs.
check "clone sizing: ...the unread arm still says nothing was created (#171 D3)" \
  0 "NOTHING WAS CREATED" cat "$SIZELOG8.out"
check "clone sizing: ...still offers the two measured routes (#171 D3)" \
  0 "drop --disk" cat "$SIZELOG8.out"
check "clone sizing: ...and still prints no runnable line, anchored (#171 D3)" 0 "" \
  no_command_lines "$SIZELOG8.out"
export FAKE_SHOW=""
# ...while the flags with no precondition are untouched by any of it.
SIZELOG7="$MWORK/size-nodisk.log"
mintbox "$SIZELOG7" new --name w9 --from work --cpu 2 >/dev/null 2>&1 || true
check "clone sizing: ...and -c needs no pre-flight to ride the copy (#171 D2)" \
  0 "-c limits.cpu=2" copyline "$SIZELOG7"
unset FAKE_SHOW

# D6 — BOTH branches narrate, from the same helper, read off the daemon. The
# issue argued the clone was silent where the mint spoke; the mint speaks no
# more than the clone does, so ruling the clone alone would have left the same
# asymmetry pointing the other way.
SIZECFG="$MWORK/clone-sized.cfg"
cat > "$SIZECFG" <<'CFG'
user.box 1
limits.cpu 6
limits.memory 12GiB
CFG
SIZEDCLONE="$MWORK/sized-clone.log"
export FAKE_CFG="$SIZECFG" FAKE_ROOT_SIZE=80GiB
check "clone: narrates the resources it actually carries (#171 D6)" \
  0 "resources, read back from incus: cpu=6 mem=12GiB disk=80GiB" \
  mintbox "$SIZEDCLONE" new --name w10 --from work/authed
# The mint half of D6, which is the part the issue's false comparison hid.
SIZEDMINT="$MWORK/sized-mint.log"
check "mint: narrates them too, from the same helper (#171 D6)" \
  0 "resources, read back from incus: cpu=6 mem=12GiB disk=80GiB" \
  mintbox "$SIZEDMINT" new --name w14 --role claude-box --container
# One helper, one call site, after the branches rejoin — so the parity is
# structural and a third way of minting cannot ship silent about its sizing.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "mint: the narration is ONE call, after the branches rejoin (#171 D6)" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  [ "$(printf "%s\n" "$fn" | grep -c "narrate_resources ")" -eq 1 ]'
# --expanded, because the question is what the instance will RUN with: a
# profile added by hand is as real as box's own per-instance stamp, and a bare
# 'config get' would report only the override.
check "clone: reads the limits with --expanded, not just the override (#171 D6)" 0 "" \
  grep -qF 'incus config get --expanded w10 limits.cpu' "$SIZEDCLONE"
# The root size is a DEVICE key, not a config one — its absence is how the
# container case answers, so it must never be read off limits.*.
check "clone: reads the root size as a device key (#171 D6)" 0 "" \
  grep -qE '^incus config device get w10 root size *$' "$SIZEDCLONE"
unset FAKE_ROOT_SIZE
# No per-instance root override — the container answer — prints no disk figure
# rather than inventing one from the pool or from a template it never loaded.
CTCLONE="$MWORK/ct-clone.log"
check "clone: no root override → the figures it HAS, and no disk guess (#171 D6)" \
  0 "resources, read back from incus: cpu=6 mem=12GiB" \
  mintbox "$CTCLONE" new --name w11 --from work/authed
check "clone: ...and says nothing at all about a disk (#171 D6)" 1 "" \
  grep -qF 'disk=' "$CTCLONE.out"
unset FAKE_CFG
# The fully degraded read: incus answers none of the three. Silence here is
# indistinguishable from the bug this line exists to fix, so it says so and
# names the verb that has the whole config.
check "clone: an unreadable read-back says so rather than going quiet (#171 D6)" \
  0 "incus reported no resource figures" \
  mintbox "$MWORK/blind-clone.log" new --name w12 --from work/authed
check "mint: ...and the mint path degrades the same way (#171 D6)" \
  0 "incus reported no resource figures" \
  mintbox "$MWORK/blind-mint.log" new --name w15 --role claude-box --container

# D5 — the post-copy handle, where box does print one, carries what incus
# actually does. 'box new --help' is that place now: the D3 refusal prints no
# command at all, so the handle lives here and nowhere else.
check "new --help: says the flags work on --from (#171 D1)" 0 \
  "The flags work on --from too" "$BOX" help new
check "new --help: ...that they ride the copy rather than resize (#171 D1)" 0 \
  "no resize, no restart" "$BOX" help new
check "new --help: ...and carries --disk's precondition (#171 D2)" 0 \
  "a root device of its own" "$BOX" help new
check "new --help: the disk handle demands a stopped box (#171 D5)" 0 \
  "STOP THE BOX" "$BOX" help new
check "new --help: ...and names the pools that defer the quota (#171 D5)" 0 \
  "'dir' or 'btrfs'" "$BOX" help new
check "new --help: ...and that no local driver shrinks a root (#171 D7)" 0 \
  "will shrink one" "$BOX" help new
# Every 'box incus' line box prints, RUN back through cmd_incus — the help's
# three handles and the narration's one. This is the assertion the issue's own
# proposal fails, and it fails the day cmd_incus's substitution changes.
HINTCFG="$MWORK/hints.cfg"; printf 'user.box 1\n' > "$HINTCFG"
HINTLOG="$MWORK/hints.log"
run_printed_hints() {  # run_printed_hints <output-file> <incus-log>
  local line
  : > "$2"
  # Capture first, THEN read (#124's class) — and it is box's own printed
  # words being word-split here, never anything a caller supplied.
  grep -oE 'box incus .*' "$1" > "$MWORK/hints.txt" || true
  while IFS= read -r line; do
    local words; read -r -a words <<<"$line"
    env FAKE_INCUS_LOG="$2" FAKE_CFG="$HINTCFG" \
        PATH="$MSHIM:$RIGSHIM:$PATH" "$BOX" "${words[@]:1}" </dev/null >/dev/null 2>&1
  done < "$MWORK/hints.txt"
}
"$BOX" help new > "$MWORK/help-new.out" 2>&1
run_printed_hints "$MWORK/help-new.out" "$HINTLOG"
# Position, not presence: 'config set <inst> limits.cpu 4' is the contract, and
# 'config set limits.cpu 4 <inst>' is the bug the issue's message would have
# shipped. '<box>' is the help's own placeholder and resolves like any name.
check "new --help: the printed cpu handle RUNS, instance first (#171 D5)" 0 "" \
  grep -qE '^incus config set <box> limits\.cpu 4 *$' "$HINTLOG"
check "new --help: the memory handle lands the same way (#171 D5)" 0 "" \
  grep -qE '^incus config set <box> limits\.memory 8GiB *$' "$HINTLOG"
check "new --help: and the root device handle too (#171 D5)" 0 "" \
  grep -qE '^incus config device set <box> root size=60GiB *$' "$HINTLOG"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "new --help: ...those three and no fourth (#171 D5)" 0 "3" \
  bash -c 'grep -cE "^incus config (set|device set) " "$1"' _ "$HINTLOG"
# The narration's own handle, driven the same way.
NARRHINT="$MWORK/narr-hints.log"
export FAKE_CFG="$SIZECFG"
mintbox "$MWORK/hint-clone.log" new --name w16 --from work/authed >/dev/null 2>&1 || true
unset FAKE_CFG
run_printed_hints "$MWORK/hint-clone.log.out" "$NARRHINT"
check "clone: the narration's own handle RUNS, instance first (#171 D5)" 0 "" \
  grep -qE '^incus config set w16 limits\.cpu <n> *$' "$NARRHINT"

# --- the read half: 'box info' surfaces it ---------------------------------
# A stamp nothing can read is not done. cmd_info printed NAME/STATE/TYPE/IPV4
# and surfaced none of the keys that already existed.
STAMPED="$MWORK/stamped.cfg"
cat > "$STAMPED" <<'CFG'
user.box 1
user.box.schema 1
user.box.created 2026-07-19T14:22:07Z
user.box.version 0.8.0
user.box.image images:debian/13/cloud
user.box.image.fingerprint 8a2f1c9d4e5b6a7c8d9e
user.box.mode vm
user.box.mode.asked auto
user.box.template claude
user.box.user claude
user.box.role claude
user.box.rig.repo heavy-duty/rig
user.box.rig.ref main
user.box.origin mint
CFG
infobox() {  # infobox <cfg-file> — 'box info work' against a canned config
  env FAKE_INCUS_LOG=/dev/null FAKE_CFG="$1" FAKE_ROW='work,RUNNING,VIRTUAL-MACHINE,0' \
    PATH="$MSHIM:$PATH" "$BOX" info work </dev/null 2>&1
}
check "info: surfaces the mint time and the box that minted it (#103)" \
  0 "MINTED     2026-07-19T14:22:07Z by box 0.8.0" infobox "$STAMPED"
check "info: surfaces the image alias AND what it resolved to (#103)" \
  0 "IMAGE      images:debian/13/cloud @ 8a2f1c9d4e5b" infobox "$STAMPED"
check "info: surfaces the template with its user and role (#103)" \
  0 "TEMPLATE   claude (user claude, role claude)" infobox "$STAMPED"
check "info: surfaces which rig converged it (#103)" \
  0 "RIG        heavy-duty/rig@main" infobox "$STAMPED"
check "info: surfaces the origin (#103)" 0 "ORIGIN     mint" infobox "$STAMPED"

# The identity reads back in the HEADER, not in the provenance block (#181).
# The block below answers how this box came to BE; the id answers which box it
# IS — the fact the NAME line only appears to carry, since a rename moves the
# name and leaves the id exactly where it was.
IDCFG="$MWORK/identified.cfg"
{ cat "$STAMPED"; echo 'user.box.id 3f2504e0-4f89-41d3-9a0c-0305e82c3301'; } > "$IDCFG"
check "info: surfaces the id (#181)" \
  0 "ID         3f2504e0-4f89-41d3-9a0c-0305e82c3301" infobox "$IDCFG"
# Adjacency is the point: NAME and ID are one statement of identity, and an id
# printed below the mint block would read as one more provenance field.
id_follows_name() {
  local out; out="$(infobox "$1")"
  [ "$(printf '%s\n' "$out" | grep -cE '^(NAME|ID)')" -eq 2 ] &&
  [ "$(printf '%s\n' "$out" | grep -nE '^ID' | head -1 | cut -d: -f1)" -eq 2 ]
}
check "info: ...directly under NAME, which is the alias it outlives (#181)" 0 "" \
  id_follows_name "$IDCFG"
check "info: ...and the state block it always printed is untouched (#181)" \
  0 "IPV4       10.1.2.3" infobox "$IDCFG"
# Still the box it always was: the new block is additive, above the snapshots.
check "info: still prints the state block it always did" 0 "IPV4       10.1.2.3" infobox "$STAMPED"

# A clone reads back as a clone, naming its source. Modelled on what the
# --from branch actually leaves behind: origin re-stamped, mode.asked cleared.
CLONECFG="$MWORK/clone.cfg"
{ grep -v -e '^user.box.origin ' -e '^user.box.mode.asked ' "$STAMPED"
  echo 'user.box.origin clone'
  echo 'user.box.origin.from work/authed'; } > "$CLONECFG"
check "info: a clone says so, and names the box it came from (#103)" \
  0 "ORIGIN     clone of work/authed" infobox "$CLONECFG"
# ...and stays silent about a demand nobody made of it. The MODE line is gated
# on 'asked' precisely so absence renders as silence rather than as a guess;
# TYPE above still reports VM off the instance type, so nothing is lost.
info_has_mode() { infobox "$1" | grep -q '^MODE'; }
check "info: a clone prints no MODE line — nobody asked IT anything (#103)" 1 "" \
  info_has_mode "$CLONECFG"
check "info: ...while TYPE still reports what it actually is (#103)" \
  0 "TYPE       VM" infobox "$CLONECFG"
# The mint keeps its MODE line — there, the operator really was asked.
check "info: a MINT still surfaces what was asked for (#103)" \
  0 "MODE       vm (asked: auto)" infobox "$STAMPED"

# --- legacy boxes: the promise that they keep working under every verb ------
# A box carrying the boundary tag and NOTHING else — every box minted before
# this stamp existed. It must still render, exit 0, and say plainly that the
# mint was not recorded rather than inventing one or erroring out.
LEGACY="$MWORK/legacy.cfg"; printf 'user.box 1\n' > "$LEGACY"
check "info: a box with NO stamp at all still renders, exit 0 (#103)" \
  0 "NAME       work" infobox "$LEGACY"
check "info: ...and says the mint was not recorded, rather than inventing one" \
  0 "predates the mint stamp" infobox "$LEGACY"
info_has() { infobox "$1" | grep -qE "$2"; }
check "info: ...and prints no half-empty IMAGE/ORIGIN lines for keys it lacks" 1 "" \
  info_has "$LEGACY" '^(IMAGE|ORIGIN|RIG|MODE) '
# Every box minted before #181 has no id, and nothing synthesises one at read
# time: an id a reader invents is not stable, which is the whole point of
# having one. Absence renders as silence, the same rule the block above keeps.
check "info: a box minted before the id prints no ID line (#181)" 1 "" \
  info_has "$LEGACY" '^ID '
check "info: ...and neither does a stamped box that predates the key (#181)" 1 "" \
  info_has "$STAMPED" '^ID '
check "info: ...while the box itself still renders, exit 0 (#181)" \
  0 "NAME       work" infobox "$STAMPED"
# 'list' is the human table and stays four narrow columns: a full UUID would
# dominate it, and the audience that wants an id is reading --json or 'info'.
# Driven, not asserted on the source — the fixture carries an id and the table
# must simply never show one.
listbox() {  # listbox <cfg-file> — 'box list' against a canned config
  env FAKE_INCUS_LOG=/dev/null FAKE_CFG="$1" FAKE_ROW='work,RUNNING,VIRTUAL-MACHINE,0' \
    PATH="$MSHIM:$PATH" "$BOX" list </dev/null 2>&1
}
list_has_id() { listbox "$1" | grep -qE '(^|[[:space:]])ID([[:space:]]|$)|[0-9a-f]{8}-[0-9a-f]{4}-'; }
check "list: still prints the box it always did (#181)" 0 "work" listbox "$IDCFG"
check "list: ...and never the id — that is what --json and 'info' are for (#181)" 1 "" \
  list_has_id "$IDCFG"
# A snapshot and a restore are the SAME box, so neither writes the key. cmd_new
# and cmd_import are the only minting doors, and only they re-stamp.
snapshot_leaves_id_alone() {
  ! awk '/^cmd_snapshot\(\) \{/,/^\}/' "$ROOT/bin/box" | grep -q 'user\.box\.id'
}
check "snapshot: leaves the id alone — a snapshot is the same box (#181)" 0 "" \
  snapshot_leaves_id_alone
# 'restore' is a table row straight to 'incus snapshot restore', so there is no
# function to inspect: what proves it is that the row has no re-stamp in it.
check "restore: is a passthrough row, so it cannot rewrite the id (#181)" 0 "" \
  bash -c 'grep -F "\"restore^" "'"$ROOT"'/bin/box" | grep -qv "user.box.id"'
# A pre-rename box carries user.claudebox=1 and no metadata at all, and is
# always a Claude box — the same mapping box_user() makes, honored forever.
PRERENAME="$MWORK/prerename.cfg"; printf 'user.claudebox 1\n' > "$PRERENAME"
check "info: a pre-rename box still reads as the claude template (#103)" \
  0 "TEMPLATE   claude" infobox "$PRERENAME"

# --- a schema from the future is not a broken box --------------------------
# A box outlives the release that minted it, so an OLDER box will one day read
# a NEWER box's stamp. It shows what it understands and says so; refusing to
# describe a box a later release minted perfectly well is the wrong answer.
FUTURE="$MWORK/future.cfg"
{ grep -v '^user.box.schema ' "$STAMPED"; echo 'user.box.schema 99'; } > "$FUTURE"
check "info: an unrecognised (newer) schema is noted, not refused (#103)" \
  0 "NOTE" infobox "$FUTURE"
check "info: ...and it still shows every key it DOES understand (#103)" \
  0 "MINTED     2026-07-19T14:22:07Z" infobox "$FUTURE"
check "info: ...and it still exits 0 — a future box is not a broken box (#103)" \
  0 "ORIGIN" infobox "$FUTURE"
# A non-integer schema lands on the same side: noted, never fatal under set -e.
GARBAGE="$MWORK/garbage.cfg"
{ grep -v '^user.box.schema ' "$STAMPED"; echo 'user.box.schema not-a-number'; } > "$GARBAGE"
check "info: a non-integer schema is noted, not fatal (#103)" 0 "NOTE" infobox "$GARBAGE"

# VERSION has ONE reader in bin/box — box_version() — and both 'box --version'
# and the mint stamp go through it. A second 'cat $root/VERSION' is how the two
# would eventually disagree about what minted a box.
# shellcheck disable=SC2016  # '$root' is bin/box's variable, matched literally
one_version_reader() {
  [ "$(grep -cF 'cat "$root/VERSION"' "$ROOT/bin/box")" -eq 1 ]
}
check "the tree's VERSION has a single reader, box_version() (#103)" 0 "" \
  one_version_reader

# ---------------------------------------------------------------------------
# The import event (#131) — DRIVEN, on both halves, like the mint stamp above.
#
# An imported box keeps the artifact's mint stamp verbatim: the mint time, the
# box version, the image and the origin belong to the originating host and
# survive the trip on purpose (#129). What was missing is any record that the
# trip HAPPENED — and the obvious fix, 'origin=import', is the wrong one: it
# would overwrite whether the thing was a mint or a clone before it was
# exported, and leave 'origin.from' naming a lineage nothing explains. So the
# import takes its own keys, and the assertions that matter most here are the
# ABSENCE ones: every key the artifact carried must come out the far side
# untouched.
#
# The write half needs its own shim, because cmd_import reads 'incus config
# show <target>' as the name-collision guard and must see the name FREE — the
# opposite answer from the one the mint shim gives.
ISHIM="$(mktemp -d)"; IWORK="$(mktemp -d)"
cat > "$ISHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the import drive. FAKE_CFG answers 'config get' with a file
# of "<key> <value>" lines — it stands in for the config that rode inside the
# artifact and that 'incus import' has just restored.
printf 'incus %s\n' "$*" | tr '\n' ' ' >> "$FAKE_INCUS_LOG"
printf '\n' >> "$FAKE_INCUS_LOG"
case "$*" in
  # Nothing exists under that name: the collision guard passes. The same call
  # enumerates volatile hwaddrs later, where an empty answer is also correct.
  "config show "*) exit 1 ;;
  "config get "*)
    [ -n "${FAKE_CFG:-}" ] || exit 0
    key="$*"; key="${key##* }"
    awk -v k="$key" '$1 == k { $1 = ""; sub(/^ /, ""); print }' "$FAKE_CFG" ;;
  *"--columns P") printf '"box-net"\n' ;;   # already on the contract, no re-home
esac
exit 0
SHIM
chmod +x "$ISHIM/incus"

# A real tarball, because cmd_import reads the instance name out of the
# artifact with tar before incus is ever called — a stub cannot fake that.
ARTIFACT="$IWORK/work-20260718T120000Z.tar.gz"
mkdir -p "$IWORK/backup" && printf 'name: work\n' > "$IWORK/backup/index.yaml"
tar -czf "$ARTIFACT" -C "$IWORK" backup/index.yaml

importbox() {  # importbox <logfile> <cfg-file|""> — the real box, shimmed
  local log="$1" cfg="$2"
  : > "$log"
  env FAKE_INCUS_LOG="$log" FAKE_CFG="$cfg" \
    PATH="${SHIM_PREFIX:+$SHIM_PREFIX:}$ISHIM:$PATH" \
    "$BOX" import "$ARTIFACT" </dev/null >"$log.out" 2>&1
  local rc=$?
  cat "$log.out"
  return "$rc"
}
# One matcher per surface, so an absence assertion is a plain non-zero exit.
# 'config set' is the ONLY call that can write a key, so grepping it is what
# separates "box stamped this" from "the artifact carried it".
import_set() { grep -F 'config set' "$1" | grep -qE "$2"; }

# --- the first trip ---------------------------------------------------------
# The artifact of a box that was MINTED elsewhere and never imported before.
# The id it carried is a fixed, obviously-fake one so the re-mint below can be
# asserted by INEQUALITY: a drawn id that happened to equal the artifact's is
# the one way "re-minted" and "carried through" look alike (#181).
MINTED_ART="$IWORK/minted.cfg"
cat > "$MINTED_ART" <<'CFG'
user.box 1
user.box.schema 1
user.box.created 2026-06-01T10:00:00Z
user.box.version 0.7.0
user.box.template claude
user.box.user claude
user.box.origin mint
user.box.id 11111111-1111-4111-8111-111111111111
CFG
ILOG="$IWORK/import.log"
check "import: a shimmed 'box import' runs to completion (#131)" 0 "imported work" \
  importbox "$ILOG" "$MINTED_ART"
check "import: records WHEN the box landed here, UTC ISO 8601 (#131)" 0 "" \
  import_set "$ILOG" 'user\.box\.imported\.last=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
check "import: records WHICH box version performed the import (#131)" 0 "" \
  import_set "$ILOG" "user\\.box\\.imported\\.last\\.by=$(cat "$ROOT/VERSION")"
check "import: pins the FIRST trip as its own key (birth pair, rig#61) (#131)" 0 "" \
  import_set "$ILOG" 'user\.box\.imported=[0-9]{4}-'
check "import: ...with the box version that made it (#131)" 0 "" \
  import_set "$ILOG" "user\\.box\\.imported\\.by=$(cat "$ROOT/VERSION")"
check "import: counts the trip — the first one is 1 (#131)" 0 "" \
  import_set "$ILOG" 'user\.box\.imported\.count=1'

# --- the absence assertions: this is the whole point of the issue -----------
# 'origin=import' is the road not taken. 'origin' says how the instance came
# into BEING — mint or clone — and the import is a third, orthogonal fact.
check "import: does NOT overwrite origin — an import is not a coming-into-being (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.origin='

# The identity is the ONE stamp key this path rewrites (#181), and it is not an
# exception to "the artifact's truth survives": an id is not a fact about the
# artifact but about a box on a host, and the box this one was exported from
# may still be running — quite possibly on this same host, which is what the
# MAC regeneration already exists to survive. Importing is minting.
check "import: re-mints the id — importing is minting (#181)" 0 "" \
  import_set "$ILOG" 'user\.box\.id=[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
check "import: ...so the artifact's id does not survive the trip (#181)" 1 "" \
  import_set "$ILOG" 'user\.box\.id=11111111-1111-4111-8111-111111111111'
# It rides the same pre-start 'config set' as the import record, so an imported
# box is never observable wearing the identity of the box it came from.
import_id_precedes_start() {
  local s t
  s="$(grep -n 'config set .*user.box.id=' "$1" | head -1 | cut -d: -f1)"
  t="$(grep -n '^incus start ' "$1" | head -1 | cut -d: -f1)"
  [ -n "$s" ] && [ -n "$t" ] && [ "$s" -lt "$t" ]
}
check "import: the re-mint precedes the start (#181)" 0 "" \
  import_id_precedes_start "$ILOG"
# Degraded, and the same call the clone makes: the artifact's id rode in
# unchallenged, and an id two live boxes share is worse than an id one lacks.
export SHIM_PREFIX="$NOUUID"
NOIDIMP="$IWORK/noid-import.log"
check "import: a host with no UUID source still imports (#181)" 0 "imported work" \
  importbox "$NOIDIMP" "$MINTED_ART"
check "import: ...and unsets the id the artifact carried (#181)" 0 "" \
  grep -qF 'config unset work user.box.id' "$NOIDIMP"
check "import: ...rather than letting two boxes wear one id (#181)" 1 "" \
  import_set "$NOIDIMP" 'user\.box\.id='
check "import: ...and says out loud that this box has no stable id (#181)" 0 "no stable id" \
  importbox "$NOIDIMP" "$MINTED_ART"
unset SHIM_PREFIX
check "import: does NOT restamp the mint time — it is the origin host's (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.created='
check "import: does NOT restamp the box version that MINTED it (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.version='
check "import: does NOT restamp the template — lineage rides in the artifact (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.template='
check "import: does NOT restamp the image the artifact was built on (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.image'
check "import: does NOT restamp the rig that converged it (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.rig\.'
# Adding a key is not a breaking change (#103's schema contract), so the schema
# does not move — and is not written here at all: stamping schema=1 onto a
# legacy artifact would claim a mint stamp shape it does not have.
check "import: does NOT touch user.box.schema — adding a key is not breaking (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.schema'
# Before the start, like the clone re-stamp: an imported box is never
# observable without the record of how it got here. Fail-closed — a missing
# line makes the arithmetic fail, not pass.
import_stamp_precedes_start() {
  local set start
  set="$(grep -n 'config set .* user.box.imported.last=' "$1" | head -1 | cut -d: -f1)"
  start="$(grep -n '^incus start ' "$1" | head -1 | cut -d: -f1)"
  [ -n "$set" ] && [ -n "$start" ] && [ "$set" -lt "$start" ]
}
check "import: the import stamp precedes the start (#131)" 0 "" \
  import_stamp_precedes_start "$ILOG"

# --- a CLONE that was exported and re-imported ------------------------------
# The case that makes 'origin=import' indefensible: it would come back
# claiming to be an import, with nothing left saying it was ever a clone and
# an origin.from pointing at a lineage no key explains.
CLONE_ART="$IWORK/clone-artifact.cfg"
{ grep -v '^user.box.origin ' "$MINTED_ART"
  echo 'user.box.origin clone'
  echo 'user.box.origin.from work/authed'; } > "$CLONE_ART"
CLOG="$IWORK/clone-import.log"
check "import: an exported CLONE imports cleanly (#131)" 0 "imported work" \
  importbox "$CLOG" "$CLONE_ART"
check "import: ...and is still a clone afterwards — origin untouched (#131)" 1 "" \
  import_set "$CLOG" 'user\.box\.origin='
check "import: ...and still names the box it was cloned from (#131)" 1 "" \
  import_set "$CLOG" 'user\.box\.origin\.from'
check "import: ...while still recording that the trip happened (#131)" 0 "" \
  import_set "$CLOG" 'user\.box\.imported\.last='

# --- the second trip: first-wins, last-wins, and a count --------------------
# The artifact of a box that has already been imported twice. Last-wins alone
# would erase the evidence of the first trip, which is the same mistake
# 'origin=import' makes one level up.
TWICE="$IWORK/twice.cfg"
{ cat "$MINTED_ART"
  echo 'user.box.imported 2026-06-15T08:00:00Z'
  echo 'user.box.imported.by 0.7.0'
  echo 'user.box.imported.last 2026-07-01T09:00:00Z'
  echo 'user.box.imported.last.by 0.8.0'
  echo 'user.box.imported.count 2'; } > "$TWICE"
RLOG="$IWORK/reimport.log"
check "re-import: an already-imported artifact imports again (#131)" 0 "imported work" \
  importbox "$RLOG" "$TWICE"
check "re-import: the FIRST trip is pinned, never rewritten (#131)" 1 "" \
  import_set "$RLOG" 'user\.box\.imported=[0-9]'
check "re-import: ...nor is the version that made it (#131)" 1 "" \
  import_set "$RLOG" 'user\.box\.imported\.by='
check "re-import: the LATEST trip IS refreshed (#131)" 0 "" \
  import_set "$RLOG" 'user\.box\.imported\.last=[0-9]{4}-'
check "re-import: ...by this box version (#131)" 0 "" \
  import_set "$RLOG" "user\\.box\\.imported\\.last\\.by=$(cat "$ROOT/VERSION")"
check "re-import: the count advances 2 → 3 (#131)" 0 "" \
  import_set "$RLOG" 'user\.box\.imported\.count=3'
# A count that is not an integer (hand-edited config, a foreign key) must not
# fail an import that has already happened — arithmetic under 'set -e' would.
BADN="$IWORK/badcount.cfg"
{ cat "$MINTED_ART"; echo 'user.box.imported.count not-a-number'; } > "$BADN"
BLOG="$IWORK/badcount.log"
check "re-import: a non-integer count does not fail the import (#131)" 0 "imported work" \
  importbox "$BLOG" "$BADN"
check "re-import: ...it restarts the count rather than inventing a total (#131)" 0 "" \
  import_set "$BLOG" 'user\.box\.imported\.count=1'
# A leading zero is the hole the non-integer fixture CANNOT catch: '08' passes
# an -eq guard (test parses decimal) and then dies in arithmetic, which reads
# it as octal. That abort would land after the physical 'incus import' and
# before the stamp, the placement fix and the start — the exact window the
# degrade-never-die contract exists to protect. A zero-padded count is not
# exotic either: it is what any external tool that formats numbers writes.
ZEROPAD="$IWORK/zeropad.cfg"
{ cat "$MINTED_ART"; echo 'user.box.imported.count 08'; } > "$ZEROPAD"
ZLOG="$IWORK/zeropad.log"
check "re-import: a zero-padded count does not fail the import (#131)" 0 "imported work" \
  importbox "$ZLOG" "$ZEROPAD"
# Counted as decimal 8, not degraded to 0 and not read as octal: '08' is a
# real previous total, so the honest next value is 9.
check "re-import: ...and counts it as decimal, so 08 advances to 9 (#131)" 0 "" \
  import_set "$ZLOG" 'user\.box\.imported\.count=9'

# --- a legacy artifact with no stamp at all ---------------------------------
# A pre-stamp box export, or a hand-rolled 'incus export' of an unmanaged VM.
# It must import cleanly, get the boundary tag, get the import record — and NOT
# acquire a fabricated mint, which is what 'not recorded' exists to say.
LLOG="$IWORK/legacy-import.log"
check "import: a legacy artifact with NO stamp imports cleanly (#131)" 0 "imported work" \
  importbox "$LLOG" /dev/null
check "import: ...it still gets the boundary tag (importing is minting) (#131)" 0 "" \
  grep -qF 'config set work user.box=1' "$LLOG"
check "import: ...and the import record (#131)" 0 "" \
  import_set "$LLOG" 'user\.box\.imported\.last='
check "import: ...but NO invented mint time (#131)" 1 "" \
  import_set "$LLOG" 'user\.box\.created='
check "import: ...and no invented mint version either (#131)" 1 "" \
  import_set "$LLOG" 'user\.box\.version='

# --- the restricted tier's import wall (#160, reported as #156) -------------
# The measured failure: a box exported on the admin tier, imported by a
# restricted user, unpacks to 100% — 1.38GB — and is THEN rejected on
# "volatile.uuid.generation ... in project user-1000 is forbidden". The key is
# incus's own, stamped on every instance it mints; the project is restricted
# because that is what the tier IS. So the whole transfer is spent to learn a
# fact box could read out of the artifact's index.yaml before starting.
#
# This is the round-trip the acceptance shape asks for, taken mocked: the
# export half is already proven above and on the admin tier, and what has
# never been exercised is the way back IN under a restricted identity. The
# fake incus logs every call it receives, so "before the transfer" is asserted
# as the ABSENCE of an 'incus import' line — the strongest form available
# here, and the one that fails if the wall is ever moved below the transfer.
RESTRICTED="$(mktemp -d)"
cat > "$RESTRICTED/id" <<'SHIM'
#!/usr/bin/env bash
# A non-root user in 'incus' and NOT in 'incus-admin' — box_tier()'s restricted
# arm, decided from live credentials exactly as it is on a real host.
case "${1:-}" in
  -u)  echo 1000 ;;
  -nG) echo "boxuser incus" ;;
  -un) echo boxuser ;;
  *)   echo "uid=1000(boxuser) gid=1000(boxuser) groups=1000(boxuser),988(incus)" ;;
esac
SHIM
chmod +x "$RESTRICTED/id"

# An artifact whose index.yaml embeds the instance config, which is where the
# forbidden keys ride. The bare ARTIFACT above carries a name and nothing else
# — deliberately kept, because it is also the no-evidence fixture below.
VM_IDX="$IWORK/vm-index.yaml"
cat > "$VM_IDX" <<'IDX'
name: work
backend: dir
pool: default
type: virtual-machine
config:
  instance:
    architecture: x86_64
    config:
      image.os: Debian
      limits.cpu: "4"
      volatile.base_image: 5b1f9d0c4a
      volatile.cloud-init.instance-id: 3d0b7e11
      volatile.eth0.hwaddr: 00:16:3e:2f:11:aa
      volatile.last_state.power: RUNNING
      volatile.uuid: 8f4a1c22-0000-4000-8000-000000000000
      volatile.uuid.generation: 8f4a1c22-0000-4000-8000-000000000000
    devices:
      root:
        path: /
        pool: default
        type: disk
IDX
VM_ART="$IWORK/vm-work.tar.gz"
mkdir -p "$IWORK/vmart/backup" && cp "$VM_IDX" "$IWORK/vmart/backup/index.yaml"
tar -czf "$VM_ART" -C "$IWORK/vmart" backup/index.yaml

importfile() {  # importfile <logfile> <artifact> [flags...] — the real box, shimmed
  local log="$1" art="$2"; shift 2
  : > "$log"
  env FAKE_INCUS_LOG="$log" FAKE_CFG="" \
    PATH="${SHIM_PREFIX:+$SHIM_PREFIX:}$ISHIM:$PATH" \
    "$BOX" import "$art" "$@" </dev/null >"$log.out" 2>&1
  local rc=$?
  cat "$log.out"
  return "$rc"
}
# The transfer itself. Every incus call lands in the log, so its absence is
# proof the multi-GB copy never began — not proof that a message was printed.
import_transferred() { grep -qE '^incus import ' "$1"; }

RESTLOG="$IWORK/restricted-import.log"
export SHIM_PREFIX="$RESTRICTED"
check "import: the restricted tier is refused, not left to incus (#160)" 1 \
  "REFUSED BEFORE THE TRANSFER" importfile "$RESTLOG" "$VM_ART"
# The six things D2 requires the refusal to name: the tier, the project, the
# offending key, that nothing was transferred, who can land it, and --force
# with its price. One check each, so a regression names which clause went.
check "import: ...the refusal names the TIER (#160 D2)" 1 "your tier is 'restricted'" \
  importfile "$RESTLOG" "$VM_ART"
check "import: ...and the project the tier puts you in (#160 D2)" 1 "user-1000" \
  importfile "$RESTLOG" "$VM_ART"
check "import: ...the refusal names the KEY incus would have died on (#160 D2)" 1 \
  "volatile.uuid.generation" importfile "$RESTLOG" "$VM_ART"
# The sentence that distinguishes this failure from the reported one: there,
# the whole 1.38GB had landed before incus spoke.
check "import: ...that NOTHING was transferred (#160 D2)" 1 "nothing was transferred" \
  importfile "$RESTLOG" "$VM_ART"
check "import: ...and the WAY OUT — who can land it instead (#160 D2)" 1 "incus-admin" \
  importfile "$RESTLOG" "$VM_ART"
check "import: ...and --force, the override (#160 D2, D3)" 1 "--force" \
  importfile "$RESTLOG" "$VM_ART"
# Priced, not merely offered: --force costs the full transfer and then incus's
# error if the project really does refuse. A message naming the escape hatch
# without its price would sell the very transfer this wall exists to save.
check "import: ...priced honestly rather than merely offered (#160 D2, D3)" 1 \
  "full transfer" importfile "$RESTLOG" "$VM_ART"
# Naming the way out is not the same as inventing one. The admin-side route
# into a restricted project is unmeasured (#160 direction 4), so the message
# says so and hands over no command nobody has run.
check "import: ...and says that route is unmeasured rather than promising it (#160 D2)" 1 \
  "unmeasured" importfile "$RESTLOG" "$VM_ART"
# The absence assertion, ANCHORED. D2 forbids printing an 'incus'/'box'
# command line asserting a route nobody has run, and the readable form of that
# is: no line of the message may begin with a command. Anchoring is what lets
# the message still say 'incus config set' mid-sentence — that names the
# MECHANISM incus applies, and explaining a mechanism is not offering a route.
# An unanchored grep would have to choose between the two, and it would choose
# by banning the explanation, which is the honest half.
check "import: ...offering no command line to run (#160 D2)" 1 "" \
  grep -qE '^box: +(sudo )?(incus|box) ' "$RESTLOG.out"
# And belt-and-braces on the specific incantations an admin-assist route would
# have to be written with, wherever in a line they appear.
check "import: ...naming no admin-assist incantation at all (#160 D2)" 1 "" \
  grep -qE 'incus (import|move|copy|admin) |box (grant|import) |--project' "$RESTLOG.out"
# The whole point of the issue, and the assertion that fails if the wall ever
# drifts below the transfer: incus was never asked to import anything.
check "import: ...BEFORE the transfer — incus import is never reached (#160)" 1 "" \
  import_transferred "$RESTLOG"
# And box never announced a transfer it was about to refuse.
check "import: ...so it never announces an import it will not perform (#160)" 1 "" \
  grep -qF 'box: importing' "$RESTLOG.out"
# EVERY key, not a sample. The keys sort alphabetically and the one incus
# actually died on sorts last of the six this artifact carries, so a head -N
# drops precisely the key the message exists to name. Assert both ends.
check "import: ...listing every key it carries, not a sample (#160)" 1 "volatile.base_image" \
  importfile "$RESTLOG" "$VM_ART"
check "import: ...and counting them (#160)" 1 "carries 6 such keys" \
  importfile "$RESTLOG" "$VM_ART"
# One key is not a special case of six, under 'set -euo pipefail': the
# singular arm is where an '&& noun=key' would end the run on the plural
# branch, silently and mid-message. Drive it, rather than reasoning about it.
ONE_ART="$IWORK/one-key.tar.gz"
mkdir -p "$IWORK/oneart/backup"
printf 'name: work\nconfig:\n  instance:\n    config:\n      volatile.uuid: 8f4a\n' \
  > "$IWORK/oneart/backup/index.yaml"
tar -czf "$ONE_ART" -C "$IWORK/oneart" backup/index.yaml
ONELOG="$IWORK/one-key.log"
check "import: an artifact carrying ONE such key still refuses cleanly (#160)" 1 \
  "carries 1 such key" importfile "$ONELOG" "$ONE_ART"
check "import: ...reaching the end of the message, not dying inside it (#160)" 1 \
  "THE WAY OUT" importfile "$ONELOG" "$ONE_ART"
# No evidence is not evidence of trouble. An artifact whose index.yaml embeds
# no config tells box nothing about what it carries, and refusing there would
# refuse artifacts nothing is known about — so it takes the old path.
BAREREST="$IWORK/bare-restricted.log"
check "import: an artifact with no readable config is NOT refused (#160)" 0 \
  "imported work" importfile "$BAREREST" "$ARTIFACT"
check "import: ...it degrades to the old path rather than guessing (#160)" 0 "" \
  import_transferred "$BAREREST"

# Config that is READ and cleared, which is the stronger half of the same
# point: the fixture above has no config at all, so it proves only that box
# refuses to guess. This one embeds a config section box parses in full and
# finds nothing low-level in — an artifact a restricted project has no reason
# to reject — and it goes through. Without it, a reader that swept up every
# key it saw would still pass every test above.
CLEAN_IDX="$IWORK/clean/backup/index.yaml"
mkdir -p "$IWORK/clean/backup"
cat > "$CLEAN_IDX" <<'IDX'
name: work
backend: dir
pool: default
type: container
config:
  instance:
    architecture: x86_64
    config:
      image.os: Debian
      limits.cpu: "4"
      limits.memory: 4GiB
      user.box: "1"
    devices:
      root:
        path: /
        pool: default
        type: disk
IDX
CLEAN_ART="$IWORK/clean-work.tar.gz"
tar -czf "$CLEAN_ART" -C "$IWORK/clean" backup/index.yaml
CLEANLOG="$IWORK/clean-import.log"
check "import: restricted tier + an artifact with no low-level keys imports (#160)" 0 \
  "imported work" importfile "$CLEANLOG" "$CLEAN_ART"
check "import: ...reaching the transfer like any other (#160)" 0 "" \
  import_transferred "$CLEANLOG"
check "import: ...so the wall is the KEYS and not the tier alone (#160 D1)" 1 "" \
  grep -qF 'REFUSED BEFORE THE TRANSFER' "$CLEANLOG.out"

# --force is the door (#160 D3). It exists because the refusal is an
# INFERENCE — read off the artifact's keys, with only the VM case measured —
# and an inference must never be the last word on a supported tier's own
# file. Same artifact, same tier, same keys as the refusal above: the only
# difference is the flag, so what these assert is the flag and nothing else.
FORCELOG="$IWORK/force-import.log"
check "import: --force skips the pre-flight on the restricted tier (#160 D3)" 0 \
  "imported work" importfile "$FORCELOG" "$VM_ART" --force
check "import: ...and really does reach 'incus import' (#160 D3)" 0 "" \
  import_transferred "$FORCELOG"
check "import: ...printing no refusal it just overrode (#160 D3)" 1 "" \
  grep -qF 'REFUSED BEFORE THE TRANSFER' "$FORCELOG.out"
# -f is the same flag, and the OPTIONS block promises both spellings.
check "import: ...under its short spelling too (#160 D3)" 0 "imported work" \
  importfile "$IWORK/force-short.log" "$VM_ART" -f
# The door swings one way. --force does not disable the wall for the next
# import, and it is not a mode: re-run without it and the refusal is back.
check "import: ...leaving the wall standing for the next import (#160 D3)" 1 \
  "REFUSED BEFORE THE TRANSFER" importfile "$RESTLOG" "$VM_ART"
unset SHIM_PREFIX

# The wall is tier-scoped, and this is what stops it becoming an import ban:
# the SAME artifact, same keys, on the admin tier, goes through.
ADMINLOG="$IWORK/admin-import.log"
check "import: the admin tier imports that same artifact (#160)" 0 "imported work" \
  importfile "$ADMINLOG" "$VM_ART"
check "import: ...and its transfer really does start (#160)" 0 "" \
  import_transferred "$ADMINLOG"
check "import: ...with no restricted-tier refusal anywhere in sight (#160)" 1 "" \
  grep -qF 'REFUSED BEFORE THE TRANSFER' "$ADMINLOG.out"

# Ordering, asserted against the source too: a runtime absence proves the wall
# fired on THIS fixture, and this proves it cannot be reordered under one that
# does not. Same shape as the collision guard's assertion above.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "import: the wall precedes 'incus import' in cmd_import (#160)" 0 "" bash -c '
  fn="$(awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  wall="$(printf "%s\n" "$fn" | grep -n "artifact_lowlevel_keys" | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "incus import" | head -1 | cut -d: -f1)"
  [ -n "$wall" ] && [ -n "$run" ] && [ "$wall" -lt "$run" ]'

# The key reader on its own. It decides what the wall refuses, so it is worth
# proving it reads the artifact's keys and not merely something shaped like a
# key: a restricted project blocks the low-level namespaces and nothing else,
# and a reader that swept up ordinary config would refuse every artifact for
# the wrong reason.
LLKEYS="$(mktemp)"
awk '/^artifact_lowlevel_keys\(\) \{/,/^\}/' "$BOX" > "$LLKEYS"
check "import: the key reader was extracted (guards the awk)" 0 "volatile" cat "$LLKEYS"
check "import: the extracted key reader is valid bash" 0 "" bash -n "$LLKEYS"
lowlevel_keys() { bash -c '. "$0"; artifact_lowlevel_keys' "$LLKEYS" < "$1"; }
lowlevel_has() { lowlevel_keys "$1" | grep -qE "$2"; }
check "import: the key reader finds the key incus refused (#160)" 0 "" \
  lowlevel_has "$VM_IDX" '^volatile\.uuid\.generation$'
check "import: ...and the rest of the volatile set with it (#160)" 0 "" \
  lowlevel_has "$VM_IDX" '^volatile\.eth0\.hwaddr$'
check "import: ...but not config a restricted project allows (#160)" 1 "" \
  lowlevel_has "$VM_IDX" '^image\.os$'
check "import: ...nor the limits an operator legitimately sets (#160)" 1 "" \
  lowlevel_has "$VM_IDX" '^limits\.'
# 'raw.*' is the other low-level namespace a restricted project blocks. No box
# artifact carries it today; a hand-rolled export can, and the wall should not
# have to be rediscovered when one does.
RAW_IDX="$IWORK/raw-index.yaml"
printf 'name: work\nconfig:\n  instance:\n    config:\n      raw.qemu: -smbios foo\n' > "$RAW_IDX"
check "import: the key reader also catches the raw.* namespace (#160)" 0 "" \
  lowlevel_has "$RAW_IDX" '^raw\.qemu$'
# An index with no config section yields nothing at all — the silent degrade
# above, at the level of the reader rather than the command.
check "import: an index with no config yields no keys (#160)" 1 "" \
  lowlevel_has "$IWORK/backup/index.yaml" '.'
rm -f "$LLKEYS"

# The help says so before you spend the transfer to find out.
check "help import warns the restricted tier off (#160)" 0 "ON THE RESTRICTED TIER" \
  "$BOX" help import
check "help import names the key class, not just the tier (#160)" 0 "volatile" \
  "$BOX" help import
check "help import keeps export one-way rather than implying parity (#160)" 0 "Export still works" \
  "$BOX" help import
# The override is documented where it is used and where it is listed, and in
# both places with its price. A flag a user only ever meets in an error
# message is a flag they meet at the worst possible moment.
check "help import documents --force (#160 D3)" 0 "--force overrides that refusal" \
  "$BOX" help import
check "help import prices it there too, not just in the refusal (#160 D3)" 0 \
  "pay the whole transfer" "$BOX" help import
check "the OPTIONS block lists --force for import (#160 D3)" 0 \
  "pre-flight refusal (import)" "$BOX" help

# --- the read half: 'box info' must not let the mint be misread -------------
# The whole hazard: MINTED carries a time that is deliberately NOT this host's,
# and a reader who meets it alone will take it for one. The IMPORTED line sits
# directly under it and states the only thing box actually knows — the
# ORDERING. It does not claim another host: a box can be exported and
# re-imported onto the SAME host (#66's upgrade advice), and nothing records
# which host minted it.
IMPCFG="$MWORK/imported.cfg"
{ cat "$STAMPED"
  echo 'user.box.imported 2026-07-20T09:14:03Z'
  echo 'user.box.imported.by 0.8.1'
  echo 'user.box.imported.last 2026-07-20T09:14:03Z'
  echo 'user.box.imported.last.by 0.8.1'
  echo 'user.box.imported.count 1'; } > "$IMPCFG"
check "info: surfaces when the box arrived, and by which box (#131)" \
  0 "IMPORTED   2026-07-20T09:14:03Z by box 0.8.1" infobox "$IMPCFG"
check "info: ...and says the mint above is NOT this arrival (#131)" \
  0 "the mint above predates it" infobox "$IMPCFG"
check "info: ...while the artifact's mint time still reads unchanged (#131)" \
  0 "MINTED     2026-07-19T14:22:07Z by box 0.8.0" infobox "$IMPCFG"
# It must not invent a location for the mint — box has no record of one.
check "info: ...and never claims the mint happened on another host (#131)" 1 "" \
  info_has "$IMPCFG" 'another host|elsewhere|remote host'
# A single trip prints ONE line: both pairs hold the same values and a
# 'first was...' continuation would be noise.
check "info: a single import prints no redundant 'first was' line (#131)" 1 "" \
  info_has "$IMPCFG" 'the first was'

# A box that made the trip more than once shows both ends and the count.
IMPCFG2="$MWORK/imported-twice.cfg"
{ cat "$STAMPED"
  echo 'user.box.imported 2026-06-15T08:00:00Z'
  echo 'user.box.imported.by 0.7.0'
  echo 'user.box.imported.last 2026-07-20T09:14:03Z'
  echo 'user.box.imported.last.by 0.8.1'
  echo 'user.box.imported.count 3'; } > "$IMPCFG2"
check "info: a repeat traveller shows the latest trip (#131)" \
  0 "IMPORTED   2026-07-20T09:14:03Z by box 0.8.1" infobox "$IMPCFG2"
check "info: ...and the first one, with the count (#131)" \
  0 "import 3 — the first was 2026-06-15T08:00:00Z by box 0.7.0" infobox "$IMPCFG2"

# An imported CLONE reads as a clone that also travelled — the two facts sit
# side by side, neither having eaten the other.
IMPCLONE="$MWORK/imported-clone.cfg"
# mode.asked is dropped, not merely unasserted: since #129 the clone path
# clears it (nobody asked THIS box anything), so a fixture built from the mint
# shape that kept the key would describe a box the clone path cannot produce.
# No assertion here reads it — which is exactly why it would rot unnoticed.
{ grep -v '^user.box.origin ' "$IMPCFG" | grep -v '^user.box.mode.asked '
  echo 'user.box.origin clone'
  echo 'user.box.origin.from work/authed'; } > "$IMPCLONE"
check "info: an imported clone is still a clone (#131)" \
  0 "ORIGIN     clone of work/authed" infobox "$IMPCLONE"
check "info: ...and still says it was imported (#131)" 0 "IMPORTED" infobox "$IMPCLONE"

# A box that was never imported says nothing at all — no empty IMPORTED line,
# the same rule every other key in the block follows.
check "info: a never-imported box prints no IMPORTED line (#131)" 1 "" \
  info_has "$STAMPED" '^IMPORTED'
# And a legacy box with no stamp whatsoever still reads as 'not recorded'.
check "info: a stampless box still says the mint was not recorded (#131)" \
  0 "predates the mint stamp" infobox "$LEGACY"
check "info: ...and prints no IMPORTED line for a key it does not have (#131)" 1 "" \
  info_has "$LEGACY" '^IMPORTED'

check "help import: names the import record it writes (#131)" 0 "import EVENT" \
  "$BOX" help import
check "help import: says the mint stamp is NOT rewritten (#131)" 0 "does not overwrite" \
  "$BOX" help import
# The help is where an operator meets the id, and 'rename' is where they need
# it: the verb's own text is what says the name is an alias and the id is not.
check "help rename: says the id follows the box (#181)" 0 "user.box.id" \
  "$BOX" help rename
check "help info: says the id outlives a rename (#181)" 0 "outlives a rename" \
  "$BOX" help info
check "help import: names the fresh id it draws (#181)" 0 "fresh box id" \
  "$BOX" help import

rm -rf "$ISHIM" "$IWORK"

rm -rf "$MSHIM" "$MWORK"

# The rehearsal itself stays runnable: syntax-checked here, run on real hosts.
check "multiuser.sh is valid bash" 0 "" bash -n "$ROOT/drill/multiuser.sh"
check "multiuser.sh refuses without the env gate" 2 "opt in" \
  bash "$ROOT/drill/multiuser.sh" --yes
check "grant-user.sh is valid bash"  0 "" bash -n "$ROOT/host/grant-user.sh"
check "revoke-user.sh is valid bash" 0 "" bash -n "$ROOT/host/revoke-user.sh"
check "teardown-host.sh is valid bash" 0 "" bash -n "$ROOT/host/teardown-host.sh"

# ---------------------------------------------------------------------------
# Revoke leaves NOTHING (the grant/revoke cleanliness pass). The gap this
# closes: --purge removed /var/lib/incus/users/<uid> but never RE-CHECKED it —
# the one path its own absence assert did not cover. And the stat must ride
# $SUDO: /var/lib/incus is not traversable by a non-root admin, so a bare
# [ -d ] answers "absent" for a directory that is very much there.
# ---------------------------------------------------------------------------
check "revoke: purge removes the incus-user state directory" 0 "" \
  grep -qF '/var/lib/incus/users/' "$ROOT/host/revoke-user.sh"
check "revoke: the absence assert covers the incus-user state too" 0 "" \
  bash -c 'awk "/Assert absence/,0" "'"$ROOT"'/host/revoke-user.sh" | grep -q "/var/lib/incus/users/"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "revoke: the state checks go through \$SUDO test (an unprivileged stat lies)" 0 "" \
  grep -qF '$SUDO test -d "/var/lib/incus/users/$uid"' "$ROOT/host/revoke-user.sh"

# ---------------------------------------------------------------------------
# The #80 guard and BOX_SUBNET. setup-host run inside a box used to build a
# nested boxnet on the guest's own uplink subnet — captured gateway, duplicate
# routes, intermittent egress blackouts. The guard's two pure functions are
# extracted and DRIVEN (a shim ip serves canned route tables, the same seam as
# the shim id), and then the WHOLE script is driven end to end under shims:
# the refusal paths must exit 1 having touched nothing (the incus/sudo shims
# log every call, and the log must not exist), the converge path must still
# run, and BOX_SUBNET must plumb through to every derived value.
# ---------------------------------------------------------------------------
cat > "$SHIMDIR/ip" <<'SHIM'
#!/usr/bin/env bash
# Fake `ip`: canned tables for the #80 guard and signature — just the reads
# setup-host and doctor make. Specific patterns first: case takes the first hit.
case "$*" in
  "-4 -o addr show dev boxnet") printf '%s\n' "${FAKE_IP4_BOXNET:-}" ;;
  "-4 route show default")      printf '%s\n' "${FAKE_IP4_DEFAULT:-}" ;;
  "-4 route show")              printf '%s\n' "${FAKE_IP4_ROUTES:-}" ;;
  "-4 -o addr show")            printf '%s\n' "${FAKE_IP4_ADDRS:-}" ;;
esac
exit 0
SHIM
chmod +x "$SHIMDIR/ip"

# The route tables, verbatim from issue #80's capture (the poisoned guest) and
# from the states around it.
D_INBOX='default via 10.88.0.1 dev enp5s0 proto dhcp src 10.88.0.202 metric 1024'
D_LAN='default via 192.168.1.1 dev eno1 proto dhcp metric 100'
A_GUEST='2: enp5s0    inet 10.88.0.202/24 metric 1024 brd 10.88.0.255 scope global dynamic enp5s0'
A_HOSTSTACK='2: eno1    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic eno1
5: boxnet    inet 10.88.0.1/24 scope global boxnet'
A_FOREIGN='2: eno1    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic eno1
3: virbr7    inet 10.88.0.7/24 brd 10.88.0.255 scope global virbr7'

SUBFN="$(mktemp)"
awk '/^valid_subnet\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$SUBFN"
check "valid_subnet: extracted from setup-host.sh (guards the awk)" 0 "return 1" cat "$SUBFN"
check "valid_subnet: the extracted function is valid bash" 0 "" bash -n "$SUBFN"
vsub() { bash -c ". '$SUBFN'; valid_subnet \"\$1\"" _ "$1"; }
check "valid_subnet: the default is valid"                 0 "" vsub 10.88.0.0/24
check "valid_subnet: the documented escape hatch is valid" 0 "" vsub 10.89.0.0/24
check "valid_subnet: any a.b.c.0/24 is valid"              0 "" vsub 192.168.7.0/24
check "valid_subnet: not-a-/24 is refused"                 1 "" vsub 10.88.0.0/16
check "valid_subnet: a nonzero host octet is refused"      1 "" vsub 10.88.0.5/24
check "valid_subnet: an octet past 255 is refused"         1 "" vsub 300.88.0.0/24
check "valid_subnet: a bare address is refused"            1 "" vsub 10.88.0.0
check "valid_subnet: garbage is refused"                   1 "" vsub banana
check "valid_subnet: an empty value is refused"            1 "" vsub ""
rm -f "$SUBFN"

CLMFN="$(mktemp)"
awk '/^subnet_claimant\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$CLMFN"
check "subnet_claimant: extracted from setup-host.sh (guards the awk)" 0 "DEFAULT GATEWAY" cat "$CLMFN"
check "subnet_claimant: the extracted function is valid bash" 0 "" bash -n "$CLMFN"
claim() { # claim <subnet> <default-route> <addrs>
  FAKE_IP4_DEFAULT="$2" FAKE_IP4_ADDRS="$3" PATH="$SHIMDIR:$PATH" \
    bash -c ". '$CLMFN'; subnet_claimant \"\$1\"" _ "$1"
}
check "claimant: the default gateway inside the target is the smoking gun" \
  0 "DEFAULT GATEWAY" claim 10.88.0.0/24 "$D_INBOX" "$A_GUEST"
check "claimant: a foreign interface inside the target is named" \
  0 "virbr7" claim 10.88.0.0/24 "$D_LAN" "$A_FOREIGN"
check "claimant: boxnet's own prior claim is the converge path — CLEAN" \
  1 "" claim 10.88.0.0/24 "$D_LAN" "$A_HOSTSTACK"
check "claimant: a free subnet is clean" \
  1 "" claim 10.89.0.0/24 "$D_LAN" "$A_HOSTSTACK"
check "claimant: 10.8.0.0/24 does not prefix-match 10.88.x (the dot terminates)" \
  1 "" claim 10.8.0.0/24 "$D_INBOX" "$A_GUEST"
rm -f "$CLMFN"

# --- choose_subnet: the four-case decision, driven case by case -------------
# 1 explicit pin: honored or refused, never overridden. 2 no pin + bridge:
# converge to the bridge (the bridge IS the pin) — the scan never runs with a
# bridge present. 3 no pin, no bridge, default free: default. 4 default
# claimed: scan 10.89…10.127, first free wins, loudly; refuse when all claimed.
PICKFN="$(mktemp)"
awk '/^(valid_subnet|subnet_claimant|choose_subnet)\(\) \{/,/^\}/' \
  "$ROOT/host/setup-host.sh" > "$PICKFN"
check "choose_subnet: extracted with its helpers (guards the awk)" 0 "auto-picked" cat "$PICKFN"
check "choose_subnet: subnet_claimant came along" 0 "DEFAULT GATEWAY" cat "$PICKFN"
check "choose_subnet: the extracted functions are valid bash" 0 "" bash -n "$PICKFN"
pick() { # pick <pin> <default-route> <addrs> [boxnet-addr]
  FAKE_IP4_DEFAULT="$2" FAKE_IP4_ADDRS="$3" FAKE_IP4_BOXNET="${4:-}" PATH="$SHIMDIR:$PATH" \
    bash -c ". '$PICKFN'; choose_subnet \"\$1\"" _ "$1"
}
pickout()   { pick "$@" 2>/dev/null; }          # stdout only: the choice itself
pickquiet() { [ -z "$(pick "$@" 2>&1 >/dev/null)" ]; }  # stderr must be EMPTY
picknoscan(){ ! pick "$@" 2>&1 | grep -qF auto-picked; }

# The bridge lines and the both-claimed / all-claimed address tables.
B_88='5: boxnet    inet 10.88.0.1/24 scope global boxnet'
B_89='5: boxnet    inet 10.89.0.1/24 scope global boxnet'
A_TWOCLAIM="$A_GUEST
3: virbr7    inet 10.89.0.7/24 brd 10.89.0.255 scope global virbr7"
A_ALLCLAIM="$(for b in $(seq 88 127); do
  printf '%d: virbr%d    inet 10.%d.0.7/24 brd 10.%d.0.255 scope global virbr%d\n' \
    "$((b - 85))" "$((b - 87))" "$b" "$b" "$((b - 87))"
done)"

# Case 1 — the pin. Refusals identical in spirit to the pre-autopick gate.
check "pick: pinned + gw-in-subnet REFUSES, names issue #80" \
  1 "issue #80" pick 10.88.0.0/24 "$D_INBOX" "$A_GUEST"
check "pick: pinned + foreign interface REFUSES, names it" \
  1 "virbr7" pick 10.88.0.0/24 "$D_LAN" "$A_FOREIGN"
check "pick: a pinned refusal still names BOX_SUBNET" \
  1 "BOX_SUBNET" pick 10.88.0.0/24 "$D_INBOX" "$A_GUEST"
check "pick: pinned against a disagreeing bridge REFUSES (never re-addresses)" \
  1 "never re-addresses" pick 10.88.0.0/24 "$D_LAN" "$A_HOSTSTACK" "$B_89"
check "pick: a garbage pin is refused by name" \
  1 "not a sane subnet" pick banana "$D_LAN" "$A_HOSTSTACK"
check "pick: a pin that clears the gate is used verbatim" \
  0 "10.89.0.0/24" pickout 10.89.0.0/24 "$D_INBOX" "$A_GUEST"
check "pick: ...silently — a pin is the operator talking, not us" \
  0 "" pickquiet 10.89.0.0/24 "$D_INBOX" "$A_GUEST"

# Case 2 — no pin, a bridge: converge to ITS subnet. No refusal, no scan —
# even when the default is claimed (THIS machine: nested stack, uplink on
# 10.88, bridge remapped to 10.89 — the #80 workaround host, bare re-run).
check "pick: bridge present converges to the bridge's own subnet" \
  0 "10.89.0.0/24" pickout "" "$D_INBOX" "$A_GUEST
$B_89" "$B_89"
check "pick: ...announcing the convergence (an off-default bridge is worth a line)" \
  0 "converging" pick "" "$D_INBOX" "$A_GUEST
$B_89" "$B_89"
check "pick: ...and the scan never ran (case 2 precedes case 4)" \
  0 "" picknoscan "" "$D_INBOX" "$A_GUEST
$B_89" "$B_89"
check "pick: bridge on the DEFAULT subnet converges silently (plain re-run)" \
  0 "" pickquiet "" "$D_LAN" "$A_HOSTSTACK" "$B_88"
check "pick: ...to the default" \
  0 "10.88.0.0/24" pickout "" "$D_LAN" "$A_HOSTSTACK" "$B_88"
# The poisoned state (#80 verbatim: bridge AND uplink both on 10.88) must not
# converge — rebuilding there re-arms the blackouts. Refuse, name the fix.
check "pick: a bridge on a FOREIGN-claimed subnet refuses (the poisoned state)" \
  1 "poisoned" pick "" "$D_INBOX" "$A_GUEST
$B_88" "$B_88"
check "pick: ...naming the bridge move as the fix" \
  1 "ipv4.address" pick "" "$D_INBOX" "$A_GUEST
$B_88" "$B_88"

# Case 3 — no pin, no bridge, default free: the default, silently.
check "pick: a free default host gets 10.88.0.0/24" \
  0 "10.88.0.0/24" pickout "" "$D_LAN" ""
check "pick: ...with no announcement" 0 "" pickquiet "" "$D_LAN" ""

# Case 4 — no pin, no bridge, default claimed: the nested case. First free
# candidate wins, the announcement names the claimant and the pin.
check "pick: default claimed by the gateway auto-picks 10.89.0.0/24" \
  0 "10.89.0.0/24" pickout "" "$D_INBOX" "$A_GUEST"
check "pick: ...saying so loudly" \
  0 "auto-picked 10.89.0.0/24" pick "" "$D_INBOX" "$A_GUEST"
check "pick: ...naming WHY (the machine's own gateway = inside a box)" \
  0 "DEFAULT GATEWAY" pick "" "$D_INBOX" "$A_GUEST"
check "pick: ...and how to pin it for scripts" \
  0 "BOX_SUBNET=10.89.0.0/24" pick "" "$D_INBOX" "$A_GUEST"
check "pick: default AND 10.89 claimed skips to 10.90.0.0/24" \
  0 "10.90.0.0/24" pickout "" "$D_INBOX" "$A_TWOCLAIM"
check "pick: every candidate claimed → the old refusal" \
  1 "refusing to build boxnet" pick "" "$D_LAN" "$A_ALLCLAIM"
check "pick: ...naming the end of the scan range" \
  1 "10.127.0.0/24" pick "" "$D_LAN" "$A_ALLCLAIM"
check "pick: ...and BOX_SUBNET as the way out" \
  1 "BOX_SUBNET" pick "" "$D_LAN" "$A_ALLCLAIM"
rm -f "$PICKFN"

# --- the whole script, driven: refuse-before-mutation, converge, plumb-through
SETUPSHIM="$(mktemp -d)"
cat > "$SETUPSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the driven setup-host: records every call (and, for the
# stdin verbs, the stdin) to $FAKE_INCUS_LOG, answers the existence probes
# from FAKE_HAVE_*, and never goes near a daemon.
[ -n "${FAKE_INCUS_LOG:-}" ] && printf 'incus %s\n' "$*" >> "$FAKE_INCUS_LOG"
case "$*" in
  *"admin init --preseed"*|*"acl edit"*|*"profile edit"*)
    if [ -n "${FAKE_INCUS_LOG:-}" ]; then sed 's/^/  | /' >> "$FAKE_INCUS_LOG"; else cat >/dev/null; fi ;;
esac
case "$*" in
  "storage show default")         [ -n "${FAKE_HAVE_STORAGE:-}" ] || exit 1 ;;
  # The live pool's placement (#180): FAKE_POOL_SOURCE unset answers the way a
  # pool whose source was never recorded does — an empty line, not a refusal.
  "storage get default source")   printf '%s\n' "${FAKE_POOL_SOURCE:-}" ;;
  # ...and the source Incus was HANDED, which for a block device is not the one
  # above: btrfs formats the device and overwrites 'source' with the new
  # filesystem's UUID. Unset answers as a 'dir' pool does — this key absent.
  "storage get default volatile.initial_source")
                                  printf '%s\n' "${FAKE_POOL_INITIAL_SOURCE:-}" ;;
  *"admin init --preseed"*)       [ -z "${FAKE_PRESEED_FAIL:-}" ] || exit 1 ;;
  "network show boxnet")          [ -n "${FAKE_HAVE_BOXNET:-}" ]  || exit 1 ;;
  "network acl show box-isolate") [ -n "${FAKE_HAVE_ACL:-}" ]     || exit 1 ;;
  "profile show box-net")         [ -n "${FAKE_HAVE_PROFILE:-}" ] || exit 1 ;;
esac
exit 0
SHIM
cat > "$SETUPSHIM/sudo" <<'SHIM'
#!/usr/bin/env bash
# Fake sudo: logs to $FAKE_SUDO_LOG and swallows everything — the driven
# setup-host must never mutate the machine running this suite.
[ -n "${FAKE_SUDO_LOG:-}" ] && printf 'sudo %s\n' "$*" >> "$FAKE_SUDO_LOG"
exit 0
SHIM
cat > "$SETUPSHIM/lsblk" <<'SHIM'
#!/usr/bin/env bash
# Fake lsblk: what filesystem UUID does the requested path hold RIGHT NOW
# (#180, panel round 3)? FAKE_DEV_UUID answers for the device named in
# FAKE_DEV_UUID_FOR (default /dev/sdb); every other path, and an unset
# FAKE_DEV_UUID, exit non-zero with no output — the way lsblk answers for a
# path that is not a block device. Without this shim the matcher could not be
# contradicted, which is how the class it guards survived two rounds.
[ -n "${FAKE_INCUS_LOG:-}" ] && printf 'lsblk %s\n' "$*" >> "$FAKE_INCUS_LOG"
dev="${*: -1}"
[ -n "${FAKE_DEV_UUID:-}" ] || exit 32
[ "$dev" = "${FAKE_DEV_UUID_FOR:-/dev/sdb}" ] || exit 32
printf '%s\n' "$FAKE_DEV_UUID"
SHIM
chmod +x "$SETUPSHIM/incus" "$SETUPSHIM/sudo" "$SETUPSHIM/lsblk"

runsetup() { # runsetup [VAR=val ...] — the real setup-host, under shims
  env FAKE_UID=1000 FAKE_GROUPS="users incus-admin" \
      PATH="$SETUPSHIM:$SHIMDIR:$PATH" "$@" bash "$ROOT/host/setup-host.sh"
}

W80="$(mktemp -d)"
# Refusal 1: an EXPLICIT pin on the subnet the default gateway sits inside —
# the inside of a box, and the operator said 10.88 out loud. A pin is never
# silently overridden, so this refuses exactly as it did pre-autopick.
check "setup-host: a pinned gw-claimed subnet REFUSES and names issue #80" 1 "issue #80" \
  runsetup BOX_SUBNET=10.88.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W80/g1.log" FAKE_SUDO_LOG="$W80/s1.log"
check "setup-host: ...naming BOX_SUBNET as the way out" 1 "BOX_SUBNET" \
  runsetup BOX_SUBNET=10.88.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: the refusal made NO incus call (refuse precedes mutation)" 1 "" \
  test -e "$W80/g1.log"
check "setup-host: the refusal made NO sudo call either" 1 "" \
  test -e "$W80/s1.log"
# Refusal 2: a pin on a subnet a foreign interface owns an address inside.
check "setup-host: a pinned foreign-claimed subnet REFUSES" 1 "virbr7" \
  runsetup BOX_SUBNET=10.88.0.0/24 FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_FOREIGN"
# Refusal 3: garbage BOX_SUBNET dies at the gate.
check "setup-host: a garbage BOX_SUBNET is refused by name" 1 "not a sane subnet" \
  runsetup BOX_SUBNET=banana
check "setup-host: a /16 BOX_SUBNET is refused" 1 "not a sane subnet" \
  runsetup BOX_SUBNET=10.88.0.0/16
# Refusal 4: an existing bridge on ANOTHER subnet is never re-addressed.
check "setup-host: a bridge on another subnet refuses (converge, don't re-address)" \
  1 "never re-addresses" \
  runsetup FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_HOSTSTACK" \
           FAKE_IP4_BOXNET='5: boxnet    inet 10.89.0.1/24 scope global boxnet' \
           BOX_SUBNET=10.88.0.0/24
# The legitimate re-run: boxnet itself owns the subnet — setup-host converges.
check "setup-host: a prior boxnet claiming the subnet CONVERGES (no false positive)" \
  0 "Host ready" \
  runsetup FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_HOSTSTACK" \
           FAKE_IP4_BOXNET='5: boxnet    inet 10.88.0.1/24 scope global boxnet' \
           FAKE_HAVE_STORAGE=1 FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1
# BOX_SUBNET plumbs through: a fresh build on 10.89.0.0/24 must derive EVERY
# value from it — the bridge address and the ACL's gateway carve-out.
check "setup-host: BOX_SUBNET drives a fresh build to completion" 0 "Host ready" \
  runsetup BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W80/g2.log" FAKE_SUDO_LOG="$W80/s2.log"
check "setup-host: ...the bridge derives from BOX_SUBNET" 0 "" \
  grep -qF 'network create boxnet ipv4.address=10.89.0.1/24' "$W80/g2.log"
check "setup-host: ...and so does the ACL's gateway carve-out" 0 "" \
  grep -qF 'destination: 10.89.0.1/32' "$W80/g2.log"
# The nested case with ZERO flags — #80's tables, no pin, no bridge: the
# auto-pick must land the whole build on 10.89, announced, and every derived
# value must follow the pick, not the default.
check "setup-host: nested with no flags auto-picks and completes" 0 "Host ready" \
  runsetup FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W80/g3.log" FAKE_SUDO_LOG="$W80/s3.log"
check "setup-host: ...announcing the auto-pick" 0 "auto-picked 10.89.0.0/24" \
  runsetup FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...the bridge follows the pick" 0 "" \
  grep -qF 'network create boxnet ipv4.address=10.89.0.1/24' "$W80/g3.log"
check "setup-host: ...the ACL carve-out follows the pick" 0 "" \
  grep -qF 'destination: 10.89.0.1/32' "$W80/g3.log"

# --- Where the pool LIVES (#180) -------------------------------------------
# pool_block is pure — driver and source in, the preseed's storage block out —
# so it is extracted and driven, the valid_subnet seam. The unset case is
# compared BYTE-FOR-BYTE against the block that shipped before the knob
# existed: "the pool is byte-for-byte the pool created today" is the issue's
# own named regression, and a substring match would not prove it.
W180="$(mktemp -d)"
POOLFN="$(mktemp)"
awk '/^pool_block\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$POOLFN"
check "pool_block: extracted from setup-host.sh (guards the awk)" 0 "storage_pools" cat "$POOLFN"
check "pool_block: the extracted function is valid bash" 0 "" bash -n "$POOLFN"
pblock() { bash -c ". '$POOLFN'; pool_block \"\$1\" \"\$2\"" _ "$1" "${2:-}"; }
printf 'storage_pools:\n- name: default\n  driver: btrfs\n' > "$W180/pre180.yaml"
pblock btrfs "" > "$W180/unset.yaml"
check "pool_block: with no source, byte-for-byte the pre-#180 block" 0 "" \
  cmp -s "$W180/pre180.yaml" "$W180/unset.yaml"
check "pool_block: a source is emitted verbatim" 0 "  source: '/dev/sdb'" pblock btrfs /dev/sdb
check "pool_block: ...and the driver line is untouched beside it" 0 "  driver: btrfs" pblock btrfs /dev/sdb
# shellcheck disable=SC2016  # the $() runs in the inner bash, not this one
check "pool_block: ...as a key OF the pool, i.e. under the driver" 0 "" bash -c '
  . "'"$POOLFN"'"; [ "$(pool_block btrfs /dev/sdb | tail -1)" = "  source: '"'"'/dev/sdb'"'"'" ]'
# AC6: the dir fallback is a DRIVER decision and placement is not — a host that
# cannot do btrfs still places its pool where it was told to.
check "pool_block: the dir fallback carries the source too" 0 "  source: '/data/bulk/incus'" \
  pblock dir /data/bulk/incus
check "pool_block: ...and is still the dir driver" 0 "  driver: dir" pblock dir /data/bulk/incus

# "Verbatim" is a claim about the value INCUS PARSES, not about the bytes on
# the line, and a substring check cannot tell the two apart. A plain YAML
# scalar ends at ' #' — so '/data/bulk/a #archive', a legal directory name and
# a legal Incus source, used to reach the daemon as '/data/bulk/a' and the pool
# was built somewhere nobody named, silently: the very defect #180 exists to
# close, arriving through the front door (panel round 2).
#
# Held from both sides. First WITHOUT a parser, so a runner missing pyyaml
# still fails on the regression rather than skipping it: the emitted source
# must be a QUOTED scalar, which is exactly what makes the value survive.
# shellcheck disable=SC2016  # the $() runs in the inner bash, not this one
check "pool_block: the source is emitted as a QUOTED yaml scalar" 0 "" bash -c '
  . "'"$POOLFN"'"; [ "$(pool_block btrfs "/data/bulk/a #archive" | tail -1)" \
     = "  source: '"'"'/data/bulk/a #archive'"'"'" ]'
check "pool_block: ...so the comment marker is inside the quotes, not opening one" 0 "" bash -c '
  . "'"$POOLFN"'"; pool_block btrfs "/data/bulk/a #archive" | tail -1 | grep -qE "^  source: .*archive.$"'
# shellcheck disable=SC2016  # the $() runs in the inner bash, not this one
check "pool_block: a quote in the source is doubled, as yaml escapes it" 0 "" bash -c '
  . "'"$POOLFN"'"; [ "$(pool_block btrfs "/data/o'"'"'brien" | tail -1)" \
     = "  source: '"'"'/data/o'"'"''"'"'brien'"'"'" ]'
# ...then WITH one, which is the assertion that actually means it: parse the
# block Incus is handed and compare the source it would read against the value
# the operator set. Every shape a plain scalar mangles, round-tripped.
if [ "$HAVE_YAML" = 1 ]; then
  roundtrip() { # roundtrip <value> — emitted, parsed, compared
    bash -c '. "'"$POOLFN"'"; pool_block btrfs "$1" > "$2"' _ "$1" "$W180/rt.yaml" \
      && python3 -c '
import sys, yaml
want = sys.argv[1]
got = yaml.safe_load(open(sys.argv[2]))["storage_pools"][0]["source"]
if got != want:
    print("parsed %r, wanted %r" % (got, want)); sys.exit(1)
' "$1" "$W180/rt.yaml"
  }
  check "pool_block: a source containing ' #' round-trips through a yaml parser" 0 "" \
    roundtrip '/data/bulk/a #archive'
  check "pool_block: ...and one containing a space" 0 "" roundtrip '/data/bulk/box pool'
  check "pool_block: ...and one containing a quote" 0 "" roundtrip "/data/o'brien/pool"
  check "pool_block: ...and one containing ': ', which used to break the preseed" 0 "" \
    roundtrip '/data/bulk/a: b'
  check "pool_block: ...and the documented block device, unchanged by any of it" 0 "" \
    roundtrip /dev/sdb
  # The preseed as a WHOLE still parses with the source quoted — the block is
  # spliced into a larger document, and a broken scalar there fails the run.
  check "pool_block: the block is well-formed yaml on its own" 0 "" bash -c '
    . "'"$POOLFN"'"; pool_block btrfs "/data/bulk/a #archive" > "'"$W180"'/whole.yaml"
    python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "'"$W180"'/whole.yaml"'
else
  echo "skip: pool_block yaml round-trip (no python3+pyyaml here; CI has both)"
fi

# The other half of verbatim: reading one back. yaml_scalar is pure — a 'key:'
# line's value in, the value YAML means out — so it is extracted and driven
# like every other seam here. awk's $2 answered "/data/bulk/box" for a pool on
# "/data/bulk/box pool", which is a wrong answer that looks like a right one.
YSFN="$(mktemp)"
awk '/^yaml_scalar\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$YSFN"
awk '/^yaml_value\(\) \{/,/^\}/'  "$ROOT/host/setup-host.sh" >> "$YSFN"
check "yaml_scalar: extracted from setup-host.sh (guards the awk)" 0 "printf" cat "$YSFN"
check "yaml_scalar: the extracted functions are valid bash" 0 "" bash -n "$YSFN"
ys() { bash -c ". '$YSFN'; yaml_scalar \"\$1\"; echo" _ "$1"; }
yv() { bash -c ". '$YSFN'; yaml_value \"\$1\" \"\$2\"; echo" _ "$1" "$2"; }
check "yaml_scalar: a plain scalar is itself" 0 "/dev/sdb" ys " /dev/sdb"
check "yaml_scalar: a plain scalar keeps its spaces" 0 "/data/bulk/box pool" ys " /data/bulk/box pool"
check "yaml_scalar: a single-quoted scalar loses only its quotes" 0 "/data/bulk/a #archive" \
  ys " '/data/bulk/a #archive'"
check "yaml_scalar: a doubled quote inside one is a single quote" 0 "/data/o'brien" \
  ys " '/data/o''brien'"
check "yaml_scalar: a double-quoted scalar is unescaped too" 0 '/data/a"b' ys ' "/data/a\"b"'
# shellcheck disable=SC2016  # the $() runs in the inner bash, not this one
check "yaml_scalar: trailing whitespace is yaml's, not the value's" 0 "" bash -c '
  . "'"$YSFN"'"; [ "$(yaml_scalar "  /dev/sdb   ")" = "/dev/sdb" ]'
# The recorded-but-empty value every loop-backed pool carries, in both
# spellings: absence, not a source named '""'. One normalisation, every key.
# shellcheck disable=SC2016  # the $() runs in the inner bash, not this one
check "yaml_scalar: a bare pair of quotes is absence" 0 "" bash -c '
  . "'"$YSFN"'"; [ -z "$(yaml_scalar "\"\"")" ] && [ -z "$(yaml_scalar "'"''"'")" ]'
check "yaml_scalar: a lone quote is not a quoted scalar" 0 "'" ys "'"
check "yaml_value: reads the value past the first colon, whole" 0 "/data/bulk/a #archive" \
  yv source "config:
  source: '/data/bulk/a #archive'"
check "yaml_value: ...and a value containing a colon survives it" 0 "/data/a: b" \
  yv source "config:
  source: '/data/a: b'"
check "yaml_value: a key it cannot find reads as absent" 0 "" \
  yv volatile.initial_source "config:
  source: /dev/sdb"
check "yaml_value: the driver comes off the same read" 0 "btrfs" \
  yv driver "name: default
driver: btrfs"
rm -f "$YSFN"

# The re-run's match test, pure (requested, live, initial → exit status), and
# driven directly rather than only through the shim — because the shim is
# exactly what hid this. Handed a BLOCK DEVICE, Incus's btrfs driver records
# what it was given in volatile.initial_source, formats the device, and then
# overwrites 'source' with the new filesystem's UUID (lxc/incus@90429bf,
# driver_btrfs.go). So the live source of the DOCUMENTED form is a bare UUID
# forever after, and a match test reading only 'source' refuses every re-run of
# a pool it had just placed correctly.
# The identity probe itself, pure-ish: two tools, either of which answers, and
# NOTHING is not an answer. lsblk first because it needs no privilege — a
# non-root run must not be silently identity-blind — and blkid behind it
# because that is the read Incus itself does to fill 'source'. The fallback is
# driven here rather than only through the end-to-end shim, which uses the
# primary: an untested fallback is a fallback that works until it is needed.
UUIDFN="$(mktemp)"
awk '/^dev_fs_uuid\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$UUIDFN"
check "dev_fs_uuid: extracted from setup-host.sh (guards the awk)" 0 "lsblk" cat "$UUIDFN"
check "dev_fs_uuid: the extracted function is valid bash" 0 "" bash -n "$UUIDFN"
UUIDSHIM="$(mktemp -d)"
mkdir -p "$UUIDSHIM/both" "$UUIDSHIM/none"
cat > "$UUIDSHIM/both/lsblk" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_LSBLK_UUID:-}"
SHIM
cat > "$UUIDSHIM/both/blkid" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_BLKID_UUID:-}"
SHIM
cat > "$UUIDSHIM/driver" <<'SHIM'
#!/usr/bin/env bash
# dev_fs_uuid, run with no privilege escalation and a PATH holding only what
# the caller put there. Prints the answer and nothing else. PATH is set HERE
# rather than through env, so 'no tools at all' does not also mean 'no bash'.
PATH="$1"
. "$2"
SUDO=""
dev_fs_uuid /dev/sdb
echo
SHIM
chmod +x "$UUIDSHIM/both/lsblk" "$UUIDSHIM/both/blkid" "$UUIDSHIM/driver"
devuuid() { # devuuid <PATH> [VAR=val ...] — dev_fs_uuid under a chosen PATH
  local p="$1"; shift
  env "$@" bash "$UUIDSHIM/driver" "$p" "$UUIDFN"
}
# The shim dir comes FIRST, so the shims win wherever a real lsblk or blkid
# also exists; the rest of PATH is there only so their '#!/usr/bin/env bash'
# can find a bash.
check "dev_fs_uuid: lsblk answers when it can, without any privilege" 0 "u-from-lsblk" \
  devuuid "$UUIDSHIM/both:/usr/bin:/bin" FAKE_LSBLK_UUID=u-from-lsblk FAKE_BLKID_UUID=u-from-blkid
check "dev_fs_uuid: ...and blkid answers when lsblk says nothing" 0 "u-from-blkid" \
  devuuid "$UUIDSHIM/both:/usr/bin:/bin" FAKE_LSBLK_UUID= FAKE_BLKID_UUID=u-from-blkid
check "dev_fs_uuid: with neither tool present the answer is NOTHING, not a guess" 0 "" \
  devuuid "$UUIDSHIM/none"
rm -rf "$UUIDSHIM"; rm -f "$UUIDFN"

PLACEDFN="$(mktemp)"
awk '/^pool_placed_at\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$PLACEDFN"
check "pool_placed_at: extracted from setup-host.sh (guards the awk)" 0 "initial" cat "$PLACEDFN"
check "pool_placed_at: the extracted function is valid bash" 0 "" bash -n "$PLACEDFN"
placed() { bash -c ". '$PLACEDFN'; pool_placed_at \"\$1\" \"\$2\" \"\$3\" \"\$4\"" _ "$1" "${2:-}" "${3:-}" "${4:-}"; }
UUID=4ff9b8f1-6e6a-4d0f-9a3c-0d1f2e3a4b5c
UUID_B=0e1d2c3b-4a59-4687-b1a2-c3d4e5f60718
# The regression round 1 found: same device, same request, second run — the
# fourth argument being what /dev/sdb resolves to NOW, which on the honest
# re-run is the filesystem Incus wrote onto it.
check "pool_placed_at: a UUID live source MATCHES the device it was made from" \
  0 "" placed /dev/sdb "$UUID" /dev/sdb "$UUID"
check "pool_placed_at: ...and a DIFFERENT device still does not" \
  1 "" placed /dev/sdc "$UUID" /dev/sdb "$UUID"
# The regression round 3 found, and the reason the fourth argument exists: an
# initial source is a STRING RECORDED AT CREATION, not a claim about what that
# name points at today. Enumeration reuses /dev/sdb for another disk; the pool
# is still on the first one; the documented identical invocation used to say
# "already placed there" about a disk it is not on.
check "pool_placed_at: the device NAME moved — same string, different disk — refuses" \
  2 "" placed /dev/sdb "$UUID" /dev/sdb "$UUID_B"
check "pool_placed_at: ...and the same name still on the same disk re-runs clean" \
  0 "" placed /dev/sdb "$UUID" /dev/sdb "$UUID"
# Fail CLOSED where identity cannot be established at all: the device is gone,
# it is not a block device, or the host has neither lsblk nor blkid. Silence
# there would be the same silence one layer down.
check "pool_placed_at: a request whose identity cannot be read refuses" \
  2 "" placed /dev/sdb "$UUID" /dev/sdb ""
# ...and it is a distinct refusal from "placed somewhere else entirely",
# because they are distinct facts and the way out of each one differs.
check "pool_placed_at: that refusal is NOT the placed-elsewhere one" \
  1 "" placed /dev/sdb /var/lib/incus/disks/default.img "" ""
# Where Incus mangled nothing, identity is not consulted and nothing changes:
# live 'source' is the path itself, so the string IS the current fact. Every
# 'dir' pool and every mounted-path source lands here.
check "pool_placed_at: a path-shaped live source never needs a device identity" \
  0 "" placed /data/bulk/incus /var/lib/incus/x /data/bulk/incus ""
# The 'dir' driver sets no initial source and mangles nothing: the fall back to
# live 'source' is the only correct read there, not a courtesy for old pools.
check "pool_placed_at: with no initial source, live source decides" \
  0 "" placed /data/bulk/incus /data/bulk/incus ""
check "pool_placed_at: ...and decides against a pool placed elsewhere" \
  1 "" placed /dev/sdb /var/lib/incus/disks/default.img ""
check "pool_placed_at: the path shape, where Incus mangles nothing, matches on both" \
  0 "" placed /data/bulk/incus /data/bulk/incus /data/bulk/incus
# A trailing slash is not a mismatch — on either source.
check "pool_placed_at: a trailing slash on the request is not a mismatch" \
  0 "" placed /data/bulk/incus/ /data/bulk/incus ""
check "pool_placed_at: ...nor one on the initial source" \
  0 "" placed /data/bulk/incus /var/lib/incus/x /data/bulk/incus/
# Fail closed: nothing requested, or nothing known, is never a match.
check "pool_placed_at: an empty request never matches" 1 "" placed "" /dev/sdb /dev/sdb
check "pool_placed_at: a pool that reports nothing at all never matches" \
  1 "" placed /dev/sdb "" ""
# An initial source must not match ACROSS pools: it is read, not assumed.
check "pool_placed_at: a loop-backed pool does not match a requested device" \
  1 "" placed /dev/sdb /var/lib/incus/disks/default.img ""

# Driven, end to end under the shims. A fresh host that sets nothing must send
# a preseed with no source: key at all — anything else changes an upgraded
# host's pool.
check "setup-host: a fresh host with no BOX_STORAGE_SOURCE completes" 0 "Host ready" \
  runsetup BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W180/p1.log"
check "setup-host: ...and its preseed carries NO source: key" 1 "" \
  grep -qE '^  \|   source:' "$W180/p1.log"
check "setup-host: ...while the storage block is the one that always shipped" 0 "" \
  grep -qF '  | - name: default' "$W180/p1.log"
check "setup-host: a fresh host places the pool where BOX_STORAGE_SOURCE says" 0 "Host ready" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" FAKE_INCUS_LOG="$W180/p2.log"
check "setup-host: ...the preseed carrying it verbatim" 0 "" \
  grep -qF "  |   source: '/dev/sdb'" "$W180/p2.log"
# ...and the shape a plain scalar silently truncated, driven all the way to the
# preseed's stdin: the pool must be asked for at the path the operator typed,
# not at the prefix before its comment marker.
check "setup-host: a source containing ' #' reaches the preseed whole" 0 "Host ready" \
  runsetup "BOX_STORAGE_SOURCE=/data/bulk/a #archive" BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" FAKE_INCUS_LOG="$W180/p10.log"
check "setup-host: ...quoted, so yaml does not read the rest as a comment" 0 "" \
  grep -qF "  |   source: '/data/bulk/a #archive'" "$W180/p10.log"
if [ "$HAVE_YAML" = 1 ]; then
  # The preseed as the daemon receives it: the shim logs every stdin verb's
  # input under its own call line with a '  | ' prefix, so take the block that
  # follows the preseed call, strip the prefix, and parse what Incus was handed.
  # shellcheck disable=SC2016  # $1/$2 are the inner bash's positional args
  check "setup-host: ...and the preseed Incus was handed parses to that source" 0 "" bash -c '
    awk "/^incus admin init --preseed/ { f = 1; next }
         f && /^  \\| / { sub(/^  \\| /, \"\"); print; next }
         f { exit }" "$1" > "$2"
    [ -s "$2" ] || { echo "no preseed block found in $1"; exit 1; }
    python3 -c "
import sys, yaml
got = yaml.safe_load(open(sys.argv[1]))[\"storage_pools\"][0][\"source\"]
want = \"/data/bulk/a #archive\"
if got != want:
    print(\"preseed carried %r, wanted %r\" % (got, want)); sys.exit(1)
" "$2"' _ "$W180/p10.log" "$W180/p10.yaml"
else
  echo "skip: setup-host preseed yaml parse (no python3+pyyaml here; CI has both)"
fi
# D3, the defect: the pool is created once, so a re-run cannot move it. It used
# to skip in silence; now it names both sources and dies.
check "setup-host: an existing pool placed ELSEWHERE refuses" 1 "already exists somewhere else" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 \
           FAKE_POOL_SOURCE=/var/lib/incus/storage-pools/default \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W180/p3.log"
check "setup-host: ...naming the LIVE source" 1 "live:      /var/lib/incus/storage-pools/default" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 \
           FAKE_POOL_SOURCE=/var/lib/incus/storage-pools/default \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...and the REQUESTED one" 1 "requested: /dev/sdb" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 \
           FAKE_POOL_SOURCE=/var/lib/incus/storage-pools/default \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...pointing at the migration it is NOT (D4)" 1 "that is a migration, not a re-run" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 \
           FAKE_POOL_SOURCE=/var/lib/incus/storage-pools/default \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...and the refusal never reached a preseed" 1 "" \
  grep -q 'admin init' "$W180/p3.log"
check "setup-host: ...nor the bridge it would have built after it" 1 "" \
  grep -q 'network create' "$W180/p3.log"
# The pool exists and IS where it was asked to be: an ordinary clean re-run.
check "setup-host: an existing pool that MATCHES re-runs clean" 0 "Host ready" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 FAKE_POOL_SOURCE=/dev/sdb \
           FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1 \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...saying the pool is already placed there" 0 "already placed there" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 FAKE_POOL_SOURCE=/dev/sdb \
           FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1 \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: a trailing slash is not a mismatch" 0 "Host ready" \
  runsetup BOX_STORAGE_SOURCE=/data/bulk/incus/ FAKE_HAVE_STORAGE=1 \
           FAKE_POOL_SOURCE=/data/bulk/incus FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 \
           FAKE_HAVE_PROFILE=1 BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
# The BLOCK-DEVICE re-run, end to end: the shape the docs recommend, on the
# second run. Incus reports the filesystem UUID it wrote onto /dev/sdb as the
# live source and keeps the device in volatile.initial_source, so this used to
# refuse to re-run against the pool it had itself just placed.
# FAKE_DEV_UUID is what /dev/sdb resolves to NOW: on the honest re-run that is
# the filesystem Incus wrote onto it, which is what makes the recorded initial
# source proof rather than a hopeful string (panel round 3). Overridable, so
# the moved-name and unreadable shapes drive the same path.
runblockdev() { # runblockdev <requested> [extra=val ...]
  local want="$1"; shift
  runsetup "BOX_STORAGE_SOURCE=$want" FAKE_HAVE_STORAGE=1 \
           "FAKE_POOL_SOURCE=$UUID" FAKE_POOL_INITIAL_SOURCE=/dev/sdb \
           "FAKE_DEV_UUID=$UUID" \
           FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1 \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" \
           FAKE_IP4_ADDRS="$A_GUEST" "$@"
}
check "setup-host: a block-device pool re-runs clean against the SAME device" \
  0 "Host ready" runblockdev /dev/sdb FAKE_INCUS_LOG="$W180/p8.log"
check "setup-host: ...saying the pool is already placed there" \
  0 "already placed there" runblockdev /dev/sdb
check "setup-host: ...naming the DEVICE the operator gave, not the UUID" \
  0 "source = /dev/sdb" runblockdev /dev/sdb
check "setup-host: ...with the UUID Incus records named beside it" \
  0 "Incus records it as '$UUID'" runblockdev /dev/sdb
check "setup-host: ...having actually asked for the initial source" 0 "" \
  grep -qF 'storage get default volatile.initial_source' "$W180/p8.log"
check "setup-host: ...and having actually PROBED the device's identity" 0 "" \
  grep -qF 'lsblk --nodeps -rno UUID -- /dev/sdb' "$W180/p8.log"
# The round-3 regression, end to end: the operator types the same command on
# the same host, and /dev/sdb is a different disk than the one the pool is on.
# 'already placed there' would be a lie with a success exit code.
check "setup-host: a block-device pool refuses when the NAME moved to another disk" \
  1 "does not name the disk the pool is on now" \
  runblockdev /dev/sdb "FAKE_DEV_UUID=$UUID_B" FAKE_INCUS_LOG="$W180/p11.log"
check "setup-host: ...naming the filesystem the pool actually is on" \
  1 "live:      $UUID" runblockdev /dev/sdb "FAKE_DEV_UUID=$UUID_B"
check "setup-host: ...and what that path holds instead" \
  1 "now holds: $UUID_B" runblockdev /dev/sdb "FAKE_DEV_UUID=$UUID_B"
check "setup-host: ...saying why a device name is not an identity" \
  1 "assigned in enumeration order" runblockdev /dev/sdb "FAKE_DEV_UUID=$UUID_B"
check "setup-host: ...and how to find the disk that does hold it" \
  1 "lsblk -o NAME,UUID" runblockdev /dev/sdb "FAKE_DEV_UUID=$UUID_B"
check "setup-host: ...that refusal reaching no preseed" 1 "" \
  grep -q 'admin init' "$W180/p11.log"
check "setup-host: ...nor the bridge it would have built after it" 1 "" \
  grep -q 'network create' "$W180/p11.log"
# Fail closed, not open: no device, not a block device, or no lsblk/blkid to
# ask. The old code called that a match; it is the absence of an answer.
check "setup-host: a device whose identity cannot be read refuses too" \
  1 "does not name the disk the pool is on now" \
  runblockdev /dev/sdb FAKE_DEV_UUID= FAKE_INCUS_LOG="$W180/p12.log"
check "setup-host: ...saying that is what happened, not that it mismatched" \
  1 "holds no filesystem this run could read" runblockdev /dev/sdb FAKE_DEV_UUID=
check "setup-host: ...and offering the unset way out" \
  1 "unset BOX_STORAGE_SOURCE" runblockdev /dev/sdb FAKE_DEV_UUID=
check "setup-host: ...that refusal reaching no preseed either" 1 "" \
  grep -q 'admin init' "$W180/p12.log"
# The path shapes are untouched by any of it: where live 'source' is a path,
# Incus mangled nothing, and no device identity is consulted or needed.
check "setup-host: a path-source re-run never probes a device identity" 0 "Host ready" \
  runsetup BOX_STORAGE_SOURCE=/data/bulk/incus FAKE_HAVE_STORAGE=1 \
           FAKE_POOL_SOURCE=/data/bulk/incus FAKE_POOL_INITIAL_SOURCE=/data/bulk/incus \
           FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1 \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
# The FRESH run reports the same way, and this is the run where it matters
# most: the operator has just typed /dev/sdb, and btrfs has just written a
# filesystem UUID over 'source'. Answering with the UUID alone names no disk
# on the host — it was the last line still doing so.
check "setup-host: a fresh placed host reports the DEVICE, not the UUID it became" \
  0 "source = /dev/sdb" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb BOX_SUBNET=10.89.0.0/24 \
           "FAKE_POOL_SOURCE=$UUID" FAKE_POOL_INITIAL_SOURCE=/dev/sdb \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...with the UUID Incus wrote named beside it" \
  0 "Incus records it as '$UUID'" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb BOX_SUBNET=10.89.0.0/24 \
           "FAKE_POOL_SOURCE=$UUID" FAKE_POOL_INITIAL_SOURCE=/dev/sdb \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
# ...and where Incus mangled nothing — every dir pool, every path source — it
# is the one line it always was, with no parenthetical to explain.
check "setup-host: a fresh path-source host reports that path plainly" \
  0 "source = /data/bulk/incus" \
  runsetup BOX_STORAGE_SOURCE=/data/bulk/incus BOX_SUBNET=10.89.0.0/24 \
           FAKE_POOL_SOURCE=/data/bulk/incus FAKE_IP4_DEFAULT="$D_INBOX" \
           FAKE_IP4_ADDRS="$A_GUEST"
# shellcheck disable=SC2016  # $PATH and $@ belong to the inner bash
check "setup-host: ...saying nothing about a UUID it does not have" 1 "" bash -c '
  runsetup() { env FAKE_UID=1000 FAKE_GROUPS="users incus-admin" \
      PATH="'"$SETUPSHIM:$SHIMDIR"':$PATH" "$@" bash "'"$ROOT"'/host/setup-host.sh"; }
  runsetup BOX_STORAGE_SOURCE=/data/bulk/incus BOX_SUBNET=10.89.0.0/24 \
           FAKE_POOL_SOURCE=/data/bulk/incus FAKE_IP4_DEFAULT="'"$D_INBOX"'" \
           FAKE_IP4_ADDRS="'"$A_GUEST"'" 2>&1 | grep -q "Incus records it as"'
check "setup-host: ...and it reached the rest of the run, not a refusal" 0 "" \
  grep -q 'network show boxnet' "$W180/p8.log"
# ...and it is a READ of that key, not an assumption: another device still
# refuses, and the refusal names the disk rather than only the UUID.
check "setup-host: a block-device pool still refuses a DIFFERENT device" \
  1 "already exists somewhere else" runblockdev /dev/sdc FAKE_INCUS_LOG="$W180/p9.log"
check "setup-host: ...naming the device it was made from" 1 "made from: /dev/sdb" \
  runblockdev /dev/sdc
check "setup-host: ...and saying why the live source is not a path" \
  1 "records the new filesystem's UUID" runblockdev /dev/sdc
check "setup-host: ...that refusal reaching no preseed either" 1 "" \
  grep -q 'admin init' "$W180/p9.log"
# Fail closed: a live pool whose source cannot be read cannot be proven to
# match, and proceeding would be the silence this whole change removes.
check "setup-host: an existing pool with no readable source refuses" 1 "reports NO source at all" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
# An unset variable on an existing pool is today's behaviour exactly: no read,
# no refusal, nothing said.
check "setup-host: with the variable unset an existing pool is not judged at all" 0 "Host ready" \
  runsetup FAKE_HAVE_STORAGE=1 FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1 \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W180/p4.log"
check "setup-host: ...not even reading the live source" 1 "" \
  grep -q 'storage get' "$W180/p4.log"
# The value dies at the gate, before anything is touched: a relative path would
# be resolved by the DAEMON, somewhere nobody named.
check "setup-host: a relative BOX_STORAGE_SOURCE is refused by name" 1 "must be an absolute path" \
  runsetup BOX_STORAGE_SOURCE=bulk/incus BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" FAKE_INCUS_LOG="$W180/p5.log"
check "setup-host: ...having made no incus call at all" 1 "" test -e "$W180/p5.log"
# The one shape quoting cannot carry: YAML FOLDS a line break inside a quoted
# scalar to a space, so '/data/a<newline>b' would reach the daemon as
# '/data/a b'. That is the #180 defect through a third door, and the gate
# refuses it rather than mangling it (panel round 3). This is not the gate
# second-guessing a placement Incus would accept — it is declining to transmit
# a value it would transmit WRONG.
check "setup-host: a newline in BOX_STORAGE_SOURCE is refused by name" 1 "control character" \
  runsetup "BOX_STORAGE_SOURCE=$(printf '/data/a\nb')" BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" FAKE_INCUS_LOG="$W180/p13.log"
check "setup-host: ...saying WHY, in terms of what yaml would do to it" \
  1 "folds a line break inside one to a space" \
  runsetup "BOX_STORAGE_SOURCE=$(printf '/data/a\nb')" BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...and having made no incus call at all" 1 "" test -e "$W180/p13.log"
check "setup-host: a tab is the same class and refused the same way" 1 "control character" \
  runsetup "BOX_STORAGE_SOURCE=$(printf '/data/a\tb')" BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
# ...and every shape that IS carried verbatim still passes the gate: the
# refusal is one class wide, not a general tightening of what a source may be.
check "setup-host: a space, a quote and a ' #' still pass the gate untouched" 0 "Host ready" \
  runsetup "BOX_STORAGE_SOURCE=/data/o'brien/a #archive b" BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
# The --minimal fallback creates the pool under /var/lib/incus and cannot carry
# a source, so honouring one is impossible there: refuse rather than build a
# host whose boxes live somewhere the operator did not name.
check "setup-host: a failed preseed with a placement requested refuses" 1 "cannot be honored" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_PRESEED_FAIL=1 BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" FAKE_INCUS_LOG="$W180/p6.log"
check "setup-host: ...never falling back to --minimal" 1 "" \
  grep -q 'admin init --minimal' "$W180/p6.log"
check "setup-host: a failed preseed with NO placement still falls back" 0 "falling back to --minimal" \
  runsetup FAKE_PRESEED_FAIL=1 BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" FAKE_INCUS_LOG="$W180/p7.log"
check "setup-host: ...and reaches --minimal to do it" 0 "" \
  grep -q 'admin init --minimal' "$W180/p7.log"
rm -f "$POOLFN" "$PLACEDFN"
rm -rf "$W180"

rm -rf "$W80" "$SETUPSHIM"

# The decision must be the FIRST effective act — before the incus install, the
# usermod, every apt call. Line order, fail-closed on either grep missing.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "setup-host: the subnet decision precedes the first mutation" 0 "" bash -c '
  guard="$(grep -n "^BOX_SUBNET=\"\$(choose_subnet " "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  mut="$(grep -n "^if ! command -v incus" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$mut" ] && [ "$guard" -lt "$mut" ]'
# The placement gate says "Nothing was changed" too, and that is only true
# ABOVE the apt calls — the suite's shim pre-installs incus, so no driven check
# can tell the difference on a FRESH host. Held by line order, like the one
# above it.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "setup-host: the placement gate precedes the first mutation too (#180)" 0 "" bash -c '
  guard="$(grep -n "^case \"\$BOX_STORAGE_SOURCE\" in" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  mut="$(grep -n "^if ! command -v incus" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$mut" ] && [ "$guard" -lt "$mut" ]'
# box-firewall follows the bridge, wherever BOX_SUBNET put it.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "box-firewall: the gateway is read off the live bridge, not hardcoded" 0 "" \
  grep -qF 'addr show dev "$NET"' "$ROOT/host/box-firewall.sh"
# The drill and migrate probes derive the prefix from the network — a
# BOX_SUBNET host must not fail its own rehearsals.
check "drill: derives the boxnet prefix from the network" 0 "" \
  grep -qF 'network get boxnet ipv4.address' "$ROOT/drill/drill.sh"
check "multiuser: derives the boxnet prefix from the network" 0 "" \
  grep -qF 'network get boxnet ipv4.address' "$ROOT/drill/multiuser.sh"
check "migrate-host: derives the boxnet prefix from the network" 0 "" \
  grep -qF 'network get boxnet ipv4.address' "$ROOT/host/migrate-host.sh"

# ---------------------------------------------------------------------------
# The doctor's #80 signature. gw_squat_signature is pure text → findings, so
# it is extracted and driven against synthetic route tables — including the
# EXACT poisoned state from the issue, the workaround state (bridge remapped:
# clean), and a healthy host running the stack (clean).
# ---------------------------------------------------------------------------
SIGFN="$(mktemp)"
awk '/^gw_squat_signature\(\) \{/,/^\}/' "$ROOT/drill/doctor.sh" > "$SIGFN"
check "gw_squat_signature: extracted from doctor.sh (guards the awk)" 0 "default" cat "$SIGFN"
check "gw_squat_signature: the extracted function is valid bash" 0 "" bash -n "$SIGFN"
sig()   { bash -c ". '$SIGFN'; gw_squat_signature \"\$1\" \"\$2\"" _ "$1" "$2"; }
nosig() { [ -z "$(sig "$1" "$2")" ]; }

# The poisoned guest, verbatim from #80: gateway held locally AND duplicated
# connected routes for the uplink subnet.
R_POISON="$D_INBOX
10.88.0.0/24 dev boxnet proto kernel scope link src 10.88.0.1 linkdown
10.88.0.0/24 dev enp5s0 proto kernel scope link src 10.88.0.202 metric 1024
10.88.0.1 dev enp5s0 proto dhcp scope link src 10.88.0.202 metric 1024"
A_POISON="$A_GUEST
17: boxnet    inet 10.88.0.1/24 scope global boxnet"
check "signature: poisoned guest — the gateway is held as a LOCAL address" \
  0 "held as a LOCAL address" sig "$R_POISON" "$A_POISON"
check "signature: poisoned guest — duplicate connected routes for the uplink" \
  0 "duplicate connected routes" sig "$R_POISON" "$A_POISON"
# The workaround state (#80's fix: bridge remapped off the uplink subnet) —
# both signature lines must be ABSENT.
R_REMAP="$D_INBOX
10.88.0.0/24 dev enp5s0 proto kernel scope link src 10.88.0.202 metric 1024
10.88.0.1 dev enp5s0 proto dhcp scope link src 10.88.0.202 metric 1024
10.89.0.0/24 dev boxnet proto kernel scope link src 10.89.0.1 linkdown"
A_REMAP="$A_GUEST
17: boxnet    inet 10.89.0.1/24 scope global boxnet"
check "signature: the remapped-bridge workaround is CLEAN" 0 "" nosig "$R_REMAP" "$A_REMAP"
# A healthy HOST running the stack: boxnet legitimately owns its subnet, and
# the uplink is elsewhere — clean, or every host would cry wolf.
R_HOST="$D_LAN
192.168.1.0/24 dev eno1 proto kernel scope link src 192.168.1.50
10.88.0.0/24 dev boxnet proto kernel scope link src 10.88.0.1"
check "signature: a healthy host running the stack is CLEAN" 0 "" nosig "$R_HOST" "$A_HOSTSTACK"
check "signature: no default route → nothing to judge (clean)" 0 "" \
  nosig "10.88.0.0/24 dev boxnet proto kernel scope link src 10.88.0.1" "$A_HOSTSTACK"
# Each line fires on its own: a captured gateway without duplicate routes...
R_GWONLY="$D_INBOX
10.88.0.0/24 dev enp5s0 proto kernel scope link src 10.88.0.202 metric 1024"
check "signature: a captured gateway alone still fires" \
  0 "held as a LOCAL address" sig "$R_GWONLY" "$A_POISON"
# ...and duplicate routes without the gateway captured (nested bridge on .5).
A_DUPONLY="$A_GUEST
17: boxnet    inet 10.88.0.5/24 scope global boxnet"
check "signature: duplicate routes alone still fire" \
  0 "duplicate connected routes" sig "$R_POISON" "$A_DUPONLY"
rm -f "$SIGFN"

# ---------------------------------------------------------------------------
# The doctor's placement report (#180). pool_findings is the same seam: pure
# 'incus storage show' text in, report lines out, driven against canned pool
# config. The question it exists to answer without an Incus lesson is "my
# boxes filled the root disk" — so the loop-backed default must be RECOGNISED
# and named, and a placed pool must not carry that warning.
# ---------------------------------------------------------------------------
PFFN="$(mktemp)"
# The two readers come with it: pool_findings reads its scalars through them,
# and extracting the report without them would drive a function this file
# assembled rather than the one doctor.sh ships.
awk '/^yaml_scalar\(\) \{/,/^\}/'   "$ROOT/drill/doctor.sh" > "$PFFN"
awk '/^yaml_value\(\) \{/,/^\}/'    "$ROOT/drill/doctor.sh" >> "$PFFN"
awk '/^pool_findings\(\) \{/,/^\}/' "$ROOT/drill/doctor.sh" >> "$PFFN"
check "pool_findings: extracted from doctor.sh (guards the awk)" 0 "driver = " cat "$PFFN"
check "pool_findings: the extracted function is valid bash" 0 "" bash -n "$PFFN"
pf() { bash -c ". '$PFFN'; pool_findings \"\$1\"" _ "$1"; }

# What a stock host looks like today: btrfs, and a source Incus chose itself
# inside its own state directory — i.e. on '/'.
P_LOOP="name: default
driver: btrfs
status: Created
config:
  size: 30GiB
  source: /var/lib/incus/storage-pools/default"
# What #180 buys: the pool on a disk of its own.
P_DEV="name: default
driver: btrfs
config:
  source: /dev/sdb"
# A pool that reports no source at all, on the driver with no CoW.
P_BARE="name: default
driver: dir
config: {}"
# What #180 buys AS INCUS ACTUALLY RECORDS IT: handed /dev/sdb, the btrfs
# driver formats the disk and replaces 'source' with the new filesystem's UUID,
# keeping the device in volatile.initial_source. A doctor that printed only the
# UUID would answer "where do my boxes live" with a string naming no disk.
P_UUID="name: default
driver: btrfs
config:
  size: 60GiB
  source: 4ff9b8f1-6e6a-4d0f-9a3c-0d1f2e3a4b5c
  volatile.initial_source: /dev/sdb"
check "pool_findings: the driver is reported" 0 "driver = btrfs" pf "$P_LOOP"
check "pool_findings: ...and so is the source" \
  0 "source = /var/lib/incus/storage-pools/default" pf "$P_LOOP"
check "pool_findings: the loop-backed default is named as the ROOT filesystem" \
  0 "charged against" pf "$P_LOOP"
check "pool_findings: ...and the way out is a FRESH host, not a re-run" \
  0 "BOX_STORAGE_SOURCE=/dev/sdb box setup-host" pf "$P_LOOP"
check "pool_findings: ...saying so, because a re-run cannot move a pool" \
  0 "migration, not a re-run" pf "$P_LOOP"
check "pool_findings: a placed pool reports its device" 0 "source = /dev/sdb" pf "$P_DEV"
check "pool_findings: ...and carries no root-disk warning" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "'"$P_DEV"'" | grep -q "charged against"'
check "pool_findings: a pool with no source at all is still reported" \
  0 "source = <none reported>" pf "$P_BARE"
check "pool_findings: ...and named as the root filesystem too" 0 "ROOT filesystem" pf "$P_BARE"
check "pool_findings: dir is named as the driver with no copy-on-write" \
  0 "no copy-on-write" pf "$P_BARE"
check "pool_findings: btrfs is not" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "'"$P_LOOP"'" | grep -q "copy-on-write"'
check "pool_findings: an unreadable pool says so rather than inventing a driver" \
  0 "driver = <unreadable>" pf ""
# The block-device pool as Incus really reports it: the UUID is what 'source'
# says, and the device it was built on is named beside it.
check "pool_findings: a UUID source is reported as the source Incus holds" \
  0 "source = 4ff9b8f1-6e6a-4d0f-9a3c-0d1f2e3a4b5c" pf "$P_UUID"
check "pool_findings: ...with the DEVICE it was made from named too" \
  0 "made from = /dev/sdb" pf "$P_UUID"
check "pool_findings: ...saying which of the two is the filesystem UUID" \
  0 "the source above is the filesystem UUID" pf "$P_UUID"
# ...in the PAST tense, and that is the point rather than the grammar: this
# function probes nothing, so 'made from' is the path Incus was HANDED at
# creation and not a claim about what that name points at today. setup-host
# refuses a re-run it cannot bind back to this filesystem for exactly that
# reason; the report says which fact it has instead of borrowing the other
# one (#180, panel round 3).
check "pool_findings: ...as the path Incus was GIVEN, not a claim about today" \
  0 "the path Incus was given when this pool was created" pf "$P_UUID"
check "pool_findings: ...warning that a device name can move and a UUID cannot" \
  0 "can move between reboots" pf "$P_UUID"
check "pool_findings: ...and naming the command that settles it" \
  0 "lsblk -o NAME,UUID" pf "$P_UUID"
# The caveat belongs to the two-fact case only: a pool whose source Incus kept
# has no second name to be confused about.
check "pool_findings: a pool Incus did not mangle gets no device-name caveat" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "'"$P_DEV"'" | grep -q "can move between reboots"'
check "pool_findings: ...and carrying no root-disk warning" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "'"$P_UUID"'" | grep -q "charged against"'
# It is a report of a DIFFERENCE, not an echo: where Incus kept the path it was
# given (every dir pool, every path source, and a block device whose by-uuid
# symlink never appeared), there is no second line to read.
check "pool_findings: a source Incus did not mangle gets no 'made from' line" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "name: default
driver: btrfs
config:
  source: /data/bulk/incus
  volatile.initial_source: /data/bulk/incus" | grep -q "made from"'
check "pool_findings: ...and neither does a pool with no initial source at all" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "'"$P_DEV"'" | grep -q "made from"'
# A loop-backed pool carries the key RECORDED AND EMPTY, which YAML renders as
# a bare pair of quotes. That is absence, not a device named '"'"'""'"'"'.
check "pool_findings: an empty initial source is absence, not a device" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "name: default
driver: btrfs
config:
  source: /var/lib/incus/disks/default.img
  volatile.initial_source: \"\"" | grep -q "made from"'
check "pool_findings: ...and the root-disk warning still fires under it" 0 "charged against" \
  pf "name: default
driver: btrfs
config:
  source: /var/lib/incus/disks/default.img
  volatile.initial_source: \"\""
# AC5 on a source with a space in it. This section exists to answer "my boxes
# filled the root disk" with a path the operator can act on, and reading the
# line with awk's $2 answered it with a DIFFERENT path — '/data/bulk/box' for a
# pool on '/data/bulk/box pool' — which is worse than not answering, because
# nothing about it looks wrong. Both shapes Incus emits: plain for a space,
# quoted once the value contains ' #'.
P_SPACE="name: default
driver: btrfs
config:
  source: /data/bulk/box pool"
P_HASH="name: default
driver: btrfs
config:
  source: '/data/bulk/a #archive'"
check "pool_findings: a source containing a space is reported WHOLE" \
  0 "source = /data/bulk/box pool" pf "$P_SPACE"
check "pool_findings: a quoted source is reported without its quotes" \
  0 "source = /data/bulk/a #archive" pf "$P_HASH"
check "pool_findings: ...and neither is mistaken for the root filesystem" 1 "" bash -c '
  . "'"$PFFN"'"; { pool_findings "'"$P_SPACE"'"; pool_findings "'"$P_HASH"'"; } | grep -q "charged against"'
# The device a quoted-and-mangled pool was made from is read the same way: this
# is the line that names the disk, so truncating it names the wrong disk.
check "pool_findings: a quoted initial source names the whole device" \
  0 "made from = /dev/disk/by-id/scsi-0QEMU disk2" pf "name: default
driver: btrfs
config:
  source: 4ff9b8f1-6e6a-4d0f-9a3c-0d1f2e3a4b5c
  volatile.initial_source: '/dev/disk/by-id/scsi-0QEMU disk2'"
rm -f "$PFFN"

# The wiring, and the judgement inside it: the pool is read off the profile
# that PLACES every box, and the whole section is informational. Placement is
# a choice, not a fault — a DIRTY line here would red every stock host on the
# day it shipped, and the verdict is what the drill reads.
check "doctor: the pool is read off the box-net profile, not guessed" 0 "" \
  grep -qF 'incus profile device get box-net root pool' "$ROOT/drill/doctor.sh"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "doctor: the placement section reports through pool_findings" 0 "" \
  grep -qF 'pool_findings "$POOL_SHOW"' "$ROOT/drill/doctor.sh"
check "doctor: the placement section judges nothing (no DIRTY line in it)" 1 "" bash -c '
  awk "/^head_ \"Storage pool/,/^head_ \"ACL/" "'"$ROOT"'/drill/doctor.sh" | grep -qE "^ *no \""'
# The 'df' line measures the pool's own filesystem, so it reads the source the
# same way the report does: '$2' of "  source: /data/bulk/box pool" is
# "/data/bulk/box", and '[ -d ]' on that either says nothing or measures a
# DIFFERENT filesystem and labels it this pool's.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "doctor: the df line reads the source through yaml_value too" 0 "" \
  grep -qF 'src="$(yaml_value source "$POOL_SHOW")"' "$ROOT/drill/doctor.sh"
# A drift guard on all five reads: nothing in either script may go back to
# taking a source line's second FIELD, which is what threw half of a path away.
#
# Widened from a pattern that required the KEY and 'print $2' to be ADJACENT.
# That one was narrower than its own name: it missed 'awk "/^  source:/ {print
# $2}"' and 'grep "^  source:" | awk "{print $2}"' (@claude-bot-andresmgsl,
# panel round 3). The offered widening was a BARE 'print $2' over both files,
# on the grounds that neither has another one — but doctor.sh has two, the ACL
# destination read and the resolv.conf nameserver read, and a guard that reds
# on unrelated correct code gets deleted rather than obeyed. So: the key and
# 'print $2' on one LINE, in any order and any distance apart, which catches
# every spelling named and neither innocent one. A read split across two lines
# is out of a grep's reach and is not claimed here.
# shellcheck disable=SC2016  # the $2 is the pattern being searched FOR
check "the source is never read as awk's second field again (#180)" 1 "" \
  grep -nE 'source.*print[[:space:]]*\$2' "$ROOT/drill/doctor.sh" "$ROOT/host/setup-host.sh"
# ...and a guard is only worth its name if it can see those spellings, so hold
# it against them rather than trusting the regex by eye. The first two are the
# ones the narrow pattern let through; the third is the one it caught.
DRIFTF="$(mktemp)"
cat > "$DRIFTF" <<'DRIFT'
awk '/^  source:/ {print $2}' "$show"
grep '^  source:' <<<"$show" | awk '{print $2}'
awk -v k=source: '$1 == k { print $2 }' <<<"$show"
DRIFT
# shellcheck disable=SC2016  # the $2 is the pattern being searched FOR
driftcount() { grep -cE 'source.*print[[:space:]]*\$2' "$1"; }
check "...and that guard catches all three spellings, not just the adjacent one" \
  0 "3" driftcount "$DRIFTF"
# ...while leaving doctor.sh's two unrelated second-field reads alone, which is
# why the pattern is not the bare one.
# shellcheck disable=SC2016  # the $2 is the pattern being searched FOR
check "...and does not red on the reads that are nothing to do with a source" \
  0 "" grep -qE 'nameserver.*print[[:space:]]*\$2' "$ROOT/drill/doctor.sh"
rm -f "$DRIFTF"

# The wiring: the signature is judged on THIS machine before any daemon call
# (the daemon answering could be the nested impostor), probed INSIDE boxes on
# both tiers, and the egress-broken-DNS-fine split names the fingerprint.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "doctor: this machine's signature precedes the daemon checks" 0 "" bash -c '
  sig="$(grep -n "is a nested box stack squatting" "'"$ROOT"'/drill/doctor.sh" | head -1 | cut -d: -f1)"
  daemon="$(grep -n "timeout 10 incus list" "'"$ROOT"'/drill/doctor.sh" | head -1 | cut -d: -f1)"
  [ -n "$sig" ] && [ -n "$daemon" ] && [ "$sig" -lt "$daemon" ]'
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "doctor: the signature is probed inside boxes on BOTH tiers" 0 "" bash -c '
  [ "$(grep -c "probe_sig \"\$probe\"" "'"$ROOT"'/drill/doctor.sh")" -eq 2 ]'
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "doctor: the egress-broken-DNS-fine fingerprint is named on both tiers" 0 "" bash -c '
  [ "$(grep -c "fingerprint" "'"$ROOT"'/drill/doctor.sh")" -ge 2 ]'
check "doctor: the ACL carve-out is checked against the live gateway" 0 "" \
  grep -qF "does NOT match boxnet's gateway" "$ROOT/drill/doctor.sh"

# ---------------------------------------------------------------------------
# The phase-D phantom, retired from the third file that carried it (#197).
# Phase D stopped rehearsing the #16 hardening when the hardening shipped —
# drill.sh's phase D is a block of `inf` lines with no `incus` call of any
# kind — so doctor's header and two of its findings were blaming a mechanism
# that does not exist, in the file bin/box points five other failure paths at.
# These two cases pin the false claims OUT.
check "doctor: the header does not claim the drill mutates the host" 1 "" \
  grep -qF 'MUTATES the host in phase D' "$ROOT/drill/doctor.sh"
check "doctor: no finding blames phase D for a mutation" 1 "" \
  grep -qE 'phase D left this behind|survived phase D' "$ROOT/drill/doctor.sh"
# ...and these pin the BEHAVIOUR in. #197 moves prose only, so every one of
# them passes BEFORE the rewrite as well as after — which is what makes the two
# cases above safe to write, a rewrite that quietly dropped a --fix branch
# reddening here. Nothing asserts the header's new wording: a text match on a
# comment the same change writes proves only that the change agrees with
# itself, and the reader needs the two claims out and these five in.
check "doctor: --fix still restores dns.mode=none" 0 "" \
  grep -qF 'incus network set boxnet dns.mode=none' "$ROOT/drill/doctor.sh"
check "doctor: --fix still removes an @internal ACL rule" 0 "" \
  grep -qF 'incus network acl rule remove box-isolate' "$ROOT/drill/doctor.sh"
check "doctor: --fix still deletes all eight leftover drill boxes" 0 "" \
  grep -qF 'for b in drill clone archive peer payroll cbprobe cbcopy cbnotours; do' \
    "$ROOT/drill/doctor.sh"
# The #16 incident is the file's best argument for running it at all, and D2
# re-attributes it to the fault rather than deleting it with the phase. Carried
# prose, not new, so this case passes on both sides of the rewrite too.
check "doctor: the #16 incident survives the re-attribution" 0 "" \
  grep -qF 'Temporary failure resolving deb.debian.org' "$ROOT/drill/doctor.sh"
# D6: doctor has no --help and gained none. A bad argument is still one line
# and exit 2, resolved before any daemon call — so this runs anywhere.
check "doctor: a bad argument still exits 2 with the one-line usage" 2 "usage: doctor.sh" \
  bash "$ROOT/drill/doctor.sh" --nonsense

# ---------------------------------------------------------------------------
# box-firewall's UFW converge and the fail-closed boot window (#86 review,
# items 1–2). The whole script is DRIVEN under shims (the setup-host seam):
# a fake ufw serves canned `ufw status` tables and logs every mutation, fake
# nft/sysctl/iptables swallow the rest, and the shim ip answers the
# live-bridge read. Stale gateway allows must converge to the live gateway,
# a fresh UFW host must get exactly the rule set it always did, a no-UFW
# host must keep its nft path, and the no-bridge-address boot window must
# mutate NOTHING — the old GW=10.88.0.1 fallback built the carve-out for
# the wrong gateway on every BOX_SUBNET host that hit it.
# ---------------------------------------------------------------------------
FWSHIM="$(mktemp -d)"; UFWSHIM="$(mktemp -d)"; WFW="$(mktemp -d)"
cat > "$UFWSHIM/ufw" <<'SHIM'
#!/usr/bin/env bash
# Fake ufw: 'status' prints $FAKE_UFW_STATUS; every call is logged to
# $FAKE_UFW_LOG. Mutations mutate nothing, of course.
[ -n "${FAKE_UFW_LOG:-}" ] && printf 'ufw %s\n' "$*" >> "$FAKE_UFW_LOG"
case "${1:-}" in status) printf '%s\n' "${FAKE_UFW_STATUS:-Status: inactive}" ;; esac
exit 0
SHIM
cat > "$FWSHIM/nft" <<'SHIM'
#!/usr/bin/env bash
# Fake nft: logs to $FAKE_NFT_LOG. The bridge-table probe answers "absent"
# so the creation path runs (and is logged) instead of being skipped.
[ -n "${FAKE_NFT_LOG:-}" ] && printf 'nft %s\n' "$*" >> "$FAKE_NFT_LOG"
case "$*" in "list table bridge box") exit 1 ;; esac
exit 0
SHIM
cat > "$FWSHIM/sysctl" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
cat > "$FWSHIM/iptables" <<'SHIM'
#!/usr/bin/env bash
# Fake iptables: the DOCKER-USER probe answers "no such chain", so the
# docker block is deterministically skipped whether or not this runner
# happens to have docker.
exit 1
SHIM
chmod +x "$UFWSHIM/ufw" "$FWSHIM/nft" "$FWSHIM/sysctl" "$FWSHIM/iptables"

runfw() { # runfw <ufw|noufw> [VAR=val ...] — the real box-firewall, under shims
  local mode="$1" p rc=0; shift
  p="$FWSHIM:$SHIMDIR:$PATH"
  [ "$mode" = ufw ] && p="$UFWSHIM:$p"
  # Stderr is captured to a file AND re-emitted, rather than only passed
  # through. The driving `check` swallows the output of a run that passes, so
  # when a later grep over the log fails there is nothing left to read — which
  # is precisely the hole #102 fell into. Keeping a copy on disk lets
  # fwlog_ready below show what the run actually said. Overwritten per call by
  # design: every fwlog_ready sits immediately after its own runfw, so "the
  # last run" is always the run being diagnosed.
  env PATH="$p" "$@" bash "$ROOT/host/box-firewall.sh" 2>"$WFW/last-run.err" || rc=$?
  cat "$WFW/last-run.err" >&2
  return "$rc"
}

# fwlog_ready <log> — the shimmed ufw actually logged mutations to <log>.
#
# Why this exists (#102): every grep in the blocks below reads a log written by
# the shimmed ufw during the driving `runfw` check. When something stops the
# UFW branch of box-firewall.sh from running at all, that log is missing — or,
# as it turned out, present but holding nothing except the `ufw status` probe.
# The greps then fail four-at-a-time with empty output: a signature that looks
# alarmingly specific and carries no information whatsoever. #102 was filed
# reading it as "the log is not written", which was a reasonable inference from
# four blank failures and was also wrong; the file was there, the mutations
# were not, and that distinction is the entire diagnosis. So assert the
# precondition explicitly, before the content greps, and on failure print what
# IS in $WFW, what the log itself holds, and what the run wrote to stderr. The
# fix below should mean this never fires — it is here for the next cause, not
# this one, and its whole job is to hand over the evidence instead of making
# the next person re-derive it from a re-run loop.
fwlog_ready() {
  local log="$1" muts
  if [ -f "$log" ]; then
    muts="$(grep -vc "^ufw status" "$log")"
    [ "$muts" -gt 0 ] && return 0
    echo "DIAGNOSIS: $log exists but logs no ufw MUTATION (only 'ufw status')."
    echo "  => box-firewall.sh took its no-UFW branch; the UFW carve-out never ran."
  else
    echo "DIAGNOSIS: $log does not exist — the shimmed ufw was never invoked."
  fi
  echo "  \$WFW ($WFW) holds:"
  # shellcheck disable=SC2012  # a human-read diagnostic dump, not parsed: `ls -la`
  # shows sizes and mtimes, which is the whole point here (a zero-byte log and a
  # log that was never created are different failures). $WFW is our own mktemp -d.
  ls -la "$WFW" 2>&1 | sed 's/^/    /'
  echo "  contents of $(basename "$log"):"
  { [ -f "$log" ] && cat "$log" || echo "(absent)"; } 2>&1 | sed 's/^/    /'
  echo "  stderr of the run that should have written it:"
  { [ -s "$WFW/last-run.err" ] && cat "$WFW/last-run.err" || echo "(empty)"; } 2>&1 | sed 's/^/    /'
  return 1
}

# Canned `ufw status` tables, modeled on the real output shape.
U_HDR='Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere'
U_FRESH="$U_HDR"
U_OLDGW="$U_HDR
Anywhere on boxnet         DENY        Anywhere
10.88.0.1 53/tcp on boxnet ALLOW       Anywhere
10.88.0.1 53/udp on boxnet ALLOW       Anywhere
67/udp on boxnet           ALLOW       Anywhere
Anywhere on boxnet         ALLOW FWD   Anywhere"
U_LIVEGW="$U_HDR
Anywhere on boxnet         DENY        Anywhere
10.89.0.1 53/tcp on boxnet ALLOW       Anywhere
10.89.0.1 53/udp on boxnet ALLOW       Anywhere
67/udp on boxnet           ALLOW       Anywhere
Anywhere on boxnet         ALLOW FWD   Anywhere"
BX88='5: boxnet    inet 10.88.0.1/24 scope global boxnet'
BX89='5: boxnet    inet 10.89.0.1/24 scope global boxnet'

# The remapped host (#80's escape hatch): bridge on 10.89, UFW still carrying
# 10.88's carve-out — the stale allows go, the live gateway's land.
check "box-firewall: a remapped bridge CONVERGES the UFW carve-out" 0 "" \
  runfw ufw FAKE_IP4_BOXNET="$BX89" FAKE_UFW_STATUS="$U_OLDGW" FAKE_UFW_LOG="$WFW/remap.log"
check "box-firewall: ...the run logged ufw mutations at all" 0 "" fwlog_ready "$WFW/remap.log"
check "box-firewall: ...the stale tcp allow is deleted" 0 "" \
  grep -qF 'ufw delete allow in on boxnet to 10.88.0.1 port 53 proto tcp' "$WFW/remap.log"
check "box-firewall: ...and the stale udp allow" 0 "" \
  grep -qF 'ufw delete allow in on boxnet to 10.88.0.1 port 53 proto udp' "$WFW/remap.log"
check "box-firewall: ...the live gateway gains its tcp allow" 0 "" \
  grep -qF 'ufw insert 1 allow in on boxnet to 10.89.0.1 port 53 proto tcp' "$WFW/remap.log"
check "box-firewall: ...and its udp allow" 0 "" \
  grep -qF 'ufw insert 1 allow in on boxnet to 10.89.0.1 port 53 proto udp' "$WFW/remap.log"
check "box-firewall: ...the live gateway's rules are never deleted" 1 "" \
  grep -qF 'delete allow in on boxnet to 10.89.0.1' "$WFW/remap.log"

# The agreeing host: rules already match the live gateway — nothing deleted
# (ufw itself skips the re-adds as existing rules).
check "box-firewall: an agreeing UFW host deletes nothing" 0 "" \
  runfw ufw FAKE_IP4_BOXNET="$BX89" FAKE_UFW_STATUS="$U_LIVEGW" FAKE_UFW_LOG="$WFW/agree.log"
# This one matters more than it looks: "no delete was issued" is an ASSERT-ABSENT
# check, so a run that issued nothing at all passes it for the wrong reason.
# fwlog_ready is what keeps the absence meaningful.
check "box-firewall: ...the run logged ufw mutations at all" 0 "" fwlog_ready "$WFW/agree.log"
check "box-firewall: ...no delete was issued" 1 "" grep -qF ' delete ' "$WFW/agree.log"

# The fresh host: no boxnet rules yet — exactly the five historical commands,
# aimed at the live gateway, and nothing else (unchanged behavior).
check "box-firewall: a fresh UFW host runs clean" 0 "" \
  runfw ufw FAKE_IP4_BOXNET="$BX88" FAKE_UFW_STATUS="$U_FRESH" FAKE_UFW_LOG="$WFW/fresh.log"
check "box-firewall: ...the run logged ufw mutations at all" 0 "" fwlog_ready "$WFW/fresh.log"
check "box-firewall: ...the deny lands" 0 "" \
  grep -qF 'ufw insert 1 deny in on boxnet' "$WFW/fresh.log"
check "box-firewall: ...the DNS allows aim at the live gateway" 0 "" \
  grep -qF 'ufw insert 1 allow in on boxnet to 10.88.0.1 port 53 proto tcp' "$WFW/fresh.log"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "box-firewall: ...DHCP and the route allow land too" 0 "" bash -c '
  grep -qF "ufw insert 1 allow in on boxnet to any port 67 proto udp" "$1" &&
  grep -qF "ufw route allow in on boxnet" "$1"' _ "$WFW/fresh.log"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "box-firewall: ...exactly the five historical mutations, no more" 0 "" \
  bash -c '[ "$(grep -vc "^ufw status" "$1")" -eq 5 ]' _ "$WFW/fresh.log"

# The boot window (#86 review item 2): bridge not yet addressed → NO guessed
# gateway, NO mutation at all — the persisted rules are left exactly as they
# are, and the skip says so. (The old fallback built 10.88.0.1 rules on a
# BOX_SUBNET host here — a latent DNS drop.)
check "box-firewall: an unaddressed bridge FAILS CLOSED on a UFW host" 0 "left as-is" \
  runfw ufw FAKE_IP4_BOXNET= FAKE_UFW_STATUS="$U_OLDGW" FAKE_UFW_LOG="$WFW/boot.log"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "box-firewall: ...not one ufw mutation was issued" 0 "" \
  bash -c '[ "$(grep -vc "^ufw status" "$1")" -eq 0 ]' _ "$WFW/boot.log"
check "box-firewall: the hardcoded gateway fallback is GONE (comments aside)" 1 "" \
  grep -qE '^[^#]*GW=10' "$ROOT/host/box-firewall.sh"

# The no-UFW host: untouched semantics — the nft input carve-out is
# interface-scoped, so it needs no gateway and applies even in the boot
# window where the UFW path now declines to guess.
check "box-firewall: a no-UFW host keeps its nft path" 0 "" \
  runfw noufw FAKE_IP4_BOXNET="$BX89" FAKE_NFT_LOG="$WFW/nft.log"
check "box-firewall: ...the DNS/DHCP accept is interface-scoped" 0 "" \
  grep -qF 'add rule inet box input iifname boxnet udp dport { 53, 67 } accept' "$WFW/nft.log"
check "box-firewall: ...and the input drop lands" 0 "" \
  grep -qF 'add rule inet box input iifname boxnet drop' "$WFW/nft.log"
check "box-firewall: the nft path survives the boot window too" 0 "" \
  runfw noufw FAKE_IP4_BOXNET= FAKE_NFT_LOG="$WFW/nftboot.log"
check "box-firewall: ...with the same interface-scoped carve-out" 0 "" \
  grep -qF 'add rule inet box input iifname boxnet udp dport { 53, 67 } accept' "$WFW/nftboot.log"

# ---------------------------------------------------------------------------
# The doctor's UFW blind spot (#86 review item 1, second half): the ACL
# check alone gave a remapped UFW host a clean bill while the stale UFW
# allow dropped box DNS. ufw_dns_findings is pure text → findings, the
# gw_squat_signature seam: extracted and driven against canned tables.
# ---------------------------------------------------------------------------
UFWFN="$(mktemp)"
awk '/^ufw_dns_findings\(\) \{/,/^\}/' "$ROOT/drill/doctor.sh" > "$UFWFN"
check "ufw_dns_findings: extracted from doctor.sh (guards the awk)" 0 "DNS allow" cat "$UFWFN"
check "ufw_dns_findings: the extracted function is valid bash" 0 "" bash -n "$UFWFN"
ufwsig()   { bash -c ". '$UFWFN'; ufw_dns_findings \"\$1\" \"\$2\" \"\$3\"" _ "$1" "$2" "$3"; }
noufwsig() { [ -z "$(ufwsig "$1" "$2" "$3")" ]; }

check "ufw findings: agreement is SILENT" 0 "" noufwsig "$U_LIVEGW" boxnet 10.89.0.1
check "ufw findings: a stale carve-out is flagged as NOT the live gateway" \
  0 "NOT boxnet's live gateway" ufwsig "$U_OLDGW" boxnet 10.89.0.1
check "ufw findings: ...naming the address it points at" \
  0 "10.88.0.1" ufwsig "$U_OLDGW" boxnet 10.89.0.1
# Our deny with no DNS allow at all is a drop — say so.
U_DENYONLY="$U_HDR
Anywhere on boxnet         DENY        Anywhere"
check "ufw findings: a deny with NO DNS allow is a drop" \
  0 "NO DNS allow" ufwsig "$U_DENYONLY" boxnet 10.89.0.1
# A UFW host box-firewall never touched has nothing to judge — clean.
check "ufw findings: an untouched UFW host is CLEAN" 0 "" noufwsig "$U_FRESH" boxnet 10.89.0.1
# A stale allow left BESIDE the live one still gets named (residue, not a drop).
U_BOTH="$U_LIVEGW
10.88.0.1 53/tcp on boxnet ALLOW       Anywhere"
check "ufw findings: a stale allow beside the live one is named" \
  0 "stale UFW DNS allow" ufwsig "$U_BOTH" boxnet 10.89.0.1
# Rules on OTHER interfaces are not boxnet's problem.
U_OTHERIF="$U_LIVEGW
10.88.0.1 53/tcp on eth0   ALLOW       Anywhere"
check "ufw findings: another interface's DNS allow is ignored" 0 "" \
  noufwsig "$U_OTHERIF" boxnet 10.89.0.1

# The wiring: doctor judges UFW's own table where UFW is active, and the fix
# points at the converging box-firewall.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "doctor: reads UFW's table through ufw_dns_findings" 0 "" \
  grep -qF 'ufw_dns_findings "$ufw_out"' "$ROOT/drill/doctor.sh"
check "doctor: the UFW fix names the converge" 0 "" \
  grep -qF 'converges the UFW allows' "$ROOT/drill/doctor.sh"
rm -f "$UFWFN"; rm -rf "$FWSHIM" "$UFWSHIM" "$WFW"

# ---------------------------------------------------------------------------
# The drill's probe ledger (#153). drill.sh counted what it RAN and never how
# much it SHOULD have run, so a skipped phase reported a clean sweep — and that
# number is transcribed into drills/<version>.md as the evidence a release was
# proven. The ledger is a self-contained block in drill.sh precisely so it can
# be extracted and DRIVEN here: the drill itself needs real hardware, but the
# arithmetic that decides "this run was short" must not.
# ---------------------------------------------------------------------------
LEDGERFN="$(mktemp)"
awk '/^# >>> probe ledger/,/^# <<< probe ledger/' "$ROOT/drill/drill.sh" > "$LEDGERFN"
check "probe ledger: extracted from drill.sh (guards the awk)" 0 "PHASE_EXPECT" cat "$LEDGERFN"
check "probe ledger: the extracted block is valid bash" 0 "" bash -n "$LEDGERFN"

# Drive the block for real. `findings` is the one thing it assumes from the
# script around it, so the harness supplies it, exactly as the drill does.
led() { bash -c "set -u; findings=(); . '$LEDGERFN'; $1"; }
# A complete run: every phase emits what it declared.
FULL='PHASE_RAN=([I]=1 [A]=8 [B]=51 [C]=9 [E]=7 [D]=0 [M]=10 [T]=1)'

# shellcheck disable=SC2016  # the snippet is evaluated by led(), not here
check "probe ledger: the declared total is 87" 0 "[87]" led 'printf "[%s]" "$(ledger_declared)"'
# The number CONTRIBUTING and drills/README.md have quoted all along with
# nothing checking it. If a phase gains probes, both move together or this reds.
check "probe ledger: ...which is the contract CONTRIBUTING states" 0 "" \
  grep -qF '87-probe' "$ROOT/CONTRIBUTING.md"

check "probe ledger: a complete run is short in nothing" 0 "[]" \
  led "$FULL; printf '[%s]' \"\$(ledger_short)\""
check "probe ledger: a complete run's floor is the declared total" 0 "[87]" \
  led "$FULL; printf '[%s]' \"\$(ledger_expected)\""

# THE regression. A phase that never executed used to be invisible: the pass
# count simply ended lower and exit 0 vouched for it.
check "probe ledger: a phase that never ran is named, not silently dropped" 0 "C(0/9)" \
  led "$FULL; PHASE_RAN[C]=0; printf '[%s]' \"\$(ledger_short)\""
check "probe ledger: ...and one missing probe inside a phase is named too" 0 "B(50/51)" \
  led "$FULL; PHASE_RAN[B]=50; printf '[%s]' \"\$(ledger_short)\""

# A floor, not an equality: adding a probe must not red the commit that adds it.
check "probe ledger: overshooting a phase is not a shortfall" 0 "[]" \
  led "$FULL; PHASE_RAN[B]=60; printf '[%s]' \"\$(ledger_short)\""

# A declared skip is honest — it lowers the expectation by exactly its probes
# and says so. The whole point is that the floor is never tuned down silently.
check "probe ledger: a declared skip lowers the floor by its probes" 0 "[78]" \
  led "$FULL; skipped C 9 'no isolation stack'; PHASE_RAN[C]=0; printf '[%s]' \"\$(ledger_expected)\""
check "probe ledger: ...so a declared skip is not a shortfall" 0 "[]" \
  led "$FULL; skipped C 9 'no isolation stack'; PHASE_RAN[C]=0; printf '[%s]' \"\$(ledger_short)\""
check "probe ledger: ...and it prints a SKIP line the record can carry" 0 "SKIP" \
  led "skipped C 9 'no isolation stack'"
check "probe ledger: ...which lands in findings, not only on the terminal" 0 "SKIP: no isolation stack" \
  led "skipped C 9 'no isolation stack' >/dev/null; printf '%s\n' \"\${findings[@]}\""
# An UNdeclared skip is still a shortfall. This is the line between the two.
check "probe ledger: an undeclared skip of the same phase still reds" 0 "C(0/9)" \
  led "$FULL; PHASE_RAN[C]=0; printf '[%s]' \"\$(ledger_short)\""

# DRILL_EXPECT raises the floor for an operator who knows the table is behind.
check "probe ledger: DRILL_EXPECT overrides the total floor" 0 "[90]" \
  led "DRILL_EXPECT=90; $FULL; printf '[%s]' \"\$(ledger_expected)\""

# ok/no must keep returning 0 — the file's SC2015 disable at the top rests on it.
check "probe ledger: tally returns 0 so ok/no still do" 0 "[0][0]" \
  led "PHASE=A; tally; printf '[%s]' \$?; PHASE=-; tally; printf '[%s]' \$?"
# A verdict emitted outside any ledgered phase means the table has drifted.
check "probe ledger: an unattributed verdict is surfaced, not swallowed" 0 "unattributed" \
  led "PHASE=-; tally; ledger_line"
check "probe ledger: the per-phase line is what a single total cannot say" 0 "B 51/51" \
  led "$FULL; ledger_line"

# The wiring, so the ledger cannot be left correct-but-unused.
ledger_keys_agree() {
  ( set -u
    # shellcheck disable=SC2034  # skipped() appends to it; the block assumes it
    findings=()
    # shellcheck disable=SC1090  # the extracted block, written just above
    . "$LEDGERFN"
    local k
    while read -r k; do
      [ "$k" = "-" ] && continue
      [ -n "${PHASE_EXPECT[$k]:-}" ] || { echo "phase header uses an undeclared key: $k"; exit 1; }
    done < <(grep -oE '^[[:space:]]*phase [A-Za-z-]+ ' "$ROOT/drill/drill.sh" | awk '{print $2}')
    for k in "${PHASE_ORDER[@]}"; do
      grep -qE "^[[:space:]]*phase $k " "$ROOT/drill/drill.sh" \
        || { echo "declared in the table but no phase opens it: $k"; exit 1; }
    done )
}
check "drill: the ledger's keys and the script's phase headers agree" 0 "" ledger_keys_agree
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "drill: the summary fails a short run instead of reporting a clean sweep" 0 "" \
  grep -qF 'no "the drill ran SHORT:' "$ROOT/drill/drill.sh"
# shellcheck disable=SC2016  # ditto
check "drill: the summary prints the denominator the record transcribes" 0 "" \
  grep -qF '%s/%s passed, %s failed' "$ROOT/drill/drill.sh"
# The two skips an operator meets most often. Either one silently short-counting
# is how a floor gets "tuned down to the weakest run" instead of held.
check "drill: a KVM-less host declares the VM probe it did not run" 0 "" \
  grep -qF 'skipped B 1 "no /dev/kvm' "$ROOT/drill/drill.sh"
check "drill: --keep-boxes declares the teardown probe it did not run" 0 "" \
  grep -qF 'skipped T 1 "--keep-boxes' "$ROOT/drill/drill.sh"

# A typo'd DRILL_EXPECT used to reach the arithmetic and leak a bash
# 'unbound variable' line into the summary. It failed safe; it did not explain.
check "probe ledger: a non-numeric DRILL_EXPECT is refused, and named" 2 \
  "DRILL_EXPECT must be a whole number, got: abc" \
  led "DRILL_EXPECT=abc; ledger_check_expect"
check "probe ledger: ...while a numeric one is accepted" 0 "" \
  led "DRILL_EXPECT=90; ledger_check_expect"
check "probe ledger: ...and an unset one is not an error" 0 "" led "ledger_check_expect"
# Refusing early is the whole point: an operator who typo'd it must find out
# before the drill starts formatting a host, not in the summary forty minutes on.
expect_guard_runs_first() {
  local guard first
  guard="$(grep -n '^ledger_check_expect || exit 2$' "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] || { echo "the DRILL_EXPECT guard is defined but never called"; return 1; }
  first="$(grep -nE '^[[:space:]]*phase [A-Za-z-]+ ' "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
  [ "$guard" -lt "$first" ] || { echo "the guard runs at $guard, after the first phase at $first"; return 1; }
}
check "drill: the DRILL_EXPECT guard is called, and before the first phase" 0 "" \
  expect_guard_runs_first

# ---------------------------------------------------------------------------
# The exit path, EXECUTED (#153). Everything above proves the ledger's
# arithmetic and that the summary's lines are written. Neither proves the drill
# LEAVES non-zero when it ran short — and an exit status is the whole of #153's
# central criterion, so grep is not evidence for it: replacing the final
# `[ "$fail" -eq 0 ]` with unconditional success passed every check above.
#
# So compose the four extracted blocks — verdicts, ledger, record, summary —
# into the runnable skeleton of a drill that has finished, and run it. The exit
# status asserted below is the real one, produced by the real gate. The record
# block is composed in even where a scenario emits no record (#152): the point
# of the skeleton is that it is the script's actual tail, and a tail assembled
# from three of its four blocks is a different tail.
# ---------------------------------------------------------------------------
VERDFN="$(mktemp)"; SUMFN="$(mktemp)"; RECFN="$(mktemp)"
awk '/^# >>> drill verdicts/,/^# <<< drill verdicts/' "$ROOT/drill/drill.sh" > "$VERDFN"
awk '/^# >>> ledger summary/,/^# <<< ledger summary/' "$ROOT/drill/drill.sh" > "$SUMFN"
awk '/^# >>> drill record/,/^# <<< drill record/'     "$ROOT/drill/drill.sh" > "$RECFN"
check "drill summary: the verdict helpers extract (guards the awk)" 0 "pass=\$((pass + 1))" \
  cat "$VERDFN"
check "drill summary: the summary extracts (guards the awk)" 0 "the drill ran SHORT:" cat "$SUMFN"
# The gate must be INSIDE the extracted window, or the scenarios below run an
# exit path that is not the script's. This is what stops the hole reopening by
# the gate simply moving out from under the marker.
# shellcheck disable=SC2016  # a literal in the target file
check "drill summary: ...with the exit gate inside the window, not below it" 0 "" \
  grep -qF '[ "$fail" -eq 0 ]' "$SUMFN"

# Run the composed skeleton. $1 is the state a finished drill would be in.
# RECORD empty is a drill run without --emit-record, which is still the common
# case; the scenarios that DO emit one set it, further down.
run_summary() {
  bash -c "set -u; . '$VERDFN'; . '$LEDGERFN'; . '$RECFN'; RECORD=''; $1; . '$SUMFN'"
}
summary_lacks() {   # 0 when the composed run does NOT say $1
  local needle="$1"; shift
  ! run_summary "$1" 2>&1 | grep -qF -e "$needle"
}
COMPLETE="$FULL; pass=87; fail=0"

check "drill summary: a complete run reports 87/87 and EXITS 0" 0 "87/87 passed, 0 failed" \
  run_summary "$COMPLETE"

# THE regression, end to end. Phase C never executed: 78 verdicts, none of them
# failing, and the drill used to leave here 0 with "78 passed, 0 failed" on the
# line an operator transcribes into drills/<version>.md as proof.
check "drill summary: a phase that never ran EXITS NON-ZERO" 1 "the drill ran SHORT:" \
  run_summary "$COMPLETE; PHASE_RAN[C]=0; pass=78"
check "drill summary: ...naming the short phase, against the full denominator" 1 \
  "short in: C(0/9)" run_summary "$COMPLETE; PHASE_RAN[C]=0; pass=78"
check "drill summary: ...and the record carries 78/87, not a clean 78" 1 \
  "78/87 passed, 1 failed" run_summary "$COMPLETE; PHASE_RAN[C]=0; pass=78"
# The verdict names both roads to a short phase, not just the commoner one.
check "drill summary: ...and does not diagnose 'never ran' as the only cause" 1 \
  "or failed before emitting the rest" run_summary "$COMPLETE; PHASE_RAN[C]=0; pass=78"

# A DECLARED skip is the line between honest and tuned-down: same 78 verdicts,
# but the run said which nine it was not going to emit, and why.
check "drill summary: a declared skip lowers the floor and EXITS 0" 0 \
  "78/78 passed, 0 failed" \
  run_summary "$COMPLETE; skipped C 9 'no isolation stack'; PHASE_RAN[C]=0; pass=78"
check "drill summary: ...and the SKIP survives into the findings block" 0 \
  "SKIP: no isolation stack" \
  run_summary "$COMPLETE; skipped C 9 'no isolation stack'; PHASE_RAN[C]=0; pass=78"

# The other road to non-zero: nothing short, one thing genuinely failed. Both
# roads have to work, and the second must not be reported as the first.
check "drill summary: a complete run with one real FAIL EXITS NON-ZERO" 1 \
  "86/87 passed, 1 failed" run_summary "$COMPLETE; pass=86; fail=1"
check "drill summary: ...and is not mislabelled as a short run" 0 "" \
  summary_lacks "the drill ran SHORT:" "$COMPLETE; pass=86; fail=1"

# ---------------------------------------------------------------------------
# The record emitter (#152). drills/README.md asks a record for six things and
# drill.sh printed none of them in that shape, so every record was retyped by
# hand out of coloured terminal output at the end of a forty-minute run — and
# two fields (the shared run ID, the wall clock) did not exist to retype.
#
# Same doctrine as the ledger above it: the emitter is a self-contained block
# precisely so the SHAPE of a record can be driven on a host with no Incus, no
# drill and no network. record_collect() touches the world; record_write()
# touches nothing but the REC_* set, which is what makes it assertable here.
# ---------------------------------------------------------------------------
check "drill record: extracted from drill.sh (guards the awk)" 0 "record_write" cat "$RECFN"
check "drill record: the extracted block is valid bash" 0 "" bash -n "$RECFN"

RECWORK="$(mktemp -d)"; RECOUT="$RECWORK/emitted.md"
# The block assumes the verdict helpers and the ledger, and nothing else — so
# the harness supplies exactly those, exactly as the drill does.
rec() { bash -c "set -u; . '$VERDFN'; . '$LEDGERFN'; . '$RECFN'; $1"; }

# --- the run ID, which had no mechanism at all before this ------------------
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: the default run ID is drill-<version>-<date>-01" 0 \
  "[drill-9.9.9-20260721-01]" rec 'printf "[%s]" "$(record_run_id 9.9.9 20260721)"'
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and record_collect derives it from the collected date" 0 \
  "[drill-9.9.9-20260721-01]" \
  rec 'REC_VERSION=9.9.9; REC_DATE=2026-07-21; record_collect o/r main 0; printf "[%s]" "$REC_RUN_ID"'
# An ID passed in is the release set's shared one and must survive collection
# untouched — three repos reconciling on it is the entire reason it exists.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...but a pinned run ID is never regenerated" 0 "[drill-shared-42]" \
  rec 'REC_RUN_ID=drill-shared-42; REC_VERSION=9.9.9; REC_DATE=2026-07-21; record_collect o/r main 0; printf "[%s]" "$REC_RUN_ID"'

# --- the wall clock, the other field that did not exist ---------------------
# drills/README.md's worked example writes "41 minutes wall clock"; 2460s is it.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: seconds become the phrase the worked example uses" 0 \
  "[41 minutes wall clock]" rec 'printf "[%s]" "$(record_wallclock 2460)"'
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...rounded to the nearest minute, not truncated" 0 "[42 minutes" \
  rec 'printf "[%s]" "$(record_wallclock 2490)"'
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and a sub-minute run is not '0 minutes'" 0 "[under a minute" \
  rec 'printf "[%s]" "$(record_wallclock 30)"'
# An unmeasured clock says so. Guessing here would put a fabricated duration in
# the one artifact whose whole job is to be believed months later.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: an unmeasured clock is stated, never guessed" 0 \
  "[wall clock not measured]" rec 'printf "[%s]" "$(record_wallclock "")"'
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and neither is a mangled one" 0 "[wall clock not measured]" \
  rec 'printf "[%s]" "$(record_wallclock abc)"'

# --- the SHAs, the field that makes a ref mean something later --------------
RECSHIM="$RECWORK/shim"; mkdir -p "$RECSHIM"
cat > "$RECSHIM/git" <<'SHIM'
#!/usr/bin/env bash
# Fake git: 'ls-remote <url> <pattern>...' prints $FAKE_LSREMOTE as the SHA, or
# nothing (an unknown ref). Anything else exits 1, as a git that cannot would.
# FAKE_PEELED, when set, makes it answer the way a real remote answers for an
# ANNOTATED tag: the tag object first, then the commit as refs/tags/<t>^{}.
#
# It answers PATTERN BY PATTERN, which is the whole point of it. `refs/tags/<t>`
# and `refs/tags/<t>^{}` are two separate refs, and ls-remote matches a pattern
# against the ref's tail component — so an exact `<t>` selects the tag object
# ALONE and the peeled line is only ever sent to a caller that asked for `<t>^{}`
# by name. A shim that appends the peeled line regardless models the response
# somebody expected instead of the protocol, and confirms their expectation by
# construction: that is how a version of this file shipped a peel-preferring awk
# over a query that could never return a peeled line to prefer.
[ "${1:-}" = ls-remote ] || exit 1
[ -n "${FAKE_LSREMOTE:-}" ] || exit 0
ref=''; peel=''
for pat in "${@:3}"; do
  case "$pat" in
    *'^{}') peel=1 ;;
    *)      [ -n "$ref" ] || ref="$pat" ;;
  esac
done
if [ -n "${FAKE_PEELED:-}" ]; then
  printf '%s\trefs/tags/%s\n' "$FAKE_LSREMOTE" "${ref:-v1}"
  # Only for a caller that named the peeled ref. A real remote sends nothing
  # here otherwise, however annotated the tag is.
  [ -n "$peel" ] && printf '%s\trefs/tags/%s^{}\n' "$FAKE_PEELED" "${ref:-v1}"
  exit 0
fi
# A branch or a lightweight tag has no peeled ref at all, so the extra pattern
# matches nothing and the answer is one line whether or not it was asked for.
printf '%s\trefs/heads/%s\n' "$FAKE_LSREMOTE" "${ref:-main}"
SHIM
cat > "$RECSHIM/curl" <<'SHIM'
#!/usr/bin/env bash
# Fake curl: prints $FAKE_CURL, or fails as a 404/rate-limited fetch would.
[ -n "${FAKE_CURL:-}" ] || exit 22
printf '%s\n' "$FAKE_CURL"
SHIM
chmod +x "$RECSHIM/git" "$RECSHIM/curl"
shim() { PATH="$RECSHIM:$PATH" bash -c "set -u; . '$VERDFN'; . '$LEDGERFN'; . '$RECFN'; $1"; }

# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: a ref that IS a commit resolves to itself, offline" 0 "[1234567]" \
  rec 'printf "[%s]" "$(record_sha o/r 1234567890abcdef1234567890abcdef12345678)"'
# ...which is the case a pinned drill hits, and it must not need a remote: the
# ls-remote for a full SHA returns nothing, so this used to record 'unresolved'.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...without asking any remote about it" 0 "[1234567]" \
  shim 'FAKE_LSREMOTE=""; FAKE_CURL=""; printf "[%s]" "$(record_sha o/r 1234567890abcdef1234567890abcdef12345678)"'
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: a branch resolves through git ls-remote" 0 "[abcdef1]" \
  shim 'export FAKE_LSREMOTE=abcdef1234567890abcdef1234567890abcdef12; printf "[%s]" "$(record_sha o/r main)"'
# An ANNOTATED tag resolves to the tag OBJECT, 40 hex characters, so the
# validator cannot catch it: the record would name an object nobody can check
# out, which is the exact failure this function's whole apparatus exists to
# refuse. --ref v0.10.0 is a shape a release drill plausibly takes.
#
# This passes ONLY because record_sha asks for `<ref>^{}` by name. The shim
# below sends the peeled line to a caller that requested it and to nobody else,
# which is what a real remote does — verified against github.com/git/git, where
# `ls-remote … v2.51.0` answers with the tag object 6d075e4 alone and the commit
# c44beea arrives only when `v2.51.0^{}` is asked for too. An earlier shim here
# appended the peel unconditionally and so proved nothing about the query.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: an annotated tag records the COMMIT, not the tag object" 0 \
  "[beef111]" \
  shim 'export FAKE_LSREMOTE=dead0000dead0000dead0000dead0000dead0000
        export FAKE_PEELED=beef1111beef1111beef1111beef1111beef1111
        printf "[%s]" "$(record_sha o/r v0.10.0)"'
# ...and the shim is only worth that if it withholds the peel from a caller who
# did not ask. Asserted directly, because every claim above rests on it.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and the fake remote peels only when the peel is REQUESTED" 0 \
  "[1 lines][2 lines]" \
  shim 'export FAKE_LSREMOTE=dead0000dead0000dead0000dead0000dead0000
        export FAKE_PEELED=beef1111beef1111beef1111beef1111beef1111
        printf "[%s lines]" "$(git ls-remote https://x v0.10.0 | grep -c .)"
        printf "[%s lines]" "$(git ls-remote https://x v0.10.0 "v0.10.0^{}" | grep -c .)"'
# ...and a lightweight tag or a branch, which send one unpeeled line, are
# unaffected — the peel is preferred where offered, not required.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...while an unpeeled answer is still the first line" 0 "[dead000]" \
  shim 'export FAKE_LSREMOTE=dead0000dead0000dead0000dead0000dead0000; printf "[%s]" "$(record_sha o/r v1)"'
# curl is the fallback because a drill host has it by construction (it fetched
# install.sh with it) and may have no git at all.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and falls back to the API when git cannot answer" 0 "[9abcdef]" \
  shim 'export FAKE_LSREMOTE=""; export FAKE_CURL=9abcdef0123456789abcdef0123456789abcdef; printf "[%s]" "$(record_sha o/r main)"'
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: neither answering is 'unresolved', not blank" 0 "[unresolved]" \
  shim 'export FAKE_LSREMOTE=""; export FAKE_CURL=""; printf "[%s]" "$(record_sha o/r main)"'
# A rate-limit body or an error page is not a SHA. Writing one into the record
# would be a lie with a monospace font on.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and a non-SHA answer is refused by the same validator" 0 \
  "[unresolved]" \
  shim 'export FAKE_LSREMOTE=""; export FAKE_CURL="{ message: rate"; printf "[%s]" "$(record_sha o/r main)"'

# --- the path guard, which runs BEFORE the host is formatted ----------------
check "drill record: no --emit-record is not an error" 0 "" rec 'record_check_path ""'
check "drill record: a writable path is accepted" 0 "" rec "record_check_path '$RECWORK/new.md'"
check "drill record: a missing directory is refused, and named" 2 "no such directory" \
  rec "record_check_path '$RECWORK/nope/rec.md'"
# THE guard that matters. The emitted file is a skeleton the operator writes
# prose into, and that edited file is the release evidence the gate reads. A
# second run pointed at it would eat exactly the judgement calls that make it
# evidence — so it does not get to, and it finds out at startup rather than
# forty minutes in.
printf 'a hand-edited record\n' > "$RECWORK/taken.md"
check "drill record: an existing record is never overwritten" 2 "already exists" \
  rec "record_check_path '$RECWORK/taken.md'"
check "drill record: ...and the refusal says why that matters" 2 "destroys the judgement" \
  rec "record_check_path '$RECWORK/taken.md'"
: > "$RECWORK/empty.md"
check "drill record: ...while an empty file is not a record and may be used" 0 "" \
  rec "record_check_path '$RECWORK/empty.md'"

# --- the rig pin, read off the mint rather than re-derived -------------------
# The record must say what the MINT used. It used to re-derive that from the
# environment, carrying bin/box's `main` default as a second spelling — and
# #150 made that spelling a lie: RIG_REF unset now resolves rig's latest
# RELEASE at mint, so an unpinned run would have recorded `main` while the
# guest was handed a tag, asserting a combination nobody drilled. So the value
# is read off the mint's own stamp (#103), and where there is no stamp to read
# the record admits it instead of naming a ref.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: an unpinned run no longer claims 'main' (#150)" 0 "[heavy-duty/rig][unresolved]" \
  rec 'record_collect o/r main 0; printf "[%s][%s]" "$REC_RIG_REPO" "$REC_RIG_REF"'
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and an overridden rig pin is what lands in the record" 0 "[you/rig][topic]" \
  rec 'export RIG_REPO=you/rig RIG_REF=topic; record_collect o/r main 0; printf "[%s][%s]" "$REC_RIG_REPO" "$REC_RIG_REF"'
# The stamp read itself, driven against a shim incus: this is what the mint
# site above fills REC_RIG_* from, and it is the only place the resolved
# default survives — bin/box resolved it, the environment never saw it.
STAMPSHIM="$(mktemp -d)"
cat > "$STAMPSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the drill's stamp read: 'config get <box> <key>' answers from
# $FAKE_STAMP ("<key> <value>" lines), and an unset key prints EMPTY, exits 0 —
# which is what a real incus does (audit B4) and what 'unresolved' guards.
case "$*" in
  "config get "*)
    [ -n "${FAKE_STAMP:-}" ] || exit 0
    key="$*"; key="${key##* }"
    awk -v k="$key" '$1 == k { $1 = ""; sub(/^ /, ""); print }' "$FAKE_STAMP" ;;
esac
exit 0
SHIM
chmod +x "$STAMPSHIM/incus"
STAMPF="$(mktemp)"
printf 'user.box.rig.repo heavy-duty/rig\nuser.box.rig.ref 0.3.1\n' > "$STAMPF"
stamped() { PATH="$STAMPSHIM:$PATH" FAKE_STAMP="$1" rec "$2"; }
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: the pin is read off the mint's stamp (#103, #150)" 0 "[0.3.1]" \
  stamped "$STAMPF" 'printf "[%s]" "$(drill_stamp drill rig.ref)"'
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and a box with no stamp is 'unresolved', never blank (#150)" 0 "[unresolved]" \
  stamped /dev/null 'printf "[%s]" "$(drill_stamp drill rig.ref)"'
rm -rf "$STAMPSHIM" "$STAMPF"
# The invocation has to reproduce the run, so the pin belongs in it: the flags
# alone name a different drill than the one that ran — and after #150 so does
# the same command left unpinned, which would resolve whatever is latest then.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: the invocation carries the env pins, not just the flags" 0 \
  "RIG_REF=topic bash drill/drill.sh --repo o/r --ref v1" \
  rec 'export RIG_REF=topic; record_collect o/r v1 0; printf "%s" "$REC_INVOCATION"'
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...the ref the MINT resolved, where the environment set none (#150)" 0 \
  "RIG_REF=0.3.1 bash drill/drill.sh" \
  rec 'REC_RIG_REF=0.3.1; record_collect o/r v1 0; printf "%s" "$REC_INVOCATION"'
INVF="$(mktemp)"
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
rec 'record_collect o/r v1 0; printf "%s" "$REC_INVOCATION"' > "$INVF" 2>/dev/null
check "drill record: ...and 'unresolved' is never put in a command line (#150)" 1 "" \
  grep -q unresolved "$INVF"
rm -f "$INVF"
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and --keep-boxes, which changes what was drilled" 0 "--keep-boxes" \
  rec 'record_collect o/r v1 1; printf "%s" "$REC_INVOCATION"'

# --- the record itself ------------------------------------------------------
# A finished drill, pinned so every field is assertable. record_collect fills
# only what is not already set, which is what lets a test pin the world away.
RECSTATE="PHASE_RAN=([I]=1 [A]=8 [B]=51 [C]=9 [E]=7 [D]=0 [M]=10 [T]=1)
REC_VERSION=9.9.9; REC_DATE=2026-07-21; REC_HOST='bare Debian 13, Incus 6.0.2'
REC_RUN_ID=drill-9.9.9-20260721-01; REC_BOX_SHA=abc1234; REC_RIG_SHA=def5678
REC_RIG_REF=0.3.1
REC_ELAPSED=2460; record_collect heavy-duty/box release/9.9.9 0"
emit() {   # emit <state> → the record that state produces, on stdout
  rm -f "$RECOUT"
  rec "$RECSTATE; $1; record_write '$RECOUT'" >/dev/null 2>&1
  cat "$RECOUT" 2>/dev/null
}
CLEAN='pass=87; fail=0'

# drills/README.md:34-42 asks for six things. One check each, because a record
# missing one of them is the hand-transcription this replaces, reintroduced.
check "drill record: names the version, as the filename must match" 0 \
  "# Release drill — 9.9.9" emit "$CLEAN"
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: carries the run ID the sibling repos reconcile on" 0 \
  '**Run ID:** `drill-9.9.9-20260721-01`' emit "$CLEAN"
check "drill record: names the host — 'real hardware' is the claim" 0 \
  "**Host:** bare Debian 13, Incus 6.0.2" emit "$CLEAN"
check "drill record: dates the run" 0 "**Date:** 2026-07-21" emit "$CLEAN"
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: pins box's candidate ref TO A SHA" 0 \
  'box `release/9.9.9` @ `abc1234`' emit "$CLEAN"
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and rig's, which is the other half of the combination" 0 \
  'rig `0.3.1` @ `def5678`' emit "$CLEAN"
# The reproduction has to carry the rig pin the run used, not just the flags:
# an unpinned run resolved a RELEASE at mint (#150), so a reproduction left
# equally unpinned would resolve whatever is latest the day it is re-run.
check "drill record: says what ran, as a command that reproduces it" 0 \
  'RIG_REF=0.3.1 bash drill/drill.sh --repo heavy-duty/box --ref release/9.9.9' emit "$CLEAN"
check "drill record: gives the numbers and the wall clock" 0 \
  "**87/87 passed, 0 failed.** 41 minutes wall clock." emit "$CLEAN"
check "drill record: carries the per-phase ledger a single total cannot say" 0 \
  "B 51/51" emit "$CLEAN"
check "drill record: states the floor and the table's total as two facts" 0 \
  "Probe floor: 87 expected this run; the table declares 87." emit "$CLEAN"
# DRILL_EXPECT can raise the floor above the table, and the record must not read
# that as an error — the operator is deliberately demanding more than the table.
check "drill record: ...which stays readable when DRILL_EXPECT raises the floor" 0 \
  "Probe floor: 90 expected this run; the table declares 87." \
  emit "DRILL_EXPECT=90; $CLEAN"
# The record is pasted into a file and read months later. Escape codes in it are
# the peculiar thing this issue found: every script emitted ANSI unconditionally.
# Emitted here rather than read from the check above, so the assertion owns the
# file it grades and a reordering cannot quietly grade a stale one.
emit "$CLEAN; no 'a coloured failure' >/dev/null" >/dev/null
check "drill record: contains no ANSI, whatever the terminal was" 1 "" \
  grep -q $'\033' "$RECOUT"

# THE thing the harness must not do. A generated file that reads like a finished
# one invites exactly the transcription-free confidence the last two waivers
# were written under, so it says what it is — in rendered text, not an HTML
# comment nobody sees.
check "drill record: says out loud that it is a draft, not a record" 0 \
  "Draft — a generated skeleton" emit "$CLEAN"
check "drill record: ...and says the judgement is the operator's to write" 0 \
  "a judgement it must not fabricate" emit "$CLEAN"

# THE #153 regression, in the artifact #153 exists to protect. A run that emitted
# 78 of 87 and failed none is not "78/78 passed" — and the record is precisely
# where that fraction used to get written down as proof a release was drilled.
check "drill record: a short run's denominator is the FLOOR, not what ran" 0 \
  "**78/87 passed" emit "pass=78; fail=0; PHASE_RAN[C]=0"
check "drill record: ...and the short phase is named in it" 0 "C 0/9" \
  emit "pass=78; fail=0; PHASE_RAN[C]=0"
# A DECLARED skip is the honest half: the floor moves, and the record says which
# probes were not expected and why — recorded as skipped, never as passing.
check "drill record: a declared skip lowers the record's denominator" 0 \
  "**78/78 passed" emit "pass=78; fail=0; PHASE_RAN[C]=0; skipped C 9 'no isolation stack' >/dev/null"
check "drill record: ...and the skip is recorded AS a skip, beside the failures" 0 \
  "- SKIP: no isolation stack" \
  emit "pass=78; fail=0; PHASE_RAN[C]=0; skipped C 9 'no isolation stack' >/dev/null"
check "drill record: ...and the waived probes are visible in the ledger line" 0 \
  "9 waived by declared skips" \
  emit "pass=78; fail=0; PHASE_RAN[C]=0; skipped C 9 'no isolation stack' >/dev/null"
check "drill record: failures land in it verbatim, uncoloured" 0 "- FAIL: the boundary held open" \
  emit "pass=86; fail=1; no 'the boundary held open' >/dev/null"
check "drill record: a clean run says so rather than leaving a bare heading" 0 \
  "Nothing to report" emit "$CLEAN"

# The audit answers, in the record rather than only on a terminal (#154). They
# were printed under a header telling a human to paste them into an issue that
# has since closed, in a repo that has been renamed — the last field still being
# retyped out of coloured output, which is the defect this emitter exists to end.
check "drill record: the audit answers land in it, not only on the terminal" 0 \
  "- A3 sibling: BLOCKED — tcp dropped" \
  emit "$CLEAN; aud 'A3 sibling: BLOCKED — tcp dropped'"
check "drill record: ...under their own heading, because they are measurements" 0 \
  "## Audit answers" emit "$CLEAN; aud 'A6 ipv6: none, as contract requires'"
# The reason they are not folded into `findings`: a real run always has audit
# answers, so folding them would retire the clean-run line entirely — a record
# could never again say plainly that nothing was wrong.
check "drill record: ...and a clean run with answers still reports nothing wrong" 0 \
  "Nothing to report" emit "$CLEAN; aud 'A6 ipv6: none, as contract requires'"
# A run with no answers grows no empty heading. Emitted here rather than read
# from a check above, so the assertion owns the file it grades.
emit "$CLEAN" >/dev/null
check "drill record: a run with no audit answers grows no empty section" 1 "" \
  grep -q '## Audit answers' "$RECOUT"

# --- the emitter on the real exit path --------------------------------------
# Everything above drives record_write directly. None of it proves the DRILL
# emits, or that emitting cannot disturb the exit status #153 made load-bearing.
# So run the composed skeleton — the script's actual tail — with a record path.
run_emit() {   # run_emit <state> — EXIT STATUS is the drill's own
  rm -f "$RECOUT"
  bash -c "set -u; . '$VERDFN'; . '$LEDGERFN'; . '$RECFN'
    RECORD='$RECOUT'; REPO=heavy-duty/box; REF=release/9.9.9; KEEP=0
    RUN_ID=drill-9.9.9-20260721-01
    $RECSTATE; $1
    . '$SUMFN'"
}
check "drill emit: a clean run writes the record and still EXITS 0" 0 \
  "record written:" run_emit "$CLEAN"
check "drill emit: ...and the file on disk is the record" 0 "**87/87 passed, 0 failed.**" \
  cat "$RECOUT"
check "drill emit: ...pinned to the run ID the drill announced at install time" 0 \
  "drill-9.9.9-20260721-01" cat "$RECOUT"
check "drill emit: ...and the operator is told it is a skeleton to edit" 0 \
  "it is a SKELETON" run_emit "$CLEAN"
# The terminal block is retargeted at the same reader, so the two agree about
# where an audit answer goes. What it must never do again is send an operator to
# heavy-duty/claudebox#15: complete, and in a repo that has been renamed (#154).
check "drill emit: the terminal audit block is headed for the record" 0 \
  "Isolation audit answers" run_emit "$CLEAN; aud 'A6 ipv6: none, as contract requires'"
check "drill: ...and no phase header sends the operator to the closed audit" 1 "" \
  grep -qF 'phase - "#15 audit answers' "$ROOT/drill/drill.sh"

# The record is written AFTER the shortfall verdict, so it carries it. Emitting
# before that `no` fires would put a clean sweep in the record on a short run,
# which is the defect #153 closed.
check "drill emit: a short run EXITS NON-ZERO with a record written" 1 \
  "record written:" run_emit "pass=78; fail=0; PHASE_RAN[C]=0"
check "drill emit: ...and the record it wrote carries the shortfall, not a sweep" 0 \
  "FAIL: the drill ran SHORT:" cat "$RECOUT"
check "drill emit: ...against the full denominator, 78/87" 0 "**78/87 passed" cat "$RECOUT"

# A record that cannot be written must not be able to turn a clean drill red:
# the exit status is the floor's verdict on the DRILL, and a full disk has no
# opinion about whether the trust boundary held. It must not be silent either.
check "drill emit: an unwritable path cannot change the drill's verdict" 0 "FAILED to write" \
  bash -c "set -u; . '$VERDFN'; . '$LEDGERFN'; . '$RECFN'
    RECORD='$RECWORK/gone/rec.md'; REPO=o/r; REF=v1; KEEP=0; RUN_ID=x
    $RECSTATE; $CLEAN
    . '$SUMFN'"
# ...and no --emit-record writes nothing at all, which is still the common run.
check "drill emit: without --emit-record nothing is written" 0 "" \
  bash -c "rm -f '$RECOUT'; . '$VERDFN'; . '$LEDGERFN'; . '$RECFN'
    RECORD=''; $RECSTATE; $CLEAN; . '$SUMFN' >/dev/null; [ ! -e '$RECOUT' ]"

# --- the wiring, so the emitter cannot be left correct-but-unreachable ------
# The path guard must run before the first phase, for the same reason the
# DRILL_EXPECT guard does: an operator who typo'd it, or who pointed it at a
# record they already wrote, must find out before the host gets formatted.
record_guard_runs_first() {
  local guard first
  # shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
  guard="$(grep -n '^record_check_path "\$RECORD" || exit 2$' "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] || { echo "the record path guard is defined but never called"; return 1; }
  first="$(grep -nE '^[[:space:]]*phase [A-Za-z-]+ ' "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
  [ "$guard" -lt "$first" ] || { echo "the guard runs at $guard, after the first phase at $first"; return 1; }
}
check "drill: the record path guard is called, and before the first phase" 0 "" \
  record_guard_runs_first
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill: the run ID is announced during the run, not only at the end" 0 \
  'inf "run ID: $RUN_ID' grep -F 'run ID:' "$ROOT/drill/drill.sh"

# --- the sg re-exec, EXECUTED ------------------------------------------------
# The drill re-execs itself into the incus-admin group, and --in-group carries no
# arguments through, so every setting the second stage needs crosses as
# environment — the clock especially: $SECONDS in the shell that finishes
# measures the time since the exec, not the drill's.
#
# This was two greps for `DRILL_RECORD=` and `DRILL_T0=` in the exec line. A grep
# proves a string is present; it cannot see that `sg -c` hands its argument to a
# SHELL, so the values on that line were shell SOURCE. An apostrophe in a record
# path — legal, and constrained by no option here — closed the quotes and the
# remainder reparsed as a command, 127, forty minutes into a run whose startup
# guard had already blessed the path. So the block is extracted and RUN, against
# shadow's real `sg` argument shape and a second stage that reports what arrived.
REEXECFN="$(mktemp)"
awk '/^# >>> group re-exec/,/^# <<< group re-exec/' "$ROOT/drill/drill.sh" > "$REEXECFN"
check "drill re-exec: extracted from drill.sh (guards the awk)" 0 "sg incus-admin" \
  cat "$REEXECFN"
check "drill re-exec: the extracted block is valid bash" 0 "" bash -n "$REEXECFN"

REXWORK="$(mktemp -d)"
cat > "$REXWORK/sg" <<'SHIM'
#!/bin/sh
# Fake sg, in shadow's shape: `sg <group> -c <string>`, string handed to a shell
# (newgrp.c: execl(shell, prog, "-c", command)). Deliberately /bin/sh, not bash:
# the drill does not get to choose which shell /etc/passwd names.
[ "$1" = incus-admin ] || { echo "sg: wrong group: $1" >&2; exit 2; }
[ "$2" = -c ] || { echo "sg: expected -c, got: $2" >&2; exit 2; }
exec /bin/sh -c "$3"
SHIM
cat > "$REXWORK/stage2.sh" <<'SHIM'
#!/usr/bin/env bash
# The second stage, reduced to "say what you were handed". Delimited, so a value
# that lost or gained a character is visible rather than merely different.
printf 'argv=[%s] record=[%s] runid=[%s] ref=[%s] repo=[%s] keep=[%s] t0=[%s] ingroup=[%s]\n' \
  "${1:-}" "$DRILL_RECORD" "$DRILL_RUN_ID" "$BOX_REF" "$BOX_REPO" \
  "$DRILL_KEEP" "$DRILL_T0" "$IN_GROUP"
SHIM
chmod +x "$REXWORK/sg" "$REXWORK/stage2.sh"

reexec() {   # reexec <record> <run-id> <ref> → what the second stage received
  # The hostile values arrive as POSITIONAL ARGUMENTS, never interpolated into
  # this snippet: a test that spliced them into its own bash -c would be making
  # the mistake it is here to catch.
  PATH="$REXWORK:$PATH" bash -c "set -u
    . '$REEXECFN'
    OWNS=0; REPO=heavy-duty/box; KEEP=0; DRILL_T0=1750000000
    SELF='$REXWORK/stage2.sh'
    RECORD=\$1; RUN_ID=\$2; REF=\$3
    reexec_in_group" _ "$1" "$2" "$3"
}

check "drill re-exec: the settings arrive on the far side at all" 0 \
  "record=[drills/0.10.0.md] runid=[drill-0.10.0-20260819-01] ref=[release/0.10.0]" \
  reexec drills/0.10.0.md drill-0.10.0-20260819-01 release/0.10.0
check "drill re-exec: ...and --in-group is what the second stage is told it is" 0 \
  "argv=[--in-group] " reexec drills/0.10.0.md drill-0.10.0-20260819-01 release/0.10.0
# The clock is the field that cannot be recovered on the far side if it is lost:
# the record's wall clock is measured from it.
check "drill re-exec: the clock crosses, because \$SECONDS restarts here" 0 \
  "t0=[1750000000]" reexec '' '' main
check "drill re-exec: ...and so does IN_GROUP, or the second stage re-execs forever" 0 \
  "ingroup=[1]" reexec '' '' main

# THE boundary. An apostrophe is legal in a Unix pathname and in a run ID, and
# this is the reproduction that was reported: the old line exited 127 here.
check "drill re-exec: an apostrophe in the record path survives verbatim" 0 \
  "record=[/tmp/release's record.md]" \
  reexec "/tmp/release's record.md" "run's-id" main
check "drill re-exec: ...and one in the run ID, which constrains nothing either" 0 \
  "runid=[run's-id]" reexec "/tmp/release's record.md" "run's-id" main
# Not just a crash: the same hole executes whatever it is handed. A value that
# reaches the far side INTACT is a value that was never parsed on the way.
# shellcheck disable=SC2016  # the $( ) is the LITERAL text being asserted on
check "drill re-exec: a command substitution crosses as text, not as a command" 0 \
  'ref=[$(touch '"$REXWORK"'/pwned)]' \
  reexec '' '' "\$(touch $REXWORK/pwned)"
check "drill re-exec: ...and nothing it named was executed" 1 "" test -e "$REXWORK/pwned"
check "drill re-exec: a semicolon is a character in a ref, not a statement" 0 \
  "ref=[main; echo owned]" reexec '' '' 'main; echo owned'
# The path to the script itself is interpolated by nobody either — SELF is
# readlink's answer, and a drill checked out under a directory with a space in it
# is not an exotic host.
SPACED="$REXWORK/a dir/it's here"; mkdir -p "$SPACED"
cp "$REXWORK/stage2.sh" "$SPACED/stage2.sh"
check "drill re-exec: the drill's own path may contain a space and an apostrophe" 0 \
  "argv=[--in-group]" \
  bash -c "PATH='$REXWORK':\$PATH; set -u
    . '$REEXECFN'
    OWNS=0; REPO=o/r; REF=main; KEEP=0; DRILL_T0=1; RECORD=; RUN_ID=
    SELF=\$1
    reexec_in_group" _ "$SPACED/stage2.sh"

# --- the settings the re-exec carries, resolved ------------------------------
# The far side of the exec re-runs this block, so what the second stage BELIEVES
# is whatever these lines make of the environment it was handed. Extracted and
# driven with the environment emptied, so a default that only looks right
# because the outer shell happened to export something is visible.
SETFN="$(mktemp)"
awk '/^# >>> drill settings/,/^# <<< drill settings/' "$ROOT/drill/drill.sh" > "$SETFN"
check "drill settings: extracted from drill.sh (guards the awk)" 0 "--emit-record" \
  cat "$SETFN"
check "drill settings: the extracted block is valid bash" 0 "" bash -n "$SETFN"
settings() {   # settings <env-assignment...> -- <argv...> → the resolved settings
  # Seeded rather than empty: "${env[@]}" on an empty array is an unbound
  # variable under this file's set -u on bash before 4.4.
  local env=(_DRILL_SETTINGS_TEST=1)
  while [ "$1" != -- ]; do env+=("$1"); shift; done; shift
  # shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
  env -i PATH="$PATH" "${env[@]}" bash -c '. "$0"
    printf "keep=[%s] record=[%s] runid=[%s] repo=[%s] ref=[%s]\n" \
      "$KEEP" "$RECORD" "$RUN_ID" "$REPO" "$REF"' "$SETFN" "$@"
}
check "drill settings: DRILL_RECORD and DRILL_RUN_ID cross the exec" 0 \
  "record=[/tmp/r.md] runid=[rid-01]" \
  settings DRILL_RECORD=/tmp/r.md DRILL_RUN_ID=rid-01 --
check "drill settings: ...and the flags win where both are given" 0 \
  "record=[/tmp/flag.md] runid=[flag-01]" \
  settings DRILL_RECORD=/tmp/env.md DRILL_RUN_ID=env-01 -- \
    --emit-record /tmp/flag.md --run-id flag-01
check "drill settings: BOX_REPO and BOX_REF cross too, and default sanely" 0 \
  "repo=[heavy-duty/box] ref=[main]" settings --
check "drill settings: --keep-boxes is read from the command line" 0 "keep=[1]" \
  settings -- --keep-boxes
check "drill settings: ...and is off when nothing asks for it" 0 "keep=[0]" settings --

# THE half that was broken. KEEP crossed the exec as a bare `KEEP=` and the
# settings line then reset it to 0 before anything could read it, so
# --keep-boxes was inert for the whole of the stage that runs the teardown phase
# and writes the record. The record's invocation field is the first thing to
# depend on it (#152), and a field that cannot be true is the hand-transcription
# problem in a new place.
check "drill settings: ...and DRILL_KEEP is how it crosses the re-exec" 0 "keep=[1]" \
  settings DRILL_KEEP=1 --
# A bare KEEP in an operator's environment is not a request to change what the
# drill asserts — the pin is DRILL_KEEP, like every other one.
check "drill settings: a stray KEEP in the environment is not the flag" 0 "keep=[0]" \
  settings KEEP=1 --

# The colour guard. Capturing this output is itself the regression: before #152
# every verdict carried escape codes into whatever file it was piped to, and the
# record was then transcribed past them. `grep -q ESC` exits 1 on a clean line.
verdicts_have_ansi() {   # 0 when the emitted verdicts still carry escape codes
  env "$@" bash -c "set -u; . '$VERDFN'; ok x; no y; note z; phase A B; skipped() { :; }" \
    | grep -q "$(printf '\033')"
}
check "drill colour: a captured verdict carries no ANSI" 1 "" verdicts_have_ansi
check "drill colour: ...nor does one under NO_COLOR" 1 "" verdicts_have_ansi NO_COLOR=1
# NO_COLOR's convention is that being SET is the signal, empty included — the
# reading that trips implementations testing for a non-empty value.
check "drill colour: ...including an empty NO_COLOR, per the convention" 1 "" \
  verdicts_have_ansi NO_COLOR=
check "drill colour: doctor.sh honours it too" 0 "" \
  grep -qF 'NO_COLOR+x' "$ROOT/drill/doctor.sh"
check "drill colour: multiuser.sh honours it too" 0 "" \
  grep -qF 'NO_COLOR+x' "$ROOT/drill/multiuser.sh"

# ...and the three checks above cannot tell the two halves of the guard apart.
# They pipe into grep, so stdout is never a terminal and `[ ! -t 1 ]` satisfies
# all three on its own: deleting the NO_COLOR clause left the suite fully green.
# A pty is what makes the distinction real — ANSI PRESENT on a terminal is the
# other half, and nothing asserted it either.
pty_verdicts() {   # pty_verdicts <env...> — the verdicts, on a real terminal
  env "$@" script -qec \
    "bash -c 'set -u; . \"$VERDFN\"; ok x; no y; note z; phase A B'" /dev/null
}
pty_has_ansi() { pty_verdicts "$@" | grep -q "$(printf '\033')"; }
# Every case PINS the variable — the baseline unsets it, the other two set it.
# Inheriting it is what a suite must not do here: NO_COLOR=1 is a valid thing
# for a developer or a review host to have set, and a baseline that inherits it
# asserts "ANSI is present" while being told to suppress ANSI. It then fails in
# precisely the environment whose behaviour it exists to test, and the green it
# gives anywhere else is a fact about the caller's shell, not about the guard.
if command -v script >/dev/null 2>&1 && pty_verdicts -u NO_COLOR >/dev/null 2>&1; then
  check "drill colour: on a real terminal the verdicts ARE coloured" 0 "" \
    pty_has_ansi -u NO_COLOR
  check "drill colour: ...and NO_COLOR alone turns them off, terminal or not" 1 "" \
    pty_has_ansi NO_COLOR=1
  # The empty case is the one implementations get wrong, and the only one the
  # tty test cannot stand in for.
  check "drill colour: ...including an empty NO_COLOR, on a terminal" 1 "" \
    pty_has_ansi NO_COLOR=
else
  # Recorded as a skip rather than passed silently — the #153 discipline, applied
  # to this file. script(1) is util-linux and present on the CI runner.
  echo "SKIP: drill colour: the pty checks need script(1); not usable here"
fi

# The help window is a line range into this file's own header, so a line added
# above it silently truncates the help. #153 moved it once already.
check "drill help: names --emit-record" 0 "--emit-record" bash "$ROOT/drill/drill.sh" --help
check "drill help: names the run ID" 0 "--run-id" bash "$ROOT/drill/drill.sh" --help
check "drill help: names NO_COLOR" 0 "NO_COLOR" bash "$ROOT/drill/drill.sh" --help
# ...and still covers the phase list rather than ending mid-sentence — the WHOLE
# list now. It used to stop on "C. Isolation baseline" while the block ran to M,
# so a tool asked directly for its phases answered with a truncated list of a
# list that was itself wrong (#154). Driven against the LEDGER's keys and not a
# fixed string: the two drifted apart for two releases because nothing compared
# them, and a phase added without a header line reds here now.
help_names_every_phase() {
  ( set -u
    # shellcheck disable=SC2034  # skipped() appends to it; the block assumes it
    findings=()
    # shellcheck disable=SC1090  # the extracted ledger, written above
    . "$LEDGERFN"
    local out k
    out="$(bash "$ROOT/drill/drill.sh" --help)" || { echo "--help failed"; exit 1; }
    for k in "${PHASE_ORDER[@]}"; do
      printf '%s\n' "$out" | grep -qE "^ *$k\. " \
        || { echo "--help does not name ledgered phase $k"; exit 1; }
    done )
}
check "drill help: it names every phase the ledger declares" 0 "" help_names_every_phase
check "drill help: ...including the last one, so the window is not short again" 0 \
  "T. Teardown" bash "$ROOT/drill/drill.sh" --help
check "drill help: ...and the window reaches the line after the list" 0 \
  "Exit 0 = every check passed" bash "$ROOT/drill/drill.sh" --help
check "drill: an unknown option is still a usage error" 2 "unknown option" \
  bash "$ROOT/drill/drill.sh" --frobnicate
# The window is quoted in two docs as a literal range, beside an instruction to
# keep it in step with the script — so a stale copy is not a stale fact, it is a
# stale instruction, and the editor who obeys it truncates the help again. The
# checks above prove the window COVERS the list; this one proves the docs quote
# the range that produced it. Read out of the '-h|--help' line rather than
# written here twice, or this check is the third copy that can drift.
docs_quote_the_help_window() {
  ( set -u
    local range doc
    range="$(sed -n "s/.*-h|--help) *sed -n '\([0-9]*,[0-9]*p\)'.*/\1/p" \
      "$ROOT/drill/drill.sh")"
    [ -n "$range" ] \
      || { echo "could not read the help window range out of drill/drill.sh"; exit 1; }
    for doc in drill/README.md CONTRIBUTING.md; do
      grep -qF "sed -n '$range'" "$ROOT/$doc" \
        || { echo "$doc does not quote the help window the script runs, $range"; exit 1; }
    done )
}
check "drill help: the docs quote the window range the script actually runs" 0 "" \
  docs_quote_the_help_window

# The drill's own README is documentation of a MEASURED thing, so it is checked
# against the measurement rather than read. It described four phases while the
# script printed eight for two releases, and E and M — some 200 lines of expose
# and migration probes — went undocumented the whole time, because nothing here
# compared the file to the ledger (#154).
readme_names_every_phase() {
  ( set -u
    # shellcheck disable=SC2034  # skipped() appends to it; the block assumes it
    findings=()
    # shellcheck disable=SC1090  # the extracted ledger, written above
    . "$LEDGERFN"
    local k
    for k in "${PHASE_ORDER[@]}"; do
      grep -qE "^\| \*\*$k\*\* \|" "$ROOT/drill/README.md" \
        || { echo "drill/README.md does not document ledgered phase $k"; exit 1; }
      # ...and with the phase's own probe count, which is the number an operator
      # reads a shortfall against. Two places to update is the point: a phase
      # that gains a probe moves the table, the README and CONTRIBUTING's total.
      grep -qE "^\| \*\*$k\*\* \|.*\| ${PHASE_EXPECT[$k]} \|" "$ROOT/drill/README.md" \
        || { echo "drill/README.md gives phase $k a count other than ${PHASE_EXPECT[$k]}"; exit 1; }
    done
    grep -qF "$(ledger_declared) probes" "$ROOT/drill/README.md" \
      || { echo "drill/README.md does not quote the table's own total, $(ledger_declared)"; exit 1; } )
}
check "drill/README: documents every ledgered phase, with its probe count" 0 "" \
  readme_names_every_phase
# The repo was renamed; the clone line and the issue links were not.
check "drill/README: no longer points at the pre-rename repo" 1 "" \
  grep -q 'heavy-duty/claudebox' "$ROOT/drill/README.md"
# The warning that cost the most to leave standing: on a script whose header
# says run it on a machine you can format, it spent an operator's caution on
# mutations phase D stopped making when the hardening shipped. Both halves are
# checked — the README says so plainly, and no line the drill PRINTS says
# otherwise. Grepped past the comments on purpose: the ones preserving this
# incident quote the old warning, and a comment is not an answer to anybody.
check "drill/README: says plainly that a run leaves no D-phase mutations" 0 "" \
  grep -qF 'no D-phase mutations' "$ROOT/drill/README.md"
check "drill: no line it PRINTS still promises D-phase residue on the host" 1 "" \
  bash -c "grep -vE '^[[:space:]]*#' '$ROOT/drill/drill.sh' | grep -q 'still applied'"
# Two lines were retired, and 'still applied' only pins one of them. The other
# was "(plus, unless re-run: dns.mode=none and NIC filtering from the D phase)"
# on the closing summary, which carries none of that string — so re-introducing
# THAT half stayed green while the check above read as though it covered both.
# So: no line the drill PRINTS calls the phase by that name at all. Matched
# case-sensitively on the "D phase"/"D-phase" shape rather than on "phase D",
# because the ledger call `phase D "D. The isolation contract, stated"` is a
# printed line and a correct one; it is the phase's own heading, not a claim
# about residue. The header states the positive version and is a comment, past
# this grep for the reason the check above gives.
check "drill: ...nor the closing line's version of the same promise" 1 "" \
  bash -c "grep -vE '^[[:space:]]*#' '$ROOT/drill/drill.sh' | grep -qE 'D[- ]phase'"

# The gate reads drills/<version>.md, so the emitter's own documentation lives
# beside the record format it produces.
check "drills/README documents the emitter" 0 "" grep -qF -- '--emit-record' "$ROOT/drills/README.md"
check "drills/README documents the audit-answers section the emitter writes" 0 "" \
  grep -qF '## Audit answers' "$ROOT/drills/README.md"
check "drills/README says the emitted record is a starting point" 0 "" \
  grep -qiF 'skeleton' "$ROOT/drills/README.md"
check "drills/README says where the shared run ID comes from" 0 "" \
  grep -qF -- '--run-id' "$ROOT/drills/README.md"

# Every extracted block and every scratch directory, including the two blocks
# and the fake-`sg` tree added in round 2 — a stray directory on /tmp holding an
# executable called `sg` is a worse leftover than a stray file.
rm -rf "$RECWORK" "$REXWORK"
rm -f "$LEDGERFN" "$VERDFN" "$SUMFN" "$RECFN" "$REEXECFN" "$SETFN"

# The docs keep the new promises.
check "help setup-host names BOX_SUBNET" 0 "BOX_SUBNET" "$BOX" help setup-host
check "help setup-host names the refusal" 0 "REFUSES" "$BOX" help setup-host
check "help doctor names the #80 signature" 0 "#80" "$BOX" help doctor
check "README documents BOX_SUBNET" 0 "" grep -qF 'BOX_SUBNET' "$ROOT/README.md"

# ---------------------------------------------------------------------------
# The versioned install (#66 → 0.7.0). BOX_INSTALL_SOURCE bypasses the network,
# so these are REAL runs of install.sh against throwaway BOX_HOME/BOX_BIN
# roots — layout, symlink chain, flat-tree migration, symlink healing, use and
# uninstall are all DRIVEN, not grepped. A fake `incus` on PATH answers the
# existing-boxes gate ($FAKE_BOXES names them), so the #66 refusals — refuse
# to flip, refuse to switch, refuse to uninstall under boxes — run for real
# too, with no daemon anywhere near this suite.
# ---------------------------------------------------------------------------
VER="$(cat "$ROOT/VERSION")"
WORK="$(mktemp -d)"
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"

ISHIM="$WORK/ishim"; mkdir -p "$ISHIM"
cat > "$ISHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus: 'list' prints $FAKE_BOXES (whitespace-separated names, one per
# line); everything else succeeds silently. Just enough for the existing-boxes
# gate that guards version flips.
case " $* " in
  *" list "*) for b in ${FAKE_BOXES:-}; do printf '%s\n' "$b"; done ;;
esac
exit 0
SHIM
chmod +x "$ISHIM/incus"

# A fabricated "newer release": the same CLI, a different VERSION — what an
# upgrade actually is, from the installer's point of view.
SRC9="$WORK/src-9.9.9"; mkdir -p "$SRC9/bin" "$SRC9/host"
cp "$ROOT/bin/box" "$SRC9/bin/box"; chmod +x "$SRC9/bin/box"
echo "9.9.9-drill" > "$SRC9/VERSION"
# A stub host/setup-host.sh that only announces itself: enough to prove WHETHER
# the installer ran host setup, and from WHICH version's tree, with no Incus and
# no root. The real script builds the isolation stack; this one echoes (#115).
cat > "$SRC9/host/setup-host.sh" <<'STUB'
#!/usr/bin/env bash
echo "SETUP-HOST-RAN-FROM 9.9.9-drill"
STUB
chmod +x "$SRC9/host/setup-host.sh"
SRC8="$WORK/src-8.8.8"; mkdir -p "$SRC8/bin"
cp "$ROOT/bin/box" "$SRC8/bin/box"; chmod +x "$SRC8/bin/box"
echo "8.8.8-drill" > "$SRC8/VERSION"

inst() {  # inst <box_home> <box_bin> [VAR=val ...] — run install.sh for real
  local h="$1" b="$2"; shift 2
  env HOME="$FAKEHOME" PATH="$ISHIM:$PATH" FAKE_BOXES= \
      BOX_HOME="$h" BOX_BIN="$b" BOX_YES=1 BOX_SKIP_SETUP_HOST=1 \
      BOX_INSTALL_SOURCE="$ROOT" "$@" bash "$ROOT/install.sh"
}
inst_setup() {  # like inst, but WITHOUT BOX_SKIP_SETUP_HOST — host setup is the
  # thing under test, so the switch that suppresses it has to come off. Safe
  # offline: the only setup-host on these fabricated sources is the echo stub
  # above, and BOX_YES=1 answers its prompt.
  local h="$1" b="$2"; shift 2
  env HOME="$FAKEHOME" PATH="$ISHIM:$PATH" FAKE_BOXES= \
      BOX_HOME="$h" BOX_BIN="$b" BOX_YES=1 \
      BOX_INSTALL_SOURCE="$ROOT" "$@" bash "$ROOT/install.sh"
}
ibox() {  # ibox [VAR=val ...] <cmd...> — run an installed box under the shim
  env HOME="$FAKEHOME" PATH="$ISHIM:$PATH" FAKE_BOXES= "$@"
}

# --- fresh install: the layout and the chain --------------------------------
H1="$WORK/h1"; B1="$WORK/b1"
check "install: a fresh install runs clean" 0 "done" inst "$H1" "$B1"
check "install: the tree lands in versions/<v>" 0 "" test -x "$H1/versions/$VER/bin/box"
check "install: 'current' points at versions/<v>" 0 "versions/$VER" readlink "$H1/current"
check "install: the PATH symlink rides the chain" 0 "$H1/current/bin/box" readlink "$B1/box"
check "install: box --version answers through the whole chain" 0 "box $VER" ibox "$B1/box" --version
check "install: INSTALLED_FROM records the local source" 0 "local:" cat "$H1/versions/$VER/INSTALLED_FROM"

# --- converge, don't clobber ------------------------------------------------
touch "$H1/versions/$VER/CANARY"
check "install: a same-version re-run is a no-op that says so (#66)" 0 "already installed" inst "$H1" "$B1"
check "install: the no-op left the tree untouched" 0 "" test -e "$H1/versions/$VER/CANARY"
check "install: BOX_REINSTALL=1 replaces that version's tree" 0 "reinstalled" inst "$H1" "$B1" BOX_REINSTALL=1
check "install: the reinstall really replaced it (canary gone)" 1 "" test -e "$H1/versions/$VER/CANARY"

# --- a second version: side-by-side, and the no-boxes flip ------------------
check "install: a second version installs side-by-side" 0 "" inst "$H1" "$B1" BOX_INSTALL_SOURCE="$SRC9"
check "install: ...into its own versions dir" 0 "" test -x "$H1/versions/9.9.9-drill/bin/box"
check "install: ...and the old version stays" 0 "" test -d "$H1/versions/$VER"
check "install: with no boxes, the default flips to the new version" 0 "box 9.9.9-drill" ibox "$B1/box" --version

# --- box versions -----------------------------------------------------------
check "versions: lists the installed versions" 0 "$VER" ibox "$B1/box" versions
check "versions: marks the current default" 0 "(current)" ibox "$B1/box" versions
check "versions: marks the running one" 0 "(running)" ibox "$B1/box" versions

# --- box use ----------------------------------------------------------------
check "use: no argument is a usage error" 2 "usage: box use" ibox "$B1/box" use
check "use: an unknown version is refused by name" 1 "no such version" ibox "$B1/box" use 1.2.3
# A version is a directory NAME — a crafted one must die at the gate, never
# reach the ln (current pointing outside the root) or an rm -rf.
check "use: a path-traversal version dies at the gate" 1 "not a sane version name" \
  ibox "$B1/box" use '../../tmp/evil'
check "use: refuses under existing boxes, naming them (#66)" 1 "wedged" \
  ibox FAKE_BOXES="wedged stuck" "$B1/box" use "$VER"
check "use: the refusal points at the remedy (box rm, then re-run)" 1 "box rm" \
  ibox FAKE_BOXES=wedged "$B1/box" use "$VER"
check "use: with no boxes, flips the default" 0 "switched to $VER" ibox "$B1/box" use "$VER"
check "use: the flip is effective through the PATH chain" 0 "box $VER" ibox "$B1/box" --version
check "install: an installed-but-not-current version is a no-op too" 0 "already installed" \
  inst "$H1" "$B1" BOX_INSTALL_SOURCE="$SRC9"
check "install: ...and does not move the default" 0 "box $VER" ibox "$B1/box" --version

# --- the upgrade-under-boxes refusal, driven end to end ---------------------
H2="$WORK/h2"; B2="$WORK/b2"
check "refusal drill: baseline install" 0 "done" inst "$H2" "$B2"
check "upgrade under boxes: REFUSES the default flip (#66)" 0 "refusing to change the default box version" \
  inst "$H2" "$B2" BOX_INSTALL_SOURCE="$SRC9" FAKE_BOXES=work
check "upgrade under boxes: the new version IS installed side-by-side" 0 "" \
  test -d "$H2/versions/9.9.9-drill"
check "upgrade under boxes: the default stayed put" 0 "box $VER" ibox "$B2/box" --version
check "upgrade under boxes: the blocking boxes are NAMED" 0 "· work" \
  inst "$H2" "$B2" BOX_INSTALL_SOURCE="$SRC8" FAKE_BOXES=work
check "upgrade under boxes: the refusal names the deliberate flip" 0 "" \
  bash -c 'grep -q "then flip the default:  box use" "'"$ROOT"'/install.sh"'

# --- migration: a 0.6.0 flat tree becomes a versioned one -------------------
H3="$WORK/h3"; B3="$WORK/b3"; mkdir -p "$H3/bin" "$B3"
cp "$ROOT/bin/box" "$H3/bin/box"; chmod +x "$H3/bin/box"
cp "$ROOT/VERSION" "$H3/VERSION"
echo "test@flat" > "$H3/INSTALLED_FROM"
ln -s "$H3/bin/box" "$B3/box"
check "migrate: a pre-0.7.0 flat tree is moved into versions/" 0 "migrating" inst "$H3" "$B3"
check "migrate: the OPERATOR'S tree moved (not a fresh copy)" 0 "test@flat" \
  cat "$H3/versions/$VER/INSTALLED_FROM"
check "migrate: nothing flat remains at the root" 1 "" test -e "$H3/bin"
check "migrate: current points at the migrated version" 0 "versions/$VER" readlink "$H3/current"
check "migrate: the PATH symlink was re-pointed through current" 0 "$H3/current/bin/box" readlink "$B3/box"
check "migrate: the migrated install answers --version" 0 "box $VER" ibox "$B3/box" --version

# #117: the migration is not silent about the entry it manufactured. The old
# tree is now a first-class 'box versions' row the operator never installed —
# so the output has to name the way back out (uninstall) and the reason to
# keep it (rollback), at the migration AND again in the closing summary, which
# is the half an operator scrolling ~250 lines of install output actually sees.
H3B="$WORK/h3b"; B3B="$WORK/b3b"; mkdir -p "$H3B/bin" "$B3B"
cp "$ROOT/bin/box" "$H3B/bin/box"; chmod +x "$H3B/bin/box"
cp "$ROOT/VERSION" "$H3B/VERSION"
ln -s "$H3B/bin/box" "$B3B/box"
mig_out="$WORK/mig-out.txt"
inst "$H3B" "$B3B" BOX_INSTALL_SOURCE="$SRC9" >"$mig_out" 2>&1 || true
check "migrate: the output points at the reap command (#117)" 0 "box uninstall $VER" \
  cat "$mig_out"
check "migrate: ...and names keeping it as a rollback target (#117)" 0 "keep it to roll back" \
  cat "$mig_out"
check "migrate: ...and the closing summary re-states it (#117)" 0 "was migrated to versions/$VER" \
  cat "$mig_out"
# ...and the note is conditional: an install with nothing to migrate must not
# mention a migration at all. grep exits 1 when the string is absent, which is
# the pass here.
nomig_out="$WORK/nomig-out.txt"
H3C="$WORK/h3c"; B3C="$WORK/b3c"
inst "$H3C" "$B3C" >"$nomig_out" 2>&1 || true
check "migrate: a NON-migrating install stays silent about migration (#117)" 1 "" \
  grep -qF "was migrated to versions/" "$nomig_out"

# ...and the seamless 0.6.0 → 0.7.0 upgrade: flat tree in, new version beside it.
H4="$WORK/h4"; B4="$WORK/b4"; mkdir -p "$H4/bin" "$B4"
cp "$ROOT/bin/box" "$H4/bin/box"; chmod +x "$H4/bin/box"
cp "$ROOT/VERSION" "$H4/VERSION"
ln -s "$H4/bin/box" "$B4/box"
check "migrate+upgrade: flat 0.6.0 in, new version installed beside it" 0 "" \
  inst "$H4" "$B4" BOX_INSTALL_SOURCE="$SRC9"
check "migrate+upgrade: both versions present" 0 "" \
  bash -c "[ -d '$H4/versions/$VER' ] && [ -d '$H4/versions/9.9.9-drill' ]"
check "migrate+upgrade: no boxes → the new version is the default" 0 "box 9.9.9-drill" \
  ibox "$B4/box" --version

# #115, end to end and fully offline: a flat pre-0.7.0 tree must still count as
# "no install yet" and RUN host setup. The migration converts the flat tree into
# versions/<v>, which is precisely what used to make had_install read 1 — the
# host then skipped setup-host while 'box --version' reported the new release,
# leaving every host-side artifact (box-firewall, #102) at the old one. The stub
# setup-host echoes a marker, so the marker IS the proof it ran.
H4B="$WORK/h4b"; B4B="$WORK/b4b"; mkdir -p "$H4B/bin" "$B4B"
cp "$ROOT/bin/box" "$H4B/bin/box"; chmod +x "$H4B/bin/box"
cp "$ROOT/VERSION" "$H4B/VERSION"
ln -s "$H4B/bin/box" "$B4B/box"
check "flat upgrade: host setup RUNS over a migrated flat tree (#115)" 0 "SETUP-HOST-RAN-FROM 9.9.9-drill" \
  inst_setup "$H4B" "$B4B" BOX_INSTALL_SOURCE="$SRC9"

# The converse, so the gate is proven to still GATE: H4B is now a genuinely
# versioned tree, which HAS already made the host-setup decision — a re-run must
# not redo it. Without this, "fix" and "run setup-host unconditionally" would be
# indistinguishable.
vers_out="$WORK/versioned-upgrade-out.txt"
inst_setup "$H4B" "$B4B" BOX_INSTALL_SOURCE="$SRC8" >"$vers_out" 2>&1 || true
check "versioned upgrade: an existing versioned install still SKIPS host setup" 0 "already had a box install" \
  cat "$vers_out"
check "versioned upgrade: ...and the stub did NOT run" 1 "" \
  grep -qF "SETUP-HOST-RAN-FROM" "$vers_out"

# 'current' does not always flip: the #66 guard holds the default under existing
# boxes. Host setup must still come from the version just installed, or the
# upgrade converges the host with the OLD release's host scripts — reinstating
# the very staleness #115 is about. The flat fixture carries no host/ dir at all,
# so going through 'current' could not even find a script to run.
H10="$WORK/h10"; B10="$WORK/b10"; mkdir -p "$H10/bin" "$B10"
cp "$ROOT/bin/box" "$H10/bin/box"; chmod +x "$H10/bin/box"
cp "$ROOT/VERSION" "$H10/VERSION"
ln -s "$H10/bin/box" "$B10/box"
check "flat upgrade under boxes: setup-host runs the NEW version's script" 0 "SETUP-HOST-RAN-FROM 9.9.9-drill" \
  inst_setup "$H10" "$B10" BOX_INSTALL_SOURCE="$SRC9" FAKE_BOXES=work
check "flat upgrade under boxes: ...while the default correctly stayed put (#66)" 0 "box $VER" \
  ibox "$B10/box" --version

# A broken current must halt the single-version path BEFORE any decision: the
# CURRENT guard keys off what current resolves to, and a dangling link makes
# that answer a lie. Drive the version tree's own binary — the current chain
# is exactly what is broken. H4 has two versions; heal current afterwards.
ln -sfn "versions/gone" "$H4/current"
check "uninstall: refuses while current is dangling (heal before delete)" 1 "dangling" \
  ibox "$H4/versions/$VER/bin/box" uninstall 9.9.9-drill --force
check "uninstall: ...and both version trees survived the refusal" 0 "" \
  bash -c "[ -d '$H4/versions/$VER' ] && [ -d '$H4/versions/9.9.9-drill' ]"
ln -sfn "versions/9.9.9-drill" "$H4/current"

# The migration reads VERSION off the old tree — disk data, not installer
# data. A hostile value must refuse BEFORE the tree moves anywhere.
H9="$WORK/h9"; B9="$WORK/b9"; mkdir -p "$H9/bin" "$B9"
cp "$ROOT/bin/box" "$H9/bin/box"; chmod +x "$H9/bin/box"
printf '%s\n' '../pwn' > "$H9/VERSION"
check "migrate: a hostile flat VERSION refuses to migrate" 1 "not a sane directory name" \
  inst "$H9" "$B9"
check "migrate: ...with the flat tree untouched where it was" 0 "" test -x "$H9/bin/box"

# --- healing: a wedged \$BINDIR/box must never block an install -------------
H5="$WORK/h5"; B5="$WORK/b5"; mkdir -p "$B5"
ln -s "$WORK/nowhere/box" "$B5/box"                    # dangling
check "heal: a DANGLING \$BINDIR/box does not wedge the install" 0 "done" inst "$H5" "$B5"
check "heal: ...and got repointed" 0 "box $VER" ibox "$B5/box" --version
H6="$WORK/h6"; B6="$WORK/b6"; mkdir -p "$B6"
ln -s /bin/true "$B6/box"                              # stale, but resolvable
check "heal: a STALE \$BINDIR/box with no tree does not fake 'installed'" 0 "installing $VER" \
  inst "$H6" "$B6"
check "heal: ...the install is real and answers" 0 "box $VER" ibox "$B6/box" --version

# --- box uninstall: one version ---------------------------------------------
check "uninstall: refuses to remove the CURRENT version" 1 "CURRENT" \
  ibox "$B1/box" uninstall "$VER" --force
check "uninstall: an unknown version is refused by name" 1 "no such version" \
  ibox "$B1/box" uninstall 5.5.5 --force
check "uninstall: a path-traversal version dies at the gate (never an rm -rf)" 1 "not a sane version name" \
  ibox "$B1/box" uninstall '../../../../etc' --force
check "uninstall: a version plus --all is ambiguous (usage error)" 2 "" \
  ibox "$B1/box" uninstall 9.9.9-drill --all --force
check "uninstall: removes a non-current version" 0 "removed version" \
  ibox "$B1/box" uninstall 9.9.9-drill --force
check "uninstall: that version dir is gone" 1 "" test -e "$H1/versions/9.9.9-drill"
check "uninstall: the current version still answers" 0 "box $VER" ibox "$B1/box" --version

# --- box uninstall: everything, in the safe order ---------------------------
check "uninstall: refuses while boxes exist, naming them" 1 "wedged" \
  ibox FAKE_BOXES=wedged "$B1/box" uninstall --all --force
check "uninstall: the refusal offers --purge-host" 1 "purge-host" \
  ibox FAKE_BOXES=wedged "$B1/box" uninstall --all --force
check "uninstall: refuses without --force when no terminal" 2 "refusing" \
  ibox bash -c "'$B1/box' uninstall --all </dev/null"
# Plant legacy crumbs: a real uninstall leaves neither name generation behind.
mkdir -p "$FAKEHOME/.local/share/claudebox"
ln -s "$WORK/gone" "$B1/claudebox"
check "uninstall --all: removes the whole install" 0 "uninstalled" \
  ibox "$B1/box" uninstall --all --force
check "uninstall --all: ZERO residue — root, symlinks, legacy names" 0 "" bash -c "
  [ ! -e '$H1' ] && [ ! -L '$H1' ] &&
  [ ! -e '$B1/box' ] && [ ! -L '$B1/box' ] &&
  [ ! -e '$B1/claudebox' ] && [ ! -L '$B1/claudebox' ] &&
  [ ! -e '$FAKEHOME/.local/share/claudebox' ]"
# The last word is a re-check: a survivor must turn into a loud INCOMPLETE,
# never a cheerful "uninstalled". (Root ignores file modes, so this drill is
# meaningful — and runnable — for a non-root runner only.)
if [ "$(id -u)" -ne 0 ]; then
  H7="$WORK/h7"; B7="$WORK/b7"
  inst "$H7" "$B7" >/dev/null 2>&1
  mkdir -p "$H7/versions/$VER/stuck"; touch "$H7/versions/$VER/stuck/pin"
  chmod 555 "$H7/versions/$VER/stuck"
  check "uninstall: a survivor makes it scream INCOMPLETE (exit 1)" 1 "INCOMPLETE" \
    ibox "$B7/box" uninstall --all --force
  chmod -R u+w "$H7" 2>/dev/null
fi

# --- the versioned verbs from a working tree: refuse, don't guess -----------
check "uninstall: refuses from a working tree" 1 "not a versioned install" "$BOX" uninstall --all --force
check "versions: refuses from a working tree" 1 "not a versioned install" "$BOX" versions
check "use: refuses from a working tree" 1 "not a versioned install" "$BOX" use 1.0.0

# The existing-boxes gate must be ONE decision: install.sh and bin/box carry
# byte-identical copies (the installer runs before any tree exists), and a
# drifted copy is two #66 stances pretending to be one.
EBBIN="$(mktemp)"; EBINST="$(mktemp)"
awk '/^existing_boxes\(\) \{/,/^\}/' "$ROOT/bin/box"     > "$EBBIN"
awk '/^existing_boxes\(\) \{/,/^\}/' "$ROOT/install.sh"  > "$EBINST"
check "existing_boxes: extracted from bin/box (guards the awk)" 0 "user.box=1" cat "$EBBIN"
check "existing_boxes: bin/box and install.sh copies are byte-identical" 0 "" diff "$EBBIN" "$EBINST"
rm -f "$EBBIN" "$EBINST"

# Same discipline for the version-name gate: one policy, two copies, no drift
# — a version that install.sh would refuse must not be one 'box use' accepts.
VVBIN="$(mktemp)"; VVINST="$(mktemp)"
awk '/^valid_version\(\) \{/,/^\}/' "$ROOT/bin/box"     > "$VVBIN"
awk '/^valid_version\(\) \{/,/^\}/' "$ROOT/install.sh"  > "$VVINST"
check "valid_version: extracted from bin/box (guards the awk)" 0 "A-Za-z0-9" cat "$VVBIN"
check "valid_version: bin/box and install.sh copies are byte-identical" 0 "" diff "$VVBIN" "$VVINST"
rm -f "$VVBIN" "$VVINST"

# --purge-host must FORWARD installer-family consent: under --force/BOX_YES
# the teardown call carries --yes, or a non-interactive combined uninstall
# dies at teardown's own prompt with the flag's promise broken.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "uninstall: --purge-host forwards consent to teardown-host (--yes)" 0 "" \
  grep -qF -- 'bash "$root/host/teardown-host.sh" --yes' "$ROOT/bin/box"

# --- the help keeps its promises --------------------------------------------
check "help: the table lists 'versions'"                0 "versions"   "$BOX" help
check "help use: names the #66 stance"                  0 "boxes"      "$BOX" help use
check "help uninstall: names --purge-host"              0 "purge-host" "$BOX" help uninstall
check "help uninstall: promises the absence re-check"   0 "absence"    "$BOX" help uninstall

# --- automation hooks the CI uninstall drill rides ---------------------------
check "teardown-host: honors --yes/BOX_YES (CI runs it unattended)" 0 "" \
  grep -qF 'BOX_YES' "$ROOT/host/teardown-host.sh"
check "teardown-host: points at box uninstall when done" 0 "" \
  grep -qF "box uninstall" "$ROOT/host/teardown-host.sh"
# ...and the other side of that contract (#113): consent NOT given and no
# terminal to ask on is a usage error, not a mute 'aborted'. Driven for real —
# the gate sits above the first 'incus' call, so a daemon-free run reaches it.
check "teardown-host: refuses without a TTY and names the override (#113)" 2 \
  "--yes (or BOX_YES=1) means yes" env -u BOX_YES bash "$ROOT/host/teardown-host.sh" </dev/null

# #102's race, pinned as a CLASS rather than at the one site that had it
# (#107). A daemon-free run cannot exercise a UFW teardown, so the shape is
# pinned instead: nowhere under host/, drill/, or bin/box may a known
# multi-line writer be piped into a line reader. `Status: active` is ufw's
# FIRST line, so the
# reader matches, closes the pipe, ufw takes SIGPIPE, and the pipeline
# yields 141 — under pipefail the branch silently reads false and the whole
# firewall block is skipped on a host the operator was told is clean.
#
# Swept, not per-file, because absence of pipefail is what made drill/wipe.sh
# survive the same shape: a file is only ever one `set -o pipefail` — the kind
# of robustness tweak that sails through review — from being #102 again. The
# sweep closes the class, so a new host/ or drill/ script — or a new bin/box
# site — inherits the pin for free instead of being one more site someone has
# to remember. bin/box joined the sweep after #134 removed its existing class.
# Comment lines are stripped before matching: each fix's own commentary quotes
# the racing shape to explain it, and a pin that cannot tell prose from code
# would fail on the very comment documenting why it exists.
#
# BOTH halves of the matcher are alternations, and both were widened in #124:
#
#   · READERS. Pinning `| grep` guarded the instance spelling, not the class.
#     `head -n1`, `sed -n '1p;q'` and `awk '/x/ {print; exit}'` all close the
#     pipe early and produce the identical wrong answer under pipefail. The
#     alternation is deliberately NOT restricted to the early-exit spellings
#     (`grep -q` but not `grep -c`, `sed …q` but not `sed s///`): telling
#     those apart by regex is exactly the kind of precision that rots, and
#     the house idiom is to capture first anyway — all six `ufw status` sites
#     in the tree already do. Banning the pipe outright costs nothing real
#     and cannot be defeated by a spelling nobody enumerated.
#
#   · WRITERS. Enumerated, not generalised. `incus config trust list` joins
#     `ufw status` because host/revoke-user.sh used it as a leftover-detection
#     condition under `set -euo pipefail` (#124). bin/box adds its multi-line
#     `incus` writers, `boxes_csv`, and the export metadata reader (#134). A
#     generic "no multi-line writer feeds a reader" matcher is unwritable here:
#     ~150 legitimate `| grep` sites exist across host/ and drill/, nearly all
#     reading an already-captured string back out of `printf '%s\n' "$var"`.
#     So the sweep claims exactly what it can check — THESE writers are never
#     piped — and grows one named writer at a time.
# shellcheck disable=SC2016  # "$1" is the subshell's positional, passed below
check "no multi-line writer is piped into a line reader under host/, drill/, or bin/box" 0 "" \
  bash -c 'bad=""
    for f in "$1"/host/*.sh "$1"/drill/*.sh "$1"/bin/box; do
      if [ "$f" = "$1/bin/box" ]; then
        writers="ufw status|incus [^|]*|boxes_csv|tar -xOf"
      else
        writers="ufw status|incus config trust list"
      fi
      awk '\''
        /^[[:space:]]*#/ { next }
        {
          line = $0
          if (logical != "") logical = logical line
          else logical = line
          if (line ~ /\\[[:space:]]*$/) {
            sub(/\\[[:space:]]*$/, "", logical)
            next
          }
          print logical
          logical = ""
        }
        END { if (logical != "") print logical }
      '\'' "$f" \
        | grep -qE "($writers)[^|]*\| *(grep|head|sed|awk|read)" \
        && bad="$bad ${f#"$1"/}"
    done
    [ -z "$bad" ] || { printf "racing reads in:%s\n" "$bad"; exit 1; }' \
    _ "$ROOT"

# The other direction, per file that removes UFW rules: the capture present and
# the delete loop breaking on absence, so the sweep above cannot be satisfied by
# deleting the block instead of fixing it.
for f in host/teardown-host.sh drill/wipe.sh; do
  # shellcheck disable=SC2016  # the $-strings are literals in the target files
  check "$f: the UFW branch reads a captured snapshot" 0 "" \
    grep -qF 'if [[ "$ufw_status" == *"Status: active"* ]]; then' "$ROOT/$f"
  # shellcheck disable=SC2016  # ditto
  check "$f: the numbered-delete loop breaks on absence, not on a pipe" 0 "" \
    grep -qF '[ -n "$line" ] || break' "$ROOT/$f"
done

# Same other-direction pin for the non-ufw writer the sweep now names: the
# --purge leftover assert must match a captured trust store, so the sweep
# cannot be satisfied by deleting the assert instead of fixing it. That assert
# is the last thing standing between "purge INCOMPLETE" and a silent claim of
# success on a host that still trusts the revoked user's certificate.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "revoke-user: the purge leftover assert reads a captured trust store" 0 "" \
  grep -qF 'trust_csv="$(incus config trust list' "$ROOT/host/revoke-user.sh"
# shellcheck disable=SC2016  # ditto
check "revoke-user: the cert leftover check matches the capture, not a pipe" 0 "" \
  grep -qF '"$trust_csv" == *$' "$ROOT/host/revoke-user.sh"
check "drill: reads the installed tree through current/" 0 "" \
  grep -qF '.local/share/box/current/VERSION' "$ROOT/drill/drill.sh"

# ---------------------------------------------------------------------------
# 'restart', and 'all' — the fleet word on the lifecycle verbs (#179)
# ---------------------------------------------------------------------------
# Driven end to end under a shim incus, because the whole of this feature is
# what box CALLS: which boxes it enumerates, in what order it keeps going, and
# what status it leaves behind. A grep would pin none of that.
FSHIM="$(mktemp -d)"; FWORK="$(mktemp -d)"
cat > "$FSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the fleet drive (#179).
#   FAKE_BOXES   space-separated names 'incus list' reports as box-tagged
#   FAKE_FAIL    space-separated names whose lifecycle call fails, as incus
#                fails: non-zero, with a reason on stderr
#   FAKE_STATES  space-separated name=STATE pairs; anything unlisted is RUNNING
#   FAKE_DEAD    non-empty: 'incus list' fails the way a daemon that is not
#                answering fails — non-zero, a reason on stderr, nothing on
#                stdout. Not the same thing as reporting no boxes.
printf 'incus %s\n' "$*" >> "$FAKE_INCUS_LOG"
state_of() {   # $1 = box name
  for kv in ${FAKE_STATES:-}; do
    if [ "${kv%%=*}" = "$1" ]; then printf '%s' "${kv#*=}"; return; fi
  done
  printf 'RUNNING'
}
case "${1:-}" in
  list)
    if [ -n "${FAKE_DEAD:-}" ]; then
      echo "Error: The incus daemon doesn't appear to be started" >&2
      exit 1
    fi
    # boxes_csv() asks twice — user.box=1 then the legacy user.claudebox=1 —
    # and dedupes. Only the modern tag answers here, so a fleet that acted
    # twice per box would show up as duplicate lifecycle calls in the log.
    case "$*" in
      *--columns\ s*)
        # box_state()'s read, which the 'stopped' precondition goes through.
        # A different --columns spelling from boxes_csv()'s 'nstS', so the two
        # reads cannot be confused for one another here either.
        state_of "${2:-}"; echo ;;
      *user.box=1*)
        for b in ${FAKE_BOXES:-}; do
          printf '%s,%s,CONTAINER,0\n' "$b" "$(state_of "$b")"
        done ;;
    esac
    exit 0 ;;
  config)
    # resolve_box()'s boundary read, for the single-box path.
    if [ "${2:-}" = get ]; then
      for b in ${FAKE_BOXES:-}; do
        if [ "$b" = "${3:-}" ] && [ "${4:-}" = user.box ]; then echo 1; exit 0; fi
      done
    fi
    exit 0 ;;
  restart|stop|start)
    for f in ${FAKE_FAIL:-}; do
      if [ "$f" = "${2:-}" ]; then
        echo "Error: The instance \"${2:-}\" is busy" >&2
        exit 1
      fi
    done
    # Incus's own already-in-state refusals, reproduced verbatim, because a
    # shim that cheerfully succeeds on them would let the mixed-state
    # assertions below pass for a build that never looked at the state. These
    # are what lxc/incus returns: restartCommon() and the !IsRunning() /
    # isRunningStatusCode() guards in the lxc driver. Note the third: 'restart'
    # on a stopped instance does NOT start it, it errors.
    case "$1:$(state_of "${2:-}")" in
      stop:STOPPED)    echo "Error: The instance is already stopped" >&2; exit 1 ;;
      start:RUNNING)   echo "Error: The container is already running" >&2; exit 1 ;;
      restart:STOPPED) echo "Error: The instance is already stopped" >&2; exit 1 ;;
    esac
    exit 0 ;;
esac
exit 0
SHIM
chmod +x "$FSHIM/incus"

FLOG="$FWORK/fleet.log"
FLEET_STATES=""
fleetbox() {   # fleetbox <boxes> <failing> <box args...> — the real box, shimmed
  local boxes="$1" failing="$2"; shift 2
  : > "$FLOG"
  env FAKE_INCUS_LOG="$FLOG" FAKE_BOXES="$boxes" FAKE_FAIL="$failing" \
    FAKE_STATES="$FLEET_STATES" PATH="$FSHIM:$PATH" "$BOX" "$@" </dev/null 2>&1
}
# The same box, against a daemon that does not answer at all. Deliberately a
# separate helper rather than a FAKE_BOXES value: "the daemon said no boxes"
# and "the daemon said nothing" are the two states this round is about telling
# apart, and they should not share a spelling in the drive either.
deadbox() {   # deadbox <box args...>
  : > "$FLOG"
  env FAKE_INCUS_LOG="$FLOG" FAKE_BOXES="one two" FAKE_FAIL="" FAKE_DEAD=1 \
    PATH="$FSHIM:$PATH" "$BOX" "$@" </dev/null 2>&1
}
# An absence assertion, as a non-zero exit: 'check' matches a substring's
# presence, so "it does NOT say the D6 line" needs the grep to be the command.
dead_says_empty() { deadbox "$@" | grep -q 'nothing to'; }
# The same, with a mixed-state daemon: <name=STATE ...> first, anything
# unlisted is RUNNING. Set-then-clear rather than a `VAR=x fn` prefix, whose
# persistence past the call is a bash-version question I would rather not ask.
mixedbox() {   # mixedbox <states> <boxes> <failing> <box args...>
  local states="$1" rc; shift
  FLEET_STATES="$states"; fleetbox "$@"; rc=$?; FLEET_STATES=""; return "$rc"
}
# What box actually asked the daemon to do, one line per lifecycle call.
acted_on() { grep -cE "^incus (restart|stop|start) $1( |\$)" "$FLOG"; }
fleet_calls() { grep -cE "^incus $1 " "$FLOG"; }
# Helpers rather than 'sh -c': the quoting a sh -c needs to carry $ILOG into a
# subshell is exactly the SC2016 the sweep reds, and a function reads better.
run_fleet_src() { sed -n '/^run_fleet()/,/^}/p' "$ROOT/bin/box"; }
run_fleet_has() { run_fleet_src | grep -qF "$1"; }
run_fleet_matches() { run_fleet_src | grep -qE "$1"; }
# Absence assertions, as a non-zero exit: 'check' matches a substring's
# presence, so "is NOT refused" needs the grep to be the command under test.
new_says_reserved() { "$BOX" new --name "$1" 2>&1 | grep -q reserved; }
# The first of the two calls inside cmd_new must be the reserved-word guard.
guard_precedes_stack() {
  sed -n '/^cmd_new()/,/^}/p' "$ROOT/bin/box" \
    | grep -o 'refuse_fleet_word\|require_stack' \
    | head -1 | grep -q refuse_fleet_word
}
# The same contract for the table door: the 'newname' precondition has to run
# ahead of the 'box' one, because resolving the first positional is a daemon
# round trip and whether 'all' is a legal new name does not depend on it. Line
# numbers rather than a first-match grep: the two markers are on different
# lines, and asking which comes first is the whole assertion.
newname_precedes_resolve() {
  local g r
  g="$(grep -n '\*,newname,\*)' "$ROOT/bin/box" | head -1 | cut -d: -f1)"
  r="$(grep -n 'inst=.*resolve_box' "$ROOT/bin/box" | head -1 | cut -d: -f1)"
  [ -n "$g" ] && [ -n "$r" ] && [ "$g" -lt "$r" ]
}

# --- D1: restart is one incus call, not down-then-start ---------------------
check "restart: one box restarts" 0 "restarted work" \
  fleetbox "work" "" restart work
check "restart: it is a single 'incus restart'" 0 "1" \
  acted_on work
check "restart: no 'stop' rides along — this is not down-then-start" 1 "" \
  grep -qE '^incus stop ' "$FLOG"
check "restart: the verb is in the table, so help renders it" 0 "usage: box restart" \
  "$BOX" help restart

# --- D3: 'all' is exactly what 'box list' prints for this caller ------------
# The tier boundary itself is Incus's — a restricted user's client is scoped to
# user-<uid> and an admin's to default, and no shim can model that refusal.
# What IS box's to get right, and what this drives, is that 'all' enumerates
# through boxes_csv() and builds no second path around the boundary: box acts
# on exactly the set the daemon showed it, no more.
check "all: acts on every box the daemon reports" 0 "restarted one" \
  fleetbox "one two three" "" restart all
check "all: ...and that is all three of them" 0 "3" \
  fleet_calls restart
check "all: the third box is named too" 0 "restarted three" \
  fleetbox "one two three" "" restart all
check "all: a box the daemon did NOT report is never touched" 1 "" \
  grep -qE '^incus restart other' "$FLOG"
# Structural, and load-bearing: the fleet set MUST come from boxes_csv(), the
# same reader 'box list' prints from. A second enumeration would be a second
# implementation of the tier boundary, which is how one of them gets a hole.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "all: the fleet is read through the 'box list' source, not a second list" 0 "" \
  run_fleet_has 'rows="$(boxes_csv)"'
check "all: run_fleet enumerates nothing else" 1 "" \
  run_fleet_matches 'incus list|--columns'

# The restricted-tier read and the admin read, each seeing only its own side —
# the assertion the test plan calls the one that must fail before the guard is
# right. Same box, same verb; the only difference is what the daemon answers.
check "all (restricted): acts on the caller's own box" 0 "stopped dev1-work" \
  fleetbox "dev1-work" "" down all
check "all (restricted): touches no admin box" 1 "" \
  grep -qE '^incus stop admin-' "$FLOG"
check "all (admin): acts on the admin's box" 0 "stopped admin-ci" \
  fleetbox "admin-ci" "" down all
check "all (admin): touches nothing in a restricted project" 1 "" \
  grep -qE '^incus stop dev1-' "$FLOG"

# --- D4: one failure does not abort the rest, and the status aggregates -----
# All three are STOPPED here, so 'start' genuinely has work to do on each and
# the only non-zero in the block is the injected failure — not a box that was
# already where it was asked to be.
check "all: a failing box does not stop the others (exit is aggregate)" 1 "started one" \
  mixedbox "one=STOPPED two=STOPPED three=STOPPED" "one two three" "two" start all
# Exit 1 throughout this block: the aggregate status is the point, so every
# case here asserts the failing status AND the work that happened anyway.
check "all: ...the box after the failure still acted" 1 "started three" \
  mixedbox "one=STOPPED two=STOPPED three=STOPPED" "one two three" "two" start all
check "all: ...the failure is named" 1 "two FAILED" \
  mixedbox "one=STOPPED two=STOPPED three=STOPPED" "one two three" "two" start all
check "all: ...with incus's own reason, never swallowed" 1 "is busy" \
  mixedbox "one=STOPPED two=STOPPED three=STOPPED" "one two three" "two" start all
check "all: ...and the run says how many of each" 1 "2 of 3 succeeded, 1 failed" \
  mixedbox "one=STOPPED two=STOPPED three=STOPPED" "one two three" "two" start all
check "all: every box was attempted despite the failure" 0 "3" \
  fleet_calls start
check "all: all three succeeding exits 0" 0 "started three" \
  mixedbox "one=STOPPED two=STOPPED three=STOPPED" "one two three" "" start all

# --- the mixed-state fleet: already-there is not a failure ------------------
# A fleet is mixed-state in the ordinary case, and Incus errors when an
# instance is already in the state you asked for. Without this, 'down all' reds
# whenever one box was already down — which unmeasures D4's exit status and
# leaves the issue's first test-plan line unmet. The shim above answers exactly
# as Incus does, so every assertion here reds if run_fleet() stops reading the
# state column.
check "mixed: 'down all' stops the running box" 0 "stopped one" \
  mixedbox "two=STOPPED" "one two" "" down all
check "mixed: ...names the already-stopped one as the success it is" 0 "two is already stopped" \
  mixedbox "two=STOPPED" "one two" "" down all
check "mixed: ...and calls incus for the one box that needed it" 0 "1" \
  fleet_calls stop
check "mixed: ...never for the box that was already there" 1 "" \
  grep -qE '^incus stop two( |$)' "$FLOG"
check "mixed: 'start all' names the already-running box" 0 "one is already running" \
  mixedbox "two=STOPPED" "one two" "" start all
check "mixed: ...and starts only the stopped one" 0 "started two" \
  mixedbox "two=STOPPED" "one two" "" start all
check "mixed: ...one call, not two" 0 "1" fleet_calls start

# The issue's test plan, line one: two boxes up, one down — 'restart all'
# reports three outcomes and leaves all three running.
check "mixed: 'restart all' restarts the running boxes" 0 "restarted one" \
  mixedbox "three=STOPPED" "one two three" "" restart all
check "mixed: ...and the second of them" 0 "restarted two" \
  mixedbox "three=STOPPED" "one two three" "" restart all
check "mixed: ...and STARTS the stopped one rather than erroring on it" 0 "started three — it was stopped" \
  mixedbox "three=STOPPED" "one two three" "" restart all
check "mixed: ...through a single 'incus start', which is not down-then-start (D1)" 0 "1" \
  fleet_calls start
check "mixed: ...with no 'stop' anywhere in the run" 1 "" \
  grep -qE '^incus stop ' "$FLOG"
check "mixed: ...two restarts and one start, three boxes, three outcomes" 0 "2" \
  fleet_calls restart

# The aggregate status still means what D4 says it means: a real failure beside
# a no-op box is still non-zero, and the no-op is still reported.
check "mixed: a real failure beside an already-stopped box still exits non-zero" 1 "two FAILED" \
  mixedbox "three=STOPPED" "one two three" "two" down all
check "mixed: ...and the already-stopped box is still reported" 1 "three is already stopped" \
  mixedbox "three=STOPPED" "one two three" "two" down all
check "mixed: ...counted as one of the successes, not skipped from the tally" 1 "2 of 3 succeeded, 1 failed" \
  mixedbox "three=STOPPED" "one two three" "two" down all

# Only the three pairs that are guaranteed to error are handled. Anything else
# goes to Incus and Incus decides — this is a refusal to make two doomed calls,
# not a state machine that has to know every state Incus will ever have.
check "mixed: an unmodelled state passes straight through to incus" 0 "stopped one" \
  mixedbox "one=FROZEN" "one" "" down all
check "mixed: ...as a real call, not a skip" 0 "1" fleet_calls stop

# require_stopped() has accepted three spellings of STOPPED in this file since
# long before the fleet word existed, so the state match does not trust Incus's
# current casing habit either.
check "mixed: the state match is case-insensitive, as require_stopped's is" 0 "two is already stopped" \
  mixedbox "two=stopped" "one two" "" down all
check "mixed: ...and it still calls incus for the box that needed it" 0 "stopped one" \
  mixedbox "two=stopped" "one two" "" down all

# --- D5: no prompt on the fleet forms, and 'rm' has no 'all' ----------------
# No TTY here, so a confirm() would exit 2 with "refusing to ... without
# --force" — which is exactly how this asserts the absence of a prompt.
check "all: 'down all' does not prompt" 0 "stopped one" \
  fleetbox "one two" "" down all
check "all: 'restart all' does not prompt" 0 "restarted one" \
  fleetbox "one two" "" restart all
check "rm has no fleet form: 'all' is resolved as an ordinary name" 1 "no such box: all" \
  fleetbox "one two" "" rm all --force
check "rm has no fleet form: it deleted nothing" 1 "" \
  grep -qE '^incus delete' "$FLOG"
check "rm's row carries no 'fleet' token" 1 "" \
  grep -qE '^  "rm\^[^^]*\^[^^]*fleet' "$ROOT/bin/box"

# --- the fleet form takes nothing after the word ----------------------------
# The single-box path forwards everything after the name to incus. The fleet
# path cannot — "this flag once" and "this flag to each of six boxes" are
# different acts — so it refuses instead of dropping the word in silence, which
# is the one outcome the operator has no way to notice.
check "all: a trailing word is a usage error, not a silent drop" 2 "takes nothing else" \
  fleetbox "one two" "" down all extra
check "all: ...and it names the word it refused" 2 "'extra'" \
  fleetbox "one two" "" down all extra
check "all: ...having touched no box" 1 "" grep -qE '^incus stop ' "$FLOG"
# The reachable spelling of a flag: box rejects an unknown --flag at parse
# time, so anything flag-shaped arrives after '--'. It is refused on the fleet
# form too, rather than being forwarded to every box or dropped.
check "all: a flag passed through '--' is refused as well" 2 "takes nothing else" \
  fleetbox "one two" "" down all -- --force
check "all: the single-box path still forwards its extras" 0 "stopped one" \
  fleetbox "one" "" down one extra
check "all: ...to incus, exactly as before" 0 "" \
  grep -qE '^incus stop one extra$' "$FLOG"

# --- D6: 'all' over zero boxes is success with a message --------------------
check "all: no boxes at all exits 0" 0 "nothing to restart" \
  fleetbox "" "" restart all
check "all: no boxes — and it called no lifecycle verb" 1 "" \
  grep -qE '^incus restart ' "$FLOG"
check "all: 'down all' on an empty host says so too" 0 "nothing to down" \
  fleetbox "" "" down all

# --- ...and a daemon that never answered is NOT an empty host ---------------
# The other side of D6, and the one that has to be told apart from it: an empty
# 'rows' means "no boxes" only if the question was asked and answered. A daemon
# that refused leaves it empty too, and reporting THAT as D6 makes 'box start
# all || alert' pass a run in which nothing happened at all — #179's own
# motivating scenario, a fleet start fired before incusd is up. run_fleet reads
# boxes_csv's status explicitly, because the '|| exit $?' call site suppresses
# errexit through the whole function body.
check "dead daemon: 'down all' does not claim the host is empty, and exits non-zero" 1 "not answering" \
  deadbox down all
check "dead daemon: ...having called no lifecycle verb" 1 "" \
  grep -qE '^incus (stop|start|restart) ' "$FLOG"
check "dead daemon: ...never reporting it as D6's empty fleet" 1 "" \
  dead_says_empty down all
check "dead daemon: 'start all' says the same thing" 1 "not answering" \
  deadbox start all
check "dead daemon: 'restart all' too" 1 "not answering" \
  deadbox restart all
# The message is require_stack()'s, so the two doors say one thing about a
# daemon that is not there — and it names the diagnosis rather than the fault.
check "dead daemon: it points at the same diagnosis require_stack does" 1 "box doctor" \
  deadbox down all
# require_stack() no-ops under --remote, so it could not have caught this one
# even if the fleet path reached it. The status read is what does.
check "dead daemon: an unreachable --remote is caught as well" 1 "not answering" \
  deadbox down all --remote lab
# The contrast, on the same shim: with the daemon answering, the empty fleet is
# still D6's success. Without this the fix could be "always die", which would
# red D6 rather than distinguish it.
check "dead daemon: an ANSWERING daemon with no boxes is still D6" 0 "nothing to down" \
  fleetbox "" "" down all

# --- D2: 'all' is reserved, refused at every door that SETS a name ----------
# No shim needed: the refusal lands before any daemon call, which is itself
# the point — a name box will never mint cannot depend on a reachable daemon.
check "new --name all is refused" 1 "reserved" \
  "$BOX" new --name all
check "new --name all names the fleet word" 1 "fleet word" \
  "$BOX" new --name all
# This whole suite runs with no incus on PATH, so the refusal above already
# happened without a daemon. Pinned structurally as well, because the ORDER is
# the contract: a name box will never mint must not depend on a reachable host.
check "new: the reserved word is refused before require_stack" 0 "" \
  guard_precedes_stack
# The other direction: the guard catches its one word and nothing else, so it
# cannot be satisfied by refusing every mint.
check "the reserved word itself is caught" 0 "" new_says_reserved all
check "an ordinary name is not refused by the reserved-word guard" 1 "" \
  new_says_reserved allocated
check "a name merely CONTAINING the word is not refused" 1 "" \
  new_says_reserved install-all
# A real tarball, because cmd_import reads the embedded instance name with tar
# before any of this is reached — and the refusal must land after that read,
# since the artifact's OWN name is a door too when no --name overrides it.
FART="$FWORK/work-20260820T120000Z.tar.gz"
mkdir -p "$FWORK/backup" && printf 'name: work\n' > "$FWORK/backup/index.yaml"
tar -czf "$FART" -C "$FWORK" backup/index.yaml
import_says_reserved() {   # extra args, e.g. --name all
  env FAKE_INCUS_LOG="$FLOG" FAKE_BOXES="" FAKE_FAIL="" PATH="$FSHIM:$PATH" \
    "$BOX" import "$FART" "$@" </dev/null 2>&1 | grep -q reserved
}
check "import --name all is refused too — import mints a name as well" 1 "reserved" \
  fleetbox "" "" import "$FART" --name all
check "import --name all refuses before the daemon is asked to import" 1 "" \
  grep -qE '^incus import' "$FLOG"
# The other direction, so the guard cannot be satisfied by refusing every
# import: the same artifact under its own embedded name gets past the word.
check "import --name all: the guard is what refused it" 0 "" \
  import_says_reserved --name all
check "import under an ordinary name is not caught by the guard" 1 "" \
  import_says_reserved

# --- ...including 'rename', which sets a name through a ROW -----------------
# The third door, and the one that shipped unguarded: 'new' and 'import' are
# function actions with a call site to put the guard in, while 'rename' is a
# table row whose second positional went straight to 'incus rename'. A box
# renamed to 'all' is unreachable by all three lifecycle verbs, which is the
# collision D2 exists to prevent — so the reserved word has to be refused where
# the name is SET, not only where a box is first minted.
renamebox() {   # renamebox <new-name> — a stopped 'work', shimmed
  mixedbox "work=STOPPED" "work" "" rename work "$@"
}
check "rename to 'all' is refused — a rename sets a name too" 1 "reserved" \
  renamebox all
check "rename to 'all' names the fleet word" 1 "fleet word" \
  renamebox all
# The assertion that fails at the head this was found on: the message alone
# would pass for a build that refused after the daemon had already renamed it.
check "rename to 'all': the daemon is never asked to rename" 1 "" \
  grep -qE '^incus rename ' "$FLOG"
# The other direction, so the guard cannot be satisfied by refusing every
# rename: an ordinary target still reaches Incus and still reports.
check "an ordinary rename target still reaches incus" 0 "renamed work to archive" \
  renamebox archive
check "...as a real 'incus rename' call" 0 "1" \
  fleet_calls rename
# ...and the identity rides straight through it, which is the whole of #181:
# 'rename' moves the NAME and touches no config, so a box that was renamed is
# still provably the same box. Asserted on the drive rather than on the source,
# because what matters is that no call was made.
check "rename: the id is never written, so it survives the rename (#181)" 1 "" \
  grep -qE 'config (set|unset) .*user\.box\.id' "$FLOG"
# Same contract as the mint doors, and the reason the token runs ahead of the
# 'box' precondition: refusing a name box will never carry must not depend on a
# reachable daemon. This suite runs with no incus on PATH, so the bare call is
# the probe, and the order is pinned structurally beside it.
check "rename to 'all' is refused with no daemon at all" 1 "reserved" \
  "$BOX" rename work all
check "rename: the reserved word is refused before the box is resolved" 0 "" \
  newname_precedes_resolve
# '--' ends box's own option parsing and the rest becomes positionals, so the
# word arrives as args[1] either way and there is no escape spelling. Driven
# because "the guard reads the parsed positional, not the command line" is the
# reason, and a reader should not have to take it on trust.
check "rename to 'all' after '--' is refused as well" 1 "reserved" \
  "$BOX" rename work -- all
# The token is on 'rename' alone: 'restore' also takes a second positional, but
# it is a snapshot label and no box ends up carrying it.
check "restore's snapshot label is not caught — a different namespace" 0 "restored work to all" \
  mixedbox "work=STOPPED" "work" "" restore work all --force
rm -rf "$FSHIM" "$FWORK"

# --- the real-daemon half, pinned so it cannot be deleted quietly -----------
# The shim above proves box acts on exactly the set the daemon showed it. What
# that set IS for a restricted caller is Incus's answer, and only the two-user
# rehearsal on a real daemon asks it. These greps are the same guard the other
# multiuser criteria carry here: a probe removed from the rehearsal reds this
# suite instead of silently reducing what CI measures.
check "multiuser: criterion (p) drives the fleet word" 0 "" \
  grep -qF 'box down all' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "multiuser: (p) reads the other user's boxes back from the admin socket" 0 "" \
  grep -qF 'untouched by $U2' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) restores its own box so later phases keep their premise" 0 "" \
  grep -qF 'box start all' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) proves the reserved name on a real daemon" 0 "" \
  grep -qF 'box new --name all' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) waits for the lease it disturbed, so (g) measures rather than skips" 0 "" \
  grep -qF 'took its boxnet lease back' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) measures the admin direction too" 0 "" \
  grep -qF "reached no restricted project" "$ROOT/drill/multiuser.sh"
# ...and measures it on something. Every other mint in that file belongs to a
# rehearsal user, so without a box of the admin's own root's 'all' enumerates
# zero and the "reached no restricted project" assertion above passes for a
# build with no run_fleet() at all — the absence of an action wearing a green
# tick. These two pin the mint and the positive half that needs it.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "multiuser: (p) mints a box of the ADMIN's own, so that direction acts on something" 0 "" \
  grep -qF 'box new --name "$ADMINBOX"' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) asserts the admin's 'all' stopped the admin's own box" 0 "" \
  grep -qF "stopped the admin's own box" "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # ditto
check "multiuser: (p) cleans that box up rather than leaving it for later phases" 0 "" \
  grep -qF 'box rm "$ADMINBOX" --force' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) is documented in the criteria list" 0 "" \
  grep -qF 'p. the fleet word' "$ROOT/drill/multiuser.sh"

# --- the three help texts mention the fleet form ----------------------------
for v in start down restart; do
  check "box help $v mentions the 'all' form" 0 "all" "$BOX" help "$v"
  check "box help $v shows it in the synopsis" 0 "<box>|all" "$BOX" help "$v"
  # The mixed-state leniency belongs to the fleet form only — D1 asked for a
  # passthrough row and that is what 'box restart <box>' is. The paragraph
  # saying "'restart all' starts a stopped box" sits three lines above, so the
  # difference is named where it is read rather than left to be discovered.
  check "box help $v says the single-box restart is not that lenient" 0 "still errors on a box that" \
    "$BOX" help "$v"
done

# ---------------------------------------------------------------------------
# The two files that name the review panel name one panel (#198). The roster
# dropped a fourth account on 2026-08-19 in .github/labels.conf — the file the
# state machine reads — and CONTRIBUTING.md, the file a contributor reads to
# learn what a handoff owes, kept it. Nothing broke at runtime and nothing here
# noticed, because nothing here compared the two. That is what this block is:
# the correction alone buys one correct day.
#
# Driven through file arguments and not against the repo's own copies alone,
# because "they agree today" is exactly what the stale pair also looked like
# from one side. The fixtures below break the agreement in each direction and
# require a red, and two more require a red for an extraction that reads
# nothing — a comparison of two empty sets passes, and would pass for a
# renamed heading or a deleted panel= line.
# ---------------------------------------------------------------------------
PANELWORK="$(mktemp -d)"

# Both extractors emit one account per line, in file order. Order is preserved
# rather than sorted here so the same two functions serve the set comparison
# and the order check below.
conf_panel() {   # conf_panel <labels.conf>
  sed -n 's/^panel=//p' "$1" | tr ' ' '\n' | sed '/^$/d'
}
# The doc's roster is the bulleted list under '## Review panel', bounded at the
# next heading. Both bounds carry weight. The bullet form is what keeps prose
# out: 'dan-claude-bot' is backticked INSIDE this section and is explicitly not
# a member, so an extractor reading every backtick reads triage onto the panel.
# The heading bound is what keeps the rest of the file out.
doc_panel() {   # doc_panel <CONTRIBUTING.md>
  # shellcheck disable=SC2016  # the backticks are markdown in the file being read
  sed -n '/^## Review panel$/,/^## /p' "$1" \
    | sed -n 's/^- `\([A-Za-z0-9._-]*\)`$/\1/p'
}
# panel_rosters_agree [<labels.conf> [<CONTRIBUTING.md>]] — the repo's own by
# default. Names the symmetric difference in both directions, so the message
# says which file is missing whom rather than that a comparison failed.
panel_rosters_agree() {
  ( set -u
    conf="${1:-$ROOT/.github/labels.conf}"; doc="${2:-$ROOT/CONTRIBUTING.md}"
    in_conf="$(conf_panel "$conf" | sort -u)"
    in_doc="$(doc_panel "$doc" | sort -u)"
    [ -n "$in_conf" ] || { echo "no panel= names read out of $conf"; exit 1; }
    [ -n "$in_doc" ] || { echo "no panel bullets read out of $doc's ## Review panel"; exit 1; }
    only_doc="$(comm -13 <(printf '%s\n' "$in_conf") <(printf '%s\n' "$in_doc") | tr '\n' ' ')"
    only_conf="$(comm -23 <(printf '%s\n' "$in_conf") <(printf '%s\n' "$in_doc") | tr '\n' ' ')"
    if [ -n "${only_doc% }" ] || [ -n "${only_conf% }" ]; then
      echo "the two rosters disagree:"
      [ -n "${only_doc% }" ] && echo "  listed in $doc, absent from $conf: ${only_doc% }"
      [ -n "${only_conf% }" ] && echo "  listed in $conf, absent from $doc: ${only_conf% }"
      exit 1
    fi
    exit 0 )
}
check "panel: the two rosters name the same set of accounts" 0 "" panel_rosters_agree
# ...and in one order, which is the other half of what the doc promises a
# reader: a list matching as a set but shuffled still reads as a different
# panel to the person comparing it against a review request.
panel_rosters_share_an_order() {
  ( set -u
    conf="$(conf_panel "$ROOT/.github/labels.conf" | tr '\n' ' ')"
    doc="$(doc_panel "$ROOT/CONTRIBUTING.md" | tr '\n' ' ')"
    [ "$conf" = "$doc" ] \
      || { echo "labels.conf lists [${conf% }]; CONTRIBUTING.md lists [${doc% }]"; exit 1; } )
}
check "panel: ...in the same order labels.conf uses" 0 "" panel_rosters_share_an_order

# --- the extraction is bounded ---------------------------------------------
# The case most likely to be got wrong, asserted directly rather than left to
# be implied by the sets happening to match: dan-claude-bot is triage, is named
# in this very section, and is never a reviewer.
doc_panel_omits_triage() {
  ( set -u
    doc_panel "$ROOT/CONTRIBUTING.md" | grep -qx 'dan-claude-bot' \
      && { echo "dan-claude-bot was read as a panel member; it is prose in the section, not a bullet"; exit 1; }
    exit 0 )
}
check "panel: dan-claude-bot is in the section and is NOT read as a member" 0 "" \
  doc_panel_omits_triage
# The heading bound, proven the same way: a bullet of the same shape in a later
# section is not the panel, so adding one must not move the roster.
awk '{ print } END { print ""; print "## Later"; print ""; print "- `grok-bot-andresmgsl`" }' \
  "$ROOT/CONTRIBUTING.md" > "$PANELWORK/later.md"
check "panel: a same-shaped bullet in a LATER section is not read as a member" 0 "" \
  panel_rosters_agree "$ROOT/.github/labels.conf" "$PANELWORK/later.md"

# --- and it fails, in both directions --------------------------------------
# The fix reverted: CONTRIBUTING.md as it stood at 362ec8d, four names against
# labels.conf's three.
awk '{ print } /^- `codex-bot-andresmgsl`$/ { print "- `grok-bot-andresmgsl`" }' \
  "$ROOT/CONTRIBUTING.md" > "$PANELWORK/reverted.md"
check "panel: the fix reverted in CONTRIBUTING.md reds" 1 "grok-bot-andresmgsl" \
  panel_rosters_agree "$ROOT/.github/labels.conf" "$PANELWORK/reverted.md"
check "panel: ...saying which file the extra name is absent from" 1 "absent from $ROOT/.github/labels.conf" \
  panel_rosters_agree "$ROOT/.github/labels.conf" "$PANELWORK/reverted.md"
# The same break made on the other file. Worth naming what this does and does
# not prove: a name removed from labels.conf lands in the SAME direction as the
# revert above — the doc holds a name the conf does not — and only shows the
# comparison is not pinned to one hard-coded file. The genuine other direction
# is the case below it.
sed 's/ kimi-bot-andresmgsl//' "$ROOT/.github/labels.conf" > "$PANELWORK/short.conf"
check "panel: a name dropped from labels.conf reds too" 1 "kimi-bot-andresmgsl" \
  panel_rosters_agree "$PANELWORK/short.conf" "$ROOT/CONTRIBUTING.md"
# The other direction: labels.conf names somebody CONTRIBUTING.md does not, so
# a contributor reads a shorter panel than the one their PR will be handed to.
# Without this the guard could be one-way and still pass everything above.
# shellcheck disable=SC2016  # ditto — a markdown bullet, not a command substitution
grep -v '^- `kimi-bot-andresmgsl`$' "$ROOT/CONTRIBUTING.md" > "$PANELWORK/thin.md"
check "panel: a name missing from CONTRIBUTING.md reds — the other direction" 1 "kimi-bot-andresmgsl" \
  panel_rosters_agree "$ROOT/.github/labels.conf" "$PANELWORK/thin.md"
check "panel: ...saying which file that one is absent from" 1 "absent from $PANELWORK/thin.md" \
  panel_rosters_agree "$ROOT/.github/labels.conf" "$PANELWORK/thin.md"

# --- an extraction that reads nothing is a failure, not an agreement --------
# Two empty sets are equal. So the heading a reader could rename in good faith,
# and the line a labels edit could drop, each have to be a red of their own.
sed 's/^## Review panel$/## Who reviews/' "$ROOT/CONTRIBUTING.md" > "$PANELWORK/noheading.md"
check "panel: a renamed section is a red, not two empty sets agreeing" 1 "no panel bullets" \
  panel_rosters_agree "$ROOT/.github/labels.conf" "$PANELWORK/noheading.md"
grep -v '^panel=' "$ROOT/.github/labels.conf" > "$PANELWORK/nopanel.conf"
check "panel: a labels.conf with no panel= line is a red as well" 1 "no panel= names" \
  panel_rosters_agree "$PANELWORK/nopanel.conf" "$ROOT/CONTRIBUTING.md"
rm -rf "$PANELWORK"

echo "---"
echo "$PASS passed, $FAIL failed"
rm -rf "$SHIMDIR" "$WORK"
[ "$FAIL" -eq 0 ]
