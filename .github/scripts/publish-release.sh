#!/bin/bash
set -euo pipefail
umask 077
version="$(tr -d '\r\n' < VERSION)"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
tag="v$version"
repo="pmeir99/MacMTP"
headers="$(mktemp "$RUNNER_TEMP/macmtp-headers.XXXXXX")"
trap 'rm -f "$headers"' EXIT
printf 'Authorization: Bearer %s\nContent-Type: application/octet-stream\n' "$GH_TOKEN" > "$headers"

gh api --paginate --slurp "repos/$repo/releases?per_page=100" > "$RUNNER_TEMP/macmtp-releases.json"
release_id="$(python3 - "$RUNNER_TEMP/macmtp-releases.json" "$version" <<'PY'
import json, pathlib, sys
pages = json.loads(pathlib.Path(sys.argv[1]).read_text())
version = sys.argv[2]
releases = [item for page in pages for item in page]
matches = [item for item in releases if item["tag_name"] == "v" + version or
           (item["name"] == "MacMTP " + version and item["tag_name"].startswith("untagged-"))]
matches.sort(key=lambda item: (item["draft"], item["tag_name"] != "v" + version))
if matches:
    print(matches[0]["id"])
PY
)"
old_tag=""
if [[ -n "$release_id" ]]; then
  [[ "$release_id" =~ ^[0-9]+$ ]]
  gh api "repos/$repo/releases/$release_id" > "$RUNNER_TEMP/macmtp-existing.json"
  old_tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$RUNNER_TEMP/macmtp-existing.json")"
  if [[ "$old_tag" == "$tag" && "$(gh api "repos/$repo/releases/$release_id" --jq '.draft')" == false ]]; then
    echo "Release $tag is already published. Bump VERSION for a new release."
    exit 0
  fi
fi

# Create the real version tag before creating or editing a release.
tag_sha="$(gh api "repos/$repo/git/matching-refs/tags/$tag"   --jq ".[] | select(.ref == \"refs/tags/$tag\") | .object.sha")"
if [[ -z "$tag_sha" ]]; then
  gh api --method POST "repos/$repo/git/refs" -f ref="refs/tags/$tag" -f sha="$GITHUB_SHA" >/dev/null
elif [[ "$tag_sha" != "$GITHUB_SHA" ]]; then
  # Only an unpublished/repaired version reaches this point.
  gh api --method PATCH "repos/$repo/git/refs/tags/$tag" -f sha="$GITHUB_SHA" -F force=true >/dev/null
fi

python3 - "$version" "$GITHUB_SHA" "$RUNNER_TEMP/macmtp-release-payload.json" <<'PY'
import json, pathlib, sys
version, commit, output = sys.argv[1:]
body = """Native Android file transfer for Apple Silicon Macs running macOS 27 or later.

Download **MacMTP.dmg** for installation, or unzip **MacMTP.zip** and move MacMTP.app into Applications.

This update improves Finder-style browsing and stability:
- Arrow-key selection in Icons, List, Columns, and Gallery, including left/right hierarchy navigation in Columns.
- Inline rename with Return, Escape, and click-away completion; Space opens native Quick Look.
- Shared thumbnails in all views, system file kinds, and a column preview with size, dates, and image dimensions when supplied by the device.
- Correct loading placeholders, session-scoped directory caching, bounded thumbnail memory, and lower background USB traffic.

Recursive folder sizes are available under View > Calculate Folder Sizes. This is optional because scanning large trees can delay USB operations. The app does not scan the entire phone on connection.

Thumbnail availability depends on the device and file format. Large videos without a device thumbnail retain a file symbol while browsing; Quick Look downloads the selected file with progress. Quick Look supports the formats available in macOS and installed preview extensions.

Software Update includes automatic release checks, verified downloads, Install & Relaunch, and rollback if the updated app cannot reopen.

USB recovery is enabled on launch and can stop ADB debugging or close Android transfer apps. You can change this in the View menu.

The app is ad hoc signed. macOS may require approval in Privacy & Security on first launch."""
pathlib.Path(output).write_text(json.dumps({
    "tag_name": "v" + version, "target_commitish": commit, "name": "MacMTP " + version,
    "draft": True, "prerelease": False, "body": body
}))
PY
if [[ -z "$release_id" ]]; then
  release_id="$(gh api --method POST "repos/$repo/releases"     --input "$RUNNER_TEMP/macmtp-release-payload.json" --jq '.id')"
