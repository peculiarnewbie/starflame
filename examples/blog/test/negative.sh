#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
examples="$(cd "$here/../.." && pwd)"
status=0

for source in "$here"/../negative/*.gleam; do
  name="$(basename "$source" .gleam)"
  scratch="$examples/.blog-negative-$name"
  rm -rf "$scratch"
  mkdir -p "$scratch/src/blog" "$scratch/build"
  cp "$here/../gleam.toml" "$scratch/gleam.toml"
  cp "$here/../manifest.toml" "$scratch/manifest.toml"
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
  rm -rf "$scratch"
done

exit "$status"
