import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../constants/db_keys.dart';
import '../../constants/enum.dart';
import '../../features/manga_book/data/downloads/downloads_repository.dart';
import '../../features/manga_book/data/manga_book/manga_book_repository.dart';
import '../../features/manga_book/presentation/downloads/controller/downloads_controller.dart';
import '../../features/settings/presentation/server/widget/client/server_url_tile/server_url_tile.dart';
import '../../features/settings/presentation/server/widget/credential_popup/credentials_popup.dart';
import '../../global_providers/global_providers.dart';
import '../logger/operation_log.dart';
import 'local_download_queue.dart';
import 'offline_chapter_manager.dart';
import 'token_manager.dart';

const hourlyOfflineCacheTask = 'suwayomi.offline-cache.hourly';
const _lastOutcomeKey = 'offlineCacheBackgroundOutcome';
const _lastRunKey = 'offlineCacheBackgroundLastRun';
const _lastDiagnosticKey = 'offlineCacheBackgroundDiagnostic';
int? _reportedRun;

bool canCacheOffline({
  required String? serverUrl,
  required AuthType? authType,
  required String? accessToken,
  required String? credentials,
}) {
  final uri = Uri.tryParse(serverUrl ?? '');
  return serverUrl != DBKeys.serverUrl.initial &&
      uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      (authType != AuthType.uiLogin ||
          accessToken?.trim().isNotEmpty == true) &&
      (authType != AuthType.basic || credentials?.trim().isNotEmpty == true);
}

Future<void> initializeHourlyOfflineCache() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    await Workmanager().initialize(hourlyOfflineCacheDispatcher);
  } catch (error, stackTrace) {
    OperationLog.instance.record('OfflineCacheHourly',
        outcome: 'initialization_failed',
        stage: 'background_scheduler',
        error: error, stackTrace: stackTrace,
        reasonCode: 'scheduler_initialization_failed');
  }
}

Future<void> scheduleHourlyOfflineCache(bool enabled,
    {Workmanager? scheduler}) async {
  if (scheduler == null && (kIsWeb || !Platform.isAndroid)) return;
  final manager = scheduler ?? Workmanager();
  try {
    if (!enabled) {
      await manager.cancelByUniqueName(hourlyOfflineCacheTask);
      return;
    }
    await manager.registerPeriodicTask(
      hourlyOfflineCacheTask,
      hourlyOfflineCacheTask,
      frequency: const Duration(hours: 1),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(
        networkType: NetworkType.unmetered,
        requiresBatteryNotLow: true,
        requiresStorageNotLow: true,
      ),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(hours: 1),
    );
    OperationLog.instance.record('OfflineCacheHourly', outcome: 'scheduled');
  } catch (error, stackTrace) {
    OperationLog.instance.record('OfflineCacheHourly',
        outcome: 'scheduling_failed', stage: 'background_scheduler',
        error: error, stackTrace: stackTrace,
        reasonCode: 'scheduler_registration_failed');
  }
}

@pragma('vm:entry-point')
void hourlyOfflineCacheDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((task, inputData) async {
    if (task != hourlyOfflineCacheTask) {
      OperationLog.instance
          .record('OfflineCacheHourly', outcome: 'unknown_task');
      return false;
    }
    OperationLog.instance.clear();
    ProviderContainer? container;
    SharedPreferences? preferences;
    var result = false;
    try {
      preferences = await SharedPreferences.getInstance();
      await preferences.reload();
      container = createBackgroundCacheContainer(preferences);
      result = await runHourlyOfflineCache(container);
    } catch (error, stackTrace) {
      OperationLog.instance.record('OfflineCacheHourly',
          outcome: 'failed', stage: 'background_scan',
          error: error, stackTrace: stackTrace,
          reasonCode: 'background_setup_failed');
    } finally {
      container?.dispose();
    }
    if (preferences != null) {
      try {
        await saveHourlyCacheDiagnostics(preferences, result);
      } catch (error, stackTrace) {
        OperationLog.instance.record('OfflineCacheHourly',
            outcome: 'diagnostics_failed', stage: 'background_scan',
            error: error, stackTrace: stackTrace,
            reasonCode: 'background_diagnostics_write_failed');
        return false;
      }
    }
    return result;
  });
}

Future<void> saveHourlyCacheDiagnostics(
    SharedPreferences preferences, bool result) async {
  final log = OperationLog.instance;
  final summary = log.latestEvent('OfflineCacheCatchUp');
  final failure = result ? null : log.latestException ?? log.latestFailure;
  final skipped =
      log.latestEvent('OfflineCacheHourly')?['outcome'] == 'unconfigured';
  final saved = await preferences.setString(
      _lastDiagnosticKey,
      jsonEncode({
        'outcome': skipped
            ? 'previous_run_skipped'
            : result
                ? 'previous_run_completed'
                : 'previous_run_failed',
        'completedAt': DateTime.now().toUtc().millisecondsSinceEpoch,
        for (final key in [
          'count',
          'copied',
          'alreadyCached',
          'excluded',
          'failed',
        ])
          if (summary?[key] is int) key: summary![key],
        if (failure?['errorType'] is String) 'errorType': failure!['errorType'],
        'reasonCode': failure?['reasonCode'] ??
            (skipped ? 'not_configured' : 'background_scan_result'),
      }));
  if (!saved) throw StateError('Background diagnostics were not persisted');
}

