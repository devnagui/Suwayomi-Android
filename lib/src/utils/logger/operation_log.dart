import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'auth_diagnostics.dart';

class OperationLog extends ValueNotifier<List<String>> {
  OperationLog({this.capacity = 500}) : super(const []) {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
  }

  static final instance = OperationLog();
  final int capacity;
  final _events = <Map<String, Object?>>[];
  final _failures = <Map<String, Object?>>[];
  final _startedAt = DateTime.now().toUtc().toIso8601String();
  String? _appVersion;
  String? _buildNumber;
  int _requestId = 0;

  int nextRequestId() => ++_requestId;

  Map<String, Object?>? latestEvent(String operation) {
    for (final event in _events.reversed) {
      if (event['operation'] == operation) return Map.unmodifiable(event);
    }
    return null;
  }

  Map<String, Object?>? get latestFailure =>
      _failures.isEmpty ? null : Map.unmodifiable(_failures.last);

  Map<String, Object?>? get latestException {
    for (final event in _failures.reversed) {
      if (event.containsKey('exception')) return Map.unmodifiable(event);
    }
    return null;
  }

  void setAppInfo(String version, String buildNumber) {
    _appVersion = _code(version);
    _buildNumber = _code(buildNumber);
  }

  void record(
    String operation, {
    required String outcome,
    int? id,
    int? mangaId,
    int? chapterId,
    int? count,
    int? durationMs,
    int? errorCount,
    int? httpStatus,
    String? errorType,
    AuthIssue? authIssue,
    String? action,
    String? stage,
    String? state,
    int? requestId,
    int? elapsedMs,
    int? attempt,
    int? progressPercent,
    String? reasonCode,
    int? completedPages,
    int? totalPages,
    int? copied,
    int? alreadyCached,
    int? excluded,
    int? failed,
    Object? error,
    StackTrace? stackTrace,
    DateTime? occurredAt,
  }) {
    errorType ??= error?.runtimeType.toString();
    final severity = error != null ||
            (errorCount ?? 0) > 0 ||
            (httpStatus ?? 0) >= 400 ||
            (failed ?? 0) > 0 ||
            state == 'ERROR' ||
            RegExp(r'error|fail|timeout|exception').hasMatch(outcome)
        ? 'error'
        : 'info';
    final frames = stackTrace
        ?.toString()
        .split('\n')
        .map((line) => RegExp(
              r'^\s*#\d+\s+.+?\s+\(((?:package:tachidesk_sorayomi/[A-Za-z0-9_./-]+\.dart|dart:[A-Za-z0-9_./-]+)(?::\d+){1,2})\)\s*$',
            ).firstMatch(line)?.group(1))
        .whereType<String>()
        .take(8)
        .toList();
    final event = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'operation': _code(operation),
      'outcome': _code(outcome),
      'severity': severity,
      if (stage != null) 'stage': _code(stage),
      if (requestId != null) 'requestId': requestId,
      if (action != null) 'action': _code(action),
      if (id != null) 'id': id,
      if (mangaId != null) 'mangaId': mangaId,
      if (chapterId != null) 'chapterId': chapterId,
      if (count != null) 'count': count,
      if (durationMs != null) 'durationMs': durationMs,
      if (elapsedMs != null) 'elapsedMs': elapsedMs,
      if (errorCount != null) 'errorCount': errorCount,
      if (httpStatus != null) 'httpStatus': httpStatus,
      if (errorType != null) 'errorType': _code(errorType),
      if (authIssue != null) 'authIssue': authIssue.name,
      if (state != null) 'state': _code(state),
      if (attempt != null) 'attempt': attempt,
      if (progressPercent != null) 'progressPercent': progressPercent,
      if (reasonCode != null) 'reasonCode': _code(reasonCode),
      if (completedPages != null) 'completedPages': completedPages,
      if (totalPages != null) 'totalPages': totalPages,
      if (copied != null) 'copied': copied,
      if (alreadyCached != null) 'alreadyCached': alreadyCached,
      if (excluded != null) 'excluded': excluded,
      if (failed != null) 'failed': failed,
      if (occurredAt != null) 'occurredAt': occurredAt.toUtc().toIso8601String(),
      if (errorType != null || error != null)
        'exception': {
          'type': _code(error?.runtimeType.toString() ?? errorType!),
          if (reasonCode != null) 'reasonCode': _code(reasonCode),
          if (frames?.isNotEmpty == true) 'stack': frames,
        },
    };
    final entry = [
      event['timestamp'],
      event['operation'],
      event['outcome'],
      if (action != null) 'action=${event['action']}',
      if (id != null) 'id=$id',
      if (mangaId != null) 'mangaId=$mangaId',
      if (chapterId != null) 'chapterId=$chapterId',
      if (count != null) 'count=$count',
      if (durationMs != null) 'durationMs=$durationMs',
      if (errorCount != null) 'errors=$errorCount',
      if (httpStatus != null) 'httpStatus=$httpStatus',
      if (errorType != null) 'errorType=${event['errorType']}',
      if (authIssue != null) 'authIssue=${authIssue.name}',
      for (final key in [
        'stage',
        'requestId',
        'elapsedMs',
        'state',
        'attempt',
        'progressPercent',
        'reasonCode',
        'completedPages',
        'totalPages',
        'copied',
        'alreadyCached',
        'excluded',
        'failed',
        'occurredAt',
      ])
        if (event.containsKey(key)) '$key=${event[key]}',
    ].join(' ');
    _events.add(event);
    if (_events.length > capacity) _events.removeAt(0);
    if (severity == 'error') {
      _failures.add(event);
      if (_failures.length > 50) _failures.removeAt(0);
    }
    final entries = [...value, entry];
    value = List.unmodifiable(
      entries.skip(entries.length > capacity ? entries.length - capacity : 0),
    );
  }

  static String _code(String value) =>
      RegExp(r'^[A-Za-z0-9_.$+-]{1,120}$').hasMatch(value) ? value : 'redacted';

  void clear() {
    _events.clear();
    _failures.clear();
    value = const [];
  }

  String exportJson() => const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        'application': 'Suwayomi-Android',
        'appVersion': _appVersion,
        'buildNumber': _buildNumber,
        'logStartedAt': _startedAt,
        'capacity': capacity,
        'failureCapacity': 50,
        'serverDownloadErrorDetails': 'not_exposed_by_current_server_api',
        'privacy':
            'No credentials, bodies, server URLs, or raw exception messages.',
        'events': _events,
        'recentFailures': _failures,
      });

  String exportText() => 'Suwayomi-Android operation log\n'
      'UTC timestamps; last $capacity operations in this app session.\n'
      'No credentials, request bodies, response bodies, or server URLs.\n\n'
      '${value.join('\n')}\n';
}
