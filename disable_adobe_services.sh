#!/bin/bash
#
# disable_adobe_services.sh - turn Adobe's background services off, or back on.
#
#   /bin/bash -c "$(curl -fsSL https://dandanilyuk.github.io/adobe_services_disabler/disable_adobe_services.sh)"
#
# There are no options. Run it, pick Disable or Enable from the menu.
#
# What it covers:
#   - Every com.adobe.* launchd job, found three ways: the plists in the
#     LaunchAgents and LaunchDaemons folders, the plists Adobe apps carry
#     inside their own bundles, and whatever launchd has loaded right now.
#     Booted out and marked disabled, so they stay off across reboots and
#     across Adobe updates that put the plists back.
#   - Adobe's app extensions (Finder Sync, right-click menu). macOS relaunches
#     these itself, so pluginkit is the only place they stay off.
#   - Running helpers: anything running out of Adobe's support folders, the
#     Creative Cloud desktop app included. Photoshop, Lightroom and the other
#     apps you open yourself are never touched, wherever they are installed,
#     and neither is a helper one of them started and is still using.
#
# If you downloaded this file, it deletes itself when it finishes.
#
# Everything is in functions and the last line calls main, so a download that
# gets cut off part way through does nothing at all instead of half of it.
#
# Windows version: disable_adobe_services.ps1

# This needs bash: arrays and process substitution. Under zsh, dash or anything
# else, restart under bash if we are a saved script. Handed to `-c`, "$0" is
# the shell binary itself, which is why it is checked for a script's first line.
if [ -z "${BASH_VERSION:-}" ]; then
  if [ -f "$0" ] && [ "$(head -c 2 "$0" 2>/dev/null)" = '#!' ]; then
    exec /bin/bash "$0"
  fi
  echo 'This needs bash. Run: /bin/bash -c "$(curl -fsSL <url>)"' >&2
  exit 1
fi

# `sh` on a Mac is bash in POSIX mode, where bash 3.2 has no process
# substitution and echo expands backslashes. Both are switches, so flip them.
set +o posix
shopt -u xpg_echo

set -u

MY_UID="$(id -u)"
GUI_DOMAIN="gui/$MY_UID"
USER_DOMAIN="user/$MY_UID"
HOME_DIR="${HOME:-/var/empty}"

# Where launchd looks for plists, and where Adobe installs apps and helpers.
AGENT_DIRS=(/Library/LaunchAgents "$HOME_DIR/Library/LaunchAgents")
DAEMON_DIRS=(/Library/LaunchDaemons)
BUNDLE_ROOTS=(/Applications/Adobe* /Applications/Utilities/Adobe*
              "/Library/Application Support/Adobe"
              "$HOME_DIR"/Applications/Adobe*
              "$HOME_DIR/Library/Application Support/Adobe")

MODE=""        # disable or enable, once chosen
FAILED=0       # commands that had to work and did not
HAVE_SUDO=0    # 1 once sudo has been granted for the daemons
TTY_FD=0       # where the menu reads keys from

# Run a command, and say so if it fails. Used where failure means the user did
# not get what they asked for.
run() {
  local err
  if ! err="$("$@" 2>&1 >/dev/null)"; then
    printf '  ! failed: %s\n' "${err:-$*}" >&2
    FAILED=$((FAILED + 1))
    return 1
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

is_adobe_label() {
  case "$1" in
    [Cc][Oo][Mm].[Aa][Dd][Oo][Bb][Ee].*) return 0 ;;
  esac
  return 1
}

