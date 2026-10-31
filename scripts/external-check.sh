#!/usr/bin/env bash
# Consume the current package sources outside the workspace. Snapshot them into
# a temporary Git repository so local edits, as well as commits in CI, are tested.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
snapshot="$dir/framework"
app="$dir/app"
mkdir -p "$snapshot" "$app"
tar -C "$root" --exclude=node_modules --exclude=build --exclude=dist \
  -cf - packages/starflame packages/rpc/kit | tar -C "$snapshot" -xf -
git -C "$snapshot" init --quiet
git -C "$snapshot" add .
git -C "$snapshot" -c user.name=Starflame -c user.email=external-check@example.invalid \
  -c commit.gpgsign=false commit --quiet -m "Package sources under test"
sha="$(git -C "$snapshot" rev-parse HEAD)"
cp -R "$root/scripts/fixtures/external/." "$app/"

cat > "$app/gleam.toml" <<EOF
name = "starflame_external_check"
version = "0.1.0"
target = "javascript"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_javascript = ">= 1.0.0 and < 2.0.0"
starflame = { git = "file://$snapshot", ref = "$sha", path = "packages/starflame" }

[dev-dependencies]
starflame_rpc_kit = { git = "file://$snapshot", ref = "$sha", path = "packages/rpc/kit" }

[starflame]
codecs = ["ext/shared:ext/codecs"]
EOF

# Install the same files that the Vite package would publish, without workspace
# links or dependency lookup into this checkout.
pnpm --dir "$root/packages/vite" pack --pack-destination "$dir"
for archive in "$dir"/*.tgz; do break; done
cat > "$app/package.json" <<EOF
{
  "name": "starflame-external-check",
  "private": true,
  "type": "module",
  "dependencies": {
    "@starflame/vite": "file:$archive",
    "capnweb": "0.12.0"
  },
  "devDependencies": {
    "esbuild": "0.28.2",
    "miniflare": "5.20261001.0-alpha",
    "vite": "8.3.2"
  }
}
EOF
cat > "$app/pnpm-workspace.yaml" <<'EOF'
allowBuilds:
  esbuild: true
  workerd: true
EOF

cd "$app"
pnpm install --no-frozen-lockfile
gleam run -m starflame_rpc_kit -- generate --api ext/api --out ext/generated
gleam run -m starflame_rpc_kit -- codecs
gleam check
pnpm exec vite build
node verify.mjs

echo "external consumer check passed"
