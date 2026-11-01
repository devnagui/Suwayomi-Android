part of '../custom_extensions.dart';

Future<QueryResult<T>> networkFirstQuery<T>(
  Future<QueryResult<T>> Function(FetchPolicy policy) query,
) async {
  final result = await query(FetchPolicy.networkOnly);
  final exception = result.exception;
  if (exception != null &&
      exception.graphqlErrors.isEmpty &&
      (exception.linkException is NetworkException ||
          exception.linkException?.originalException is TimeoutException)) {
    final cached = await query(FetchPolicy.cacheOnly);
    if (!cached.hasException && cached.data != null) {
      logger.w('Server unavailable; showing cached query data');
      OperationLog.instance
          .record('NetworkFirstQuery', outcome: 'offline_cache');
      return cached;
    }
  }
  return result;
}

extension GraphQlExtensions<T> on QueryResult<T> {
  T? get result {
    if (hasException && exception != null) {
      OperationLog.instance.record(
        'GraphQLResult',
        outcome: 'failed',
        errorType:
            exception!.linkException?.runtimeType.toString() ?? 'GraphQLError',
        errorCount: exception!.graphqlErrors.length,
      );
      if (kDebugMode) {
        exception?.log();
      }
      throw OperationMessageException(exception!);
    }
    return parsedData;
  }
}

extension FutureGraphQlExtensions<T> on Future<QueryResult<T>> {
  Future<U?> getData<U>(Convert<T, U?> parse) =>
      then((res) => res.result.apply(parse));
}

extension ObservableGraphQlExtensions<T> on ObservableQuery<T> {
  Stream<U?> getData<U>(Convert<T, U?> parse) =>
      stream.map((res) => res.result.apply(parse));
}

extension StreamGraphQlExtensions<T> on Stream<QueryResult<T>> {
  Stream<T?> get data => map((response) => response.result);

  Stream<U?> getData<U>(Convert<T, U?> parse) =>
      map((res) => res.result.apply(parse));
}

class OperationMessageException implements Exception {
  final OperationException exception;

  OperationMessageException(this.exception);

  @override
  String toString() {
    StringBuffer toString = StringBuffer();
    List<GraphQLError> graphqlErrors = exception.graphqlErrors;
    for (GraphQLError error in graphqlErrors) {
      if (toString.isNotEmpty) toString.write(', ');
      toString.write(error.message);
    }
    LinkException? linkException = exception.linkException;
    if (linkException != null && linkException.originalException != null) {
      if (toString.isNotEmpty) toString.write(', ');

      if (linkException is ServerException) {
        toString.write((linkException.parsedResponse?.response).toToastString);
      } else {
        toString.write(linkException.originalException);
      }
    }
    return toString.toString();
  }
}
