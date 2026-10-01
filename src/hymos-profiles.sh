#!/bin/bash
# Read and edit ~/.config/hypr/hymos-profiles.conf, the per-application
# overrides for Hymos.
#
# The plugin owns parsing and validation (hyprctl hymos reload reports any
# mistake with a line number), so this script only has to keep the text of the
# file well-formed. It deliberately rewrites the file from scratch instead of
# editing in place, because a hand-maintained file has comments, blank lines and
# section ordering that sed would quietly destroy.
#
# Usage:
#   hymos-profiles.sh list
#   hymos-profiles.sh add <glob>
#   hymos-profiles.sh set <glob> <key> <value>
#   hymos-profiles.sh unset <glob> <key>
#   hymos-profiles.sh remove <glob>
#
# <key> is one of: enabled step duration drag_ratio drag_scroll curve
#
# Exit codes: 0 ok, 1 bad usage or value, 2 the file could not be written.

set -uo pipefail

conf="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hymos-profiles.conf"

# The keys a profile may set, with the values each one accepts. Anything else is
# refused here so a typo cannot end up in the file for the plugin to complain
# about later.
valid_key() {
  case "$1" in
    enabled | drag_scroll) [[ $2 == 0 || $2 == 1 || $2 == true || $2 == false || $2 == on || $2 == off ]] ;;
    curve) [[ $2 == expo || $2 == linear || $2 == smooth ]] ;;
    step) [[ $2 =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v v="$2" 'BEGIN{exit !(v>=1 && v<=12)}' ;;
    duration) [[ $2 =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v v="$2" 'BEGIN{exit !(v>=80 && v<=900)}' ;;
    drag_ratio) [[ $2 =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && awk -v v="$2" 'BEGIN{exit !(v>=-20 && v<=20)}' ;;
    *) return 1 ;;
  esac
}

# Is $1 a key a profile may set? Separate from valid_key, which also checks the
# value. unset has no value to check, so it needs this one.
known_key() {
  case "$1" in
    enabled | step | duration | drag_ratio | drag_scroll | curve) return 0 ;;
    *) return 1 ;;
  esac
}

usage() { echo "usage: hymos-profiles.sh list|add|set|unset|remove ..." >&2; exit 1; }

cmd=${1:-}
case "$cmd" in
  list | add | set | unset | remove) ;;
  "") usage ;;
  *) echo "unknown command: $cmd" >&2; usage ;;
esac

