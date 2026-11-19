#!/bin/bash
set -euo pipefail
umask 077
version="$(tr -d '\r\n' < VERSION)"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
tag="v$version"
repo="pmeir99/MacMTP"
headers="$(mktemp "$RUNNER_TEMP/macmtp-headers.XXXXXX")"
trap 'rm -f "$headers"' EXIT
# Keep the short-lived token out of curl's command-line arguments and logs.
printf 'Authorization: Bearer %s\nContent-Type: application/octet-stream\n' "$GH_TOKEN" > "$headers"

release_id="$(gh api --paginate "repos/$repo/releases?per_page=100" --jq ".[] | select(.tag_name == \"$tag\") | .id")"
if [[ -n "$release_id" ]]; then
  [[ "$release_id" =~ ^[0-9]+$ ]]
  if [[ "$(gh api "repos/$repo/releases/$release_id" --jq '.draft')" == false ]]; then
    echo "Release $tag is already published. Bump VERSION for a new release."
    exit 0
  fi
else
  cat > "$RUNNER_TEMP/macmtp-release-notes" <<'NOTES'
Native Android file transfer for Apple Silicon Macs running macOS 27 or later.

Download **MacMTP.dmg** for installation, or unzip **MacMTP.zip** and move MacMTP.app into Applications.

Software Update includes automatic release checks, verified downloads, Install & Relaunch, and rollback if the updated app cannot reopen.

USB recovery is enabled on launch and can stop ADB debugging or close Android transfer apps. You can change this in the View menu.

The app is ad hoc signed. macOS may require approval in Privacy & Security on first launch.
NOTES
  release_id="$(gh api --method POST "repos/$repo/releases" -f tag_name="$tag"     -f target_commitish="$GITHUB_SHA" -f name="MacMTP $version"     -F "body=@$RUNNER_TEMP/macmtp-release-notes" -F draft=true --jq '.id')"
fi

# Address drafts by ID: GitHub's tag-based endpoints require a published tag.
gh api --method PATCH "repos/$repo/releases/$release_id" -f target_commitish="$GITHUB_SHA" >/dev/null
for name in MacMTP.zip MacMTP.dmg SHA256SUMS.txt; do
  existing="$(gh api "repos/$repo/releases/$release_id/assets?per_page=100"     --jq ".[] | select(.name == \"$name\") | .id")"
  if [[ -n "$existing" ]]; then
    [[ "$existing" =~ ^[0-9]+$ ]]
    gh api --method DELETE "repos/$repo/releases/assets/$existing"
  fi
  curl --fail --silent --show-error --retry 3 --retry-delay 2     --header "@$headers" --data-binary "@dist/$name"     "https://uploads.github.com/repos/$repo/releases/$release_id/assets?name=$name"     > "$RUNNER_TEMP/macmtp-upload.json"
done

# Verify GitHub's own asset digests before making the release public.
for attempt in 1 2 3 4 5; do
  gh api "repos/$repo/releases/$release_id" > "$RUNNER_TEMP/macmtp-release.json"
  if python3 - "$RUNNER_TEMP/macmtp-release.json" <<'PY'
import hashlib, json, pathlib, sys
release = json.loads(pathlib.Path(sys.argv[1]).read_text())
assets = {item["name"]: item for item in release["assets"]}
for name in ["MacMTP.zip", "MacMTP.dmg", "SHA256SUMS.txt"]:
    payload = pathlib.Path("dist", name).read_bytes()
    asset = assets.get(name, {})
    expected = "sha256:" + hashlib.sha256(payload).hexdigest()
    if asset.get("size") != len(payload) or asset.get("digest") != expected:
        sys.exit(1)
PY
  then
    gh api --method PATCH "repos/$repo/releases/$release_id"       -F draft=false -f make_latest=true > "$RUNNER_TEMP/macmtp-published.json"
    echo "Published https://github.com/$repo/releases/tag/$tag"
    exit 0
  fi
  sleep 2
done
echo "Release assets could not be verified; the release remains a draft." >&2
exit 1
