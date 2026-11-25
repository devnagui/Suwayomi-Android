import 'dart:async';
import 'dart:io';

import 'package:gql/ast.dart';
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
    final operation = request.operation.operationName ??
        request.operation.document.definitions
            .whereType<OperationDefinitionNode>()
            .firstOrNull
            ?.name
            ?.value ??
        'AnonymousOperation';
    final input = request.variables['input'];
    final inputMap =
        input is Map<String, dynamic> ? input : const <String, dynamic>{};
    final ids = request.variables['ids'] ?? inputMap['ids'];
    final id = request.variables['id'] ?? inputMap['id'];
    final mangaId = request.variables['mangaId'] ?? inputMap['mangaId'];
    final chapterId = request.variables['chapterId'] ?? inputMap['chapterId'];
    final requestId = operationLog.nextRequestId();
    final isSubscription = request.operation.document.definitions
        .whereType<OperationDefinitionNode>()
        .any((definition) => definition.type == OperationType.subscription);
    final stage = isSubscription ? 'subscription' : 'api_request';
    final stopwatch = Stopwatch()..start();
    operationLog.record(
      operation,
      outcome: 'started',
      stage: stage,
      requestId: requestId,
      id: id is int ? id : null,
      mangaId: mangaId is int ? mangaId : null,
      chapterId: chapterId is int ? chapterId : null,
      count: ids is List ? ids.length : null,
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
                : isSubscription ? 'event' : 'response',
            stage: stage,
            requestId: requestId,
            id: id is int ? id : null,
            mangaId: mangaId is int ? mangaId : null,
            chapterId: chapterId is int ? chapterId : null,
            count: _nodeCount(response.data),
            durationMs: isSubscription ? null : stopwatch.elapsedMilliseconds,
            elapsedMs: isSubscription ? stopwatch.elapsedMilliseconds : null,
            errorCount: response.errors?.length ?? 0,
            reasonCode: response.errors?.isNotEmpty == true
                ? _graphQlReason(response.errors!)
                : null,
            errorType:
                response.errors?.isNotEmpty == true ? 'GraphQLError' : null,
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
            stage: stage,
            requestId: requestId,
            id: id is int ? id : null,
            mangaId: mangaId is int ? mangaId : null,
            chapterId: chapterId is int ? chapterId : null,
            durationMs: isSubscription ? null : stopwatch.elapsedMilliseconds,
            elapsedMs: isSubscription ? stopwatch.elapsedMilliseconds : null,
            error: error is LinkException
                ? error.originalException ?? error
                : error,
            stackTrace: stackTrace,
            reasonCode: _transportReason(error, status),
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

  String _graphQlReason(List<GraphQLError> errors) {
    for (final error in errors) {
      final message = error.message.toLowerCase();
      if (message.contains('timed out waiting for webview')) {
        return 'server_webview_timeout';
      }
      if (message.contains('nullpointerexception')) {
        return 'server_null_pointer_exception';
      }
      if (message.contains('outofmemoryerror')) {
        return 'server_out_of_memory_error';
      }
      if (message.contains('no space left on device')) {
        return 'server_storage_full';
      }
      final authIssue = classifyAuthIssue(error.message);
      if (authIssue == AuthIssue.apiValidation) {
        return 'graphql_validation_error';
      }
      if (authIssue != null) {
        return 'authentication_failure';
      }
    }
    return 'graphql_errors_returned';
  }

  String _transportReason(Object error, int? status) {
    final cause = error is LinkException ? error.originalException : error;
    if (cause is TimeoutException) return 'request_timeout';
    if (cause is SocketException) return 'network_unavailable';
    if (cause is HandshakeException) return 'tls_handshake_failed';
    if (cause is FormatException) return 'invalid_response';
    if (status == 401 || status == 403) return 'authentication_required';
    if (status != null) return 'http_error';
    return 'transport_failure';
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
