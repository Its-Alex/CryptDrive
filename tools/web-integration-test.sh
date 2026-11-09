#!/usr/bin/env bash
# Runs app/integration_test/web_flow_test.dart in headless Chrome through chromedriver.
# Usage: CHROME=/path/to/chrome CHROMEDRIVER=/path/to/chromedriver tools/web-integration-test.sh
# (get a matching pair with: npx @puppeteer/browsers install chrome@stable chromedriver@stable)
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
: "${CHROME:?set CHROME to a Chrome binary}" "${CHROMEDRIVER:?set CHROMEDRIVER to a matching chromedriver}"

work="$(mktemp -d "${TMPDIR:-/tmp}/cryptdrive-web-test.XXXXXX")"
# chromedriver finds Chrome only under a well-known name on PATH.
mkdir "$work/bin"
ln -s "$CHROME" "$work/bin/google-chrome"
PATH="$work/bin:$PATH" "$CHROMEDRIVER" --port=4444 >"$work/chromedriver.log" 2>&1 &
chromedriver_pid=$!
trap 'kill "$chromedriver_pid" 2>/dev/null || true; rm -r "$work"' EXIT

cd "$repo/app"
CHROME_EXECUTABLE="$CHROME" flutter drive --driver test_driver/integration_test.dart \
	--target integration_test/web_flow_test.dart -d web-server --browser-name=chrome --headless --release \
	--no-web-resources-cdn
