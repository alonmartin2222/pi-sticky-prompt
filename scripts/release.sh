#!/usr/bin/env bash
#
# One-shot local release script for pi-sticky-prompt.
#
# Usage:
#     scripts/release.sh                 # patch bump (0.1.2 -> 0.1.3)
#     scripts/release.sh minor           # 0.1.2 -> 0.2.0
#     scripts/release.sh major           # 0.1.2 -> 1.0.0
#     scripts/release.sh 0.4.7           # explicit version
#
# What it does, in order:
#   1. Preflight: clean tree, on main, in sync with origin, tools present.
#   2. npm version <bump> — bumps package.json, creates a commit + tag.
#   3. Builds the macOS HUD via make-app.sh release.
#   4. Stamps the new version into Info.plist and re-codesigns ad-hoc.
#   5. ditto-zips PiStickyPrompt.app and computes a sha256.
#   6. Pushes main + the new tag to origin.
#   7. Creates a GitHub release and attaches PiStickyPrompt.app.zip
#      (uses `gh release create`).
#   8. Updates the Homebrew cask in the sibling tap repo (version + sha256),
#      commits and pushes.
#   9. Runs `npm publish` — prompts interactively for your 2FA OTP.
#
# Prerequisites (one-time setup):
#   - npm login   (authenticated as alonmartin2222)
#   - gh auth login   (authenticated as alonmartin2222) — see notes below
#   - tap repo cloned at ~/git/pi-extensions/homebrew-pi
#
# gh CLI auth note:
#   If `gh api user --jq .login` doesn't print 'alonmartin2222', either
#   re-run `gh auth login` and pick that account, or drop a personal access
#   token (Contents: write on both repos) at:
#       ~/.config/pi-sticky-prompt/github-token
#   The script will pick it up automatically.

set -euo pipefail

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
REPO_SLUG="alonmartin2222/pi-sticky-prompt"
EXPECTED_OWNER="${REPO_SLUG%%/*}"
TAP_LOCAL="${HOME}/git/pi-extensions/homebrew-pi"
CASK_PATH="Casks/pi-sticky-prompt.rb"
TOKEN_FILE="${HOME}/.config/pi-sticky-prompt/github-token"
COMMIT_AUTHOR_NAME="Alon Martin"
COMMIT_AUTHOR_EMAIL="alonmartin2222@users.noreply.github.com"

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
step()  { printf "\033[1;34m==>\033[0m \033[1m%s\033[0m\n" "$*"; }
ok()    { printf "    \033[1;32m✓\033[0m %s\n" "$*"; }
warn()  { printf "    \033[1;33m!\033[0m %s\n" "$*"; }
die()   { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Recovery on failure
# -----------------------------------------------------------------------------
STATE_TAG=""
STATE_GH_RELEASE=0
STATE_NPM=0

on_error() {
    local code=$?
    echo
    printf "\033[1;31m✗ release failed (exit %d)\033[0m\n" "$code" >&2
    if [[ -n "$STATE_TAG" ]]; then
        echo "Recovery hints:" >&2
        echo "  - The bump commit + tag $STATE_TAG exist locally." >&2
        echo "  - Inspect with:  git log --oneline -3 && git tag --list 'v*' | tail" >&2
        echo "  - To undo everything before pushing:" >&2
        echo "      git reset --hard HEAD~1 && git tag -d $STATE_TAG" >&2
        if [[ $STATE_GH_RELEASE -eq 0 ]]; then
            echo "  - GitHub release was NOT created — safe to retry." >&2
        else
            echo "  - GitHub release was created. Delete with:" >&2
            echo "      gh release delete $STATE_TAG --repo $REPO_SLUG" >&2
        fi
        if [[ $STATE_NPM -eq 0 ]]; then
            echo "  - npm publish did NOT run — retry with:  npm publish" >&2
        fi
    fi
    exit "$code"
}
trap on_error ERR

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
BUMP="${1:-patch}"

step "Preflight checks"

# tools
for tool in npm node swift git gh shasum ditto codesign /usr/libexec/PlistBuddy; do
    command -v "$tool" >/dev/null 2>&1 || [[ -x "$tool" ]] \
        || die "missing required tool: $tool"
done
ok "tools available"

# clean working tree
[[ -z "$(git status --porcelain)" ]] \
    || { git status --short; die "working tree is dirty — commit or stash first"; }
ok "working tree clean"

# on main
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[[ "$BRANCH" == "main" ]] || die "not on main (currently on '$BRANCH')"
ok "on main"

# in sync with origin
git fetch origin --quiet --tags
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse '@{u}')
[[ "$LOCAL" == "$REMOTE" ]] || die "local main is not in sync with origin/main"
ok "in sync with origin/main"

# gh auth
if [[ -f "$TOKEN_FILE" ]]; then
    export GH_TOKEN
    GH_TOKEN="$(cat "$TOKEN_FILE")"
    ok "using GH token from $TOKEN_FILE"
fi
LOGIN=$(gh api user --jq .login 2>/dev/null || echo "")
[[ "$LOGIN" == "$EXPECTED_OWNER" ]] \
    || die "gh CLI is authenticated as '$LOGIN', expected '$EXPECTED_OWNER'.
  Fix one of:
    a) gh auth login   (and pick the $EXPECTED_OWNER account)
    b) drop a PAT at:  $TOKEN_FILE"
ok "gh auth as $LOGIN"

