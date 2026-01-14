#!/bin/sh
set -eu

tag="${GITHUB_REF_NAME:-}"
if [ -z "$tag" ]; then
  echo "GITHUB_REF_NAME not set" >&2
  exit 1
fi

version="${tag#v}"
meta_file="extension/extension.toml"

id=$(sed -n 's/^id = "\([^"]*\)"/\1/p' "$meta_file" | head -n 1)
if [ "$id" != "banjo-acp" ]; then
  echo "extension.toml id $id must be banjo-acp" >&2
  exit 1
fi

toml_version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$meta_file" | head -n 1)
if [ "$toml_version" != "$version" ]; then
  echo "extension.toml version $toml_version does not match tag $version" >&2
  exit 1
fi

if ! grep -q "/releases/download/v${version}/" "$meta_file"; then
  echo "extension.toml archive URLs must reference v${version}" >&2
  exit 1
fi

ext_dir=$(mktemp -d /tmp/banjo-extensions-XXXXXX)
trap 'rm -rf "$ext_dir"' EXIT

git clone --depth 1 https://github.com/zed-industries/extensions "$ext_dir/extensions" >/dev/null 2>&1

ext_toml="$ext_dir/extensions/extensions.toml"
ext_version=$(awk '
  /^\[banjo\]$/ {in_section=1; next}
  in_section && /^version =/ {gsub(/"/, "", $3); print $3; exit}
  in_section && /^\[/ {exit}
' "$ext_toml")

if [ -z "$ext_version" ]; then
  echo "banjo entry not found in zed extensions.toml" >&2
  exit 1
fi

if [ "$ext_version" != "$version" ]; then
  echo "zed extensions.toml version $ext_version does not match $version" >&2
  exit 1
fi

ext_sha=$(git -C "$ext_dir/extensions" ls-tree HEAD extensions/banjo | awk '{print $3}')
cur_sha=$(git rev-parse HEAD)

if [ -z "$ext_sha" ]; then
  echo "zed extensions repo missing extensions/banjo submodule" >&2
  exit 1
fi

if [ "$ext_sha" != "$cur_sha" ]; then
  echo "zed extensions submodule $ext_sha does not match $cur_sha" >&2
  exit 1
fi
