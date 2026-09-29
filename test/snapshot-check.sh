#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/busctl" <<'MOCK'
#!/bin/bash
[[ " $* " == *' --auto-start=no '* ]] || exit 3
case "$*" in
  *RegisteredStatusNotifierItems*)
    if [[ $SNAP_CASE == missing ]]; then echo '{"data":[]}'
    else echo '{"data":[":1.9/StatusNotifierItem"]}'; fi ;;
  *'org.kde.StatusNotifierItem Id'*) echo 's "Fcitx"' ;;
  *'org.kde.StatusNotifierItem Menu'*) echo '{"data":"/MenuBar"}' ;;
  *'org.kde.StatusNotifierItem IconName'*) echo '{"data":"input-keyboard-symbolic"}' ;;
  *'com.canonical.dbusmenu GetLayout'*) echo '{"data":[0,[0,{},[{"data":[100,{"toggle-type":{"data":"radio"},"toggle-state":{"data":1}},[]]}]]]}' ;;
  *'com.canonical.dbusmenu Event'*) echo "$*" >> "$SNAP_CALLS" ;;
  *'com.canonical.dbusmenu AboutToShow'*) echo "$*" >> "$SNAP_CALLS" ;;
  *) exit 4 ;;
esac
MOCK
chmod +x "$tmp/busctl"
export PATH="$tmp:$PATH" SNAP_CALLS="$tmp/calls"
SNAP_CASE=missing "$here/scripts/snapshot" | jq -e '. == {"sni":false}' >/dev/null
SNAP_CASE=present "$here/scripts/snapshot" | jq -e '.sni and .icon == "input-keyboard-symbolic" and .items[0] == {"id":100,"icon":"","text":"","radio":true,"checked":true,"sub":false}' >/dev/null
SNAP_CASE=present "$here/scripts/snapshot" click 100 | jq -e '.sni' >/dev/null
grep -q 'Event isvu 100 clicked' "$tmp/calls"
echo ok