# 0 if $1 is one of the lines of $2. Compared as plain text, not a regex,
# because labels are full of dots and those would match anything.
in_list() {
  case $'\n'"$2"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# --- The menu ----------------------------------------------------------------

PICK_TTY=""

# Put the terminal back exactly as we found it: cursor visible, signals on.
pick_cleanup() {
  printf '\033[?25h'
  if [ -n "$PICK_TTY" ]; then
    stty "$PICK_TTY" <&"$TTY_FD" 2>/dev/null
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
  # \003 keystroke we can handle, and the traps are kept as a backstop for
  # anything that gets through. All of it is undone the moment we return.
  PICK_TTY="$(stty -g <&"$TTY_FD" 2>/dev/null || true)"
  [ -n "$PICK_TTY" ] && stty -isig <&"$TTY_FD" 2>/dev/null
  trap pick_cleanup EXIT
  trap 'pick_cleanup; exit 130' INT TERM HUP
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
    IFS= read -rsn1 -u "$TTY_FD" key || { PICKED=-1; break; }
    case "$key" in
      '')  PICKED=$selected; break ;;    # Enter
      q|Q|$'\003') PICKED=-1; break ;;   # q or Ctrl-C
      $'\033')
        rest=""
        # Integer timeout only: macOS ships bash 3.2, which rejects "-t 0.05".
        IFS= read -rsn2 -t 1 -u "$TTY_FD" rest
        case "$rest" in
          '[A'|'OA') selected=$(( (selected + count - 1) % count )) ;;
          '[B'|'OB') selected=$(( (selected + 1) % count )) ;;
          '')        PICKED=-1; break ;;   # plain Esc
          '['*)
            # Some other key. Read to the end of its sequence, a letter or a
            # tilde, so the tail is not taken for typing: shift-F2 ends in Q.
            while true; do
              case "$rest" in
                *[[:alpha:]~]) break ;;
              esac
              IFS= read -rsn1 -t 1 -u "$TTY_FD" key || break
              rest="$rest$key"
            done
            ;;
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
# Parallel arrays rather than a map: bash 3.2 has no associative arrays.
# A launchd job is a kind (agent or daemon), a label, and the plist to load it
# from again, which is empty for a job that was not found in a launchd folder.

ITEM_KIND=(); ITEM_LABEL=(); ITEM_PLIST=()
APPEX_IDS=(); APPEX_STATES=()
SEEN="|"
GUI_LOADED=""; GUI_DISABLED=""
SYS_LOADED=""; SYS_DISABLED=""
PROCS=""

# Labels launchd has loaded in a domain, one per line. In `launchctl print`
# they are the last word of each line of the "services" block.
loaded_labels() {
  launchctl print "$1" 2>/dev/null | awk '
    /^[[:space:]]*services = [{]/ { inside = 1; next }
    inside && /^[[:space:]]*[}]/  { exit }
    inside && NF                  { print $NF }'
}

# Labels marked disabled in a domain, one per line. launchctl prints
# `"label" => disabled`, or `=> true` on older systems.
disabled_labels() {
  launchctl print-disabled "$1" 2>/dev/null | sed -n \
    -e 's/^[[:space:]]*"\(.*\)" => disabled[[:space:]]*$/\1/p' \
    -e 's/^[[:space:]]*"\(.*\)" => true[[:space:]]*$/\1/p'
}

# Record a job once. com.adobe.ccxprocess.plist ships in both /Library and
# ~/Library: same label, one job, so the first one found is kept.
add_item() {
  local key="$1 $2"
  case "$SEEN" in
    *"|$key|"*) return 0 ;;
  esac
  SEEN="$SEEN$key|"
  ITEM_KIND+=("$1"); ITEM_LABEL+=("$2"); ITEM_PLIST+=("${3:-}")
}

# Every running Adobe helper, one per line: class, pid, uid, path, owner.
#   stop     a background helper, ours to stop
#   inuse    started by an app that is still running (the owner) - left alone
#   install  an install, update or uninstall in flight
# A helper is recognised by where it runs from, never by "adobe" appearing
# somewhere in its path: that would also match Photoshop on an external disk
# and every program in the home folder of a user called adobe.
scan_processes() {
  ps -axo pid=,ppid=,uid=,comm= 2>/dev/null | awk -v self="$$" '
    function under(path, dir) { return substr(path, 1, length(dir)) == dir }
    function is_helper(p) {
      return under(p, "/Library/Application Support/Adobe/") ||
             (home != "" && under(p, home "/Library/Application Support/Adobe/")) ||
             under(p, "/Library/PrivilegedHelperTools/com.adobe.") ||
             under(p, "/Applications/Utilities/Adobe") ||
             under(p, "/Applications/Adobe Creative Cloud/")
    }
    function is_install(p) {
      return p ~ /\/Adobe Desktop Common\/HDBox\/(Setup|Install\.app\/.*|Uninstaller\.app\/.*)$/ ||
             p ~ /\/Adobe Desktop Common\/DEBox\// ||
             p ~ /\/Adobe Creative Cloud\/Utils\/Creative Cloud (Installer|Uninstaller)\.app\// ||
             under(p, "/Library/Application Support/Adobe/Uninstall/")
    }
    BEGIN { home = ENVIRON["HOME"] }
    {
      path = $0
      sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+/, "", path)
      parent[$1] = $2; owner[$1] = $3; exe[$1] = path; order[++n] = $1
    }
    END {
      for (i = 1; i <= n; i++) {
        pid = order[i]; path = exe[pid]
        if (pid == self || !is_helper(path)) continue
        class = "stop"; by = ""
        if (is_install(path)) {
          class = "install"
        } else {
          # Walk up towards launchd. A parent that is not an Adobe helper is
          # an app that started this one itself and is still running.
          a = parent[pid]
          for (hops = 0; hops < 32 && a + 0 > 1 && (a in exe); hops++) {
            if (!is_helper(exe[a])) { class = "inuse"; by = exe[a]; break }
            a = parent[a]
          }
        }
        printf "%s\t%s\t%s\t%s\t%s\n", class, pid, owner[pid], path, by
      }
    }'
}

