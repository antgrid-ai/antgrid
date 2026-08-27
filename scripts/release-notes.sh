#!/usr/bin/env bash
# Compose a release body: what shipped, then how to install it.
#
# The change list comes from GitHub's own release-notes API rather than
# `git log`, because that API lists MERGED PRS and skips direct pushes — and in
# this history the direct pushes are exactly the commits with unpublishable
# subjects ("fixes", "just comments"). Going through a PR is what earns a line
# in the notes. Nothing here rewords a title, so a vague PR title ships as a
# vague release note and has to be fixed at review time instead.
set -euo pipefail

TAG="${1:?usage: release-notes.sh <tag> <target-commitish>}"
# Mandatory, not optional: the API requires target_commitish whenever tag_name
# does not already reference an existing tag, which is every dispatch-path
# release — `gh release create` mints the tag after this has already run.
TARGET="${2:?usage: release-notes.sh <tag> <target-commitish>}"
REPO="${GH_REPO:-antgrid-ai/antgrid}"

# Diff against the previous STABLE tag: a prerelease is a preview of the next
# stable, so whatever shipped in it must appear again in the stable notes that
# follow. Resolving this is the whole job — with no previous_tag_name the API
# silently walks back to the first commit in the repo, and a hundred-item
# release body looks plausible enough to publish that nobody re-reads it.
#
# `git tag --list` exits 0 on a shallow clone — it just under-reports — so the
# missing-tags case has to be probed directly. Neither guard below can see it.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  echo "::error::shallow checkout — the tag list is incomplete, refusing to generate notes from it" >&2
  exit 1
fi
# -v:refname, not -creatordate: creatordate is the TAG's date for an annotated
# tag but the tagged COMMIT's date for a lightweight one, so a hand-pushed tag
# (which this workflow explicitly supports) sorts by an unrelated clock.
if ! merged="$(git tag --list 'v*' --merged "$TARGET" --sort=-v:refname)"; then
  echo "::error::cannot list tags merged into $TARGET — not a valid commitish?" >&2
  exit 1
fi
# -F because $TAG is a literal: its dots would otherwise match any character.
stable() { grep -v -- '-' | grep -vxF "$TAG" || true; }
prev="$(printf '%s\n' "$merged" | stable | head -1)"
if [ -z "$prev" ]; then
  # `main` and `development` are not ancestors of each other, so a release cut
  # from one cannot reach tags that live on the other. Widening to the newest
  # stable tag anywhere beats failing: this runs after the tag is pushed and the
  # whole build matrix is spent, and a too-wide range is repairable afterwards
  # with `gh release edit` where a stranded tag is not.
  prev="$(git tag --list 'v*' --sort=-v:refname | stable | head -1)"
  if [ -n "$prev" ]; then
    # stderr, like every other annotation here: stdout IS the release body.
    echo "::warning::no stable tag reachable from $TARGET — falling back to $prev" >&2
  fi
fi

# `gh api` has no --retry of its own, and this call gates a release whose
# artifacts are already built, signed and notarized — so retry rather than throw
# that away on one 5xx. Mirrors the `curl --retry 3` on the caller's appcast probe.
for attempt in 1 2 3; do
  if body="$(gh api -X POST "repos/$REPO/releases/generate-notes" \
    -f tag_name="$TAG" \
    ${prev:+-f previous_tag_name="$prev"} \
    -f target_commitish="$TARGET" \
    --jq '.body')"; then
    break
  fi
  if [ "$attempt" = 3 ]; then
    echo "::error::generate-notes failed after 3 attempts" >&2
    exit 1
  fi
  sleep $(( attempt * 5 ))
done
# `--jq` renders a null field as the literal string `null`. That and an empty
# body both reach the "no user-facing changes" fallback below, which would
# publish a confident lie over a real release — so stop here instead.
if [ -z "$body" ] || [ "$body" = null ]; then
  echo "::error::generate-notes returned an empty body" >&2
  exit 1
fi

