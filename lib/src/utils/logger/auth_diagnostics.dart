enum AuthIssue {
  alreadyAuthenticated,
  unauthorized,
  forbidden,
  invalidCredentials,
  tokenExpired,
  tokenRevoked,
  apiValidation,
}

AuthIssue? classifyAuthIssue(String message) {
  final value = message.toLowerCase();
  if (value.contains('already logged-in') ||
      value.contains('already logged in')) {
    return AuthIssue.alreadyAuthenticated;
  }
  if (value.contains('incorrect username or password') ||
      value.contains('invalid credentials')) {
    return AuthIssue.invalidCredentials;
  }
  if (value.contains('expired')) return AuthIssue.tokenExpired;
  if (value.contains('revoked') || value.contains('password change')) {
    return AuthIssue.tokenRevoked;
  }
  if (value.contains('unauthorized') || value.contains('authentication')) {
    return AuthIssue.unauthorized;
  }
  if (value.contains('forbidden')) return AuthIssue.forbidden;
  if (value.contains('validation error') || value.contains('fieldundefined')) {
    return AuthIssue.apiValidation;
  }
  return null;
}

String redactAuthError(String message, Iterable<String?> secrets) {
  var result = message;
  for (final secret in secrets) {
    if (secret != null && secret.isNotEmpty) {
      result = result.replaceAll(secret, '[redacted]');
    }
  }
  result = result.replaceAll(
    RegExp(r'\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    '[redacted authorization]',
  );
  return result.replaceAll(
    RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
    '[redacted token]',
  );
}