collect() {
  local dir root p label first second state id

  ITEM_KIND=(); ITEM_LABEL=(); ITEM_PLIST=(); SEEN="|"
  APPEX_IDS=(); APPEX_STATES=()

  # The per-user disabled list is shared by the gui/ and user/ domains. gui/
  # is the usual way in, but it only exists while that user is logged in at
  # the screen; over ssh there is only user/.
  GUI_LOADED="$(loaded_labels "$GUI_DOMAIN")"
  GUI_DISABLED="$(disabled_labels "$GUI_DOMAIN")"
  [ -n "$GUI_DISABLED" ] || GUI_DISABLED="$(disabled_labels "$USER_DOMAIN")"
  SYS_LOADED="$(loaded_labels system)"
  SYS_DISABLED="$(disabled_labels system)"

  # 1. The launchd folders. These come first so that a job found again below
  #    keeps the plist that Enable can load it from.
  for dir in "${AGENT_DIRS[@]}"; do
    for p in "$dir"/[Cc][Oo][Mm].[Aa][Dd][Oo][Bb][Ee].*.plist; do
      [ -f "$p" ] && add_item agent "$(plist_label "$p")" "$p"
    done
  done
  for dir in "${DAEMON_DIRS[@]}"; do
    for p in "$dir"/[Cc][Oo][Mm].[Aa][Dd][Oo][Bb][Ee].*.plist; do
      [ -f "$p" ] && add_item daemon "$(plist_label "$p")" "$p"
    done
  done

  # 2. Jobs an Adobe app carries inside its own bundle and registers itself
  #    (CCLibrary.app does). They never appear in the launchd folders.
  #    Resources and Frameworks hold nearly all the files and none of these.
  for root in "${BUNDLE_ROOTS[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r p; do
      label="$(plist_label "$p")"
      is_adobe_label "$label" || continue
      case "$p" in
        */LaunchAgents/*)  add_item agent "$label" ;;
        */LaunchDaemons/*) add_item daemon "$label" ;;
      esac
    done < <(find "$root" -maxdepth 9 \
               \( -name Resources -o -name Frameworks -o -name node_modules \) -prune -o \
               -type f -name '*.plist' \
               \( -path '*/Contents/Library/LaunchAgents/*' -o -path '*/Contents/Library/LaunchDaemons/*' \) \
               -print 2>/dev/null)
  done

  # 3. Whatever launchd has loaded under an Adobe label, wherever it came from.
  while IFS= read -r label; do
    is_adobe_label "$label" && add_item agent "$label"
  done <<< "$GUI_LOADED"
  while IFS= read -r label; do
    is_adobe_label "$label" && add_item daemon "$label"
  done <<< "$SYS_LOADED"

  # 4. Labels already marked disabled. A job found only by step 3 is no longer
  #    loaded once it has been disabled, and this is how Enable finds it again.
  while IFS= read -r label; do
    is_adobe_label "$label" && add_item agent "$label"
  done <<< "$GUI_DISABLED"
  while IFS= read -r label; do
    is_adobe_label "$label" && add_item daemon "$label"
  done <<< "$SYS_DISABLED"

  # `pluginkit -m` prints either "com.foo.bar(1.0)" or "- com.foo.bar(1.0)",
  # where a leading + or - means the extension was explicitly turned on or off.
  while read -r first second; do
    case "$first" in
      '+'|'-'|'!') state="$first"; id="$second" ;;
      *)           state=" ";      id="$first" ;;
    esac
    id="${id%%(*}"
    is_adobe_label "$id" || continue
    APPEX_IDS+=("$id"); APPEX_STATES+=("$state")
  done < <(pluginkit -m 2>/dev/null)

  PROCS="$(scan_processes)"
}

has_kind() {
  local i
  for ((i = 0; i < ${#ITEM_KIND[@]}; i++)); do
    [ "${ITEM_KIND[$i]}" = "$1" ] && return 0
  done
  return 1
}

# --- Status ------------------------------------------------------------------

N_ENABLED=0    # launchd jobs and extensions that are on
N_DISABLED=0   # ... and that are off
N_STUCK=0      # jobs marked disabled that launchd still has loaded
N_RUNNING=0    # helpers running that are ours to stop
N_INUSE=0      # helpers running on behalf of an open app

show_status() {
  local kind i label state class pid uid path by note
  N_ENABLED=0; N_DISABLED=0; N_STUCK=0; N_RUNNING=0; N_INUSE=0

  echo "$1"
  for kind in agent daemon; do
    for ((i = 0; i < ${#ITEM_LABEL[@]}; i++)); do
      [ "${ITEM_KIND[$i]}" = "$kind" ] || continue
      label="${ITEM_LABEL[$i]}"
      if [ "$kind" = agent ]; then
        item_state "$label" "$GUI_DISABLED" "$GUI_LOADED"
      else
        item_state "$label" "$SYS_DISABLED" "$SYS_LOADED"
      fi
      printf '  %-8s %-46s %s\n' "[$kind]" "$label" "$ITEM_STATE"
    done
  done
  for ((i = 0; i < ${#APPEX_IDS[@]}; i++)); do
    case "${APPEX_STATES[$i]}" in
      -) state="disabled"; N_DISABLED=$((N_DISABLED + 1)) ;;
      *) state="enabled";  N_ENABLED=$((N_ENABLED + 1)) ;;
    esac
    printf '  %-8s %-46s %s\n' "[appex]" "${APPEX_IDS[$i]}" "$state"
  done
  while IFS=$'\t' read -r class pid uid path by; do
    note=""
    case "$class" in
      stop)    N_RUNNING=$((N_RUNNING + 1)) ;;
      inuse)   N_INUSE=$((N_INUSE + 1)); note=", in use by ${by##*/}" ;;
      install) note=", installing" ;;
      *)       continue ;;
    esac
    printf '  %-8s %-46s pid %s%s\n' "[running]" "${path##*/}" "$pid" "$note"
  done <<< "$PROCS"
}

