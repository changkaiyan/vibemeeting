import 'dart:html' as html;

bool isLikelyMobileBrowser() {
  final ua = html.window.navigator.userAgent.toLowerCase();
  const mobileKeywords = <String>[
    'android',
    'iphone',
    'ipad',
    'ipod',
    'mobile',
    'harmonyos',
    'windows phone',
  ];
  final matchesUserAgent = mobileKeywords.any(ua.contains);
  if (matchesUserAgent) return true;

  final touchPoints = html.window.navigator.maxTouchPoints ?? 0;
  final width = html.window.screen?.width ?? html.window.innerWidth ?? 0;
  return touchPoints > 0 && width <= 900;
}
