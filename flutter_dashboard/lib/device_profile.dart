import 'dart:html' as html;

import 'package:flutter/material.dart';

class DeviceProfile {
  const DeviceProfile._();

  static bool isLikelyMobileBrowser({Uri? uri}) {
    final params = (uri ?? Uri.base).queryParameters;
    final override = params['mobile']?.trim();
    if (override == '1' || override == 'true') return true;
    if (override == '0' || override == 'false') return false;

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

  static bool isPhoneWidth(BuildContext context, {double breakpoint = 820}) {
    return MediaQuery.sizeOf(context).width <= breakpoint;
  }
}
