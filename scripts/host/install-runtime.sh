#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# install-runtime.sh - copies the conductor runtime into ${CX_HOME:-$HOME/.conductor}/runtime/<version>
# (docs/DESIGN.md section 7.5).
#
# Usage: install-runtime.sh [--from DIR]      normal mode (WSL / Linux); DIR defaults to the
#                                             plugin root that contains this script
#        bash -s < install-runtime.sh         bootstrap mode (from Git Bash): the source is
#                                             wslpath -u "$CX_STAGE_WIN"
#        install-runtime.sh -h|--help | --version
#
# Copies .claude-plugin bin scripts hooks worker-shims templates (never tests, docs, skills or
# commands) into runtime/.tmp.<pid>, strips a CR before every LF and refuses a file that still
# holds a CR, sets the exec bits, writes RUNTIME_STAMP (version, installed_at, source, sha256
# over the sorted relative paths and contents), then, holding flock on runtime/.install.lock,
# swaps it into runtime/<version> (unless the same sha256 is already installed) and points
# runtime/current at it. Emits CX_RUNTIME {version, path, changed, stripped_cr}.
#
# Exit codes: 0 installed or already current; 1 usage error (bad --from, no version);
# 2 FAILED (copy failed, flock missing or the lock timed out after 60 s); 44 CRLF_CORRUPT.

# The script's own path, taken at file scope: under bash -s the top-level BASH_SOURCE is empty,
# while inside a function BASH_SOURCE[0] is the literal "main", so a file named main in the
# cwd (the WSL home) would otherwise switch bootstrap mode off.
CX_IR_SELF="${BASH_SOURCE[0]:-}"

