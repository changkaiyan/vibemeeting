String workspaceSttReadyStateLabel(int? readyState) {
  switch (readyState) {
    case 0:
      return 'connecting';
    case 1:
      return 'open';
    case 2:
      return 'closing';
    case 3:
      return 'closed';
    default:
      return 'not-created';
  }
}

String workspaceSttErrorLabel(String? errorText) {
  final text = (errorText ?? '').trim();
  return text.isEmpty ? '-' : text;
}
