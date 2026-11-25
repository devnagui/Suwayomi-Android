// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'features/settings/presentation/appearance/widgets/app_theme_selector/app_theme_selector.dart';
import 'features/settings/presentation/appearance/widgets/is_true_black/is_true_black_tile.dart';
import 'features/settings/presentation/server/widget/client/server_url_tile/server_url_tile.dart';
import 'features/settings/presentation/server/widget/credential_popup/credentials_popup.dart';
import 'features/settings/widgets/app_theme_mode_tile/app_theme_mode_tile.dart';
import 'global_providers/global_providers.dart';
import 'l10n/generated/app_localizations.dart';
import 'routes/router_config.dart';
import 'utils/extensions/custom_extensions.dart';
import 'utils/misc/toast/toast.dart';
import 'utils/network/connectivity_provider.dart';
import 'utils/network/hourly_offline_cache.dart';
import 'utils/network/local_download_queue.dart';
import 'utils/network/offline_chapter_manager.dart';
import 'utils/network/token_manager.dart';

class Sorayomi extends ConsumerStatefulWidget {
  const Sorayomi({super.key});

  @override
  ConsumerState<Sorayomi> createState() => _SorayomiState();
}

class _SorayomiState extends ConsumerState<Sorayomi>
    with WidgetsBindingObserver {
  Timer? _catchUpTimer;
  bool _cacheEnabled = false;
  bool _workerStarted = false;
  bool? _hourlyEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _catchUp());
    // Also recover while the app stays open if subscription delivery fails.
    _catchUpTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _catchUp(),
    );
  }

  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  void _catchUp() {
    if (!mounted) return;
    if (!_cacheEnabled) {
      if (_workerStarted) {
        ref.invalidate(localDownloadQueueProvider);
        _workerStarted = false;
      }
      return;
    }
    _workerStarted = true;
    ref.read(localDownloadQueueProvider.notifier).setForeground(_foreground);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(reportHourlyOfflineCache(ref.read(sharedPreferencesProvider)));
      ref.invalidate(isChapterOfflineProvider);
    }
    _catchUp();
  }

  @override
  void dispose() {
    _catchUpTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final serverUrl = ref.watch(serverUrlProvider);
    final authType = ref.watch(authTypeKeyProvider);
    final accessToken = ref.watch(uiLoginAccessTokenProvider);
    final credentials = ref.watch(credentialsProvider);
    // Settings initialization can persist the localhost default before setup.
    // It is not a configured remote server. Also wait for login credentials.
    final enabled = canCacheOffline(
      serverUrl: serverUrl,
      authType: authType,
      accessToken: accessToken,
      credentials: credentials,
    );
    if (_hourlyEnabled != enabled) {
      _hourlyEnabled = enabled;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(scheduleHourlyOfflineCache(_cacheEnabled));
      });
    }
    if (_cacheEnabled != enabled) {
      _cacheEnabled = enabled;
      WidgetsBinding.instance.addPostFrameCallback((_) => _catchUp());
    }
    // Keep the worker active independently of visible chapter tiles, without
    // rebuilding the whole app on each page's progress update.
    if (enabled) {
      ref.listen(localDownloadQueueProvider, (previous, next) {
      if (next.entries.any((entry) =>
          entry.value.status == LocalCacheStatus.failed &&
          previous?[entry.key]?.status != LocalCacheStatus.failed)) {
        final context = rootNavigatorKey.currentContext;
        if (context != null) {
          ref.read(toastProvider)?.showError(context.l10n.offlineCacheFailed);
        }
      }
      });
      ref.listen(connectivityStatusProvider, (previous, next) {
      if (previous == false && next) _catchUp();
      });
    }
    ref.listen(graphQlClientProvider, (_, __) {
      // Signing in or changing the server must retry an initial failed scan.
      WidgetsBinding.instance.addPostFrameCallback((_) => _catchUp());
    });
    final routes = ref.watch(routerConfigProvider);
    final themeMode = ref.watch(appThemeModeProvider);
    final appLocale = ref.watch(l10nProvider);
    final appScheme = ref.watch(appSchemeProvider);
    final isTrueBlack = ref.watch(isTrueBlackProvider);
    final client = ref.watch(graphQlClientNotifierProvider);
    return GraphQLProvider(
      client: client,
      child: MaterialApp.router(
        builder: FToastBuilder(),
        onGenerateTitle: (context) => context.l10n.appTitle,
        debugShowCheckedModeBanner: false,
        theme: FlexThemeData.light(
          scheme: appScheme,
          useMaterial3: true,
          useMaterial3ErrorColors: true,
        ).copyWith(
          tabBarTheme: const TabBarThemeData(tabAlignment: TabAlignment.center),
        ),
        darkTheme: FlexThemeData.dark(
          scheme: appScheme,
          useMaterial3: true,
          useMaterial3ErrorColors: true,
          darkIsTrueBlack: isTrueBlack.ifNull(),
        ).copyWith(
          tabBarTheme: const TabBarThemeData(tabAlignment: TabAlignment.center),
        ),
        themeMode: themeMode ?? ThemeMode.system,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: appLocale,
        routerConfig: routes,
      ),
    );
  }
}
