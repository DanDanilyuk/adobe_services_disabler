#!/bin/bash
#
# disable_adobe_services.sh - turn Adobe's background services off, or back on.
#
#   /bin/bash -c "$(curl -fsSL https://dandanilyuk.github.io/adobe_services_disabler/disable_adobe_services.sh)"
#
# There are no options. Run it, pick Disable or Enable from the menu.
#
# What it covers:
#   - Every com.adobe.* plist in the launchd folders. Booted out and marked
#     disabled so they stay off across reboots. Matched by wildcard, so this
#     keeps working after an Adobe update recreates them.
#   - Adobe's app extensions (Finder Sync, right-click menu). macOS relaunches
#     these itself, so pluginkit is the only place they stay off.
#   - Running helpers. Anything whose executable path contains "adobe", except
#     the creative apps in /Applications/Adobe* which are never touched.
#
# If you downloaded this file, it deletes itself when it finishes.
#
# Everything is in functions and the last line calls main, so a download that
# gets cut off part way through does nothing at all instead of half of it.
#
# Windows version: disable_adobe_services.ps1

# Under `sh script.sh` or another shell, restart under real bash: this needs
# arrays and process substitution. "$0" is only a file when it was downloaded.
if [ -z "${BASH_VERSION:-}" ] || shopt -qo posix 2>/dev/null; then
  if [ -f "$0" ] && [ -r "$0" ]; then
    exec /bin/bash "$0"
  fi
  echo 'This needs bash. Run: /bin/bash -c "$(curl -fsSL <url>)"' >&2
  exit 1
fi

set -u

GUI_DOMAIN="gui/$(id -u)"

# Run a command, and say so if it fails. Used where failure means the user did
# not get what they asked for.
run() {
  local err
  if ! err="$("$@" 2>&1 >/dev/null)"; then
    echo "  ! failed: ${err:-$*}" >&2
  fi
}

# Run a command and ignore failure. Used for bootout on a job that is not
# loaded, and bootstrap on one that already is - both are normal and harmless.
try_run() {
  "$@" >/dev/null 2>&1 || true
}

plist_label() {
  /usr/libexec/PlistBuddy -c 'Print :Label' "$1" 2>/dev/null \
    || basename "$1" .plist
}

PICK_TTY=""

# Put the terminal back exactly as we found it: cursor visible, signals on.
pick_cleanup() {
  printf '\033[?25h'
  if [ -n "$PICK_TTY" ]; then
    stty "$PICK_TTY" 2>/dev/null
    PICK_TTY=""
  fi
}

# Arrow-key menu. Sets PICKED to the chosen index, or -1 if the user backs out.
pick() {
  local options=("$@") count=$# selected=0 i key rest=""

  # Hide the cursor while the menu is up, otherwise it parks below the list and
  # reads as a stray bar. Having hidden it we must guarantee it comes back,
  # and a trap alone will not do that: bash does not run an INT trap while it
  # is blocked inside `read -n1`, so Ctrl-C would kill us with the cursor
  # still hidden. Taking ISIG off the terminal turns Ctrl-C into an ordinary
  # \003 keystroke we can handle, and the trap is kept as a backstop for
  # anything that gets through. Both are undone the moment we return.
  PICK_TTY="$(stty -g 2>/dev/null || true)"
  [ -n "$PICK_TTY" ] && stty -isig 2>/dev/null
  trap pick_cleanup EXIT INT TERM HUP
  printf '\033[?25l'

  while true; do
    for ((i = 0; i < count; i++)); do
      # \033[K clears the line first. The highlighted row is one column wider
      # than a plain one (the reverse-video block includes a trailing space),
      # so without this, moving off a row leaves its last cell still inverted.
      if [ "$i" -eq "$selected" ]; then
        printf '\033[K  \033[7m %s \033[0m\n' "${options[$i]}"
      else
        printf '\033[K   %s\n' "${options[$i]}"
      fi
    done

    # On EOF read fails with key empty - same as Enter. Quit rather than let a
    # dying terminal "press Enter" on whatever row happened to be highlighted.
    IFS= read -rsn1 key || { PICKED=-1; break; }
    case "$key" in
      '')  PICKED=$selected; break ;;    # Enter
      q|Q|$'\003') PICKED=-1; break ;;   # q or Ctrl-C
      $'\033')
        rest=""
        # Integer timeout only: macOS ships bash 3.2, which rejects "-t 0.05".
        read -rsn2 -t 1 rest
        case "$rest" in
          '[A') selected=$(( (selected + count - 1) % count )) ;;
          '[B') selected=$(( (selected + 1) % count )) ;;
          *)    PICKED=-1; break ;;      # plain Esc
        esac
        ;;
    esac

    printf '\033[%dA' "$count"           # back to the top of the list, redraw
  done

  # Wipe the menu on the way out. Without this the highlighted row stays
  # inverted on screen for the rest of the run, which looks like a stray bar.
  printf '\033[%dA' "$count"
  for ((i = 0; i < count; i++)); do
    printf '\033[K\n'
  done
  printf '\033[%dA' "$count"

  pick_cleanup
  trap - EXIT INT TERM HUP
}

