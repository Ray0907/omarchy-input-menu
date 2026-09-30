#!/bin/bash
# Sandbox test for scripts/add-engine: stubbed pacman, omarchy-pkg-add, gum, busctl, systemctl.
# Runs anywhere with bash, jq, sed, awk. Run: bash test/add-engine-check.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export T FAKE_LOG="$T/log" HOME="$T/home"
mkdir -p "$T/bin" "$HOME"

cat >"$T/bin/pacman" <<'STUB'
#!/bin/bash
tab() { case "$1" in fcitx5-chewing) echo chewing;; fcitx5-mozc) echo mozc;; fcitx5-hangul) echo hangul;; fcitx5-unikey) echo unikey;;
  fcitx5-chinese-addons) echo "cangjie pinyin shuangpin wbx zrm";; esac; }
case "$1" in
  -Q) grep -qx -- "$2" "$T/installed" ;;
  -Ql) grep -qx -- "$2" "$T/installed" || exit 1; for n in $(tab "$2"); do echo "$2 /usr/share/fcitx5/inputmethod/$n.conf"; echo "$2 /usr/share/doc/$2/README"; done ;;
esac
STUB
cat >"$T/bin/omarchy-pkg-add" <<'STUB'
#!/bin/bash
echo "pkg-add $*" >>"$FAKE_LOG"
[[ -n ${FAKE_PKG_FAIL:-} ]] && { echo "error: failed retrieving file" >&2; exit 1; }
for p in "$@"; do grep -qx -- "$p" "$T/installed" || echo "$p" >>"$T/installed"; done
STUB
cat >"$T/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >>"$FAKE_LOG"
case "$*" in *is-active*) [[ -z ${FAKE_UNIT_DOWN:-} ]] ;; *restart*) touch "$T/restarted" ;; esac
STUB
cat >"$T/bin/hyprctl" <<'STUB'
#!/bin/bash
n=${FAKE_WINDOWS:-0}; printf '['; for ((i=0;i<n;i++)); do ((i)) && printf ','; printf '{}'; done; printf ']\n'
STUB
cat >"$T/bin/sleep" <<'STUB'
#!/bin/bash
echo x >>"$T/sleeps"
STUB
cat >"$T/bin/gum" <<'STUB'
#!/bin/bash
# Scripted answers: each gum choose/confirm pops the first line of $T/answers.
echo "gum $*" >>"$FAKE_LOG"
sub=$1; shift
case "$sub" in
  choose) a=$(head -1 "$T/answers"); tail -n +2 "$T/answers" >"$T/a.x"; mv "$T/a.x" "$T/answers"
          rows=$(cat); IFS='|' read -ra pats <<<"$a"; for p in "${pats[@]}"; do [[ -n $p ]] && grep -F -- "$p" <<<"$rows"; done; exit 0 ;;
  confirm) a=$(head -1 "$T/answers"); tail -n +2 "$T/answers" >"$T/a.x"; mv "$T/a.x" "$T/answers"; [[ $a == yes ]] ;;
  *) cat >/dev/null 2>&1 || true ;;
esac
STUB
cat >"$T/bin/busctl" <<'STUB'
#!/bin/bash
echo "busctl $*" >>"$FAKE_LOG"
case " $* " in *" --auto-start=no "*) ;; *) echo "$*" >>"$FAKE_LOG.bad" ;; esac
all=" $* "
loaded() { echo chewing; echo mozc; if [[ -e $T/restarted ]]; then while read -r p; do case $p in fcitx5-hangul) echo hangul;; fcitx5-unikey) echo unikey;;
  fcitx5-chinese-addons) printf '%s\n' cangjie pinyin shuangpin wbx zrm;; esac; done <"$T/installed"; fi; }
if [[ $all == *" State "* ]]; then exit 0; fi
if [[ $all == *" Exit "* ]]; then exit 0; fi
if [[ $all == *" CurrentInputMethodGroup "* ]]; then echo '{"type":"s","data":["Default"]}'; exit 0; fi
if [[ $all == *" InputMethodGroupInfo "* ]]; then
  [[ -n ${FAKE_READ_FAIL:-} ]] && exit 1
  [[ -n ${FAKE_READ_BAD:-} ]] && { echo '{}'; exit 0; }
  jq -Rn --arg layout "${FAKE_LAYOUT:-us}" '[inputs|split("\t")|[.[0],(.[1]//"")]] | {type:"sa(ss)",data:[$layout,.]}' <"$T/group"; exit 0; fi
