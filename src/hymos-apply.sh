#!/bin/bash
# Build (once per Hyprland version / source change), load and configure the
# Hymos Hyprland plugin. Called by the bar widget on startup and on every
# settings change, so the shell starting up is what brings smooth scrolling
# back after a reboot.
#
# Usage: hymos-apply.sh [--enabled 0|1] [--step N] [--duration MS]
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
    --enabled | --step | --duration) set[${1#--}]="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$cache_root"
# one bar per monitor calls this at once; serialize so we build and load once
exec 9>"$cache_root/.lock"
flock 9

# --- config -----------------------------------------------------------------
mkdir -p "$(dirname "$conf")"
touch "$conf"
for key in "${!set[@]}"; do
  if grep -q "^[[:space:]]*$key[[:space:]]*=" "$conf"; then
    sed -i "s|^[[:space:]]*$key[[:space:]]*=.*|$key = ${set[$key]}|" "$conf"
  else
    echo "$key = ${set[$key]}" >>"$conf"
  fi
done

# --- build ------------------------------------------------------------------
hypr_commit=$(hyprctl version -j | sed -n 's/.*"commit": *"\([0-9a-f]*\)".*/\1/p' | head -1)
source_sum=$(cksum <"$source_file" | cut -d' ' -f1)
plugin="$cache_root/${hypr_commit:-unknown}-$source_sum/hymos.so"

if [[ ! -f $plugin ]]; then
  for tool in g++ pkg-config; do
    command -v "$tool" >/dev/null || { echo "Hymos needs $tool to build (sudo pacman -S base-devel)" >&2; exit 2; }
  done
  pkg-config --exists hyprland || { echo "Hymos needs the Hyprland headers (hyprland.pc not found)" >&2; exit 2; }

  mkdir -p "$(dirname "$plugin")"
  rm -f "$(dirname "$plugin")"/.hymos.* # leftovers from a build that was killed
  tmp=$(mktemp "$(dirname "$plugin")/.hymos.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  # shellcheck disable=SC2046
  if ! g++ -shared -fPIC --no-gnu-unique -O2 -std=c++2b "$source_file" -o "$tmp" \
    $(pkg-config --cflags pixman-1 libdrm hyprland pangocairo libinput libudev wayland-server xkbcommon) 2>"$cache_root/build.log"; then
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
