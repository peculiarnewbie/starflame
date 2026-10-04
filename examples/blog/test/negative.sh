#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
packages="$(cd "$here/../../../packages" && pwd)"
scratch_root="$(mktemp -d)"
trap 'rm -rf "$scratch_root"' EXIT
status=0

for source in "$here"/../negative/*.gleam; do
  name="$(basename "$source" .gleam)"
  scratch="$scratch_root/$name"
  mkdir -p "$scratch/src/blog" "$scratch/build"
  # Outside the repo, the relative path dependencies need to be absolute.
  sed "s|\"../../packages|\"$packages|" "$here/../gleam.toml" >"$scratch/gleam.toml"
  sed "s|\"../../packages|\"$packages|" "$here/../manifest.toml" >"$scratch/manifest.toml"
  cp -R "$here/../src/." "$scratch/src/"
  cp -R "$here/../build/packages" "$scratch/build/packages"
  cp "$source" "$scratch/src/blog/negative_$name.gleam"

  case "$name" in
    missing_required_field) expected="display_name" ;;
    wrong_insert_type) expected="Expected type:" ;;
    nullable_not_optional) expected="option.Option(String)" ;;
  esac

  if output="$(cd "$scratch" && gleam build 2>&1)"; then
    code=0
  else
    code=$?
  fi
  if [ "$code" -ne 0 ] && grep -Fq "$expected" <<<"$output"; then
    echo "PASS rejected at compile time: $name"
  else
    echo "FAIL $name"
    echo "$output" | tail -20
    status=1
  fi
done

exit "$status"
