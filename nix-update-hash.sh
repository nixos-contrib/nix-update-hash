#!/usr/bin/env bash
# Repairs the fixed-output hashes a dependency bump leaves stale -- vendorHash,
# cargoHash, npmDepsHash, or any other -- and optionally commits and pushes
# the result.
#
# It builds the installables and, for every "hash mismatch in fixed-output
# derivation" error, writes the hash Nix got over the one it was given, in
# whichever .nix file under the working directory holds it. The hash is found
# by value rather than by attribute name, so no per-repository configuration
# is needed. Anything else that breaks the build fails the run.
#
# Kept to bash 3.2, the /bin/bash macOS runners ship.
#
# Environment:
#   INSTALLABLES    Space- or newline-separated flake installables to build.
#   COMMIT          "true" to commit and push the updated files.
#   COMMIT_MESSAGE  Message of that commit.
#   AUTHOR_NAME     Author and committer name of that commit.
#   AUTHOR_EMAIL    Author and committer email of that commit.

set -euo pipefail

INSTALLABLES=${INSTALLABLES:-.#default}
COMMIT=${COMMIT:-true}
COMMIT_MESSAGE=${COMMIT_MESSAGE:-chore(nix): update dependency hash}
AUTHOR_NAME=${AUTHOR_NAME:-github-actions[bot]}
AUTHOR_EMAIL=${AUTHOR_EMAIL:-41898283+github-actions[bot]@users.noreply.github.com}

# A stale hash surfaces one derivation at a time when one fixed-output
# derivation only becomes reachable once another one builds, so the build is
# retried after each round of updates. Each round fixes at least one hash, so
# this only bounds a chain of them.
ATTEMPTS=5

# Word-split on purpose: the input is a whitespace-separated list.
# shellcheck disable=SC2206
installables=($INSTALLABLES)
updated_files=""

nix_command() {
  nix --extra-experimental-features 'nix-command flakes' "$@"
}

# Prints "<specified> <got>" for each hash mismatch in a build log.
hash_mismatches() {
  awk '
    /specified:/ { specified = $NF }
    /got:/ && specified != "" { print specified, $NF; specified = "" }
  ' | sort -u
}

# Prints a hash in the given encoding: "sri", "nix32", "base16" or "base64".
hash_encode() {
  local hash=$1 encoding=$2
  nix_command hash convert --hash-algo "${hash%%-*}" --to "$encoding" "$hash"
}

# Counts the occurrences of a literal string across the .nix files.
occurrences() {
  { grep -roF --include='*.nix' -- "$1" . || true; } | wc -l | tr -d ' '
}

# Writes the got hash over the specified one, in the encoding the file uses.
update_hash() {
  local specified=$1 got=$2 encoding found="" count

  # Nix reports SRI, but a file may still hold an older encoding.
  for encoding in sri nix32 base16 base64; do
    if [ "$encoding" = sri ]; then
      found=$specified
    else
      found=$(hash_encode "$specified" "$encoding" 2>/dev/null) || continue
    fi

    count=$(occurrences "$found")
    if [ "$count" -gt 1 ]; then
      echo "::error::$specified appears $count times under $(pwd), so it is unclear which derivation it belongs to. Give each fixed-output derivation its own placeholder hash."
      return 1
    fi
    [ "$count" -eq 1 ] && break
    found=""
  done

  if [ -z "$found" ]; then
    echo "::error::Nix expected $specified, but no .nix file under $(pwd) contains it. It may be computed rather than written out, or belong to another flake input."
    return 1
  fi

  local replacement=$got
  if [ "$encoding" != sri ]; then
    replacement=$(hash_encode "$got" "$encoding")
  fi

  local file
  file=$(grep -rlF --include='*.nix' -- "$found" . | sed 's|^\./||')
  OLD=$found NEW=$replacement perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
  echo "::notice file=$file::Updated $found to $replacement"

  case " $updated_files " in
    *" $file "*) ;;
    *) updated_files="${updated_files:+$updated_files }$file" ;;
  esac
}

attempt=1
while :; do
  echo "::group::nix build ${installables[*]} (attempt $attempt)"
  if log=$(nix_command build --no-link --keep-going "${installables[@]}" 2>&1); then
    printf '%s\n' "$log"
    echo "::endgroup::"
    break
  fi
  printf '%s\n' "$log"
  echo "::endgroup::"

  mismatches=$(printf '%s\n' "$log" | hash_mismatches)
  if [ -z "$mismatches" ]; then
    echo "::error::The build failed for a reason other than a stale hash."
    exit 1
  fi
  if [ "$attempt" -ge "$ATTEMPTS" ]; then
    echo "::error::Hashes were still stale after $ATTEMPTS builds."
    exit 1
  fi

  while read -r specified got; do
    update_hash "$specified" "$got"
  done <<EOF
$mismatches
EOF

  attempt=$((attempt + 1))
done

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "updated=$([ -n "$updated_files" ] && echo true || echo false)" >>"$GITHUB_OUTPUT"
  echo "files=$updated_files" >>"$GITHUB_OUTPUT"
fi

if [ -z "$updated_files" ]; then
  echo "Every hash is up to date."
  exit 0
fi

if [ "$COMMIT" != true ]; then
  exit 0
fi

if ! branch=$(git symbolic-ref --quiet --short HEAD); then
  echo "::error::HEAD is detached, so there is no branch to push to. Check out the pull request branch, e.g. actions/checkout with ref: \${{ github.head_ref }}."
  exit 1
fi

# Word-split on purpose: the list holds paths without spaces, as written above.
# shellcheck disable=SC2086
git add -- $updated_files
git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" commit --quiet --message "$COMMIT_MESSAGE"
git push --quiet origin "HEAD:refs/heads/$branch"
echo "Pushed $(git rev-parse --short HEAD) to $branch."
