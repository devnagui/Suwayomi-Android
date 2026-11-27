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

Version 0.6.15 retains hourly offline caching, structured diagnostics,
incremental sync, Activity navigation, serialized read-ahead, rotation fixes
and verified resumable downloads with durable reading-position sync, and
replenishes reader read-ahead throughout chapter transitions.
To build its
ARM64 upgrade APK, use `flutter build apk --release --split-per-abi
--target-platform android-arm64`. The ARM64 APK has version code 2012 and is
written to `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.
Use the existing signing identity and install as an update; do not uninstall
the app or clear its data to replace an APK.

The [upstream releases][release] refer to the original Sorayomi project, not a
published release of this fork.


## Post installation

  - Configure your server address in `Navigation bar > more screen > Server URL`.
  - **Reading position** is saved on the device before network synchronization,
    including the first page, re-reading completed chapters and moving backwards.
    Page/chapter history is kept separately for each configured server and
    signed-in account; no tokens/passwords are stored in the reading journal.
    Pending chapter positions survive app restarts and replay in reading-time
    order, so the latest reading event, not the largest chapter number, wins.
    Network writes are serialized/debounced, flushed on reader exit/app pause,
    retried while foregrounded and on startup/resume/reconnect.
    **Continue** prefers the latest local/server reading independently of
    chapter filters, and readers restore its page instead of stale query data.
    A pending message remains visible until the existing server API acknowledges
    the update. Server reads before replay are network-only; newer server
    history supersedes older pending device positions instead of being overwritten.
    No HA server code/version/configuration changes are required.
    The unchanged server API stamps its own receipt time and has no atomic
    compare-and-set: simultaneous device writes, clock skew and same-second
    timestamps cannot be resolved perfectly by Android alone. Equal timestamps
    prefer the local reading; acknowledged server positions are retained for
    conflict checks. Pending reading data is not part of disposable query caches.
  - Manga chapter lists load the chapters already stored on the server, without
    requiring the source website to respond. After the first full load,
    reopening manga details checks a lightweight server ID/status/order index
    and fetches full details only for missing chapters or changed URLs.
    Unchanged chapter metadata is not rewritten. IDs, not chapter numbers or
    timestamps, identify missing entries, so late/backfilled chapters are
    included. Read/bookmark/download state, page counts and source ordering
    still update for existing chapters; server removals never delete device
    page files. Full source refresh also reloads names, scanlators and other
    metadata for known chapters. Pull to refresh (or the tablet refresh button) checks the source
    for new chapters. Only network outages use offline chapter metadata.
    Source/authentication errors stay visible instead of silently showing an
    older list. Operation logs record chapter counts, active chapter filters,
    visible counts, and offline fallback. If a chapter appears in Updates but
    not manga details, also check unread, downloaded, bookmarked, and scanlator
    filters; those filters apply only to the manga's chapter list.
  - **Activity** replaces the separate Updates and Downloads navigation
    destinations on phones and tablets. Its **Updates** and **Downloads**
    sections preserve their own scroll/selection/navigation state and controls;
    existing `/updates` and `/downloads` links still select the right section.
    **Updates** lists recently discovered library chapters. **Downloads**
    manages the server's download queue (progress, pause/resume, and cancellation).
    Their functions remain distinct within one destination; downloaded chapters
    can still appear in Updates. Source-website fetching remains governed by
    the server/extension API, which does not expose a chapter-number cutoff;
    incremental Android sync does not claim to make source listing incremental.
  - In **Settings > Reader**, turning **Swipe toggle** off disables left/right
    page dragging in single-page and continuous horizontal readers, including
    right-to-left mode. The existing chapter-swipe-labeled setting also controls
    horizontal page swipes. Tap navigation, the page slider, vertical/webtoon
    scrolling, pinch zoom, and panning a zoomed page remain available.
    **Last page swipe** does not override disabled horizontal swiping.
    Rotating a phone no longer enables tablet-only chapter gestures: device
    classification uses its shorter screen dimension. Optional vertical
    edge gestures do not capture lateral drags, and zero-velocity drag ends
    do not advance a page.
  - **Smart downloads** prepares the next three chapters when entering the
    reader and every time the current chapter changes, without waiting for
    current-page network requests or returning to the manga summary.
    For example, reading 84 prepares 85, 86 and 87; moving to 85 replenishes
    86, 87 and 88. Page changes also recheck the request without duplicating
    the active window. This applies to paged/continuous horizontal LTR/RTL,
    vertical and webtoon modes. Chapter transitions reset the reader's page
    controllers rather than inheriting the previous chapter's scroll state.
    It uses the unfiltered chapter sequence, supports fractional chapters,
    and prefers the current scanlator among duplicate chapter numbers.
    One chapter is requested on the server, verified downloaded, and copied
    through the existing serialized device queue before the next is requested.
    Server/device-cached chapters are reused; repeated reader builds and a
    lost enqueue response do not duplicate work. The summary shows waiting,
    server progress, device progress, retry attempts, paused and ready states,
    including when chapter rows are hidden by filters or lazy loading.
    Three application attempts use 30/60-second backoff; persistent failure
    stops the window until **Retry** or a new reading window. A chapter
    transition rebuilds the pending window in reading order and releases the
    old failure lock, while an owned in-flight task stays serialized. These are in
    addition to the server/device workers' existing internal retry limits.
    Unrelated queued work is allowed to finish first, and paused pending server
    work is not automatically resumed. Existing manual cache exclusions and
    explicit smart-download disable settings are respected. Fresh/unset
    preferences enable this feature; disabling it cancels pending read-ahead,
    without deleting files or stopping already submitted server work.
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
  - **Offline caching (open the updated app once after installation):** unread,
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
    resumes verified pages of incomplete chapters on a later run. Resume data
    is reused only for the same server/page URL sequence and cache generation;
    changing URLs, clearing caches, or removing downloads cannot resurrect
    stale pages. Every newly copied page must decode as an image (JPEG, PNG,
    WebP or GIF) before completion; HTML/login responses, empty/truncated
    bodies and corrupt images are rejected. Encoded pages are limited to
    32 MiB and decoded validation is downsampled. Android app-private free
    space is checked before requesting pages and during writes, keeping
    16 MiB reserved. Missing capacity information fails explicitly instead of
    assuming space is available. The native capacity plugin also registers
    in the WorkManager background engine, not just the foreground Activity.
    It only copies chapters the
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

Commit source and dependency locks before building a release, and record its
branch and commit in the build receipt. Integrate parallel worktrees into this
repository before delivery; an APK is not a backup of uncommitted source.

GitHub validation uses a pinned Ubuntu runner and lock-enforced dependency
resolution. Superseded PR runs are cancelled and each job has a time limit.
Scheduler tests install their fake only after WorkManager's host initialization,
so Linux CI does not overwrite the fake with a real Linux scheduler. Validation
failures remain visible; tests are not removed or retried to hide defects.

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