# Sets ITEM_STATE for a label, given its domain's disabled and loaded lists.
item_state() {
  if ! in_list "$1" "$2"; then
    ITEM_STATE="enabled"; N_ENABLED=$((N_ENABLED + 1))
  elif in_list "$1" "$3"; then
    ITEM_STATE="disabled, but still loaded"; N_STUCK=$((N_STUCK + 1))
  else
    ITEM_STATE="disabled"; N_DISABLED=$((N_DISABLED + 1))
  fi
}

# --- Apply -------------------------------------------------------------------

# Mark an agent enabled or disabled. gui/ first, user/ if there is no gui/
# domain to ask (see collect). Either way it is the same per-user list.
agent_ctl() {
  launchctl "$1" "$GUI_DOMAIN/$2" >/dev/null 2>&1 \
    || run launchctl "$1" "$USER_DOMAIN/$2"
}

# Switch every job of one kind, agent or daemon, off or on. Jobs are booted
# out by label rather than by plist path, so it does not matter which of two
# plists a job was loaded from, or whether it has one in a launchd folder.
apply_launchd() {
  local kind="$1" i label plist
  for ((i = 0; i < ${#ITEM_LABEL[@]}; i++)); do
    [ "${ITEM_KIND[$i]}" = "$kind" ] || continue
    label="${ITEM_LABEL[$i]}"
    plist="${ITEM_PLIST[$i]}"
    if [ "$MODE" = disable ]; then
      echo "Disabling $label"
      if [ "$kind" = agent ]; then
        try_run launchctl bootout "$GUI_DOMAIN/$label"
        try_run launchctl bootout "$USER_DOMAIN/$label"
        agent_ctl disable "$label"
      else
        try_run sudo launchctl bootout "system/$label"
        run sudo launchctl disable "system/$label"
      fi
    else
      echo "Enabling $label"
      if [ "$kind" = agent ]; then
        agent_ctl enable "$label"
        [ -n "$plist" ] && try_run launchctl bootstrap "$GUI_DOMAIN" "$plist"
      else
        run sudo launchctl enable "system/$label"
        [ -n "$plist" ] && try_run sudo launchctl bootstrap system "$plist"
      fi
    fi
  done
}

apply_agents() {
  has_kind agent || return 0
  echo "== Launch agents =="
  apply_launchd agent
}

apply_appex() {
  [ "${#APPEX_IDS[@]}" -gt 0 ] || return 0
  local i id
  echo
  echo "== App extensions =="
  for ((i = 0; i < ${#APPEX_IDS[@]}; i++)); do
    id="${APPEX_IDS[$i]}"
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
  has_kind daemon || return 0
  echo
  echo "== Launch daemons (needs sudo) =="
  # Prompt on the real terminal, not stdin: stdin is the script under
  # curl|bash, or the "1"/"2" line under echo 1 | bash.
  if sudo -n true 2>/dev/null || { sudo -v </dev/tty; } 2>/dev/null; then
    HAVE_SUDO=1
  else
    echo "sudo declined, skipping the system daemons. Everything else is still applied." >&2
    return 0
  fi
  apply_launchd daemon
}

# Signal a process: ours directly, anyone else's through the sudo we were
# already given. stdin is closed off because the caller is reading a list.
signal() {
  if [ "$3" = "$MY_UID" ]; then
    kill "-$1" "$2" 2>/dev/null
  else
    sudo -n kill "-$1" "$2" </dev/null 2>/dev/null
  fi
}

# 0 while pid $1 is still the program at path $2, so that a pid handed to
# something new in the meantime is never signalled.
still_running() {
  [ "$(ps -p "$1" -o comm= 2>/dev/null)" = "$2" ]
}

kill_helpers() {
  local round i tries busy class pid uid path by seen=" " theirs=""
  local -a pids uids paths
  echo
  echo "== Stopping running Adobe processes =="

  # Up to three sweeps: a helper can be restarted by another one a moment
  # before that one is stopped itself. AdobeIPCBroker is the usual offender.
  for round in 1 2 3; do
    pids=(); uids=(); paths=()
    while IFS=$'\t' read -r class pid uid path by; do
      case " $seen$theirs " in
        *" $pid "*) ;;
        *)
          if [ "$class" = inuse ]; then
            seen="$seen$pid "
            echo "Leaving ${path##*/} (pid $pid): ${by##*/} is using it"
          elif [ "$class" = stop ] && [ "$uid" != "$MY_UID" ] && [ "$HAVE_SUDO" -eq 0 ]; then
            theirs="$theirs $pid"
          elif [ "$class" = stop ]; then
            seen="$seen$pid "
            echo "Stopping ${path##*/} (pid $pid)"
          fi
          ;;
      esac
      [ "$class" = stop ] || continue
      case " $theirs " in
        *" $pid "*) continue ;;
      esac
      pids+=("$pid"); uids+=("$uid"); paths+=("$path")
      signal TERM "$pid" "$uid"
    done < <(scan_processes)
    [ "${#pids[@]}" -gt 0 ] || break

    # SIGTERM is enough for most of them. Give them two seconds, then SIGKILL
    # whatever ignored it.
    for tries in 1 2 3 4 5 6 7 8 9 10; do
      busy=0
      for ((i = 0; i < ${#pids[@]}; i++)); do
        still_running "${pids[$i]}" "${paths[$i]}" && { busy=1; break; }
      done
      [ "$busy" -eq 1 ] || break
      sleep 0.2
    done
    for ((i = 0; i < ${#pids[@]}; i++)); do
      still_running "${pids[$i]}" "${paths[$i]}" \
        && signal KILL "${pids[$i]}" "${uids[$i]}"
    done
    sleep 0.5    # anything that is going to come back does so about now
  done

  [ "$seen" = " " ] && [ -z "$theirs" ] && echo "None running."
  if [ -n "$theirs" ]; then
    echo
    echo "These belong to another user. To stop them too:"
    echo "  sudo kill$theirs"
  fi
}

# Stopping the helpers under a running install can leave a half-installed
# app behind, so Disable waits for it instead. 0 if one is in flight.
install_in_flight() {
  local class pid uid path by found=1
  while IFS=$'\t' read -r class pid uid path by; do
    [ "$class" = install ] || continue
    if [ "$found" -eq 1 ]; then
      echo "Adobe is installing, updating or uninstalling something right now:" >&2
      found=0
    fi
    echo "  ${path##*/} (pid $pid)" >&2
  done <<< "$PROCS"
  return "$found"
}

# Look again and say what is actually true now, rather than assume it worked.
report() {
  collect
  echo
  show_status "Now:"
  echo
  if [ "$MODE" = disable ]; then
    if [ "$FAILED" -eq 0 ] && [ $((N_ENABLED + N_STUCK + N_RUNNING)) -eq 0 ]; then
      echo "Done. Adobe's background services are off, and stay off after a restart."
    else
      echo "Done, but not everything is off: see the lines marked enabled, still"
      echo "loaded or running above. Anything still loaded is gone after a restart."
    fi
    if [ "$N_INUSE" -gt 0 ]; then
      echo "The helpers marked in use belong to an Adobe app you have open. Quit it"
      echo "and run this again to stop them."
    fi
    echo "Opening an Adobe app starts some helpers again; run this again to stop"
    echo "them. Also check System Settings > General > Login Items for Adobe"
    echo "entries, and re-run this after an Adobe update."
  else
    if [ "$FAILED" -eq 0 ] && [ $((N_DISABLED + N_STUCK)) -eq 0 ]; then
      echo "Done. Adobe's launch items are back on and loaded, so Creative Cloud may"
      echo "open by itself in a moment. The Finder Sync and right-click extensions"
      echo "come back when Finder next needs them; log out and back in if they do not."
    else
      echo "Done, but not everything is back on: see the lines marked disabled above."
    fi
  fi
}

# Delete the downloaded copy. "$0" is only a real .sh file when someone saved
# it; piped into bash it is "bash", so this does nothing. The .sh check also
# means we can never delete a shell binary. A git checkout is someone's source,
# and its .git is a plain file rather than a folder in a worktree or submodule.
self_delete() {
  case "$0" in
    *.sh) ;;
    *) return 0 ;;
  esac
  [ -f "$0" ] || return 0
  if [ -e "$(dirname "$0")/.git" ]; then
    return 0
  fi
  rm -f -- "$0" 2>/dev/null && echo "Removed the downloaded script."
}

# --- Main --------------------------------------------------------------------

main() {
  local reply ask=1

  if [ "$(uname -s)" != Darwin ]; then
    echo "This is the macOS script. On Windows, use disable_adobe_services.ps1." >&2
    exit 1
  fi

  # Under sudo we would be root, and every per-user step (the agents, the
  # extensions) would quietly land on root's account instead of yours.
  if [ "$MY_UID" -eq 0 ] && [ "${SUDO_UID:-0}" != 0 ]; then
    echo "Run this without sudo. It asks for your password itself, and only if" >&2
    echo "Adobe has system daemons installed." >&2
    exit 1
  fi

  collect
  if [ "${#ITEM_LABEL[@]}" -eq 0 ] && [ "${#APPEX_IDS[@]}" -eq 0 ] \
     && [ -z "$PROCS" ]; then
    echo "Nothing from Adobe found. Nothing to do."
    self_delete
    exit 0
  fi

  show_status "Current Adobe launch items:"
  echo

  PICKED=-1
  if [ ! -t 0 ]; then
    # Input is piped rather than typed: 1 disables, 2 enables.
    ask=0
    IFS= read -r reply || reply=""
    case "$reply" in
      1) PICKED=0 ;;
      2) PICKED=1 ;;
      '')
        # Nothing was piped in, which is what `curl ... | bash` looks like:
        # stdin was the script itself. Ask on the terminal, if there is one.
        if [ -t 1 ] && { exec 3</dev/tty; } 2>/dev/null; then
          TTY_FD=3; ask=1
        else
          echo "No choice given, so nothing was changed. Pipe in 1 to disable or 2 to enable."
        fi
        ;;
    esac
  fi
  if [ "$ask" -eq 1 ]; then
    echo "Up/down to move, Enter to select, q to quit:"
    pick "Disable Adobe startup services" "Enable Adobe startup services" "Quit"
    printf '\033[1A\033[K'   # the instructions have served their purpose too
  fi

  case "$PICKED" in
    0) MODE=disable ;;
    1) MODE=enable ;;
    *) self_delete; exit 0 ;;
  esac

  # The menu may have been up for a while, so look at what is running again.
  PROCS="$(scan_processes)"
  if [ "$MODE" = disable ] && install_in_flight; then
    echo "Nothing was changed. Run this again once it has finished." >&2
    exit 1
  fi

  apply_agents
  apply_appex
  apply_daemons
  [ "$MODE" = disable ] && kill_helpers

  report
  self_delete
  [ "$FAILED" -eq 0 ] || exit 1
}

main
