#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_PACKAGE="com.kkomaprogrammer.desktabchrome"
APP_RECEIVER="$APP_PACKAGE/.SetupDoneReceiver"
STATE_DIR="$HOME/.desktab"
CACHE_ROOT="$STATE_DIR/runtime-cache"
LOCK_DIR="$STATE_DIR/bootstrap.lock"
HEARTBEAT_FILE="$STATE_DIR/heartbeat"
HEARTBEAT_STATE_FILE="$STATE_DIR/heartbeat-state"
PKG_LOG="$STATE_DIR/package-manager.log"
EXTRACT_LOG="$STATE_DIR/extract.log"
EXTRACT_CHECKPOINT="$STATE_DIR/extract-checkpoint"
CURRENT_STAGE="고속 설치 시작"
CURRENT_PCT=1
CURRENT_ETA=360
OWN_LOCK=0
HEARTBEAT_LOOP_PID=""
BOOTSTRAP_PID="$$"
mkdir -p "$STATE_DIR" "$CACHE_ROOT"

log() { printf '[deskTAB] %s\n' "$*"; }

write_state() {
  local tmp="$HEARTBEAT_STATE_FILE.tmp.${BASHPID:-$$}"
  printf '%s|%s|%s\n' "$CURRENT_PCT" "$CURRENT_ETA" "$CURRENT_STAGE" > "$tmp"
  mv -f "$tmp" "$HEARTBEAT_STATE_FILE"
}

write_heartbeat() {
  local state tmp
  state="$(cat "$HEARTBEAT_STATE_FILE" 2>/dev/null || true)"
  [ -n "$state" ] || return 0
  tmp="$HEARTBEAT_FILE.tmp.${BASHPID:-$$}"
  printf '%s|%s|%s\n' "$(date +%s)" "$BOOTSTRAP_PID" "$state" > "$tmp"
  mv -f "$tmp" "$HEARTBEAT_FILE"
}

publish_state() { write_state; write_heartbeat; }

heartbeat_loop() {
  set +e
  while true; do
    write_heartbeat
    sleep 2
  done
}

broadcast_progress() {
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_PROGRESS" \
    --ei progress "$1" --el eta "$2" --es stage "$3" >/dev/null 2>&1 || true
}

progress() {
  local pct="$1" eta="$2"; shift 2
  CURRENT_PCT="$pct"
  CURRENT_ETA="$eta"
  CURRENT_STAGE="$*"
  log "$pct% · $CURRENT_STAGE"
  publish_state
  broadcast_progress "$pct" "$eta" "$CURRENT_STAGE"
}

cleanup() {
  set +e
  [ -n "$HEARTBEAT_LOOP_PID" ] && kill "$HEARTBEAT_LOOP_PID" >/dev/null 2>&1 || true
  if [ "$OWN_LOCK" = "1" ] && [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK_DIR"
  fi
}

failed() {
  local code=$?
  local line="${BASH_LINENO[0]:-?}"
  set +e
  CURRENT_PCT=-1
  CURRENT_ETA=0
  CURRENT_STAGE="실패: $CURRENT_STAGE · line $line · exit $code"
  log "$CURRENT_STAGE"
  publish_state
  /system/bin/am broadcast -n "$APP_RECEIVER" -a "$APP_PACKAGE.SETUP_FAILED" \
    --es stage "$CURRENT_STAGE" >/dev/null 2>&1 || true
  exit "$code"
}

ps_table() {
  ps -A -o PID=,PPID=,ARGS= 2>/dev/null || /system/bin/ps -A -o PID=,PPID=,ARGS= 2>/dev/null || true
}

pid_args() {
  ps_table | awk -v p="$1" '$1==p {$1=""; $2=""; sub(/^[[:space:]]+/,""); print; exit}'
}

is_ancestor_pid() {
  local target="$1" cur="${PPID:-0}" next
  case "$target" in ''|*[!0-9]*) return 1;; esac
  while [ "$cur" -gt 1 ] 2>/dev/null; do
    [ "$cur" = "$target" ] && return 0
    next="$(ps -o PPID= -p "$cur" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$next" in ''|*[!0-9]*) break;; esac
    [ "$next" = "$cur" ] && break
    cur="$next"
  done
  return 1
}

kill_tree() {
  local parent="$1" child
  while read -r child; do
    [ -n "$child" ] || continue
    [ "$child" = "$$" ] && continue
    kill_tree "$child"
  done < <(ps_table | awk -v p="$parent" '$2==p {print $1}')
  [ "$parent" = "$$" ] || kill -TERM "$parent" >/dev/null 2>&1 || true
}

wait_dead() {
  local pid="$1" n
  for n in $(seq 1 20); do
    kill -0 "$pid" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  return 1
}

cleanup_previous_installer() {
  local oldpid args pid ppid pargs

  # Only the process that actually owns our lock can be an old installer. The old
  # implementation scanned every command line containing desktab-bootstrap.sh and
  # could therefore kill the CURRENT loader (its own parent) and recursively kill
  # itself. Never terminate an ancestor of the current process.
  oldpid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  case "$oldpid" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$oldpid" != "$$" ] && kill -0 "$oldpid" >/dev/null 2>&1; then
        if is_ancestor_pid "$oldpid"; then
          log "현재 실행의 상위 프로세스 PID $oldpid 보호 · 종료하지 않음"
        else
          args="$(pid_args "$oldpid")"
          case "$args" in
            *desktab-bootstrap*|*installer-v11*|*desktop-repair*)
              log "이전 deskTAB 설치 프로세스 종료: PID $oldpid"
              kill_tree "$oldpid"
              if ! wait_dead "$oldpid"; then
                kill -KILL "$oldpid" >/dev/null 2>&1 || true
              fi
              ;;
            *)
              log "stale lock PID $oldpid 는 deskTAB 프로세스가 아니므로 종료하지 않음"
              ;;
          esac
        fi
      fi
      ;;
  esac
  rm -rf "$LOCK_DIR"

  # Clean only orphaned archive workers that reference deskTAB's own runtime cache.
  # This cannot match the loader/current installer and avoids broad process killing.
  while read -r pid ppid pargs; do
    [ -n "${pid:-}" ] || continue
    [ "$pid" = "$$" ] && continue
    is_ancestor_pid "$pid" && continue
    case "$pargs" in
      *"$CACHE_ROOT"*runtime-arm64.tar.zst*)
        case "$pargs" in
          *zstd*|*tar*)
            log "이전 이미지 해제 worker 종료: PID $pid"
            kill_tree "$pid"
            wait_dead "$pid" || kill -KILL "$pid" >/dev/null 2>&1 || true
            ;;
        esac
        ;;
    esac
  done < <(ps_table)
  return 0
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    OWN_LOCK=1
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    return 0
  fi

  # A new installer may have won the race after cleanup. Never delete a live lock.
  local owner
  owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if printf '%s' "$owner" | grep -qE '^[0-9]+$' && kill -0 "$owner" >/dev/null 2>&1; then
    log "다른 deskTAB 설치가 이미 시작됨: PID $owner"
    return 48
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  OWN_LOCK=1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
}

run_pkg() {
  local label="$1"; shift
  local attempt=0 code start now elapsed sig last_sig last_change idle line base_eta pid
  while true; do
    attempt=$((attempt + 1))
    : > "$PKG_LOG"
    start="$(date +%s)"
    last_change="$start"
    last_sig=""
    base_eta="$CURRENT_ETA"
    set +e
    env DEBIAN_FRONTEND=noninteractive "$@" >"$PKG_LOG" 2>&1 &
    pid=$!
    set -e
