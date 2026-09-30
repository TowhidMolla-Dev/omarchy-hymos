#!/bin/bash
# Build (once per Hyprland version / source change), load and configure the
# Hymos Hyprland plugin. Called by the bar widget on startup and on every
# settings change, so the shell starting up is what brings smooth scrolling
# back after a reboot.
#
# Usage: hymos-apply.sh [--enabled 0|1] [--step N] [--duration MS]
#                     [--drag-scroll 0|1] [--drag-button left|middle|right]
#                     [--drag-ratio F] [--drag-threshold PX] [--drag-fling 0|1]
#                     [--drag-fling-tau MS] [--drag-fling-min-speed F]
#                     [--drag-fling-max-speed F] [--drag-click-suppress 0|1]
#                     [--curve expo|linear|smooth] [--axis-lock 0|1]
# Keys left out keep their current value in ~/.config/hypr/hymos.conf.
#
# Exit codes: 2 missing build tools/headers, 3 build failed, 4 load failed.

set -uo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
source_file="$script_dir/hyprland/hymos.cpp"
conf="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hymos.conf"
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/hymos"

declare -A set=()
while (($#)); do
  case "$1" in
    --enabled | --step | --duration | --drag-scroll | --drag-button | --drag-ratio | \
      --drag-threshold | --drag-fling | --drag-fling-tau | \
      --drag-fling-min-speed | --drag-fling-max-speed | \
      --drag-click-suppress | --axis-lock) (($# >= 2)) || { echo "missing value for $1" >&2; exit 1; }
      set[${1#--}]="$2"; shift 2 ;;
    --curve) (($# >= 2)) || { echo "missing value for $1" >&2; exit 1; }
      [[ $2 =~ ^(expo|linear|smooth)$ ]] || { echo "invalid --curve: ${2:0:32}" >&2; exit 1; }
      set[curve]="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# values end up in the config file (and in sed), so only plain in-range integers
in_range() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= $2 && 10#$1 <= $3)); }
[[ -v set[enabled] ]] && ! in_range "${set[enabled]}" 0 1 && { echo "invalid --enabled: ${set[enabled]:0:32}" >&2; exit 1; }
[[ -v set[step] ]] && ! in_range "${set[step]}" 1 12 && { echo "invalid --step: ${set[step]:0:32}" >&2; exit 1; }
[[ -v set[duration] ]] && ! in_range "${set[duration]}" 80 900 && { echo "invalid --duration: ${set[duration]:0:32}" >&2; exit 1; }
[[ -v set[drag-scroll] ]] && ! in_range "${set[drag-scroll]}" 0 1 && { echo "invalid --drag-scroll: ${set[drag-scroll]:0:32}" >&2; exit 1; }
[[ -v set[drag-click-suppress] ]] && ! in_range "${set[drag-click-suppress]}" 0 1 && { echo "invalid --drag-click-suppress: ${set[drag-click-suppress]:0:32}" >&2; exit 1; }
[[ -v set[axis-lock] ]] && ! in_range "${set[axis-lock]}" 0 1 && { echo "invalid --axis-lock: ${set[axis-lock]:0:32}" >&2; exit 1; }
[[ -v set[drag-fling] ]] && ! in_range "${set[drag-fling]}" 0 1 && { echo "invalid --drag-fling: ${set[drag-fling]:0:32}" >&2; exit 1; }
[[ -v set[drag-button] ]] && [[ ! "${set[drag-button]}" =~ ^(left|middle|right)$ ]] && { echo "invalid --drag-button: ${set[drag-button]:0:32}" >&2; exit 1; }
# these are floats the plugin range-checks again; keep them plainly numeric
for f in drag-ratio drag-threshold drag-fling-tau drag-fling-min-speed \
  drag-fling-max-speed; do
  [[ -v set[$f] ]] && ! [[ "${set[$f]}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && { echo "invalid --$f: ${set[$f]:0:32}" >&2; exit 1; }
done
# The plugin rejects out-of-range values at load time but cannot fail the
# script, so a bad value used to land silently as success. Reject it here too.
in_range_f() { [[ $1 =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v>=lo && v<=hi)}'; }
for spec in drag-ratio:-20:20 drag-threshold:0:1000; do
  f=${spec%%:*}; rest=${spec#*:}; lo=${rest%%:*}; hi=${rest##*:}
  [[ -v set[$f] ]] && ! in_range_f "${set[$f]}" "$lo" "$hi" && { echo "--$f out of range ($lo..$hi): ${set[$f]:0:32}" >&2; exit 1; }
done

mkdir -p "$cache_root"
# one bar per monitor calls this at once; serialize so we build and load once
exec 9>"$cache_root/.lock"
flock 9

# --- config -----------------------------------------------------------------
mkdir -p "$(dirname "$conf")"
touch "$conf"
for raw in "${!set[@]}"; do
  # the config file spells keys with underscores (drag_scroll), the flags with dashes
  value=${set[$raw]}
  key=${raw//-/_}
  if grep -q "^[[:space:]]*$key[[:space:]]*=" "$conf"; then
    sed -i "s|^[[:space:]]*$key[[:space:]]*=.*|$key = $value|" "$conf"
  else
    echo "$key = $value" >>"$conf"
  fi
done

# --- build ------------------------------------------------------------------
hypr_commit=$(hyprctl version -j | sed -n 's/.*"commit": *"\([0-9a-f]*\)".*/\1/p' | head -1)
# the build recipe (this script) is part of the key, so a changed recipe rebuilds
source_sum=$(cat "$source_file" "$0" | cksum | cut -d' ' -f1)
plugin="$cache_root/${hypr_commit:-unknown}-$source_sum/hymos.so"

if [[ ! -f $plugin ]]; then
  # The result is loaded into the compositor, so the build must not pick up
  # anything from the user's environment: only the system toolchain by
  # absolute path, only the system .pc files, and an otherwise empty
  # environment (no CXXFLAGS, LDFLAGS, CPATH, GCC_EXEC_PREFIX, LD_PRELOAD,
  # PKG_CONFIG_PATH, ...).
  cxx=/usr/bin/g++
  pkgconf=/usr/bin/pkg-config
  for tool in "$cxx" "$pkgconf"; do
    [[ -x $tool ]] || { echo "Hymos needs $tool to build (install base-devel)" >&2; exit 2; }
  done
  build_env=(/usr/bin/env -i PATH=/usr/bin LC_ALL=C
    PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig:/usr/share/pkgconfig)
  "${build_env[@]}" "$pkgconf" --exists hyprland || { echo "Hymos needs the Hyprland headers (hyprland.pc not found)" >&2; exit 2; }
  if ! cflags=$("${build_env[@]}" "$pkgconf" --cflags pixman-1 libdrm hyprland pangocairo libinput libudev wayland-server xkbcommon); then
    echo "Hymos is missing build dependencies (pkg-config failed)" >&2
    exit 2
  fi
  # hyprland.pc points at the hyprpm header cache (/var/cache/hyprpm/<user>/headersRoot),
  # but a Nix-style install puts the headers in /usr/include/hyprland instead and leaves
  # that cache missing. gcc ignores nonexistent -I paths, so the build then silently
  # falls back to /usr/include and fails on "color-management-v1.hpp", which only
  # resolves when the protocols directory is on the include path. Add the real
  # directories when they exist so both layouts build.
  for dir in /usr/include /usr/include/hyprland/protocols /usr/include/hyprland /usr/include/hyprland/src; do
    [[ -d $dir ]] && cflags="$cflags -I$dir"
  done

  mkdir -p "$(dirname "$plugin")"
  rm -f "$(dirname "$plugin")"/.hymos.* # leftovers from a build that was killed
  tmp=$(mktemp "$(dirname "$plugin")/.hymos.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  # shellcheck disable=SC2086
  if ! "${build_env[@]}" "$cxx" -shared -fPIC --no-gnu-unique -O2 -std=c++2b "$source_file" -o "$tmp" \
    $cflags 2>"$cache_root/build.log"; then
    echo "Hymos failed to build, see $cache_root/build.log" >&2
    exit 3
  fi
  mv "$tmp" "$plugin"
  trap - EXIT
  # drop builds for other Hyprland versions / sources
  find "$cache_root" -mindepth 1 -maxdepth 1 -type d ! -path "$(dirname "$plugin")" -exec rm -rf {} +
fi

# --- load -------------------------------------------------------------------
# `loaded` remembers which build is in the running Hyprland, so an updated
# plugin replaces the old one instead of stacking on top of it.
state="$cache_root/loaded"
if hyprctl plugin list -j | grep -q '"name": "hymos"'; then
  if [[ $(cat "$state" 2>/dev/null) != "$plugin" ]]; then
    hyprctl plugin unload "$(cat "$state" 2>/dev/null)" >/dev/null 2>&1
  fi
fi
if ! hyprctl plugin list -j | grep -q '"name": "hymos"'; then
  out=$(hyprctl plugin load "$plugin")
  [[ $out == ok* ]] || { echo "Hymos failed to load: $out" >&2; exit 4; }
  echo "$plugin" >"$state"
fi

hyprctl hymos reload
