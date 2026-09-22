# Subaccount compatibility E2E — 2026-09-22

Historical test report, not a replacement for Console's domain or API contracts.
The Android App can authenticate a Workspace subaccount and operate its own Node,
but three compatibility defects prevent calling the support complete.

## Environment and scope

- App source: `fc61a5c`, version `1.0.8+9`; no application code modified.
- Console source: `6dd2ef6e6`; running API includes permission fix `a4c258746`.
- Unmodified Casdoor `3.42.0` in the local E2E stack.
- Fresh Android 14 / API 34 x86_64 Docker emulator; actual debug APK, Android
  Chrome device authorization, JNI runtime and VPN permission flow.
- Console URL: `http://web.10.147.223.128.nip.io:14173`.
- Isolated owner and default-member subaccount `710324-app-test`, Workspace
  `da90d9fd-d8eb-4c4d-97db-4f27c21f687c`. No existing user's password, role or
  device configuration was changed.
- Local public release metadata was empty. For this test only, the stable
  version was set to `v2.7.0` through the admin API and restored afterward.
  Android used its bundled JNI Core, which reported `2.6.4-75cd6ab4`; this was
  not a test of downloading or upgrading the native runtime.

Build and existing regression suite:

```sh
scripts/flutter_docker.sh bash -lc \
  'flutter pub get && flutter build apk --debug \
    --dart-define=EASYTIER_CONSOLE_URL=http://web.10.147.223.128.nip.io:14173 \
    && flutter test'
```

APK build succeeded; all **221 existing tests passed**. These tests do not cover
the three defects below. The initial host/Docker mixed-toolchain attempt failed
because the host rewrote generated package paths; the successful run used only
the repository's Docker helper, with tracked dependency files unchanged.

## Executed checks

| Check | Observed result |
| --- | --- |
| Real device-code login with a subaccount | Passed; no registration or email required; entered the assigned Workspace. |
| Account settings | Passed; displayed the subaccount name and handled the empty email. |
| Workspace scope | Passed; `/auth/me` with the App's actual token returned exactly one Workspace with member role. |
| App restart | Passed; restored the saved login without entering credentials again. |
| OAuth refresh | Passed; after advancing only the isolated App's saved refresh timestamp, native refresh returned 200 and `/auth/me` returned 200. |
| Device enrollment | Device came online with the correct subaccount owner, but used an extra manual Auto Key; see defect 1. |
| Join own Node | Passed; native attach returned 201, then the Node became active/online at `10.144.0.1`. |
| Read own Node configuration | Passed; App's actual config request returned 200; the local-device page showed applied, consistent configuration. |
| Leave network | Passed; native remove returned 200; the Node disappeared and the App showed no joined networks. |
| Other Workspace access | Supplementary API check using the actual App token: foreign network list and Node config both returned 403. |
| Network administration | Backend correctly returned 403, but App exposed forbidden actions and misreported the error; see defect 3. |
| Disable account | Backend access stopped, but App stayed signed in and repeatedly refreshed tokens; see defect 2. |
| Reset password | Passed for both disabled and active states: refresh returned 400 and the App returned to the login page. |
| Enable and sign in after reset | Passed with the replacement password; the assigned Workspace was preserved. |
| Manual-key creation limit | Failed: App could not start its engine despite having a usable default member key; see defect 1. |

This run does **not** establish Windows/macOS native coverage, same-Workspace
foreign-device UI coverage, peer-to-peer traffic quality, or runtime upgrade
compatibility. The App currently has no UI for editing Node configuration, so
configuration writes were not claimed as an App feature tested here.

## Confirmed defects

### 1. Major: bootstrap ignores the member's default enrollment key

`lib/src/auth/console_auth_http_service.dart:887` selects a key by the platform
Auto Key display name. It ignores `is_member_default` and otherwise creates a
manual, pre-approved key. The first enrollment created `Android Auto Key` even
though the subaccount already had a valid default key requiring approval.

To exercise the failure, the isolated Auto Key was unassigned by the owner and
four additional manual keys were created through Console. The test had attempted
to rename the key, but PATCH accepts owner changes only: the omitted owner
unassigned it, removing it from the member-visible list. Five recent manual
creations exhausted the normal creation burst allowance. On the next real App
login:

1. Reading enrollment keys returned 200.
2. App attempted `prepareCoreBootstrap.createKey`, which returned 429 with
   `enrollment_key_rate_limited`.
3. App displayed an engine error and could not enroll/connect.
4. A supplementary request using the same App token successfully retrieved the
   existing member-default key secret. The default key remained unrevoked.

This is a demonstrated **creation-rate** failure. An active-count limit failure
has the same selection defect but was not independently exercised in this run.

### 2. Major: disabled accounts remain in the signed-in UI

After disabling the active test subaccount, refreshing the network list twice
produced two native refresh responses of 200 followed by network responses of
401. App retained its cached home screen and did not clear the session.

`lib/src/auth/console_auth_http_service.dart:1011` retries a 401 after refreshing,
but a second 401 does not publish `SessionExpiredException`. Console disabling
and password resetting have different provider-token behavior, so the passing
password-reset path does not cover this case. Backend access remained denied;
this finding is not an authorization bypass.

### 3. Minor: member administration controls and 403 copy are incorrect

The App's Workspace model does not parse capabilities. A default member sees
both **New network** and **Delete network**. Submitting a new network returned
403 and displayed “当前登录态已失效，请重新登录。” although the session was valid.
No real network deletion was attempted through the member UI.

The relevant paths are `console_auth_models.dart:101`,
`console_auth_http_service.dart:1387`, `workspace_home_pages.dart:70`, and
`workspace_home_network_more_menu.dart:47` under `lib/src/`.

## Evidence and follow-up

Evidence is stored under [evidence/subaccounts-2026-09-22](evidence/subaccounts-2026-09-22/):

- [Joined network](evidence/subaccounts-2026-09-22/joined.png)
- [Creation rejected with wrong copy](evidence/subaccounts-2026-09-22/create-denied.png)
- [Member's network menu](evidence/subaccounts-2026-09-22/network-menu.png)
- [Home retained after disabling](evidence/subaccounts-2026-09-22/disabled-home.png)
- [Bootstrap creation-rate error](evidence/subaccounts-2026-09-22/key-rate-limit.png)
- [Login page after password reset](evidence/subaccounts-2026-09-22/reset-login.png)
- [Sanitized native HTTP outcomes](evidence/subaccounts-2026-09-22/auth-events.json)

The temporary emulator was removed, manual fixture keys revoked, and the test
Node, network, device and subaccount removed through Console. The isolated owner
Workspace and lifecycle/audit records remain for diagnosis. Temporary public
release metadata was restored. No production deployment or Casdoor change was
made.

Subsequent scope was approved in Console ADR 0052: compatibility for automatic
key requests and Account checks during device-token exchange/refresh, keeping
App and Casdoor source unchanged. The member menu and 403 copy limitation
remains a future App change. This report records the pre-fix observations.

Domain context impact: none because this report records existing contracts and
observed defects without changing domain meaning.

Architecture impact: none because no application or backend implementation,
Module ownership, public Interface or dependency edge changed.