if [[ $all == *" AvailableInputMethods "* ]]; then
  [[ -n ${FAKE_AVAILABLE_FAIL:-} ]] && exit 1
  { echo keyboard-us; loaded | grep -vxFf "$T/notloaded"; } | sort -u \
    | jq -Rn '[inputs|[.,.,"","","","",true]] | {type:"a(ssssssb)",data:[.]}'; exit 0; fi
if [[ $all == *" SetInputMethodGroupInfo "* ]]; then
  a=("$@"); i=0; for k in "${!a[@]}"; do [[ ${a[k]} == 'ssa(ss)' ]] && i=$k; done
  printf '%s\n' "${a[i+1]}" "${a[i+2]}" >"$T/written-group"
  n=${a[i+3]}; : >"$T/group.new"
  for ((j=0;j<n;j++)); do printf '%s\t%s\n' "${a[i+4+2*j]}" "${a[i+5+2*j]}" >>"$T/group.new"; done
  [[ -n ${FAKE_SET_FAIL:-} ]] && exit 1
  [[ -n ${FAKE_SET_IGNORE:-} ]] && exit 0
  [[ -n ${FAKE_SET_RELAYOUT:-} ]] && printf 'keyboard-us\tchanged\nchewing\t\n' >"$T/group.new"
  mv "$T/group.new" "$T/group"; exit 0; fi
exit 0
STUB
chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"

S="$HERE/scripts/add-engine"; fails=0
check() { if [[ $2 != "$3" ]]; then echo "FAIL: $1: got [$2] want [$3]"; fails=1; fi; }
group() { tr '\t' ':' <"$T/group" | tr '\n' ' ' | sed 's/ $//'; }
count() {
  local n rc
  n=$(grep -c -- "$1" "$FAKE_LOG"); rc=$?
  case $rc in 0|1) echo "$n" ;; *) echo ERR; return 1 ;; esac
}
reset() { rm -f "$FAKE_LOG" "$T/restarted" "$T/sleeps" "$T/answers" "$T/notloaded"; : >"$T/notloaded"; : >"$FAKE_LOG"
  printf 'fcitx5-chewing\nfcitx5-mozc\n' >"$T/installed"; printf 'keyboard-us\t\n' >"$T/group"
  unset FAKE_PKG_FAIL FAKE_UNIT_DOWN FAKE_WINDOWS FAKE_SET_FAIL FAKE_READ_FAIL FAKE_READ_BAD FAKE_AVAILABLE_FAIL FAKE_SET_IGNORE FAKE_SET_RELAYOUT FAKE_LAYOUT; }

# Counting must distinguish a real zero from a missing or unreadable log.
reset; : >"$FAKE_LOG"
check "count no matches" "$(count 'busctl')" 0
rm "$FAKE_LOG"; check "count missing log" "$(count 'busctl' 2>/dev/null)" ERR
mkdir "$FAKE_LOG"; check "count log read error" "$(count 'busctl' 2>/dev/null)" ERR
rmdir "$FAKE_LOG"

# 1. installed engines missing from the group, both already loaded: no pkg-add, no restart, appended in order
reset
out=$("$S" --engines fcitx5-chewing,fcitx5-mozc --yes 2>&1); check "installed rc" "$?" 0
check "installed group" "$(group)" "keyboard-us: chewing: mozc:"
check "installed bus logging" "$(count '^busctl .* CurrentInputMethodGroup$')" 2
check "no pkg-add for installed" "$(count 'pkg-add')" 0
check "no restart when loaded" "$(count 'restart')" 0
[[ $out == *"Added to the input method group: chewing mozc"* ]] || { echo "FAIL: summary line: $out"; fails=1; }

# 2. second run is a no-op
out=$("$S" --engines fcitx5-chewing,fcitx5-mozc --yes 2>&1); check "second rc" "$?" 0
[[ $out == *"Already set up"* ]] || { echo "FAIL: no 'Already set up': $out"; fails=1; }
check "group unchanged" "$(group)" "keyboard-us: chewing: mozc:"
check "second run did not restart" "$(count 'restart')" 0
check "second run did not write" "$(count 'SetInputMethodGroupInfo')" 1

