# Release signing for Android

`android/app/build.gradle.kts` signs a release build with the keystore named in
`android/key.properties`. That file and the keystore are **gitignored**
(`android/.gitignore`) and must never be committed or shared.

## One-time setup (the person who owns the Play Console account)

```bash
keytool -genkey -v -keystore ~/dastavez-upload.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias upload
```

Keep `~/dastavez-upload.jks` and its passwords in the password manager. Losing
them means a new app listing: Play App Signing lets Google hold the *app*
signing key, but the *upload* key is yours.

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
