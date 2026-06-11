# Android Emulator E2E Runbook

This project can run Android client E2E checks against the local console at
`http://10.147.223.128:14173/`. The current emulator setup uses the Docker
Android emulator and exposes adb at `localhost:5555`.

## Build And Install

Preferred Docker-based build path:

```sh
scripts/flutter_docker.sh bash -lc \
  'flutter pub get && flutter build apk --debug \
    --dart-define=EASYTIER_CONSOLE_URL=http://10.147.223.128:14173'
adb connect localhost:5555
adb -s localhost:5555 install -r build/app/outputs/flutter-apk/app-debug.apk
```

The Docker helper keeps large toolchain caches on the host under
`/data/project/.cache/easytier-pro-app/`:

- `gradle-home/` for Gradle wrapper distributions and dependency cache;
- `pub-cache/` for Dart and Flutter packages;
- `android-sdk/ndk/` for the Android NDK installed by Gradle;
- `android-sdk/cmake/` for CMake installed by Gradle;
- `android-sdk/temp/` for Android SDK manager temporary downloads.

By default the helper temporarily maps the Gradle wrapper distribution from
`gradle-*-all.zip` to `gradle-*-bin.zip` inside the container. This does not
modify repository files, and avoids repeated large `all` distribution downloads
for normal APK builds. Set `EASYTIER_GRADLE_DISTRIBUTION=all` when the exact
wrapper distribution is required.

If a previous interrupted download leaves a corrupt Gradle zip, clear only the
wrapper distribution cache and rerun the same helper command:

```sh
rm -rf /data/project/.cache/easytier-pro-app/gradle-home/wrapper/dists/gradle-*
```

Direct host build path:

```sh
flutter pub get
flutter build apk --debug \
  --dart-define=EASYTIER_CONSOLE_URL=http://10.147.223.128:14173
adb connect localhost:5555
adb -s localhost:5555 install -r build/app/outputs/flutter-apk/app-debug.apk
```

If the debug signature changes, uninstall once before installing:

```sh
adb -s localhost:5555 uninstall net.easytier.pro
```

## Device Authorization Login

Use the helper script instead of manually tapping through Chrome:

```sh
export EASYTIER_E2E_USERNAME='<username>'
export EASYTIER_E2E_PASSWORD='<password>'
node scripts/android_device_auth_login.mjs --serial localhost:5555
```

The script:

- starts or foregrounds the app;
- taps the Flutter login/retry button when visible;
- resets `tcp:9222` to Chrome DevTools on the emulator;
- finds the active Casdoor device authorization page;
- submits the form through Chrome DevTools without printing the password;
- returns to the app so Flutter resumes device-code polling;
- waits for `Device authorization completed` or `Session established` in the
  app log.

Useful options:

```sh
node scripts/android_device_auth_login.mjs --help
node scripts/android_device_auth_login.mjs --serial localhost:5555 --skip-tap
```

## Failure Notes

On Android, the app intentionally defers device-code polling while the external
browser is foregrounded. After approving the Casdoor page, the app must be
foregrounded before the code expires. If the app shows "登录验证码已过期", tap
"重新尝试登录" to return to the login page, then start a fresh login. The helper
script handles this path when it starts from the visible login or retry screen.

If Chrome DevTools hangs, reset the adb forward:

```sh
adb -s localhost:5555 forward --remove tcp:9222
adb -s localhost:5555 forward tcp:9222 localabstract:chrome_devtools_remote
curl http://127.0.0.1:9222/json/list
```

The app log used by the helper is under the package private directory:

```sh
adb -s localhost:5555 shell \
  "run-as net.easytier.pro sh -c 'tail -n 200 /data/data/net.easytier.pro/code_cache/easytier-pro-app/logs/gui-*.log'"
```

## VPN Permission

When Android shows the system VPN permission dialog after login, approve it once
for the emulator. If automation is needed, inspect the active window first:

```sh
adb -s localhost:5555 shell uiautomator dump /sdcard/window.xml
adb -s localhost:5555 shell cat /sdcard/window.xml
```

Then tap the dialog's positive button center from the reported `bounds`.