ProviderContainer createBackgroundCacheContainer(
        SharedPreferences preferences) =>
    ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      // Never open the foreground engine's Hive box or WebSocket subscriptions.
      graphQlClientProvider.overrideWith(
        (ref) => createGraphQlClient(ref,
            cache: GraphQLCache(store: InMemoryStore())),
      ),
      downloadsRepositoryProvider.overrideWith((ref) {
        final client = ref.watch(graphQlClientProvider);
        return DownloadsRepository(client, client);
      }),
      downloadUpdatesProvider.overrideWith((ref) => const Stream.empty()),
      mangaBookRepositoryProvider.overrideWith((ref) => MangaBookRepository(
            ref.watch(graphQlClientProvider),
            ref,
            cacheChapterPages: false,
          )),
    ]);

Future<bool> runHourlyOfflineCache(
  ProviderContainer container, {
  Duration budget = const Duration(minutes: 8),
}) async {
  final subscriptions = <ProviderSubscription<Object?>>[];
  try {
    if (!canCacheOffline(
      serverUrl: container.read(serverUrlProvider),
      authType: container.read(authTypeKeyProvider),
      accessToken: container.read(uiLoginAccessTokenProvider),
      credentials: container.read(credentialsProvider),
    )) {
      OperationLog.instance
          .record('OfflineCacheHourly', outcome: 'unconfigured');
      return true;
    }
    subscriptions.addAll([
      container.listen(graphQlClientProvider, (_, __) {}),
      container.listen(downloadsRepositoryProvider, (_, __) {}),
      container.listen(mangaBookRepositoryProvider, (_, __) {}),
      container.listen(offlineChapterManagerProvider, (_, __) {}),
    ]);
    OperationLog.instance.record('OfflineCacheHourly', outcome: 'started');
    final result = await container
        .read(localDownloadQueueProvider.notifier)
        .reconcile()
        .timeout(budget);
    OperationLog.instance
        .record('OfflineCacheHourly', outcome: result ? 'completed' : 'failed');
    return result;
  } catch (error, stackTrace) {
    OperationLog.instance.record('OfflineCacheHourly',
        outcome: 'failed',
        stage: 'background_scan',
        error: error,
        stackTrace: stackTrace,
        reasonCode: error is TimeoutException
            ? 'background_deadline'
            : 'background_job_failed');
    return false;
  } finally {
    for (final subscription in subscriptions) {
      subscription.close();
    }
  }
}

Future<void> reportHourlyOfflineCache(SharedPreferences preferences) async {
  try {
    await preferences.reload();
    final raw = preferences.getString(_lastDiagnosticKey);
    final decoded = raw == null ? null : jsonDecode(raw);
    if (raw != null && decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid background diagnostic receipt');
    }
    final details = decoded as Map<String, dynamic>?;
    int? number(String key) {
      final value = details?[key];
      return value is int ? value : null;
    }

    String? text(String key) {
      final value = details?[key];
      return value is String ? value : null;
    }

    if (details != null &&
        (number('completedAt') == null ||
            !{
              'previous_run_skipped',
              'previous_run_completed',
              'previous_run_failed',
            }.contains(text('outcome')))) {
      throw const FormatException('Incomplete background diagnostic receipt');
    }
    final run = details == null
        ? preferences.getInt(_lastRunKey)
        : number('completedAt');
    final outcome = details == null
        ? preferences.getString(_lastOutcomeKey)
        : text('outcome');
    if (run == null || run == _reportedRun || outcome == null) return;
    OperationLog.instance.record('OfflineCacheHourly',
        outcome: outcome,
        stage: 'background_scan',
        occurredAt: DateTime.fromMillisecondsSinceEpoch(run, isUtc: true),
        count: number('count'),
        copied: number('copied'),
        alreadyCached: number('alreadyCached'),
        excluded: number('excluded'),
        failed: number('failed'),
        errorType: text('errorType'),
        reasonCode: text('reasonCode') ?? 'summary_unavailable');
    _reportedRun = run;
  } catch (error, stackTrace) {
    OperationLog.instance.record('OfflineCacheHourly',
        outcome: 'diagnostics_failed', stage: 'background_scan',
        error: error, stackTrace: stackTrace,
        reasonCode: 'background_diagnostics_read_failed');
  }
}