[[ $# -ge 1 ]] && shift

# Read the file into an array of sections. Each element is
#   <header>\n<setting>...   for a real profile, or a comment block.
sections=()
if [[ -f $conf ]]; then
  current=""
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^[[:space:]]*\[profile[[:space:]]+(.+)\][[:space:]]*$ ]]; then
      current="${BASH_REMATCH[1]}"
      sections+=("[profile $current]")
    elif [[ $line =~ ^[[:space:]]*\[.*\][[:space:]]*$ ]]; then
      # some other section: keep it verbatim so we never eat a user's file
      current=""
      sections+=("$line")
    elif [[ -n $current ]]; then
      sections[-1]+=$'\n'"$line"
    elif [[ $line =~ ^[[:space:]]*# || $line =~ ^[[:space:]]*$ ]]; then
      sections+=("$line")
    else
      # a setting with no section header; keep it so it is not lost
      sections+=("$line")
    fi
  done <"$conf"
fi

# Header line of a stored section, i.e. its first line.
section_header() {
  printf '%s' "${1%%$'\n'*}"
}

# Body of a stored section: everything after its first line. An empty result
# is meaningful (a profile whose keys were all removed), so it must not fall
# back to the header itself.
section_body() {
  local section=$1
  if [[ $section == *$'\n'* ]]; then
    printf '%s' "${section#*$'\n'}"
  fi
}

# index of the profile whose header is exactly $1, or -1
find_section() {
  local want="[profile $1]" i
  for i in "${!sections[@]}"; do
    if [[ $(section_header "${sections[i]}") == "$want" ]]; then
      echo "$i"
      return 0
    fi
  done
  echo -1
  return 1
}

atomic_write() {
  local tmp
  tmp=$(mktemp "$conf.XXXXXX") || {
    echo "cannot create a temporary file next to $conf" >&2
    exit 2
  }
  printf '%s\n' "${sections[@]}" >"$tmp" || {
    rm -f "$tmp"
    echo "cannot write $tmp" >&2
    exit 2
  }
  # Replace by rename, so the original survives a failure partway through and
  # the plugin never reads a half-written file.
  mv -f "$tmp" "$conf" || {
    rm -f "$tmp"
    echo "cannot replace $conf" >&2
    exit 2
  }
}

case $cmd in
  list)
    if [[ ! -f $conf ]]; then
      exit 0
    fi
    cat "$conf"
    ;;

  add)
    (($# >= 1)) || usage
    glob=$1
    [[ -n $glob ]] || usage
    [[ $glob != *[[:space:]]* ]] || {
      echo "a profile name cannot contain spaces: $glob" >&2
      exit 1
    }
    if find_section "$glob" >/dev/null; then
      echo "profile already exists: $glob" >&2
      exit 1
    fi
    sections+=("[profile $glob]")
    atomic_write
    ;;

  set)
    (($# >= 3)) || usage
    glob=$1 key=$2 value=$3
    known_key "$key" || {
      echo "unknown key: $key" >&2
      exit 1
    }
    valid_key "$key" "$value" || {
      echo "invalid value for $key: $value" >&2
      exit 1
    }
    idx=$(find_section "$glob") || {
      echo "no such profile: $glob" >&2
      exit 1
    }
    section=${sections[idx]}
    body=""
    found=0
    # A here-string on an empty string still produces one empty line, which
    # would be written back as a stray blank line. Guard on a non-empty body.
    if [[ -n $(section_body "$section") ]]; then
      while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*([A-Za-z_]+)[[:space:]]*=(.*)$ ]] && [[ ${BASH_REMATCH[1]} == "$key" ]]; then
          # replace in place. Any trailing comment goes: we own this line.
          body+="$key = $value"$'\n'
          found=1
        else
          body+="$line"$'\n'
        fi
      done <<<"$(section_body "$section")"
    fi
    [[ $found == 1 ]] || body+="$key = $value"$'\n'
    sections[idx]="[profile $glob]"$'\n'"${body%$'\n'}"
    atomic_write
    ;;

  unset)
    (($# >= 2)) || usage
    glob=$1 key=$2
    known_key "$key" || {
      echo "unknown key: $key" >&2
      exit 1
    }
    idx=$(find_section "$glob") || {
      echo "no such profile: $glob" >&2
      exit 1
    }
    section=${sections[idx]}
    body=""
    if [[ -n $(section_body "$section") ]]; then
      while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*([A-Za-z_]+)[[:space:]]*= ]] && [[ ${BASH_REMATCH[1]} == "$key" ]]; then
          continue # drop it: the global value takes over again
        fi
        body+="$line"$'\n'
      done <<<"$(section_body "$section")"
    fi
    # A profile with no keys left overrides nothing, so drop it rather than
    # leaving an entry in the panel that does nothing.
    if [[ -z ${body%$'\n'} ]]; then
      unset 'sections[idx]'
    else
      sections[idx]="[profile $glob]"$'\n'"${body%$'\n'}"
    fi
    atomic_write
    ;;

  remove)
    (($# >= 1)) || usage
    glob=$1
    idx=$(find_section "$glob") || {
      echo "no such profile: $glob" >&2
      exit 1
    }
    # Drop the section whole, keys and all. Guarding this on the body being
    # empty meant removing a profile that still had overrides did nothing.
    unset 'sections[idx]'
    atomic_write
    ;;
esac