#!/bin/bash
# 打包 pageturner.koplugin：tools/package.sh [版本] [输出 zip]
# 版本不要带 v；资产名 pageturner.koplugin-<版本>.zip（旧版带 v 的也能被更新器认）。
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-dev}"
VERSION="${VERSION#v}"
OUT="${2:-dist/pageturner.koplugin-$VERSION.zip}"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R pageturner.koplugin "$STAGE/pageturner.koplugin"

# 临时副本注入版本；源码保持占位符 / 0.0.0-dev
sed -i.bak "s/@VERSION@/${VERSION}/g" "$STAGE/pageturner.koplugin/pageturner_version.lua"
sed -i.bak "s/version = \"[^\"]*\"/version = \"${VERSION}\"/" "$STAGE/pageturner.koplugin/_meta.lua"
rm -f "$STAGE/pageturner.koplugin/"*.bak "$STAGE/pageturner.koplugin/"*/*.bak 2>/dev/null || true
rm -f "$STAGE/pageturner.koplugin/pageturner_version.lua.bak" "$STAGE/pageturner.koplugin/_meta.lua.bak"

# 语法扫一眼，坏包别发出去
if command -v luajit >/dev/null 2>&1; then
    for f in "$STAGE/pageturner.koplugin"/*.lua; do
        luajit -bl "$f" >/dev/null
    done
fi

(cd "$STAGE" && zip -rqX "$OUT" pageturner.koplugin -x '*.DS_Store' '*~')
echo "$OUT"
unzip -l "$OUT" | head -30
