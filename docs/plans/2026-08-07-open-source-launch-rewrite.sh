#!/usr/bin/env bash
# Produce the public Antgrid history from the private repo.
#   - truncate to the last month (single root)
#   - strip every commit-message body (subject line only)
#   - purge *.md from all history, then restore the wanted ones in one commit
# Non-destructive: reads the remote, writes only into $OUT.
set -euo pipefail

SRC_URL="https://github.com/antgrid-ai/antgrid.git"
CUT=01cb42e420402404cda7d6a85ec371d3e29c6309   # 2026-07-22, the cutoff
GRAFT2=8bdcacbfc7f1e2d11874c12ae7983afece68b2d7 # second entry point into the window
FR="/c/Users/Admin/AppData/Roaming/Python/Python314/Scripts/git-filter-repo.exe"
OUT="${1:?usage: rewrite.sh <outdir>}"

rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT"

echo "==> bare clone (heads + tags only; refs/pull is never fetched)"
git clone --bare -q "$SRC_URL" mirror.git
cd mirror.git

echo "==> save the .md tree we want back at HEAD"
git ls-tree -r --name-only development | grep -i '\.md$' > ../md-list.txt
git archive development -- $(tr '\n' ' ' < ../md-list.txt) > ../md-at-head.tar
# *.md symlinks (the six AGENTS.md) cannot be extracted by tar on Windows, so
# record path+target and re-add them through the index instead.
git ls-tree -r development | awk '$1=="120000"' | while read mode type sha path; do
  printf '%s\t%s\n' "$path" "$(git cat-file blob $sha)"
done | grep -i 'md' > ../md-symlinks.txt || true

echo "==> prune refs: development only, drop tags outside the window"
for b in $(git for-each-ref --format='%(refname:short)' refs/heads | grep -vx development); do
  git branch -D "$b" -q
done
git rev-list development --not "$CUT" > ../keep.txt
for t in $(git for-each-ref --format='%(refname:short)' refs/tags); do
  target=$(git rev-list -1 "$t")
  grep -qx "$target" ../keep.txt || { git tag -d "$t" >/dev/null; echo "   dropped tag $t"; }
done

echo "==> graft: make the cutoff a root, reparent the second entry point onto it"
git replace --graft "$CUT"
git replace --graft "$GRAFT2" "$CUT"

echo "==> filter-repo: purge *.md, strip message bodies, bake the grafts"
"$FR" --force \
  --path-glob '*.md' --invert-paths \
  --message-callback 'return message.split(bytes([10]))[0]' \
  --replace-refs delete-no-add

echo "==> restore documentation in one commit"
cd "$OUT"
git clone -q mirror.git antgrid-public
cd antgrid-public
tar xf ../md-at-head.tar 2>/dev/null || true   # symlink entries fail on Windows; handled below
rm -rf docs/competitive docs/lunel-comparison.md \n       docs/plans/2026-08-07-open-source-launch.md \n       docs/plans/2026-08-07-open-source-launch-rewrite.sh
git add -A
while IFS=$'	' read -r path target; do
  [ -n "$path" ] || continue
  rm -f "$path"
  sha=$(printf '%s' "$target" | git hash-object -w --stdin)
  git update-index --add --cacheinfo 120000,"$sha","$path"
  echo "   symlink $path -> $target"
done < ../md-symlinks.txt
git -c user.name='Bharath Mohan' -c user.email='bharath.m03@gmail.com' \
    commit -q -m 'docs: restore documentation'
echo "==> done: $OUT/antgrid-public"