# 3. new package: pkg-add with only the missing one, restart, added after fcitx5 loaded it
reset; "$S" --engines fcitx5-chewing,fcitx5-hangul --yes >/dev/null 2>&1; check "new pkg rc" "$?" 0
check "pkg-add only missing" "$(grep 'pkg-add' "$FAKE_LOG")" "pkg-add fcitx5-hangul"
check "restarted once" "$(count 'systemctl --user restart omarchy-fcitx5')" 1
check "group after install" "$(group)" "keyboard-us: chewing: hangul:"

# 4. existing entries keep their order and layout
reset; printf 'keyboard-us\t\nmozc\tjp\n' >"$T/group"; export FAKE_LAYOUT=jp
"$S" --engines fcitx5-chewing --yes >/dev/null 2>&1
check "existing kept, new appended" "$(group)" "keyboard-us: mozc:jp chewing:"
check "group name and default layout kept" "$(tr '\n' ':' <"$T/written-group")" "Default:jp:"

# 5. install failure: nothing else touched
reset; export FAKE_PKG_FAIL=1
out=$("$S" --engines fcitx5-hangul --yes 2>&1); check "install failure rc" "$?" 1
[[ $out == *"Installation failed"* ]] || { echo "FAIL: no failure message"; fails=1; }
check "no restart after failed install" "$(count 'restart')" 0; check "group untouched after failed install" "$(group)" "keyboard-us:"
check "no D-Bus after failed install" "$(count 'busctl')" 0

# 5b. Enter with nothing ticked asks again instead of ending; it never installs on an empty pick
reset; printf '\n\nKorean\nno\n' >"$T/answers"
out=$("$S" 2>&1); check "empty pick rc" "$?" 0
check "empty pick asks again" "$(count 'gum choose')" 3
[[ $out == *"Tick at least one"* ]] || { echo "FAIL: no tick-one hint: $out"; fails=1; }
[[ $out != *"Nothing selected"* ]] || { echo "FAIL: empty pick ended the run: $out"; fails=1; }
grep -qx fcitx5-hangul "$T/installed" || { echo "FAIL: Korean should be installed after the retry"; fails=1; }

# 6. restart declined (interactive): packages stay, group unchanged, says how to finish
reset; printf 'Korean\nno\n' >"$T/answers"
out=$("$S" 2>&1); check "declined rc" "$?" 0
[[ $out == *"Restart declined"* ]] || { echo "FAIL: no decline message: $out"; fails=1; }
check "declined group" "$(group)" "keyboard-us:"; check "declined restart count" "$(count 'restart')" 0
check "declined did not exit fcitx5" "$(count ' Exit')" 0
grep -qx fcitx5-hangul "$T/installed" || { echo "FAIL: package should stay installed"; fails=1; }

# 7. an input method fcitx5 does not load is skipped with a message
reset; echo unikey >"$T/notloaded"
out=$("$S" --engines fcitx5-hangul,fcitx5-unikey --yes 2>&1); check "partial rc" "$?" 0
check "partial group" "$(group)" "keyboard-us: hangul:"
[[ $out == *"Skipped (not loaded by fcitx5): unikey"* ]] || { echo "FAIL: skip message: $out"; fails=1; }

# 8. a package with more than three input methods asks (interactive) and adds only the chosen
reset; printf 'Pinyin\npinyin|shuangpin\nyes\n' >"$T/answers"
"$S" >/dev/null 2>&1; check "multi-IM chosen only" "$(group)" "keyboard-us: pinyin: shuangpin:"
check "recommended selection" "$(count '--selected pinyin')" 1

# 9. scripted --ims filter
reset; "$S" --engines fcitx5-chinese-addons --ims zrm --yes >/dev/null 2>&1
check "--ims filter" "$(group)" "keyboard-us: zrm:"
check "scripted does not use gum" "$(count 'gum')" 0

# 10. refusals: unknown package, unit not active
reset; "$S" --engines fcitx5-evil --yes >/dev/null 2>&1; check "unknown package rc" "$?" 2
check "unknown package touched nothing" "$(count 'pkg-add')$(count 'busctl')" "00"
"$S" --engines 'fcitx5-\143hewing' --yes >/dev/null 2>&1; check "escaped package rc" "$?" 2
check "escaped package touched nothing" "$(count 'pkg-add')$(count 'busctl')" "00"
export FAKE_UNIT_DOWN=1; "$S" --engines fcitx5-chewing --yes >/dev/null 2>&1; check "unit down rc" "$?" 1
check "unit down group" "$(group)" "keyboard-us:"; unset FAKE_UNIT_DOWN