else
  gh api --method PATCH "repos/$repo/releases/$release_id"     --input "$RUNNER_TEMP/macmtp-release-payload.json" >/dev/null
fi

for name in MacMTP.zip MacMTP.dmg SHA256SUMS.txt; do
  existing="$(gh api "repos/$repo/releases/$release_id/assets?per_page=100"     --jq ".[] | select(.name == \"$name\") | .id")"
  if [[ -n "$existing" ]]; then
    [[ "$existing" =~ ^[0-9]+$ ]]
    gh api --method DELETE "repos/$repo/releases/assets/$existing"
  fi
  curl --fail --silent --show-error --retry 3 --retry-delay 2     --header "@$headers" --data-binary "@dist/$name"     "https://uploads.github.com/repos/$repo/releases/$release_id/assets?name=$name"     > "$RUNNER_TEMP/macmtp-upload.json"
done

for attempt in 1 2 3 4 5; do
  gh api "repos/$repo/releases/$release_id" > "$RUNNER_TEMP/macmtp-release.json"
  if python3 - "$RUNNER_TEMP/macmtp-release.json" "$tag" <<'PY'
import hashlib, json, pathlib, sys
release = json.loads(pathlib.Path(sys.argv[1]).read_text())
if release["tag_name"] != sys.argv[2]:
    sys.exit(1)
assets = {item["name"]: item for item in release["assets"]}
for name in ["MacMTP.zip", "MacMTP.dmg", "SHA256SUMS.txt"]:
    payload = pathlib.Path("dist", name).read_bytes()
    asset = assets.get(name, {})
    if asset.get("size") != len(payload) or asset.get("digest") != "sha256:" + hashlib.sha256(payload).hexdigest():
        sys.exit(1)
PY
  then
    python3 - "$RUNNER_TEMP/macmtp-release-payload.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text())
payload.update(draft=False, make_latest="true")
path.write_text(json.dumps(payload))
PY
    gh api --method PATCH "repos/$repo/releases/$release_id"       --input "$RUNNER_TEMP/macmtp-release-payload.json" > "$RUNNER_TEMP/macmtp-published.json"
    python3 - "$RUNNER_TEMP/macmtp-published.json" "$tag" <<'PY'
import json, pathlib, sys
release = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert release["tag_name"] == sys.argv[2] and not release["draft"]
assert any(a["name"] == "MacMTP.zip" and "/download/" + sys.argv[2] + "/" in a["browser_download_url"]
           for a in release["assets"])
PY
    # Remove only temporary tags/drafts created while staging this same version.
    if [[ "$old_tag" == untagged-* ]]; then
      old_ref="$(gh api "repos/$repo/git/matching-refs/tags/$old_tag" --jq '.[].ref')"
      if [[ -n "$old_ref" ]]; then
        gh api --method DELETE "repos/$repo/git/refs/tags/$old_tag"
      fi
    fi
    gh api "repos/$repo/releases?per_page=100" > "$RUNNER_TEMP/macmtp-cleanup.json"
    python3 - "$RUNNER_TEMP/macmtp-cleanup.json" "$version" "$release_id" <<'PY' > "$RUNNER_TEMP/macmtp-orphans"
import json, pathlib, sys
for item in json.loads(pathlib.Path(sys.argv[1]).read_text()):
    if (str(item["id"]) != sys.argv[3] and item["draft"] and item["name"] == "MacMTP " + sys.argv[2]
            and item["tag_name"].startswith("untagged-")):
        print(item["id"])
PY
    while IFS= read -r orphan; do
      [[ "$orphan" =~ ^[0-9]+$ ]]
      gh api --method DELETE "repos/$repo/releases/$orphan"
    done < "$RUNNER_TEMP/macmtp-orphans"
    echo "Published https://github.com/$repo/releases/tag/$tag"
    exit 0
  fi
  sleep 2
done
echo "Release assets could not be verified; the release remains a draft." >&2
exit 1
