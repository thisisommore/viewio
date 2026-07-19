# Building the macOS Release DMG

Produces `build/dist/viewio-macos-arm64.dmg`: arm64-only Release build,
Developer ID signed, notarized and stapled (both the app and the DMG).

All commands run from the **repository root**.

## Prerequisites (one-time setup)

1. **Developer ID Application certificate** in your login keychain
   (Apple Developer account → Certificates → Developer ID Application).
2. **Notary credentials** stored in the keychain under the profile name
   `viewio-notary` (uses an app-specific password from
   https://appleid.apple.com):

   ```bash
   xcrun notarytool store-credentials viewio-notary \
     --apple-id <your-apple-id-email> --team-id NNJNNZZKNN
   ```

3. `build/dist/ExportOptions.plist` (already in the repo layout):
   method `developer-id`, teamID `NNJNNZZKNN`.

## Build steps

### 1. Archive (Release, arm64-only)

```bash
rm -rf build/viewio.xcarchive build/dist/export
xcodebuild archive \
  -project viewio.xcodeproj \
  -scheme viewio \
  -configuration Release \
  -archivePath build/viewio.xcarchive \
  ARCHS=arm64
```

> Drop `ARCHS=arm64` for a universal (arm64 + x86_64) build — roughly
> doubles the DMG size.

### 2. Export with Developer ID signing

```bash
xcodebuild -exportArchive \
  -archivePath build/viewio.xcarchive \
  -exportPath build/dist/export \
  -exportOptionsPlist build/dist/ExportOptions.plist
```

### 3. Notarize and staple the app

```bash
cd build/dist/export
ditto -c -k --keepParent viewio.app viewio.zip
xcrun notarytool submit viewio.zip --keychain-profile viewio-notary --wait
xcrun stapler staple viewio.app
cd -
```

> If the upload times out (`deadlineExceeded` / "appears to be offline"),
> just rerun `notarytool submit` — it is transient Apple-side flakiness.

### 4. Rebuild the DMG

```bash
cd build/dist
rm -rf staging/viewio.app
cp -R export/viewio.app staging/
hdiutil create -volname viewio -srcfolder staging -ov -format UDZO viewio-macos-arm64.dmg
cd -
```

(`staging/` already contains the `Applications` symlink.)

### 5. Sign, notarize and staple the DMG

```bash
cd build/dist
codesign --force --sign "Developer ID Application: Om More (NNJNNZZKNN)" \
  --timestamp viewio-macos-arm64.dmg
xcrun notarytool submit viewio-macos-arm64.dmg --keychain-profile viewio-notary --wait
xcrun stapler staple viewio-macos-arm64.dmg
cd -
```

## Verify

```bash
# Gatekeeper assessment of the DMG
spctl -a -vv -t open --context context:primary-signature \
  build/dist/viewio-macos-arm64.dmg
# → accepted, source=Notarized Developer ID

# Stapled ticket on the DMG
xcrun stapler validate build/dist/viewio-macos-arm64.dmg

# App inside: mount and check
hdiutil attach -nobrowse -readonly -mountpoint /tmp/viewio_verify \
  build/dist/viewio-macos-arm64.dmg
spctl -a -vv /tmp/viewio_verify/viewio.app
xcrun stapler validate /tmp/viewio_verify/viewio.app
file /tmp/viewio_verify/viewio.app/Contents/MacOS/viewio          # thin arm64
/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" \
  /tmp/viewio_verify/viewio.app/Contents/Info.plist               # e.g. 26.0
hdiutil detach /tmp/viewio_verify
```

## Notes

- Minimum macOS version is set by `MACOSX_DEPLOYMENT_TARGET` on the `viewio`
  target in `viewio.xcodeproj` (currently 26.0).
- Debug builds use `ONLY_ACTIVE_ARCH=YES`, so they are always arm64-only on
  Apple Silicon and are signed with the Apple Development certificate — do
  not distribute those.
