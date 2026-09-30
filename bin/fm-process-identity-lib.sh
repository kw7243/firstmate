#!/usr/bin/env bash
# Kernel process coordinates shared by session ownership and transient locks.
# A PID is comparable only inside the same boot and PID namespace. Missing
# coordinates are uncertainty, never proof that a process in another view died.
# No side effects on source; non-Linux callers retain their native PID view.

fm_process_namespace() {
  local boot namespace
  [ -d /proc/self/ns ] || return 1
  boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || return 1
  namespace=$(readlink /proc/self/ns/pid 2>/dev/null) || return 1
  [ -n "$boot" ] && [ -n "$namespace" ] || return 1
  printf '%s/%s\n' "$boot" "$namespace"
}

fm_process_starttime() {  # <pid>
  local line
  local -a fields
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  line=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  read -r -a fields <<< "${line##*)}"
  [ "${#fields[@]}" -ge 20 ] || return 1
  case "${fields[19]}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "${fields[19]}"
}
