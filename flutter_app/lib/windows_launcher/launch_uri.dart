Uri parseLauncherBaseUri(String rawInput) {
  final trimmed = rawInput.trim();
  if (trimmed.isEmpty) {
    return Uri.parse('http://127.0.0.1:8000');
  }

  final direct = Uri.tryParse(trimmed);
  if (direct != null && direct.hasScheme) {
    return _normalizeHostOnlyPath(direct);
  }

  final withScheme = Uri.tryParse('http://$trimmed');
  if (withScheme != null && withScheme.hasAuthority) {
    return _normalizeHostOnlyPath(withScheme);
  }

  return Uri.parse('http://127.0.0.1:8000');
}

Uri buildLauncherTargetUri({
  required Uri baseUri,
  required String targetInput,
}) {
  final trimmed = targetInput.trim();
  if (trimmed.isEmpty) {
    return baseUri.resolve('/accounts/login');
  }

  final direct = Uri.tryParse(trimmed);
  if (direct != null && direct.hasScheme) {
    return direct;
  }

  if (trimmed.startsWith('/')) {
    return baseUri.resolve(trimmed);
  }

  return baseUri.resolve('/$trimmed');
}

Uri _normalizeHostOnlyPath(Uri uri) {
  if (uri.path.isEmpty) {
    return uri.replace(path: '');
  }
  return uri;
}

bool canOpenInEmbeddedWebView(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

String normalizeDesktopTargetInput(String rawInput) {
  final trimmed = rawInput.trim();
  if (trimmed.isEmpty) {
    return '/accounts/login';
  }

  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.hasScheme) {
    return trimmed;
  }

  if (trimmed.startsWith('/')) {
    return trimmed;
  }

  final hasPathSeparator = trimmed.contains('/') || trimmed.contains('?');
  if (hasPathSeparator) {
    return '/$trimmed';
  }

  return '/m/$trimmed';
}

String resolveDesktopLivekitUrl({
  required String tokenPayloadUrl,
  required String publicUrlOverrideInput,
}) {
  final override = publicUrlOverrideInput.trim();
  if (override.isEmpty) {
    return tokenPayloadUrl.trim();
  }

  final parsedOverride = Uri.tryParse(override);
  if (parsedOverride != null && parsedOverride.hasScheme) {
    if (!override.contains('://')) {
      final withWs = Uri.tryParse('ws://$override');
      if (withWs != null && withWs.hasAuthority) {
        return withWs.toString();
      }
    }
    final scheme = parsedOverride.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      return parsedOverride
          .replace(scheme: scheme == 'https' ? 'wss' : 'ws')
          .toString();
    }
    return override;
  }

  final withWs = Uri.tryParse('ws://$override');
  if (withWs != null && withWs.hasAuthority) {
    return withWs.toString();
  }

  return override;
}
