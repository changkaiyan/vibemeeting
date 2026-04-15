double clampRemoteControlUnit(num value) {
  if (value.isNaN) return 0;
  if (value < 0) return 0;
  if (value > 1) return 1;
  return value.toDouble();
}

({int x, int y}) mapNormalizedToScreenPoint({
  required double x,
  required double y,
  required int screenWidth,
  required int screenHeight,
}) {
  final width = screenWidth <= 1 ? 1 : screenWidth;
  final height = screenHeight <= 1 ? 1 : screenHeight;
  final clampedX = clampRemoteControlUnit(x);
  final clampedY = clampRemoteControlUnit(y);
  return (
    x: (clampedX * (width - 1)).round(),
    y: (clampedY * (height - 1)).round(),
  );
}

int? windowsVirtualKeyFromHidUsage(int usage) {
  if (usage >= 0x70004 && usage <= 0x7001D) {
    return 0x41 + (usage - 0x70004);
  }
  if (usage >= 0x7001E && usage <= 0x70026) {
    return 0x31 + (usage - 0x7001E);
  }
  if (usage == 0x70027) {
    return 0x30;
  }
  if (usage >= 0x7003A && usage <= 0x70045) {
    return 0x70 + (usage - 0x7003A);
  }

  switch (usage) {
    case 0x70028:
      return 0x0D; // Enter
    case 0x70029:
      return 0x1B; // Escape
    case 0x7002A:
      return 0x08; // Backspace
    case 0x7002B:
      return 0x09; // Tab
    case 0x7002C:
      return 0x20; // Space
    case 0x70049:
      return 0x2D; // Insert
    case 0x7004A:
      return 0x24; // Home
    case 0x7004B:
      return 0x21; // Page Up
    case 0x7004C:
      return 0x2E; // Delete
    case 0x7004D:
      return 0x23; // End
    case 0x7004E:
      return 0x22; // Page Down
    case 0x7004F:
      return 0x27; // Right
    case 0x70050:
      return 0x25; // Left
    case 0x70051:
      return 0x28; // Down
    case 0x70052:
      return 0x26; // Up
    case 0x700E0:
      return 0xA2; // Left Ctrl
    case 0x700E1:
      return 0xA0; // Left Shift
    case 0x700E2:
      return 0xA4; // Left Alt
    case 0x700E3:
      return 0x5B; // Left Win
    case 0x700E4:
      return 0xA3; // Right Ctrl
    case 0x700E5:
      return 0xA1; // Right Shift
    case 0x700E6:
      return 0xA5; // Right Alt
    case 0x700E7:
      return 0x5C; // Right Win
    default:
      return null;
  }
}
