import 'dart:convert';

String meetingAiRealtimeAudioWsPath(String apiPath) {
  if (apiPath.startsWith('/api/')) {
    return '/ws/${apiPath.substring(5)}';
  }
  return apiPath.replaceFirst('/api/', '/ws/');
}

class MeetingRealtimeBotConfig {
  const MeetingRealtimeBotConfig({
    required this.provider,
    required this.baseUrl,
    required this.openaiModel,
    required this.openaiVoice,
    required this.volcModel,
    required this.volcVoice,
    required this.volcWsUrl,
    required this.volcAppId,
    required this.volcResourceId,
    required this.volcUid,
    required this.displayName,
    required this.apiKeySet,
    required this.volcAppKeySet,
    required this.volcAccessKeySet,
  });

  final String provider;
  final String baseUrl;
  final String openaiModel;
  final String openaiVoice;
  final String volcModel;
  final String volcVoice;
  final String volcWsUrl;
  final String volcAppId;
  final String volcResourceId;
  final String volcUid;
  final String displayName;
  final bool apiKeySet;
  final bool volcAppKeySet;
  final bool volcAccessKeySet;

  factory MeetingRealtimeBotConfig.fromMeetingJson(Map<String, dynamic> json) {
    final provider = (json['realtime_bot_provider'] ?? 'openai')
        .toString()
        .trim()
        .toLowerCase();
    final legacyModel = (json['realtime_bot_model'] ?? '').toString().trim();
    final legacyVoice = (json['realtime_bot_voice'] ?? '').toString().trim();
    final openaiModel =
        (json['realtime_bot_openai_model'] ?? '').toString().trim();
    final openaiVoice =
        (json['realtime_bot_openai_voice'] ?? '').toString().trim();
    final volcModel =
        (json['realtime_bot_volc_model'] ?? '').toString().trim();
    final volcVoice =
        (json['realtime_bot_volc_voice'] ?? '').toString().trim();
    return MeetingRealtimeBotConfig(
      provider: provider == 'volcengine' ? 'volcengine' : 'openai',
      baseUrl: (json['realtime_bot_base_url'] ?? 'https://api.openai.com')
          .toString()
          .trim(),
      openaiModel: openaiModel.isNotEmpty
          ? openaiModel
          : legacyModel.isNotEmpty
              ? legacyModel
              : 'gpt-realtime',
      openaiVoice: openaiVoice.isNotEmpty
          ? openaiVoice
          : legacyVoice.isNotEmpty
              ? legacyVoice
              : 'marin',
      volcModel: volcModel.isNotEmpty
          ? volcModel
          : legacyModel.isNotEmpty
              ? legacyModel
              : '2.2.0.0',
      volcVoice: volcVoice.isNotEmpty ? volcVoice : legacyVoice,
      volcWsUrl: (json['realtime_bot_volc_ws_url'] ??
              'wss://openspeech.bytedance.com/api/v3/realtime/dialogue')
          .toString()
          .trim(),
      volcAppId: (json['realtime_bot_volc_app_id'] ?? '').toString().trim(),
      volcResourceId: (json['realtime_bot_volc_resource_id'] ??
              'volc.speech.dialog')
          .toString()
          .trim(),
      volcUid: (json['realtime_bot_volc_uid'] ?? '').toString().trim(),
      displayName:
          (json['realtime_bot_display_name'] ?? '实时语音助手').toString().trim(),
      apiKeySet: _asBool(json['realtime_bot_api_key_set'], false),
      volcAppKeySet: _asBool(json['realtime_bot_volc_app_key_set'], false),
      volcAccessKeySet:
          _asBool(json['realtime_bot_volc_access_key_set'], false),
    );
  }
}

class MeetingRealtimeBotControlsDraft {
  const MeetingRealtimeBotControlsDraft({
    required this.provider,
    required this.enabled,
    required this.muted,
    required this.displayName,
    required this.baseUrl,
    required this.openaiModel,
    required this.openaiVoice,
    required this.volcModel,
    required this.volcVoice,
    required this.volcWsUrl,
    required this.volcAppId,
    required this.volcResourceId,
    required this.volcUid,
    required this.apiKeyAlreadySet,
    required this.volcAccessKeyAlreadySet,
  });

  final String provider;
  final bool enabled;
  final bool muted;
  final String displayName;
  final String baseUrl;
  final String openaiModel;
  final String openaiVoice;
  final String volcModel;
  final String volcVoice;
  final String volcWsUrl;
  final String volcAppId;
  final String volcResourceId;
  final String volcUid;
  final bool apiKeyAlreadySet;
  final bool volcAccessKeyAlreadySet;

  String? validateForSave({
    String apiKey = '',
    String volcAccessKey = '',
  }) {
    if (displayName.trim().isEmpty) return '会议内显示名称不能为空';
    if (provider == 'volcengine') {
      if (volcWsUrl.trim().isEmpty ||
          volcAppId.trim().isEmpty ||
          volcResourceId.trim().isEmpty) {
        return '请完整填写火山引擎 WebSocket / App ID / Resource ID';
      }
      if (enabled &&
          !volcAccessKeyAlreadySet &&
          volcAccessKey.trim().isEmpty) {
        return '启用前请填写火山引擎 Access Key';
      }
      return null;
    }
    if (baseUrl.trim().isEmpty ||
        openaiModel.trim().isEmpty ||
        openaiVoice.trim().isEmpty) {
      return '请完整填写 OpenAI Base URL / Model / Voice';
    }
    if (enabled && !apiKeyAlreadySet && apiKey.trim().isEmpty) {
      return '启用前请填写 OpenAI API Key';
    }
    return null;
  }

