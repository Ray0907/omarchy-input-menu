#!/bin/bash
# Sandbox test for scripts/save-modes: the mode cache is only written on real paths, through an exclusive temporary file.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
S="$HERE/scripts/save-modes"
F="$HOME/.local/state/input-menu-modes.json"
fails=0
check() { if [[ $2 != "$3" ]]; then echo "FAIL: $1: got [$2] want [$3]"; fails=1; fi; }
reset() { rm -rf "$HOME"; mkdir -p "$HOME/.local/state" "$HOME/elsewhere"; printf 'victim\n' >"$HOME/elsewhere/victim"; }
rcof() { "$@" >"$T/out" 2>&1; echo $?; }
J='{"fcitx_mozc":[{"icon":"a","text":"A"}]}'

[[ -x $S ]] || { echo "FAIL: scripts/save-modes missing or not executable"; echo FAILED; exit 1; }
reset; check "plain write rc" "$(rcof "$S" "$J")" 0
check "plain write content" "$(jq -c . "$F" 2>/dev/null)" "$J"
check "no leftover temporary files" "$(find "$HOME/.local/state" -name 'input-menu-modes.json.*' | wc -l | tr -d ' ')" 0
check "overwrite rc" "$(rcof "$S" '{"x":[]}')" 0
check "overwrite content" "$(jq -c . "$F")" '{"x":[]}'

reset; ln -s "$HOME/elsewhere/victim" "$F"
check "symlink at path refused" "$(rcof "$S" "$J")" 1
check "symlink target untouched" "$(cat "$HOME/elsewhere/victim")" victim
[[ $(<"$T/out") == *symlink* ]] || { echo "FAIL: no symlink notice: $(<"$T/out")"; fails=1; }

reset; ln -s "$HOME/elsewhere/new-target" "$F"
check "dangling symlink refused" "$(rcof "$S" "$J")" 1
[[ ! -e $HOME/elsewhere/new-target ]] || { echo "FAIL: dangling link target was created"; fails=1; }

reset; rm -rf "$HOME/.local/state"; ln -s "$HOME/elsewhere" "$HOME/.local/state"
check "linked ancestor refused" "$(rcof "$S" "$J")" 1
check "linked ancestor target untouched" "$(ls "$HOME/elsewhere" | tr '\n' ' ')" "victim "

reset; mkdir "$F"
check "directory at path refused" "$(rcof "$S" "$J")" 1
check "directory left empty" "$(ls -A "$F" | wc -l | tr -d ' ')" 0

reset; ln -s "$HOME/elsewhere/victim" "$F.tmp"
check "planted .tmp link write rc" "$(rcof "$S" "$J")" 0
check "planted .tmp link target untouched" "$(cat "$HOME/elsewhere/victim")" victim

reset; printf '%s\n' "$J" >"$F"
check "non-object refused" "$(rcof "$S" '[1,2]')" 1
check "invalid json refused" "$(rcof "$S" 'not json')" 1
check "old cache kept after refusal" "$(jq -c . "$F")" "$J"
check "missing argument" "$(rcof "$S")" 2

if (( fails )); then echo FAILED; exit 1; fi
echo ok