# The trailer (New Contributors, Full Changelog) ships exactly as GitHub wrote
# it — the first-contribution credit is the point, not noise: it is what a new
# contributor looks for after a PR lands. No `|| true` on either awk: a bare
# pattern exits 0 whether or not it matches, so a non-zero status means the
# program itself is broken, and swallowing that publishes an empty changelog.
#
# `[*]` rather than `\*`: awk expands escapes when assigning -v, so a backslash
# here is consumed before the regex ever sees it (and warns while doing it).
boundary='^(## New Contributors|[*][*]Full Changelog[*][*])'
changes="$(printf '%s\n' "$body" | awk -v b="$boundary" '$0 ~ b {exit} /^\* /')"
trailer="$(printf '%s\n' "$body" | awk -v b="$boundary" '$0 ~ b {f=1} f')"

# Types that describe the pipeline, not the product. A reader of these notes
# cannot observe any of them, and they are the bulk of the merge volume. A `ci`
# SCOPE is as unobservable as a `ci` type — `fix(ci): ...` is pipeline work
# wearing a fix prefix, and it is common enough here to matter.
#
# Three deliberate omissions, each a type that LOOKS internal here and is not:
#   `revert`   — undoing a shipped change is itself a shipped change.
#   `refactor` — in this repo it labels behaviour changes, not code motion.
#                `refactor(relay,bridge): stop metering open streams as the paid
#                axis` is a BILLING change; dropping it is a silent one.
#   `!`        — Conventional Commits' breaking-change marker is not matched, so
#                `build!:` survives where `build:` does not.
#
# A scope counts as pipeline work only when EVERY component in it is. This repo
# writes comma-separated multi-scopes (`fix(relay,web)`, `refactor(bridge,app)`),
# so a bare `(ci|deps|test|docs)` alternation would both miss `fix(ci,docs)` and
# risk swallowing `fix(ci,bridge)` — a bridge fix that happens to touch CI.
#
# A title carrying no prefix at all cannot be caught here; that is what the
# `changelog-ignore` label in .github/release.yml is for.
changes="$(printf '%s\n' "$changes" | grep -Ev \
  '^\* ((ci|chore|docs|build|test|style|deps)(\([^)]*\))?|[a-z]+\(((ci|deps|test|docs),)*(ci|deps|test|docs)\)): ' || true)"

if [ -n "$changes" ]; then
  printf "## What's Changed\n\n%s\n\n" "$changes"
else
  # Worded to not contradict the trailer: GitHub's New Contributors block is
  # built from the UNFILTERED body, so it can still credit someone for the very
  # PRs this branch just filtered out. "Nothing user-facing" plus a first-time
  # contributor credit reads as a bug; "no user-facing changes" plus a pointer
  # to the full changelog does not.
  printf "## What's Changed\n\nNo user-facing changes in this build — pipeline and maintenance work only. The full changelog below lists everything that landed.\n\n"
fi

# The Store LISTING, not site/src/config.ts's get.microsoft.com installer
# handoff. Nothing pins this file to the site (contracts.spec.ts pins the site
# itself), and the site URL carries `cid=site` — reusing it here would report
# every install driven from a release page as website-driven. A release-page
# campaign id would need to be its own, not a borrowed one.
cat <<'INSTALL'
## Install

- **macOS** (antgrid-macos.dmg): signed and notarized. Open the .dmg and drag Antgrid to Applications.
- **Windows**: install from the [Microsoft Store](https://apps.microsoft.com/detail/9N0P7ZRL4D9W).
- **Linux** (antgrid-linux.AppImage): `chmod +x antgrid-linux.AppImage` then run it. Needs GTK 3 and WebKit2GTK on the host (`libgtk-3-0`, `libwebkit2gtk-4.1-0`, `libsecret-1-0`).
INSTALL

if [ -n "$trailer" ]; then
  printf '\n%s\n' "$trailer"
fi

# Provenance. The tag already pins the commit, but a build timestamp is the only
# way to tell two rebuilds of the same tag apart. Both halves or neither — a
# lone SHA renders as "Built from `abc123` at ." with a dangling preposition.
if [ -n "${RELEASE_SHA:-}" ] && [ -n "${RELEASE_BUILT:-}" ]; then
  printf '\n<sub>Built from `%s` at %s.</sub>\n' "$RELEASE_SHA" "$RELEASE_BUILT"
fi