# npm auth
NPM_USER=$(npm whoami 2>/dev/null || echo "")
[[ "$NPM_USER" == "$EXPECTED_OWNER" ]] \
    || die "npm CLI is authenticated as '$NPM_USER', expected '$EXPECTED_OWNER'.
  Run 'npm login' and use the $EXPECTED_OWNER account."
ok "npm auth as $NPM_USER"

# tap repo
[[ -d "$TAP_LOCAL/.git" ]] \
    || die "Homebrew tap repo not found at $TAP_LOCAL
  Clone it first:  git clone git@github-personal:$EXPECTED_OWNER/homebrew-pi.git $TAP_LOCAL"
ok "tap repo present at $TAP_LOCAL"

# -----------------------------------------------------------------------------
# Bump version
# -----------------------------------------------------------------------------
step "Bumping version ($BUMP)"

# Make sure npm version doesn't try to GPG-sign and uses our committer.
git config commit.gpgsign false
git config tag.gpgsign    false
git config user.name      "$COMMIT_AUTHOR_NAME"
git config user.email     "$COMMIT_AUTHOR_EMAIL"

NEW_TAG=$(npm version "$BUMP" -m "chore(release): %s")
NEW_VERSION="${NEW_TAG#v}"
STATE_TAG="$NEW_TAG"
ok "new version: $NEW_VERSION (tag $NEW_TAG)"

# -----------------------------------------------------------------------------
# Build .app
# -----------------------------------------------------------------------------
step "Building macOS HUD"
( cd PiStickyPrompt && ./make-app.sh release .. >/dev/null )
ok "built PiStickyPrompt.app"

step "Stamping Info.plist with $NEW_VERSION"
PLIST="PiStickyPrompt.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_VERSION"            "$PLIST"
codesign --force --deep --sign - PiStickyPrompt.app >/dev/null 2>&1
ok "Info.plist stamped + re-codesigned"

# -----------------------------------------------------------------------------
# Zip + sha
# -----------------------------------------------------------------------------
step "Packaging PiStickyPrompt.app.zip"
rm -f PiStickyPrompt.app.zip
ditto -c -k --keepParent --rsrc --sequesterRsrc PiStickyPrompt.app PiStickyPrompt.app.zip
SHA256=$(shasum -a 256 PiStickyPrompt.app.zip | awk '{print $1}')
ZIP_SIZE=$(ls -lh PiStickyPrompt.app.zip | awk '{print $5}')
ok "zip: $ZIP_SIZE  sha256: $SHA256"

# -----------------------------------------------------------------------------
# Push commit + tag
# -----------------------------------------------------------------------------
step "Pushing main + tag $NEW_TAG"
git push origin main
git push origin "$NEW_TAG"
ok "pushed"

# -----------------------------------------------------------------------------
# GitHub release
# -----------------------------------------------------------------------------
step "Creating GitHub release $NEW_TAG"
NOTES_FILE=$(mktemp)
trap 'rm -f "$NOTES_FILE"' EXIT
{
    echo "Release $NEW_VERSION"
    echo
    echo "## Changes"
    echo
    PREV_TAG=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
               | sed -n '2p')
    if [[ -n "$PREV_TAG" ]]; then
        git log "$PREV_TAG..HEAD" --pretty='- %s' --no-merges
    else
        git log --pretty='- %s' --no-merges -20
    fi
} > "$NOTES_FILE"

gh release create "$NEW_TAG" \
    ./PiStickyPrompt.app.zip \
    --repo "$REPO_SLUG" \
    --title "$NEW_TAG" \
    --notes-file "$NOTES_FILE"
STATE_GH_RELEASE=1
ok "release created"

# -----------------------------------------------------------------------------
# Homebrew tap bump
# -----------------------------------------------------------------------------
step "Bumping Homebrew cask in $TAP_LOCAL"
(
    cd "$TAP_LOCAL"
    git fetch origin --quiet
    git checkout main --quiet
    git pull --quiet --ff-only
    sed -i '' "s|version \".*\"|version \"$NEW_VERSION\"|" "$CASK_PATH"
    sed -i '' "s|sha256 \".*\"|sha256 \"$SHA256\"|"        "$CASK_PATH"
    if [[ -z "$(git status --porcelain)" ]]; then
        warn "cask already at $NEW_VERSION/$SHA256 — nothing to commit"
    else
        git -c commit.gpgsign=false \
            -c user.name="$COMMIT_AUTHOR_NAME" \
            -c user.email="$COMMIT_AUTHOR_EMAIL" \
            commit -am "fix(pi-sticky-prompt): bump to $NEW_VERSION"
        git push origin main
    fi
)
ok "cask bumped"

# -----------------------------------------------------------------------------
# npm publish (interactive 2FA prompt happens here)
# -----------------------------------------------------------------------------
step "Publishing to npm — paste your 2FA OTP at the prompt"
npm publish
STATE_NPM=1
ok "published to npm"

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo
echo "🎉  Released $NEW_TAG"
echo
echo "    GitHub:    https://github.com/$REPO_SLUG/releases/tag/$NEW_TAG"
echo "    npm:       https://www.npmjs.com/package/pi-sticky-prompt/v/$NEW_VERSION"
echo "    Homebrew:  https://github.com/$EXPECTED_OWNER/homebrew-pi/blob/main/$CASK_PATH"
echo
echo "    End users upgrade with:"
echo "      brew upgrade --cask pi-sticky-prompt && pi install npm:pi-sticky-prompt@latest"
