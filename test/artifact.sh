#!/usr/bin/env bash
# Offline coverage for box's release artifact hook (#251).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0

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

asset_shape() {
  [ "$(find "$1" -mindepth 1 -maxdepth 1 -printf '.' | wc -c)" -eq 2 ] \
    && [ -f "$2" ] && [ -f "$3" ]
}

sidecar_ok() {
  (cd "$1" && sha256sum -c "$(basename "$2")")
}

dir_empty() {
  [ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

WORK="$(mktemp -d)"
WORKSPACE_SENTINEL="$ROOT/.ceremony-src-artifact-test-$$"
trap 'rm -rf "$WORK"; rm -f "$WORKSPACE_SENTINEL"' EXIT
ASSETS="$WORK/assets"
VERSION=0.0.0-test
ARTIFACT="$ASSETS/box-$VERSION.sh"
SIDECAR="$ARTIFACT.sha256"
ACTION="$ROOT/.github/actions/release-artifact/action.yml"

check "release artifact: script is valid bash" 0 "" \
  bash -n "$ROOT/dist/release-artifact.sh"
check "release artifact: hook has exactly one run step" 0 "1" \
  grep -c '^      run:' "$ACTION"
check "release artifact: hook delegates to the tested build script" 0 "" \
  grep -qF "\"\$GITHUB_WORKSPACE/dist/release-artifact.sh\"" "$ACTION"
check "release artifact: hook passes the release version" 0 "" \
  grep -qF -- "--version \"\$VERSION\"" "$ACTION"
check "release artifact: hook passes the workspace root" 0 "" \
  grep -qF -- "--root \"\$GITHUB_WORKSPACE\"" "$ACTION"
check "release artifact: hook does not duplicate installer build logic" 1 "" \
  grep -qF 'make-installer.sh' "$ACTION"
printf 'release-job workspace state, never payload\n' > "$WORKSPACE_SENTINEL"
check "release artifact: builds from the committed checkout" 0 "wrote" \
  env RELEASE_ASSETS_DIR="$ASSETS" \
  bash "$ROOT/dist/release-artifact.sh" --version "$VERSION"
rm -f "$WORKSPACE_SENTINEL"
check "release artifact: output directory contains exactly the two assets" 0 "" \
  asset_shape "$ASSETS" "$ARTIFACT" "$SIDECAR"
check "release artifact: installer proves its payload" 0 "payload intact" \
  bash "$ARTIFACT" --check
check "release artifact: checksum sidecar verifies beside the asset" 0 "OK" \
  sidecar_ok "$ASSETS" "$SIDECAR"

ART_HOME="$WORK/artifact-home"
ART_BIN="$WORK/artifact-bin"
DIRECT_HOME="$WORK/direct-home"
DIRECT_BIN="$WORK/direct-bin"
mkdir -p "$ART_BIN" "$DIRECT_BIN"

check "release artifact: installs offline through the tree installer" 0 "done" \
  env BOX_HOME="$ART_HOME" BOX_BIN="$ART_BIN" BOX_YES=1 BOX_SKIP_SETUP_HOST=1 \
  bash "$ARTIFACT"
check "release artifact: checkout installs offline through the same installer" 0 "done" \
  env BOX_HOME="$DIRECT_HOME" BOX_BIN="$DIRECT_BIN" BOX_YES=1 BOX_SKIP_SETUP_HOST=1 \
  BOX_INSTALL_SOURCE="$ROOT" bash "$ROOT/install.sh"

TREE_VERSION="$(cat "$ROOT/VERSION")"
ART_TREE="$ART_HOME/versions/$TREE_VERSION"
DIRECT_TREE="$DIRECT_HOME/versions/$TREE_VERSION"
check "release artifact: installed trees differ only in provenance" 0 "" \
  diff -ru --exclude=INSTALLED_FROM "$ART_TREE" "$DIRECT_TREE"
check "release artifact: provenance names the asset and payload checksum" 0 \
  "artifact:box-$VERSION.sh sha256:" \
  grep -F "artifact:box-$VERSION.sh sha256:" "$ART_TREE/INSTALLED_FROM"
check "release artifact: provenance is one line" 0 "1" \
  awk 'END { print NR; exit NR == 1 ? 0 : 1 }' "$ART_TREE/INSTALLED_FROM"
check "release artifact: release-job workspace state is not packed" 1 "" \
  test -e "$ART_TREE/$(basename "$WORKSPACE_SENTINEL")"

UNPACKED_ROOT="$WORK/unpacked-box"
UNPACKED_ASSETS="$WORK/unpacked-assets"
UNPACKED_HOME="$WORK/unpacked-home"
UNPACKED_BIN="$WORK/unpacked-bin"
mkdir -p "$UNPACKED_ROOT" "$UNPACKED_BIN"
git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$UNPACKED_ROOT"
printf 'unpacked source member\n' > "$UNPACKED_ROOT/unpacked-only"
check "release artifact: builds from an unpacked non-Git tree" 0 "wrote" \
  bash "$ROOT/dist/release-artifact.sh" --version "$VERSION" \
  --root "$UNPACKED_ROOT" --assets-dir "$UNPACKED_ASSETS"
check "release artifact: installer from an unpacked tree is valid" 0 "done" \
  env BOX_HOME="$UNPACKED_HOME" BOX_BIN="$UNPACKED_BIN" BOX_YES=1 \
  BOX_SKIP_SETUP_HOST=1 bash "$UNPACKED_ASSETS/box-$VERSION.sh"
check "release artifact: an unpacked tree is read as-is" 0 "unpacked source member" \
  grep -F 'unpacked source member' \
  "$UNPACKED_HOME/versions/$TREE_VERSION/unpacked-only"

BAD_ROOT="$WORK/not-box"
BAD_ASSETS="$WORK/bad-assets"
mkdir -p "$BAD_ROOT" "$BAD_ASSETS"
printf 'not a box tree\n' > "$BAD_ROOT/README"
check "release artifact: a non-box root aborts" 1 "not a box tree" \
  bash "$ROOT/dist/release-artifact.sh" --version "$VERSION" \
  --root "$BAD_ROOT" --assets-dir "$BAD_ASSETS"
check "release artifact: an abort publishes nothing" 0 "" \
  dir_empty "$BAD_ASSETS"

# The suite drives only local trees. Keep the forbidden network callers absent
# as source assertions so adding one is a named failure, not a failed request.
check "release artifact: test uses no curl" 1 "" \
  grep -Eq '(^|[;&|[:space:]])curl([[:space:]]|$)' "$ROOT/test/artifact.sh"
check "release artifact: test uses no gh" 1 "" \
  grep -Eq '(^|[;&|[:space:]])gh([[:space:]]|$)' "$ROOT/test/artifact.sh"
check "release artifact: test uses no git fetch" 1 "" \
  grep -Eq 'git[[:space:]]+fetch([[:space:]]|$)' "$ROOT/test/artifact.sh"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