# --- Find everything ---------------------------------------------------------
# Two arrays per kind rather than one map: bash 3.2 has no associative arrays.

AGENT_PLISTS=();  AGENT_LABELS=()
DAEMON_PLISTS=(); DAEMON_LABELS=()
APPEX_IDS=();     APPEX_STATES=()

collect() {
  local p label seen=" "

  # com.adobe.ccxprocess.plist ships in both /Library and ~/Library. Same
  # label, one job, so keep the first and skip the duplicate.
  for p in /Library/LaunchAgents/com.adobe.*.plist \
           "$HOME"/Library/LaunchAgents/com.adobe.*.plist; do
    [ -e "$p" ] || continue
    label="$(plist_label "$p")"
    case "$seen" in
      *" $label "*) continue ;;
    esac
    seen="$seen$label "
    AGENT_PLISTS+=("$p")
    AGENT_LABELS+=("$label")
  done

  for p in /Library/LaunchDaemons/com.adobe.*.plist; do
    [ -e "$p" ] || continue
    DAEMON_PLISTS+=("$p")
    DAEMON_LABELS+=("$(plist_label "$p")")
  done

  # `pluginkit -m` prints either "com.foo.bar(1.0)" or "- com.foo.bar(1.0)",
  # where a leading + or - means the extension was explicitly turned on or off.
  local first second state id
  while read -r first second; do
    case "$first" in
      '+'|'-'|'!') state="$first"; id="$second" ;;
      *)           state=" ";      id="$first" ;;
    esac
    id="${id%%(*}"
    case "$id" in
      com.adobe.*) APPEX_IDS+=("$id"); APPEX_STATES+=("$state") ;;
    esac
  done < <(pluginkit -m 2>/dev/null)
}

# --- Status ------------------------------------------------------------------

# launchctl prints `"label" => disabled`. Compared as plain text, not a regex,
# because labels are full of dots and those would match anything.
is_disabled() {
  case "$2" in
    *"\"$1\" => disabled"*|*"\"$1\" => true"*) return 0 ;;
  esac
  return 1
}

