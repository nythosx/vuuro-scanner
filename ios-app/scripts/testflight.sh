#!/bin/bash
set -euo pipefail

SCAN_SERVICE_BASE_URL="${SCAN_SERVICE_BASE_URL:-https://scan.vuuro.com}"
build_number="${BUILD_NUMBER:-${CI_PIPELINE_IID:-}}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
keychain="$work/testflight.keychain-db"
profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
profile_uuid=""

cleanup() {
  security delete-keychain "$keychain" > /dev/null 2>&1 || true
  if [ -n "$profile_uuid" ]; then
    rm -f "$profile_dir/$profile_uuid.mobileprovision"
  fi
  rm -rf "$work"
}
trap cleanup EXIT

missing=""
for name in IOS_CERTIFICATE_P12_BASE64 IOS_CERTIFICATE_PASSWORD IOS_APPSTORE_PROFILE_BASE64 IOS_DEVELOPMENT_TEAM ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64 SCAN_SERVICE_APP_KEY; do
  if [ -z "${!name:-}" ]; then
    missing="$missing $name"
  fi
done
if [ -n "$missing" ]; then
  echo "error: the TestFlight upload needs these CI/CD variables, missing:$missing (see docs/hosting-spec.md, TestFlight step)"
  exit 1
fi
case "$build_number" in
  ''|*[!0-9.]*) echo "error: BUILD_NUMBER must be digits (and dots), got '$build_number'"; exit 1 ;;
esac
case "$SCAN_SERVICE_APP_KEY" in
  *[!A-Za-z0-9._-]*) echo "error: SCAN_SERVICE_APP_KEY may only use letters, digits, . _ - (the server generates hex)"; exit 1 ;;
esac
if [ "${#SCAN_SERVICE_APP_KEY}" -ne 64 ]; then
  echo "error: SCAN_SERVICE_APP_KEY has length ${#SCAN_SERVICE_APP_KEY}, expected 64"
  exit 1
fi

cd "$repo_root/ios-app"
command -v xcodegen > /dev/null || brew install xcodegen
xcodegen generate

keychain_password="$(openssl rand -hex 24)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
printf '%s' "$IOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$work/cert.p12"
security import "$work/cert.p12" -k "$keychain" -P "$IOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security > /dev/null
rm -f "$work/cert.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

mkdir -p "$profile_dir"
printf '%s' "$IOS_APPSTORE_PROFILE_BASE64" | base64 --decode > "$work/appstore.mobileprovision"
security cms -D -i "$work/appstore.mobileprovision" > "$work/appstore.plist"
profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$work/appstore.plist")"
if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$work/appstore.plist" > /dev/null 2>&1; then
  echo "error: IOS_APPSTORE_PROFILE_BASE64 is an ad-hoc or development profile; TestFlight needs an App Store distribution profile"
  exit 1
fi
cp "$work/appstore.mobileprovision" "$profile_dir/$profile_uuid.mobileprovision"

umask 077
{
  echo "SCAN_SERVICE_BASE_URL = $(printf '%s' "$SCAN_SERVICE_BASE_URL" | sed 's#//#/$()/#')"
  echo "SCAN_SERVICE_APP_KEY = $SCAN_SERVICE_APP_KEY"
  echo "DEVELOPMENT_TEAM = $IOS_DEVELOPMENT_TEAM"
  echo "CODE_SIGN_STYLE = Manual"
  echo "CODE_SIGN_IDENTITY = Apple Distribution"
  echo "PROVISIONING_PROFILE_SPECIFIER = $profile_uuid"
  echo "CURRENT_PROJECT_VERSION = $build_number"
} > "$work/release.xcconfig"
echo "build number $build_number, Scan Service $SCAN_SERVICE_BASE_URL"

xcodebuild archive \
  -project VuuroScan.xcodeproj \
  -scheme VuuroScan \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$work/VuuroScan.xcarchive" \
  -xcconfig "$work/release.xcconfig" \
  OTHER_CODE_SIGN_FLAGS="--keychain $keychain"

plist="$work/VuuroScan.xcarchive/Products/Applications/VuuroScan.app/Info.plist"
baked_url="$(/usr/libexec/PlistBuddy -c 'Print :ScanServiceBaseURL' "$plist")"
baked_key_length="$(/usr/libexec/PlistBuddy -c 'Print :ScanServiceAppKey' "$plist" | tr -d '\n' | wc -c | tr -d ' ')"
if [ "$baked_url" != "$SCAN_SERVICE_BASE_URL" ]; then
  echo "error: the archive points at '$baked_url', expected $SCAN_SERVICE_BASE_URL"
  exit 1
fi
if [ "$baked_key_length" -ne 64 ]; then
  echo "error: the archive app key has length $baked_key_length, expected 64"
  exit 1
fi
echo "archive points at $baked_url with an app key of $baked_key_length characters"

printf '%s' "$ASC_KEY_P8_BASE64" | base64 --decode > "$work/asc_key.p8"
cat > "$work/ExportOptions-TestFlight.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$IOS_DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict><key>com.vuuro.scan</key><string>$profile_uuid</string></dict>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
  -archivePath "$work/VuuroScan.xcarchive" \
  -exportPath "$work/export" \
  -exportOptionsPlist "$work/ExportOptions-TestFlight.plist" \
  -authenticationKeyPath "$work/asc_key.p8" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
echo "uploaded; the build shows up in App Store Connect > TestFlight after Apple finishes processing"
