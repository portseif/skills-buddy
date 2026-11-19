#!/bin/zsh
# Builds Skills Buddy for Apple silicon and Intel, signs it with a Developer ID,
# notarizes and staples it, packs it in a zip and a disk image (signed, notarized
# and stapled too), and publishes both as a GitHub release tagged with the app's
# MARKETING_VERSION.
#
#   scripts/release.sh notes.md       publish with these release notes
#   scripts/release.sh                leave a draft release to write notes on GitHub
#   scripts/release.sh --no-publish   build, sign and notarize only
#
# Needs a Developer ID Application certificate in your keychain and a notarytool
# profile saved with `xcrun notarytool store-credentials <profile> ...`.
# SIGNING_IDENTITY and NOTARY_PROFILE override the defaults below.
set -euo pipefail
cd "${0:A:h}/.."

signing_identity=${SIGNING_IDENTITY:-"Developer ID Application"}
notary_profile=${NOTARY_PROFILE:-notarytool}

fail() { print -u2 "release: $*"; exit 1 }
step() { print "\n==> $*" }

publish=true
notes_file=""
for argument in "$@"; do
  case $argument in
    --no-publish) publish=false ;;
    -*) fail "unknown option $argument" ;;
    *) notes_file=$argument ;;
  esac
done
[[ -z $notes_file || -f $notes_file ]] || fail "no notes file at $notes_file"

version=$(xcodebuild -project SkillsBuddy.xcodeproj -scheme SkillsBuddy -configuration Release -showBuildSettings 2>/dev/null \
  | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
[[ -n $version ]] || fail "couldn't read MARKETING_VERSION from the project"

if $publish; then
  [[ -z $(git status --porcelain) ]] || fail "commit or stash your changes first"
  git fetch --quiet origin
  [[ $(git rev-parse HEAD) == $(git rev-parse '@{upstream}') ]] || fail "push first: HEAD doesn't match its upstream branch"
  if git ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null; then
    fail "$version is already released; bump MARKETING_VERSION in project.yml and run xcodegen generate"
  fi
fi

derived_data=.build/Release
release_folder=.build/release/$version
app_name="Skills Buddy.app"
app_path=$release_folder/$app_name
zip_path=$release_folder/Skills-Buddy-$version.zip
dmg_path=$release_folder/Skills-Buddy-$version.dmg

# Submits a zip or disk image and waits; fails with the log command if Apple
# doesn't accept it.
notarize() {
  local result notary_status submission_id
  result=$(xcrun notarytool submit "$1" --keychain-profile "$notary_profile" --wait --output-format json) || true
  notary_status=$(plutil -extract status raw -o - - <<< "$result" 2>/dev/null) || true
  if [[ $notary_status != Accepted ]]; then
    submission_id=$(plutil -extract id raw -o - - <<< "$result" 2>/dev/null) || true
    fail "notarization of ${1:t} ${notary_status:-failed}${submission_id:+, see xcrun notarytool log $submission_id --keychain-profile $notary_profile}"
  fi
}

# Attaches the ticket. The ticket server can time out right after notarization
# (stapler's error 68), so try a few times before giving up.
staple() {
  local attempt
  for attempt in 1 2 3 4; do
    xcrun stapler staple "$1" && return
    (( attempt < 4 )) && { print "stapling ${1:t} failed, retrying in 20s"; sleep 20 }
  done
  fail "couldn't staple ${1:t}"
}

step "Building Skills Buddy $version"
xcodebuild -project SkillsBuddy.xcodeproj -scheme SkillsBuddy -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived_data" ONLY_ACTIVE_ARCH=NO -quiet build
rm -rf "${release_folder:?}"
mkdir -p "$release_folder"
ditto "$derived_data/Build/Products/Release/$app_name" "$app_path"

# Re-signing swaps Xcode's ad-hoc signature for the Developer ID one, with the
# hardened runtime and secure timestamp notarization requires. It also drops the
# get-task-allow entitlement the ad-hoc build carries, which notarization rejects.
step "Signing with $signing_identity"
codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_path"
codesign --verify --strict --deep "$app_path"

step "Notarizing (usually a few minutes)"
ditto -c -k --keepParent "$app_path" "$zip_path"
notarize "$zip_path"

# Stapling puts the ticket in the app, so it opens offline; zip it again after.
step "Stapling"
staple "$app_path"
rm "$zip_path"
ditto -c -k --keepParent "$app_path" "$zip_path"
spctl --assess --type execute "$app_path" || fail "Gatekeeper rejected the stapled app"

# The disk image holds the stapled app and a link to Applications to drag it
# onto. Apple's steps: a read-only zlib image (UDZO), signed with the Developer ID
# under its own identifier, then notarized and stapled itself.
step "Making the disk image"
dmg_folder=$release_folder/dmg
mkdir -p "$dmg_folder"
ditto "$app_path" "$dmg_folder/$app_name"
ln -s /Applications "$dmg_folder/Applications"
hdiutil create -volname "Skills Buddy" -srcfolder "$dmg_folder" -format UDZO -ov -quiet "$dmg_path"
rm -rf "$dmg_folder"
bundle_identifier=$(plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist")
codesign --sign "$signing_identity" --timestamp --identifier "$bundle_identifier.dmg" "$dmg_path"
hdiutil verify -quiet "$dmg_path"

step "Notarizing the disk image"
notarize "$dmg_path"
staple "$dmg_path"
spctl --assess --type open --context context:primary-signature "$dmg_path" || fail "Gatekeeper rejected the disk image"

if ! $publish; then
  print "\nBuilt $zip_path and $dmg_path (not published)"
  exit 0
fi

step "Publishing $version on GitHub"
release_options=(--target "$(git rev-parse HEAD)" --title "Skills Buddy $version")
if [[ -n $notes_file ]]; then
  release_options+=(--notes-file "$notes_file")
else
  release_options+=(--draft --generate-notes)
fi
gh release create "$version" "$zip_path" "$dmg_path" "${release_options[@]}"
