#!/bin/bash
# Builds, signs, notarizes and staples a muxFinder for distribution (PLAN.md D28).
#
#   scripts/release.sh
#
# - Checks first that notarytool's keychain profile AC_NOTARY_PROFILE (or the one named by
#   MUXFINDER_NOTARY_PROFILE) works. This script never reads, prints or stores credentials;
#   create the profile once with `xcrun notarytool store-credentials`.
# - Runs scripts/build-app.sh --release: build/muxFinder.app signed by the first "Developer ID
#   Application" identity (or MUXFINDER_SIGN_IDENTITY), hardened runtime, secure timestamp.
# - Uploads a ditto zip of the app to Apple's notary service and waits up to 30 minutes. On any
#   verdict other than Accepted it saves the notary log to build/notarization-log.json, prints
#   it, and stops.
# - Staples the ticket to the app (retrying while it propagates), validates it, requires
#   Gatekeeper's verdict "source=Notarized Developer ID", and writes build/muxFinder.zip (the
#   stapled app, zipped with ditto) for distribution.
# Exit status: 0 notarized and stapled; 1 a step failed (no later step ran); 2 usage.
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "usage: scripts/release.sh" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/muxFinder.app"
UPLOAD="$ROOT/build/muxFinder-notarization.zip"
ZIP="$ROOT/build/muxFinder.zip"
RESULT="$ROOT/build/notarization.json"
LOG="$ROOT/build/notarization-log.json"
PROFILE="${MUXFINDER_NOTARY_PROFILE:-AC_NOTARY_PROFILE}"

echo "Checking the notarytool keychain profile ${PROFILE}..."
if ! xcrun notarytool history --keychain-profile "$PROFILE" > /dev/null 2>&1; then
  echo "error: notarytool cannot use the keychain profile \"$PROFILE\"." >&2
  echo "Create it once with: xcrun notarytool store-credentials \"$PROFILE\" --key <AuthKey.p8>" \
    "--key-id <key id> --issuer <issuer id>" >&2
  exit 1
fi

"$ROOT/scripts/build-app.sh" --release
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=4 "$APP" 2>&1 | awk '/^(Authority|TeamIdentifier|Timestamp)=/'

rm -f "$UPLOAD" "$ZIP" "$RESULT" "$LOG"
/usr/bin/ditto -c -k --keepParent "$APP" "$UPLOAD"

echo "Submitting to Apple's notary service (waits up to 30 minutes)..."
SUBMITTED=1
xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --wait --timeout 30m \
  --output-format json > "$RESULT" || SUBMITTED=0
STATUS="$(plutil -extract status raw -o - "$RESULT" 2> /dev/null || true)"
ID="$(plutil -extract id raw -o - "$RESULT" 2> /dev/null || true)"
rm -f "$UPLOAD"
if [ "$SUBMITTED" != 1 ] || [ "$STATUS" != "Accepted" ]; then
  echo "error: notarization did not succeed (status: ${STATUS:-none})." >&2
  if [ -n "$ID" ]; then
    xcrun notarytool log "$ID" --keychain-profile "$PROFILE" "$LOG" || true
    [ -f "$LOG" ] && cat "$LOG" >&2
    echo "Notary log: $LOG" >&2
  else
    cat "$RESULT" >&2 || true
  fi
  exit 1
fi
echo "Notarized: submission $ID accepted."

# The ticket can take a moment to propagate after Accepted.
for attempt in 1 2 3; do
  if xcrun stapler staple "$APP"; then
    break
  elif [ "$attempt" = 3 ]; then
    echo "error: stapling failed three times." >&2
    exit 1
  fi
  sleep 30
done
xcrun stapler validate "$APP"

VERDICT="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1 || true)"
printf '%s\n' "$VERDICT"
case "$VERDICT" in
  *"accepted"*"source=Notarized Developer ID"*) ;;
  *)
    echo "error: Gatekeeper does not accept the app as notarized." >&2
    exit 1
    ;;
esac

/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
echo "Released: $APP (notarized, stapled) and $ZIP."