main() {
  set -uo pipefail
  unset CDPATH
  CX_PROG=install-runtime
  local src="" self="$CX_IR_SELF" bootstrap=0 here=""
  if [ -n "$self" ] && [ -f "$self" ]; then
    here="$(cd -- "$(dirname -- "$self")" && pwd)"
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        if [ -n "$here" ]; then
          awk 'NR <= 2 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$here/install-runtime.sh"
        fi
        exit 0 ;;
      --version)
        local v=""
        [ -n "$here" ] && v="$(sed -n 's/^CX_VERSION=//p' "$here/../lib/common.sh" | head -n 1)"
        printf 'install-runtime %s\n' "${v:-unknown}"
        exit 0 ;;
      --from) [ $# -ge 2 ] || { printf 'install-runtime: --from needs a directory\n' >&2; exit 1; }; src="$2"; shift 2 ;;
      --from=*) src="${1#*=}"; shift ;;
      *) printf 'install-runtime: unknown argument: %s\ninstall-runtime: try --help\n' "$1" >&2; exit 1 ;;
    esac
  done
  if [ -z "$src" ]; then
    if [ -n "$here" ]; then
      src="$(cd -- "$here/../.." && pwd)"
    elif [ -n "${CX_STAGE_WIN:-}" ]; then
      bootstrap=1
      src="$(wslpath -u "$CX_STAGE_WIN" 2>/dev/null)" || src=""
      if [ -z "$src" ]; then
        local w="${CX_STAGE_WIN//\\//}"
        if [[ $w =~ ^([A-Za-z]):(/.*)?$ ]]; then
          src="/mnt/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"
        fi
      fi
    fi
  fi
  if [ -z "$src" ] || [ ! -f "$src/scripts/lib/common.sh" ]; then
    printf 'install-runtime: no plugin source at %s (expected scripts/lib/common.sh there)\n' "${src:-?}" >&2
    exit 1
  fi
  src="$(cd -- "$src" && pwd)"
  # shellcheck source=../lib/common.sh
  . "$src/scripts/lib/common.sh"
  local version
  version="$(sed -n 's/^CX_VERSION=//p' "$src/scripts/lib/common.sh" | head -n 1 | tr -d "\"'\r")"
  if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
    cx_note "no valid CX_VERSION= line in $src/scripts/lib/common.sh"
    exit 1
  fi
  command -v flock >/dev/null 2>&1 || { cx_note "flock (util-linux) is required"; cx_signal FAILED 2 "flock is required"; }
  command -v sha256sum >/dev/null 2>&1 || { cx_note "sha256sum (coreutils) is required"; cx_signal FAILED 2 "sha256sum is required"; }

  local home="${CX_HOME:-$HOME/.conductor}" rt tmp d f n_cr=0 sha
  rt="$home/runtime"
  mkdir -p "$rt" || cx_signal FAILED 2 "cannot create $rt"
  tmp="$rt/.tmp.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp" || cx_signal FAILED 2 "cannot create $tmp"
  for d in "${CX_RUNTIME_DIRS[@]}"; do
    [ -e "$src/$d" ] || continue
    if ! cp -R "$src/$d" "$tmp/$d"; then
      rm -rf "$tmp"
      cx_signal FAILED 2 "copy of $src/$d failed"
    fi
  done
  # Strip CR before LF; refuse whatever still holds a CR.
  local -a crs=()
  mapfile -t crs < <(grep -rl $'\r' "$tmp" 2>/dev/null)
  if [ "${#crs[@]}" -gt 0 ]; then
    sed -i 's/\r$//' "${crs[@]}"
    n_cr="${#crs[@]}"
    mapfile -t crs < <(grep -rl $'\r' "$tmp" 2>/dev/null)
    if [ "${#crs[@]}" -gt 0 ]; then
      local list=""
      for f in "${crs[@]}"; do list="$list ${f#"$tmp"/}"; done
      rm -rf "$tmp"
      cx_note "a CR is left inside a line after stripping (the installed runtime is unchanged):$list"
      cx_signal CRLF_CORRUPT 44 "CR left in:$list"
    fi
  fi
  # Exec bits.
  (
    cd -- "$tmp" || exit 1
    shopt -s nullglob globstar
    for f in bin/* scripts/**/*.sh scripts/lib/*.py hooks/*.sh worker-shims/*; do
      [ -f "$f" ] && chmod 0755 "$f"
    done
  )
  sha="$(cd -- "$tmp" && find . -type f ! -name RUNTIME_STAMP -print | LC_ALL=C sort \
    | while IFS= read -r f; do printf '%s\n' "$f"; sha256sum < "$f"; done | sha256sum | cut -d' ' -f1)"
  {
    printf 'version=%s\n' "$version"
    printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source=%s\n' "$src"
    printf 'sha256=%s\n' "$sha"
  } > "$tmp/RUNTIME_STAMP"

  local changed=false cur=""
  exec 9>> "$rt/.install.lock" || { rm -rf "$tmp"; cx_signal FAILED 2 "cannot open $rt/.install.lock"; }
  if ! flock -w 60 9; then
    rm -rf "$tmp"
    cx_signal FAILED 2 "timed out waiting 60 s for $rt/.install.lock"
  fi
  if [ -f "$rt/$version/RUNTIME_STAMP" ]; then
    cur="$(sed -n 's/^sha256=//p' "$rt/$version/RUNTIME_STAMP" | head -n 1)"
  fi
  if [ -n "$cur" ] && [ "$cur" = "$sha" ]; then
    rm -rf "$tmp"
    if [ ! -L "$rt/current" ]; then
      ln -sfn "$version" "$rt/current.tmp.$$" && mv -T "$rt/current.tmp.$$" "$rt/current"
    fi
  else
    if [ -e "$rt/$version" ]; then
      mv -T "$rt/$version" "$rt/.old.$$" || { rm -rf "$tmp"; cx_signal FAILED 2 "cannot move the old runtime aside"; }
    fi
    if ! mv -T "$tmp" "$rt/$version"; then
      [ -e "$rt/.old.$$" ] && mv -T "$rt/.old.$$" "$rt/$version"
      rm -rf "$tmp"
      cx_signal FAILED 2 "cannot move the new runtime into place"
    fi
    rm -rf "$rt/.old.$$"
    ln -sfn "$version" "$rt/current.tmp.$$" && mv -T "$rt/current.tmp.$$" "$rt/current"
    changed=true
  fi
  flock -u 9
  exec 9>&-
  if [ "$changed" = true ]; then
    printf 'conductor runtime %s installed at %s%s (%s files had CRLF line endings)\n' "$version" "$rt/$version" \
      "$([ "$bootstrap" = 1 ] && printf ' from Git Bash')" "$n_cr"
  else
    printf 'conductor runtime %s already current at %s\n' "$version" "$rt/$version"
  fi
  cx_emit RUNTIME version "$version" path "$rt/$version" changed:bool "$changed" stripped_cr:int "$n_cr"
  exit 0
}

main "$@" < /dev/null
