#!/bin/zsh
# Regenerates the AppIcon set, the title-bar mark and the alternate Dock icon
# from design/*.svg.
set -euo pipefail
cd "${0:A:h}/.."
ICONSET=SkillsBuddy/Resources/Assets.xcassets/AppIcon.appiconset
MARK=SkillsBuddy/Resources/Assets.xcassets/AppMark.imageset
mkdir -p "$ICONSET" "$MARK"
for pixels in 16 32 64 128 256 512 1024; do
  swift scripts/render-svg.swift design/app-icon.svg "$ICONSET/icon-$pixels.png" "$pixels"
done
cp design/app-mark.svg "$MARK/app-mark.svg"
# The Dock icon offered in Settings › Appearance › Advanced.
DOCK=SkillsBuddy/Resources/Assets.xcassets/DockIconMidnight.imageset
mkdir -p "$DOCK"
swift scripts/render-svg.swift design/app-icon-midnight.svg "$DOCK/dock-icon-midnight.png" 1024
