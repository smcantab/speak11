#!/bin/bash
# ── Speak11 release helper ──────────────────────────────────────────
# Usage: bash release.sh <version>    (e.g. bash release.sh 1.1.0)
#
# Creates (or updates) a GitHub release from CHANGELOG.md.
# The CHANGELOG is the single source of truth for release notes.
#
# Steps:
#   1. Extracts the section for the given version from CHANGELOG.md
#   2. Appends a standard GitHub footer
#   3. Builds a zip from HEAD via git archive
#   4. Creates a draft release (or updates if it already exists)
#
# Publish manually: gh release edit v<version> --draft=false

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: bash release.sh <version>" >&2
    echo "Example: bash release.sh 1.1.0" >&2
    exit 1
fi

TAG="v$VERSION"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGELOG="$SCRIPT_DIR/CHANGELOG.md"

if [ ! -f "$CHANGELOG" ]; then
    echo "Error: CHANGELOG.md not found at $CHANGELOG" >&2
    exit 1
fi

# ── Extract release notes from CHANGELOG.md ──────────────────────────
# Grab everything between "## v<version>" and the next "## v" heading.
NOTES=$(awk -v ver="## v$VERSION" '
    $0 == ver { found=1; next }
    found && /^## v/ { exit }
    found { print }
' "$CHANGELOG")

if [ -z "$NOTES" ]; then
    echo "Error: no section found for v$VERSION in CHANGELOG.md" >&2
    exit 1
fi

# Trim leading/trailing blank lines (awk for macOS portability)
NOTES=$(echo "$NOTES" | awk 'NF{p=1} p{lines[++n]=$0} END{while(n>0&&lines[n]=="")n--;for(i=1;i<=n;i++)print lines[i]}')

# Append GitHub-specific footer
NOTES="$NOTES

---

**Getting started:** download \`speak11.zip\`, unzip, and double-click \`install.command\`.

See the [README](https://github.com/smcantab/speak11#readme) for full documentation."

# ── Build zip ────────────────────────────────────────────────────────
ZIP=$(mktemp "${TMPDIR:-/tmp/}speak11_XXXXXXXXXX")
mv "$ZIP" "$ZIP.zip"
ZIP="$ZIP.zip"
git -C "$SCRIPT_DIR" archive --format=zip --prefix=speak11/ HEAD -o "$ZIP"

# ── Create or update release ─────────────────────────────────────────
if gh release view "$TAG" &>/dev/null; then
    echo "Updating existing release $TAG..."
    gh release edit "$TAG" --title "Speak11 $TAG" --notes "$NOTES"
    gh release delete-asset "$TAG" speak11.zip --yes 2>/dev/null || true
    gh release upload "$TAG" "$ZIP#speak11.zip"
else
    echo "Creating draft release $TAG..."
    gh release create "$TAG" "$ZIP#speak11.zip" \
        --title "Speak11 $TAG" \
        --draft \
        --notes "$NOTES"
fi

rm -f "$ZIP"

echo ""
echo "Release $TAG ready."
echo "To publish: gh release edit $TAG --draft=false"
