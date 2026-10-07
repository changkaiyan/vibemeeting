/// Capture capability is independent of the URL scheme: some HTTP contexts
/// expose mediaDevices, and a supported browser without a microphone still joins.
class JoinCapturePolicy {
  const JoinCapturePolicy({
    required this.mediaDevicesAvailable,
    required this.microphoneRequested,
    required this.cameraRequested,
  });

  final bool mediaDevicesAvailable;
  final bool microphoneRequested;
  final bool cameraRequested;

  bool get microphoneEnabled => mediaDevicesAvailable && microphoneRequested;
  bool get cameraEnabled => mediaDevicesAvailable && cameraRequested;
  String? get warning => mediaDevicesAvailable
      ? null
      : '当前浏览器未提供媒体采集接口，正在尝试以旁听方式入会。'
          '如需麦克风、摄像头或屏幕共享，请使用浏览器支持的安全访问环境。';
}
