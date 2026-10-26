# Release signing for Android

`android/app/build.gradle.kts` signs a release build with the keystore named in
`android/key.properties`. That file and the keystore are **gitignored**
(`android/.gitignore`) and must never be committed or shared.

## One-time setup (the person who owns the Play Console account)

```bash
keytool -genkey -v -keystore ~/dastavez-upload.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias upload
```

Keep `~/dastavez-upload.jks` and its passwords in the password manager.

Enrol the app in **Play App Signing** at the first upload (the default for new
apps). Google then holds the *app signing key*, the one that "never changes
during the lifetime of your app" and signs what phones install; this keystore
is only the *upload key*. Losing or leaking it is recoverable: create a new
upload key, export its certificate (`keytool -export -rfc -keystore NEW.jks
-alias upload -file upload_certificate.pem`) and use **Request upload key
reset** in Play Console › Protected with Play › Play app signing; updates
continue as the same app once Google approves it.

What is *not* recoverable is a build signed outside Play: a phone that
installed a release over USB, signed with this upload key, cannot be updated
by the Play build (signed with Google's key). Uninstall it first, which wipes
its capture batch, so upload pending bills before switching.

Source: developer.android.com/studio/publish/app-signing and Play Console
help answer 9842756, read 2026-10-26 (DAS-135).

Then create `android/key.properties`:

```properties
storePassword=<store password>
keyPassword=<key password>
keyAlias=upload
storeFile=/absolute/path/to/dastavez-upload.jks
```

## What the build does

- `key.properties` present → the release build is signed with it.
- `key.properties` absent → **the release build fails** with a message pointing
  here. A debug-signed "release" can never reach the Play Console by accident,
  and cannot be installed over a real install (different signature).
- For a local experiment only, `flutter build apk --release
  -Pdastavez.allowDebugSigning=true` (or the equivalent `--dart-define`-free
  Gradle property through `android/gradle.properties`) signs with the debug
  key and prints a warning. Never upload such a build.

## Play Console

- Enrol in **Play App Signing** on first upload; upload the `.aab`
  (`flutter build appbundle --release`).
- The build must be made **without** `--dart-define=ALLOW_SERVER_OVERRIDE=true`:
  that flag re-enables the server-address field in a release build (see
  `lib/core/api/api_client.dart`, `kAllowServerOverride`) and exists only for
  sideloaded test builds.
