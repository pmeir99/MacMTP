#!/bin/bash
set -euo pipefail
version="$(tr -d '\r\n' < VERSION)"
tag="v$version"
repo="pmeir99/MacMTP"
export GH_REPO="$repo"
if gh release view "$tag" --json isDraft --jq '.isDraft' > "$RUNNER_TEMP/macmtp-draft" 2>/dev/null; then
  if [[ "$(cat "$RUNNER_TEMP/macmtp-draft")" == false ]]; then
    echo "Release $tag is already published. Bump VERSION for a new release."
    exit 0
  fi
else
  gh release create "$tag" --draft --target "$GITHUB_SHA" --title "MacMTP $version" --notes "Native Android file transfer for Apple Silicon Macs running macOS 27 or later.

Download **MacMTP.dmg** for installation, or unzip **MacMTP.zip** and move MacMTP.app into Applications.

This release adds Software Update: automatic release checks, verified downloads, Install & Relaunch, and rollback if the updated app cannot reopen.

USB recovery is enabled on launch and can stop ADB debugging or close Android transfer apps. You can change this in the View menu.

The app is ad hoc signed. macOS may require approval in Privacy & Security on first launch."
fi
# A retry can reuse a draft created by an earlier commit. Bind the release to
# the commit whose verified app is being uploaded before publishing its tag.
release_id="$(gh api "repos/$repo/releases?per_page=100" --jq ".[] | select(.tag_name == \"$tag\") | .id")"
[[ "$release_id" =~ ^[0-9]+$ ]]
gh api --method PATCH "repos/$repo/releases/$release_id" -f target_commitish="$GITHUB_SHA" >/dev/null
gh release upload "$tag" dist/MacMTP.zip dist/MacMTP.dmg dist/SHA256SUMS.txt --clobber
# The updater uses GitHub's own asset digest. Verify it before exposing the release.
for attempt in 1 2 3 4 5; do
  gh api "repos/$repo/releases/$release_id" > "$RUNNER_TEMP/macmtp-release.json"
  if python3 - "$RUNNER_TEMP/macmtp-release.json" <<'PY'
import hashlib, json, pathlib, sys
release = json.loads(pathlib.Path(sys.argv[1]).read_text())
assets = {item["name"]: item for item in release["assets"]}
for name in ["MacMTP.zip", "MacMTP.dmg"]:
    payload = pathlib.Path("dist", name).read_bytes()
    asset = assets.get(name, {})
    if asset.get("size") != len(payload) or asset.get("digest") != "sha256:" + hashlib.sha256(payload).hexdigest():
        sys.exit(1)
PY
  then
    gh release edit "$tag" --draft=false --latest
    echo "Published https://github.com/$repo/releases/tag/$tag"
    exit 0
  fi
  sleep 2
done
echo "Release assets could not be verified; the release remains a draft." >&2
exit 1
