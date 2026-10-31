#!/usr/bin/env bash
# Builds a throwaway app outside this repository, depending on the framework by
# git at the current commit. This is the check the examples cannot give us: they
# use path dependencies inside the same workspace and are edited alongside the
# framework.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sha="$(git -C "$root" rev-parse HEAD)"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

mkdir -p "$dir/src/ext"

cat > "$dir/gleam.toml" <<EOF
name = "starflame_external_check"
version = "0.1.0"
target = "javascript"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
starflame = { git = "file://$root", ref = "$sha", path = "packages/starflame" }

[dev-dependencies]
starflame_rpc_kit = { git = "file://$root", ref = "$sha", path = "packages/rpc/kit" }

[starflame]
codecs = ["ext/shared:ext/codecs"]
EOF

cat > "$dir/src/ext/shared.gleam" <<'EOF'
pub type Note {
  Note(id: Int, body: String)
}
EOF

cat > "$dir/src/ext/app.gleam" <<'EOF'
import ext/codecs
import ext/shared.{type Note}
import gleam/dynamic.{type Dynamic}

pub fn encode(note: Note) {
  codecs.note_to_plain(note)
}

pub fn decode(value: Dynamic) {
  codecs.note_from_plain(value)
}
EOF

cd "$dir"
gleam run -m starflame_rpc_kit -- codecs
gleam build

echo "external consumer check passed"
