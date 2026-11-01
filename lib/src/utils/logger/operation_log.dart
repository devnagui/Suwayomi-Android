import 'package:flutter/foundation.dart';

import 'auth_diagnostics.dart';

class OperationLog extends ValueNotifier<List<String>> {
  OperationLog({this.capacity = 500}) : super(const []) {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
  }

  static final instance = OperationLog();
  final int capacity;

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
  }) {
    final entry = [
      DateTime.now().toUtc().toIso8601String(),
      operation,
      outcome,
      if (id != null) 'id=$id',
      if (mangaId != null) 'mangaId=$mangaId',
      if (chapterId != null) 'chapterId=$chapterId',
      if (count != null) 'count=$count',
      if (durationMs != null) 'durationMs=$durationMs',
      if (errorCount != null) 'errors=$errorCount',
      if (httpStatus != null) 'httpStatus=$httpStatus',
      if (errorType != null) 'errorType=$errorType',
      if (authIssue != null) 'authIssue=${authIssue.name}',
    ].join(' ');
    final entries = [...value, entry];
    value = List.unmodifiable(
      entries.skip(entries.length > capacity ? entries.length - capacity : 0),
    );
  }

  void clear() => value = const [];

  String exportText() => 'Suwayomi-Android operation log\n'
      'UTC timestamps; last $capacity operations in this app session.\n'
      'No credentials, request bodies, response bodies, or server URLs.\n\n'
      '${value.join('\n')}\n';
}
