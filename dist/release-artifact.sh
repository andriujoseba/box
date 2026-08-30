#!/usr/bin/env bash
set -euo pipefail
# dist/release-artifact.sh — build box's offline release asset and checksum.
#
# The release hook runs after the tag exists and before GitHub publishes the
# release. A non-zero exit therefore leaves the tag created and no release
# published. Recover by fixing the cause, then deleting and re-pushing the same
# tag so both release doors see the corrected tree (#251).

usage() {
  cat <<'USAGE'
release-artifact.sh — build box's release installer and checksum
  --version VER       release version                              [required]
  --root DIR          box tree to pack                    [default: repo root]
  --assets-dir DIR    output directory       [default: $RELEASE_ASSETS_DIR]
USAGE
}

die() { printf 'release-artifact: ERROR: %s\n' "$*" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version=''
root="$(cd "$script_dir/.." && pwd)"
assets_dir="${RELEASE_ASSETS_DIR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --version)    version="${2:?--version needs a value}"; shift 2 ;;
    --root)       root="${2:?--root needs a value}"; shift 2 ;;
    --assets-dir) assets_dir="${2:?--assets-dir needs a value}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown argument '$1' (see --help)" ;;
  esac
done

[ -n "$version" ] || die "--version is required"
[ -n "$assets_dir" ] || die "--assets-dir or RELEASE_ASSETS_DIR is required"
[ -d "$root" ] || die "--root '$root' is not a directory"
root="$(cd "$root" && pwd)"
mkdir -p "$assets_dir"
assets_dir="$(cd "$assets_dir" && pwd)"

artifact="box-$version.sh"
sidecar="$artifact.sha256"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tree" "$work/assets"

# A release checkout may contain ceremony's own checkout in .ceremony-src and
# other job state. When --root is a Git work tree, HEAD is the release payload;
# never pack the mutable workspace around it. An unpacked source tarball has no
# commit to prefer, so copy that tree as-is for offline and hand-driven builds.
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  top="$(git -C "$root" rev-parse --show-toplevel)"
  [ "$(cd "$top" && pwd)" = "$root" ] || die "--root must name the Git work-tree root"
  git -C "$root" archive --format=tar HEAD | tar -xf - -C "$work/tree"
else
  tar -C "$root" --exclude=.git -cf - . | tar -xf - -C "$work/tree"
fi

[ -x "$work/tree/dist/make-installer.sh" ] \
  || die "--root is not a box tree: dist/make-installer.sh is missing or not executable"

"$work/tree/dist/make-installer.sh" \
  --name box \
  --version "$version" \
  --root "$work/tree" \
  --out "$work/assets/$artifact" \
  --entrypoint install.sh \
  --srcvar BOX_INSTALL_SOURCE

# Prove the finished installer before either release asset becomes visible.
bash "$work/assets/$artifact" --check
(
  cd "$work/assets"
  sha256sum "$artifact" > "$sidecar"
  sha256sum -c "$sidecar"
)

[ ! -e "$assets_dir/$artifact" ] || die "$assets_dir/$artifact already exists"
[ ! -e "$assets_dir/$sidecar" ] || die "$assets_dir/$sidecar already exists"
mv "$work/assets/$artifact" "$work/assets/$sidecar" "$assets_dir/"
printf 'release-artifact: wrote %s and %s\n' \
  "$assets_dir/$artifact" "$assets_dir/$sidecar"
