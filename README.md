<p align="center">
 <img width=200px height=200px src="assets/icons/launcher/sorayomi_icon.png" alt="Sorayomi logo"/>
</p>

<h1 align="center"> Suwayomi-Android </h1>

<div align="center">

[![Platform](https://img.shields.io/badge/platform-Android-lightgrey)][release]
[![Discord](https://img.shields.io/discord/801021177333940224.svg?label=discord&labelColor=7289da&color=2c2f33&style=flat)](https://discord.gg/DDZdqZWaHA)

</div>

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/devnagui/Suwayomi-Android)](https://github.com/devnagui/Suwayomi-Android)
[![GitHub License](https://img.shields.io/github/license/devnagui/Suwayomi-Android)](https://github.com/devnagui/Suwayomi-Android/blob/main/LICENSE)
![CI](https://github.com/devnagui/Suwayomi-Android/actions/workflows/publish.yml/badge.svg)

</div>



<p align="center">
An Android-only thin client fork of <a href="https://github.com/Suwayomi/Tachidesk-Sorayomi">Sorayomi</a>, built with <a href="https://flutter.dev/">Flutter</a> to read manga from a <a href="https://github.com/Suwayomi/Suwayomi-Server">Suwayomi-Server</a> instance.</br></br>
Suwayomi-Android needs to connect to an already hosted server.</br></br>
This fork targets Android. The existing Android application ID and Sorayomi app branding are unchanged.
</p>

---

Only Android application code and APK packaging are maintained. Unsupported
platform targets and their release jobs have been removed. Phone, foldable and
tablet layouts, source browsing, library, history, downloads, recovery tools and
current remote server-management features remain available. Manga sources and
heavy processing run on Suwayomi-Server, not inside this client.
Shared Flutter dependencies may still declare other platforms. The small
adaptive-icon font dependency is retained because Flutter's icon tree shaker
requires it; no non-Android application target or release artifact is built.

## Is this application usable? Should I test it?

Here is a list of current features for interaction with Sorayomi:

- Managing installed Extensions.
- Interaction with your library.
- Browsing installed sources.
- Viewing manga and chapters.
- Reading, downloading, and managing chapters.
- Viewing chapter updates

**Note:** Keep in mind that Sorayomi and Suwayomi-Server are alpha software, so it can have issues. See [Support and help](#support-and-help) if it happens.


### Supported Suwayomi versions

These are the versions of [Suwayomi-Server][suwayomi-server] that Sorayomi supports.

#### Current Android build

- This source tree targets the current Suwayomi-Server GraphQL API, verified
  against server revision `6b481e8b` (2026-10-21). Older servers without
  `MangaType.user`, `ChapterType.user`, `userSettings`, or extension stores
  are not supported by this build.
- Library membership, reading progress, and automatic download/update
  preferences use the logged-in user's data. Server-wide settings remain
  separate. UI Login uses JWT authentication for GraphQL, subscriptions,
  covers, reader image prefetch, and offline page downloads. Expired access
  tokens share a single refresh attempt; failed refreshes keep the authentication
  error visible.
- Extension repositories use the extension-store API; both APK and JAR
  extension uploads are supported.


## Downloading and Running the app

### Android

Build this fork with `flutter build apk --release`. The APK is written to
`build/app/outputs/flutter-apk/app-release.apk`.

The [upstream releases][release] refer to the original Sorayomi project, not a
published release of this fork.


## Post installation

  - Configure your server address in `Navigation bar > more screen > Server URL`.
  - Chapter selection actions on manga details and Updates reserve their own
    space above Android's navigation buttons/gesture area. The action surface
    is opaque and wraps on narrow displays rather than covering chapter rows.
  - **Updates** and **Updates summary** expose **Cancel all updates** while
    checks are active. Confirmation stops running/queued checks, not chapter
    downloads, and does not remove manga, chapters, or library membership.
    Running and pending manga in **Updates summary** have individual **Cancel
    update** buttons. These require the server's scoped `mangaIds` cancellation
    support; an older server shows an error rather than cancelling every manga.
  - For servers configured with native **UI Login**, choose **Settings > Server >
    Authentication > UI Login** and sign in with your server account. Use the
    server's direct HTTPS address, not a temporary Home Assistant ingress URL.
    Changing only the Android setting does not change the server's authentication
    mode. **Basic Auth (legacy)** remains available for older server setups;
    saved settings are not silently switched. A successful login clears cached
    query data and chapter metadata so the new account does not inherit stale
    user-specific state; downloaded page files remain on the device.
  - In `Settings > General`, use **Clear Cache** to reset local GraphQL data,
    cached chapter metadata, and image caches, or **Remove missing manga links**
    to check cached IDs against the current server before removing stale local
    references. Failed server checks never remove entries.
  - Manga details include **Forget local manga**, even when the manga cannot
    load. These actions never delete server manga or chapters, reset sign-in
    settings, or remove downloaded page files. Chapter metadata may need to be reloaded
    from the server after clearing caches.
  - **Operation log** is available from **More**, **Settings > General**, and
    the log icon on **Settings > Server** and the **UI Login** dialog, including
    when login fails. It shows the last 500 GraphQL, media and cache operations.
    Choose **Copy log** or **Export operation log** to share versioned JSON
    diagnostics (`suwayomi-android-operations.json`). The viewer remains
    human-readable. JSON includes app/build versions, request IDs, processing
    stages, download states, attempts, progress and safe exception types,
    reason codes and application-only stack locations when available.
    Metadata caching is summarized per batch, not per chapter; individual
    storage failures remain visible.
    The latest 50 failures are retained separately so ordinary activity
    cannot immediately evict them from the 500-event history.
    An HTTP 200 response acknowledges an API call, not a finished download.
    The current server download API exposes no exception/message field:
    queue errors use `server_reason_unavailable`, requiring server logs for
    their cause. Known server exceptions are classified only when an API
    response actually supplies them; no backend exception is invented.
    Login errors are selectable and have a separate **Copy error** button.
    Copy or export before restarting the app.
    Logs are bounded and clear on app restart or explicit log clearing.
    They do not contain credentials, request/response bodies, raw exception
    messages, local filesystem paths, or server URLs. No logs are uploaded
    automatically.
  - **Unreleased (requires installing the updated APK):** unread,
    server-downloaded library chapters are
    copied to the device one chapter at a time. Catch-up runs at startup,
    foreground/reconnect, and every five minutes in the foreground, including
    chapters the server finished while Android was closed. After setup/sign-in,
    Android WorkManager also checks approximately every hour while the app
    is closed, using an unmetered connection (normally Wi-Fi), sufficient
    battery and free storage; charging is not required. Open the updated app
    once to register the job. Reboot does not remove its schedule, but Doze,
    Samsung sleeping-app settings, loss of connectivity, or force-stop can
    delay/prevent execution; an exact hourly deadline is not guaranteed.
    On Samsung, allow background activity and remove the app from sleeping/
    deep-sleeping apps if necessary. A run is bounded to eight minutes and
    retries incomplete chapters on a later run. It only copies chapters the
    server reports downloaded; it does not request source updates or
    re-enqueue server downloads.
    Metadata is paged in batches of 25; read chapters and non-library manga
    are not automatically backfilled. A server-only chapter's checkmark menu
    offers **Save on device** (including read chapters) and the existing
    **Delete** action. Green download checks indicate local offline copies.
    Catch-up failures appear as `OfflineCacheCatchUp failed` in Operation log;
    local copy failures also show a notification and a retry icon. Hourly
    scheduling and the previous background run's result appear as
    `OfflineCacheHourly` entries when the app is opened/resumed. The latest
    background receipt persists its actual completion time, copy/skip/failure
    counts and safe failure details, where available; a completed scan does
    not by itself mean any chapters were copied. Explicit
    local deletions stay excluded from automatic copying across restarts;
    **Save on device** permits copying them again. Completion manifests and
    atomically published pages protect caches from interrupted workers.
    No source
    timeout, server download queue, or resource-guard setting is changed.

## Building from source

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes.

### Prerequisites

You can install Flutter & Dart from [Official website](https://docs.flutter.dev/get-started/install)

  - Dart sdk
  - Flutter - Channel Stable

### Building

1.  Clone this Android fork:

```
  $ git clone https://github.com/devnagui/Suwayomi-Android.git
  $ cd Suwayomi-Android
```
2.  You can install all dependencies by running this command in terminal:

```
  $ flutter pub get
```

3.  Generate the client models and API bindings (generated Dart files are
    ignored by this repository):

```
  $ dart run build_runner build --delete-conflicting-outputs
```

4.  Now enter the following command to start debugging the app:

```
  $ flutter run
```

-  Localization generator
```
  $ flutter gen-l10n
```

- When updating the server API, regenerate the schema from the target server,
  replace `lib/src/graphql/schema.graphql`, and regenerate the client:
```
  $ dart run build_runner build --delete-conflicting-outputs
  $ flutter analyze
  $ flutter test
  $ flutter build apk --release
```
  Do not hand-edit generated GraphQL files. GraphQL cursors are opaque strings,
  not integer offsets. Existing offline chapter metadata is migrated when read.
  Android asset paths are maintained in `lib/src/constants/assets.dart`;
  `flutter_gen_runner` is not required.
  `go_router_builder` is pinned to the version compatible with `go_router` 14.

- GitHub pull requests and main-branch pushes regenerate the bindings and run
  analysis/tests with Flutter 3.44.1 without requiring signing credentials.
  Manual builds and release tags additionally build signed APKs and require
  repository secrets `PLAY_STORE_UPLOAD_KEY`, `KEYSTORE_KEY_ALIAS`,
  `KEYSTORE_STORE_PASSWORD`, and `KEYSTORE_KEY_PASSWORD`. Private signing keys
  stay local unless the repository owner explicitly provisions those secrets;
  missing secrets fail the signed build rather than changing the signing identity.

- Pull-Request Suggestion
  - Install GitHooks after cloning the repo using `git config --local core.hooksPath .githooks`

## Support and help

-   Join Suwayomi's [discord server](https://discord.gg/DDZdqZWaHA) to hang out with the community and receive support and help.


## Built Using

- [Flutter](https://flutter.dev/) provides the native Android UI.

- [Flutter Riverpod](https://pub.dev/packages/riverpod/) - A simple way to access state while robust and testable.

- [Riverpod Architecture](https://codewithandrea.com/articles/flutter-app-architecture-riverpod-introduction/) - File architecture developed by [@bizz84](https://github.com/bizz84)

Find other dependencies in [pubspec.yaml](pubspec.yaml)

## Credit

- The `Suwayomi-server` project is developed by [@AriaMoradi](https://github.com/AriaMoradi) and contributors,

- The `Tachidesk-Sorayomi` project is developed by [@DattatreyaReddy](https://github.com/DattatreyaReddy) and contributors,

- CI-CD for `Tachidesk-Sorayomi` is developed by [@mahor1221](https://github.com/mahor1221) and contributors.

## Translation
Feel free to translate the project on [Weblate](https://hosted.weblate.org/projects/suwayomi/tachidesk-sorayomi/)

<details><summary>Translation Progress</summary>
<a href="https://hosted.weblate.org/engage/suwayomi/">
<img src="https://hosted.weblate.org/widgets/suwayomi/-/tachidesk-sorayomi/multi-auto.svg" alt="Translation status" />
</a>
</details>

## License

A link for [Tachidesk is provided here](https://github.com/Suwayomi/Tachidesk) and is licensed under `Mozilla Public License v2.0`.

You can obtain a copy of `Mozilla Public License v2.0` from https://mozilla.org/MPL/2.0/


    Copyright (C) Contributors to the Suwayomi project

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.


[release]: https://github.com/Suwayomi/Tachidesk-Sorayomi/releases
[suwayomi-server]: https://github.com/Suwayomi/Suwayomi-Server
[suwayomi-server-preview]: https://github.com/Suwayomi/Suwayomi-Server-preview/releases
