#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h}
source_dir="$repo_root/src"
destination=${1:-"$repo_root/dist/Codex SubRouter.app"}
build_arch=${BUILD_ARCH:-$(uname -m)}
case "$build_arch" in
  arm64|x86_64) ;;
  *) print -u2 "Unsupported BUILD_ARCH: $build_arch"; exit 1 ;;
esac
temp_root=${TMPDIR:-/tmp}
build_temp=$(mktemp -d "${temp_root%/}/codex-provider-build.XXXXXX")
trap 'rm -rf "$build_temp"' EXIT
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources"
xcrun swiftc -swift-version 5 -target "$build_arch-apple-macos14.0" -O \
  -module-cache-path "$build_temp/modules" -debug-prefix-map "$repo_root=." -framework AppKit \
  "$source_dir/Core.swift" "$source_dir/Settings.swift" "$source_dir/HostDiscovery.swift" \
  "$source_dir/App.swift" "$source_dir/Tests.swift" \
  -o "$destination/Contents/MacOS/CodexSubRouter"
cp "$source_dir/Info.plist" "$destination/Contents/Info.plist"
if [[ -n ${APP_BUNDLE_ID:-} ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$destination/Contents/Info.plist"
fi
xcrun swift -module-cache-path "$build_temp/modules" "$source_dir/Icon.swift" "$build_temp/AppIcon.iconset" "$destination/Contents/Resources/AppIcon.icns"
xattr -cr "$destination"
codesign --force --sign - --options runtime --timestamp=none "$destination"
if [[ "$build_arch" == $(uname -m) ]]; then
  "$destination/Contents/MacOS/CodexSubRouter" --self-test
else
  print "Cross-compiled $build_arch; run --self-test on a matching Mac before releasing it."
fi
codesign --verify --deep --strict "$destination"
print "Built: $destination"
