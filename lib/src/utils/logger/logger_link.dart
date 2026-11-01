import 'dart:async';

import 'package:graphql/client.dart';

import 'auth_diagnostics.dart';
import 'operation_log.dart';

class LoggerLink extends Link {
  LoggerLink({OperationLog? operationLog})
      : operationLog = operationLog ?? OperationLog.instance;

  final OperationLog operationLog;

  @override
  Stream<Response> request(
    Request request, [
    NextLink? forward,
  ]) {
    if (forward == null) {
      throw StateError('LoggerLink requires a following link');
    }
    final operation = request.operation.operationName ?? 'AnonymousOperation';
    final input = request.variables['input'];
    final inputMap =
        input is Map<String, dynamic> ? input : const <String, dynamic>{};
    final id = request.variables['id'] ?? inputMap['id'];
    final mangaId = request.variables['mangaId'] ?? inputMap['mangaId'];
    final chapterId = request.variables['chapterId'] ?? inputMap['chapterId'];
    final stopwatch = Stopwatch()..start();
    operationLog.record(
      operation,
      outcome: 'started',
      id: id is int ? id : null,
      mangaId: mangaId is int ? mangaId : null,
      chapterId: chapterId is int ? chapterId : null,
    );
    return forward(request).transform(
      StreamTransformer<Response, Response>.fromHandlers(
        handleData: (response, sink) {
          AuthIssue? authIssue;
          for (final error in response.errors ?? const <GraphQLError>[]) {
            authIssue ??= classifyAuthIssue(error.message);
          }
          operationLog.record(
            operation,
            outcome: response.errors?.isNotEmpty == true
                ? 'graphql_error'
                : 'response',
            count: _nodeCount(response.data),
            durationMs: stopwatch.elapsedMilliseconds,
            errorCount: response.errors?.length ?? 0,
            httpStatus:
                response.context.entry<HttpLinkResponseContext>()?.statusCode,
            authIssue: authIssue,
          );
          sink.add(response);
        },
        handleError: (error, stackTrace, sink) {
          final status = error is HttpLinkServerException
              ? error.response.statusCode
              : null;
          operationLog.record(
            operation,
            outcome: 'transport_error',
            durationMs: stopwatch.elapsedMilliseconds,
            errorType: error.runtimeType.toString(),
            httpStatus: status,
            authIssue: status == 401
                ? AuthIssue.unauthorized
                : status == 403
                    ? AuthIssue.forbidden
                    : null,
          );
          sink.addError(error, stackTrace);
        },
        handleDone: (sink) {
          stopwatch.stop();
          sink.close();
        },
      ),
    );
  }

  int? _nodeCount(dynamic value) {
    if (value is Map) {
      final nodes = value['nodes'];
      if (nodes is List) return nodes.length;
      for (final nested in value.values) {
        final count = _nodeCount(nested);
        if (count != null) return count;
      }
    }
    return null;
  }
}