show_status() {
  local gui sys i label state
  gui="$(launchctl print-disabled "$GUI_DOMAIN" 2>/dev/null)"
  sys="$(launchctl print-disabled system 2>/dev/null)"

  echo "Current Adobe launch items:"
  for ((i = 0; i < ${#AGENT_LABELS[@]}; i++)); do
    label="${AGENT_LABELS[$i]}"
    is_disabled "$label" "$gui" && state="disabled" || state="enabled"
    printf '  [agent]  %-46s %s\n' "$label" "$state"
  done
  for ((i = 0; i < ${#DAEMON_LABELS[@]}; i++)); do
    label="${DAEMON_LABELS[$i]}"
    is_disabled "$label" "$sys" && state="disabled" || state="enabled"
    printf '  [daemon] %-46s %s\n' "$label" "$state"
  done
  for ((i = 0; i < ${#APPEX_IDS[@]}; i++)); do
    case "${APPEX_STATES[$i]}" in
      -) state="disabled" ;;
      *) state="enabled" ;;
    esac
    printf '  [appex]  %-46s %s\n' "${APPEX_IDS[$i]}" "$state"
  done
}

# --- Apply -------------------------------------------------------------------

apply_agents() {
  [ "${#AGENT_PLISTS[@]}" -gt 0 ] || return 0
  local i plist label
  echo "== Launch agents =="
  for ((i = 0; i < ${#AGENT_PLISTS[@]}; i++)); do
    plist="${AGENT_PLISTS[$i]}"
    label="${AGENT_LABELS[$i]}"
    if [ "$MODE" = disable ]; then
      echo "Disabling $label"
      try_run launchctl bootout "$GUI_DOMAIN" "$plist"
      run launchctl disable "$GUI_DOMAIN/$label"
    else
      echo "Enabling $label"
      run launchctl enable "$GUI_DOMAIN/$label"
      try_run launchctl bootstrap "$GUI_DOMAIN" "$plist"
    fi
  done
}

apply_appex() {
  [ "${#APPEX_IDS[@]}" -gt 0 ] || return 0
  local id
  echo
  echo "== App extensions =="
  for id in "${APPEX_IDS[@]}"; do
    if [ "$MODE" = disable ]; then
      echo "Disabling $id"
      run pluginkit -e ignore -i "$id"
    else
      echo "Enabling $id"
      run pluginkit -e use -i "$id"
    fi
  done
}

apply_daemons() {
  [ "${#DAEMON_PLISTS[@]}" -gt 0 ] || return 0
  local i plist label
  echo
  echo "== Launch daemons (needs sudo) =="
  if ! sudo -v; then
    echo "sudo declined, skipping the system daemons. Everything else was applied." >&2
    return 0
  fi
  for ((i = 0; i < ${#DAEMON_PLISTS[@]}; i++)); do
    plist="${DAEMON_PLISTS[$i]}"
    label="${DAEMON_LABELS[$i]}"
    if [ "$MODE" = disable ]; then
      echo "Disabling $label"
      try_run sudo launchctl bootout system "$plist"
      run sudo launchctl disable "system/$label"
    else
      echo "Enabling $label"
      run sudo launchctl enable "system/$label"
      try_run sudo launchctl bootstrap system "$plist"
    fi
  done
}

kill_helpers() {
  local pid path found=0 stubborn=""
  echo
  echo "== Stopping running Adobe processes =="
  while read -r pid path; do
    # Never touch the creative apps - someone may have work open.
    case "$path" in
      /Applications/Adobe*) continue ;;
      *[Aa]dobe*) ;;
      *) continue ;;
    esac
    found=1
    echo "Stopping ${path##*/} (pid $pid)"
    if ! kill "$pid" 2>/dev/null; then
      stubborn="$stubborn $pid"
    fi
  done < <(ps -axo pid=,comm=)

  [ "$found" -eq 0 ] && echo "None running."
  if [ -n "$stubborn" ]; then
    echo
    echo "These are owned by another user. To stop them too:"
    echo "  sudo kill$stubborn"
  fi
}

# Delete the downloaded copy. "$0" is only a real .sh file when someone saved
# it; piped into bash it is "bash", so this does nothing. The .sh check also
# means we can never delete a shell binary. A git checkout is someone's source.
self_delete() {
  case "$0" in
    *.sh) ;;
    *) return 0 ;;
  esac
  [ -f "$0" ] || return 0
  if [ -d "$(dirname "$0")/.git" ]; then
    return 0
  fi
  rm -f -- "$0" 2>/dev/null && echo "Removed the downloaded script."
}

# --- Main --------------------------------------------------------------------

main() {
  local reply

  collect

  if [ "${#AGENT_PLISTS[@]}" -eq 0 ] && [ "${#DAEMON_PLISTS[@]}" -eq 0 ] \
     && [ "${#APPEX_IDS[@]}" -eq 0 ]; then
    echo "Nothing from Adobe found. Nothing to do."
    self_delete
    exit 0
  fi

  show_status
  echo

  if [ -t 0 ]; then
    echo "Up/down to move, Enter to select, q to quit:"
    pick "Disable Adobe startup services" "Enable Adobe startup services" "Quit"
    printf '\033[1A\033[K'   # the instructions have served their purpose too
  else
    # Input is piped rather than typed: 1 disables, 2 enables.
    IFS= read -r reply || reply=""
    case "$reply" in
      1) PICKED=0 ;;
      2) PICKED=1 ;;
      *) PICKED=-1 ;;
    esac
  fi

  case "$PICKED" in
    0) MODE=disable ;;
    1) MODE=enable ;;
    *) self_delete; exit 0 ;;
  esac
  echo

  apply_agents
  apply_appex
  apply_daemons
  [ "$MODE" = disable ] && kill_helpers

  echo
  if [ "$MODE" = disable ]; then
    echo "Done. AdobeIPCBroker sometimes comes back once more, but not after a"
    echo "reboot. Also check System Settings > General > Login Items for Adobe"
    echo "entries, and re-run this after an Adobe update."
  else
    echo "Done. Everything loads again at your next login. The Finder Sync and"
    echo "right-click extensions come back when Finder next needs them; log out"
    echo "and back in if they do not."
  fi

  self_delete
}

main
