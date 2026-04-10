import 'package:flutter/material.dart';

import 'device_profile_platform.dart'
    if (dart.library.html) 'device_profile_web.dart' as platform;

class DeviceProfile {
  const DeviceProfile._();

  static bool isLikelyMobileBrowser({Uri? uri}) {
    final params = (uri ?? Uri.base).queryParameters;
    final override = params['mobile']?.trim();
    if (override == '1' || override == 'true') return true;
    if (override == '0' || override == 'false') return false;
    return platform.isLikelyMobileBrowser();
  }

  static bool isPhoneWidth(BuildContext context, {double breakpoint = 820}) {
    return MediaQuery.sizeOf(context).width <= breakpoint;
  }
}