# 11. group write failure is reported, safe to rerun
reset; export FAKE_SET_FAIL=1; "$S" --engines fcitx5-chewing --yes >/dev/null 2>&1; check "set failure rc" "$?" 1
check "set failure group" "$(group)" "keyboard-us:"; unset FAKE_SET_FAIL
"$S" --engines fcitx5-chewing --yes >/dev/null 2>&1; check "rerun after failure" "$(group)" "keyboard-us: chewing:"

# 12. open windows are mentioned in the restart confirmation path; --yes still restarts
reset; export FAKE_WINDOWS=2; out=$("$S" --engines fcitx5-hangul --yes 2>&1)
[[ $out == *"2 window"* ]] || { echo "FAIL: open windows not mentioned: $out"; fails=1; }; unset FAKE_WINDOWS

# 13. scripted confirmations never use gum, with or without --yes
reset; out=$(printf 'no\n' | "$S" --engines fcitx5-hangul 2>&1); check "scripted decline rc" "$?" 0
[[ $out == *"Restart declined"* ]] || { echo "FAIL: scripted decline: $out"; fails=1; }
check "scripted decline group" "$(group)" "keyboard-us:"
check "scripted decline no restart" "$(count 'restart')" 0
check "scripted decline no gum" "$(count 'gum')" 0
reset; printf 'yes\n' | "$S" --engines fcitx5-hangul >/dev/null 2>&1; check "scripted confirm rc" "$?" 0
check "scripted confirm group" "$(group)" "keyboard-us: hangul:"
check "scripted confirm no gum" "$(count 'gum')" 0

# 14. failed/malformed group reads and failed availability reads never write or restart
for fault in FAKE_READ_FAIL FAKE_READ_BAD FAKE_AVAILABLE_FAIL; do
  reset; export "$fault=1"
  "$S" --engines fcitx5-chewing --yes >/dev/null 2>&1; check "$fault rc" "$?" 1
  check "$fault no write" "$(count 'SetInputMethodGroupInfo')" 0
  check "$fault no restart" "$(count 'restart')" 0
  check "$fault unchanged" "$(group)" "keyboard-us:"
done

# 15. verify the entire write, not merely presence of the new name
for fault in FAKE_SET_IGNORE FAKE_SET_RELAYOUT; do
  reset; export "$fault=1"
  "$S" --engines fcitx5-chewing --yes >/dev/null 2>&1; check "$fault verification rc" "$?" 1
done

# 16. a package whose only loaded engine is excluded must stay excluded
reset; printf 'chewing\nmozc\n' >"$T/notloaded"
out=$("$S" --engines fcitx5-chewing --yes 2>&1); check "all unavailable rc" "$?" 1
check "all unavailable group" "$(group)" "keyboard-us:"
[[ $out == *"Skipped (not loaded by fcitx5): chewing"* ]] || { echo "FAIL: all unavailable message: $out"; fails=1; }

# 17. duplicate package requests are installed once
reset; "$S" --engines fcitx5-hangul,fcitx5-hangul --yes >/dev/null 2>&1; check "duplicate rc" "$?" 0
check "duplicate package install" "$(grep 'pkg-add' "$FAKE_LOG")" "pkg-add fcitx5-hangul"
check "duplicate group" "$(group)" "keyboard-us: hangul:"

# 18. missing/empty option values are bad arguments, never interactive fallback
for flag in --engines --ims; do
  reset; "$S" "$flag" >/dev/null 2>&1; check "$flag missing rc" "$?" 2
  "$S" "$flag" '' >/dev/null 2>&1; check "$flag empty rc" "$?" 2
  "$S" "$flag" --yes >/dev/null 2>&1; check "$flag option as value rc" "$?" 2
  check "$flag no effects" "$(count 'pkg-add')$(count 'busctl')$(count 'gum')" "000"
done

# 19. all bus calls across all cases are checked, not just the last case
[[ -f $S ]] || { echo "FAIL: missing scripts/add-engine"; fails=1; }
grep -nE 'sudo|pkexec' "$S" && { echo "FAIL: script must not contain privilege commands"; fails=1; }
[[ ! -e $FAKE_LOG.bad ]] || { echo "FAIL: busctl without --auto-start=no:"; cat "$FAKE_LOG.bad"; fails=1; }

if (( fails )); then echo FAILED; exit 1; fi
echo ok