  Map<String, dynamic> buildSavePayload({
    String apiKey = '',
    String volcAppKey = '',
    String volcAccessKey = '',
  }) {
    final validationError = validateForSave(
      apiKey: apiKey,
      volcAccessKey: volcAccessKey,
    );
    if (validationError != null) {
      throw ArgumentError(validationError);
    }
    final payload = <String, dynamic>{
      'realtime_bot_provider': provider == 'volcengine' ? 'volcengine' : 'openai',
      'realtime_bot_enabled': enabled,
      'realtime_bot_muted': muted,
      'realtime_bot_display_name': displayName.trim(),
    };
    if (provider == 'volcengine') {
      payload['realtime_bot_volc_model'] =
          volcModel.trim().isEmpty ? '2.2.0.0' : volcModel.trim();
      payload['realtime_bot_volc_voice'] = volcVoice.trim();
      payload['realtime_bot_volc_ws_url'] = volcWsUrl.trim();
      payload['realtime_bot_volc_app_id'] = volcAppId.trim();
      payload['realtime_bot_volc_resource_id'] = volcResourceId.trim();
      payload['realtime_bot_volc_uid'] = volcUid.trim();
      if (volcAppKey.trim().isNotEmpty) {
        payload['realtime_bot_volc_app_key'] = volcAppKey.trim();
      }
      if (volcAccessKey.trim().isNotEmpty) {
        payload['realtime_bot_volc_access_key'] = volcAccessKey.trim();
      }
      return payload;
    }
    payload['realtime_bot_base_url'] = baseUrl.trim();
    payload['realtime_bot_openai_model'] = openaiModel.trim();
    payload['realtime_bot_openai_voice'] = openaiVoice.trim();
    if (apiKey.trim().isNotEmpty) {
      payload['realtime_bot_api_key'] = apiKey.trim();
    }
    return payload;
  }
}

enum RealtimeBotIngressMessageKind {
  ready,
  ack,
  asrInterim,
  asrFinal,
  replyDelta,
  noContent,
  error,
  result,
}

class RealtimeBotIngressMessage {
  const RealtimeBotIngressMessage({
    required this.kind,
    required this.previewText,
    required this.recognizedText,
    required this.detail,
    required this.message,
  });

  final RealtimeBotIngressMessageKind kind;
  final String previewText;
  final String recognizedText;
  final String detail;
  final Map<String, dynamic>? message;
}

RealtimeBotIngressMessage? parseRealtimeBotIngressMessage(dynamic rawData) {
  Map<String, dynamic>? payload;
  if (rawData is String) {
    final text = rawData.trim();
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        payload = decoded;
      } else if (decoded is Map) {
        payload = decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {
      return null;
    }
  } else if (rawData is Map<String, dynamic>) {
    payload = rawData;
  } else if (rawData is Map) {
    payload = rawData.map(
      (key, value) => MapEntry(key.toString(), value),
    );
  }
  if (payload == null) return null;

  final type = (payload['type'] ?? '').toString().trim().toLowerCase();
  switch (type) {
    case 'ready':
      return const RealtimeBotIngressMessage(
        kind: RealtimeBotIngressMessageKind.ready,
        previewText: '',
        recognizedText: '',
        detail: '',
        message: null,
      );
    case 'ack':
      return const RealtimeBotIngressMessage(
        kind: RealtimeBotIngressMessageKind.ack,
        previewText: '',
        recognizedText: '',
        detail: '',
        message: null,
      );
    case 'asr':
      final text = (payload['text'] ?? '').toString().trim();
      final isInterim = _asBool(payload['is_interim'], false);
      return RealtimeBotIngressMessage(
        kind: isInterim
            ? RealtimeBotIngressMessageKind.asrInterim
            : RealtimeBotIngressMessageKind.asrFinal,
        previewText: isInterim ? '' : text,
        recognizedText: text,
        detail: '',
        message: null,
      );
    case 'reply_delta':
      return const RealtimeBotIngressMessage(
        kind: RealtimeBotIngressMessageKind.replyDelta,
        previewText: '',
        recognizedText: '',
        detail: '',
        message: null,
      );
    case 'no_content':
      return const RealtimeBotIngressMessage(
        kind: RealtimeBotIngressMessageKind.noContent,
        previewText: '',
        recognizedText: '',
        detail: '',
        message: null,
      );
    case 'error':
      return RealtimeBotIngressMessage(
        kind: RealtimeBotIngressMessageKind.error,
        previewText: '',
        recognizedText: '',
        detail: (payload['detail'] ?? 'audio ingress failed').toString().trim(),
        message: null,
      );
    case 'result':
      final rawMessage = payload['message'];
      Map<String, dynamic>? normalizedMessage;
      if (rawMessage is Map<String, dynamic>) {
        normalizedMessage = rawMessage;
      } else if (rawMessage is Map) {
        normalizedMessage = rawMessage.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
      return RealtimeBotIngressMessage(
        kind: RealtimeBotIngressMessageKind.result,
        previewText: (payload['preview_text'] ?? '').toString().trim(),
        recognizedText: (payload['recognized_text'] ?? '').toString().trim(),
        detail: '',
        message: normalizedMessage,
      );
    default:
      return null;
  }
}

bool _asBool(dynamic value, bool fallback) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
  }
  return fallback;
}
