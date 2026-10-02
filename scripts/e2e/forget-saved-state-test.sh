#!/bin/bash
# forget-saved-state.py removes only the folder of the named app: a mapping
# entry that is not a UUID, or a folder that is a symlink, deletes nothing.
#   bash scripts/e2e/forget-saved-state-test.sh
set -e
H=$(mktemp -d); export HOME=$H
S="$H/Library/Daemon Containers/X/Data/Library/Saved Application State"; mkdir -p "$S"
U=11111111-2222-3333-4444-555555555555; mkdir "$S/$U.savedState"
mkdir -p "$H/Library/Daemon Containers/X/Data/victim.savedState"; touch "$H/Library/Daemon Containers/X/Data/victim.savedState/keep"
V=AAAAAAAA-2222-3333-4444-555555555555; ln -s "$H/Library/Daemon Containers/X/Data/victim.savedState" "$S/$V.savedState"
python3 - "$S/ApplicationMapping.plist" <<PY
import plistlib,sys
e=lambda i:{"protected":{"signingIdentifier":i}}
plistlib.dump([e("t.app"),"../../victim",e("t.app"),"$V",e("t.app"),"$U",e("other"),"$U"],open(sys.argv[1],"wb"))
PY
python3 "$(dirname "$0")/forget-saved-state.py" t.app
test -f "$H/Library/Daemon Containers/X/Data/victim.savedState/keep" || { echo "FAIL: the victim was deleted"; exit 1; }
test ! -e "$S/$U.savedState" || { echo "FAIL: the app's own folder remains"; exit 1; }
echo ok
rm -rf "$H"
