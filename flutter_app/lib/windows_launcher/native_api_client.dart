import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/api_exception.dart';
import '../features/dashboard/models.dart';
import '../meeting_room/models.dart';
import 'native_join_target.dart';

class DesktopMeetingApiClient {
  DesktopMeetingApiClient({
    required this.baseUri,
    required this.accessToken,
  });

  final Uri baseUri;
  final String accessToken;

  Uri _uri(String path) => baseUri.resolve(path);

  static Future<String> loginWithPassword({
    required Uri baseUri,
    required String username,
    required String password,
  }) async {
    final response = await http.post(
      baseUri.resolve('/api/auth/login'),
      headers: const <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'username': username,
        'password': password,
      }),
    );
    if (response.statusCode >= 400) {
      throw _apiExceptionFromResponse(response);
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final token = (data['access_token'] ?? '').toString().trim();
    if (token.isEmpty) {
      throw const ApiException(
        statusCode: 500,
        detail: 'Login response did not include access_token',
        payload: null,
      );
    }
    return token;
  }

  Future<UserProfileData> fetchProfile() async {
    final response = await _authedRequest('GET', '/api/profile');
    final payload = await _jsonOrThrow(response) as Map<String, dynamic>;
    return UserProfileData.fromJson(payload);
  }

  Future<UserProfileData> updateProfile({
    required String avatarUrl,
    required String defaultDisplayName,
  }) async {
    final response = await _authedRequest(
      'PATCH',
      '/api/profile',
      body: <String, dynamic>{
        'avatar_url': avatarUrl.trim(),
        'default_display_name': defaultDisplayName.trim(),
      },
    );
    final payload = await _jsonOrThrow(response) as Map<String, dynamic>;
    return UserProfileData.fromJson(payload);
  }

  Future<List<MeetingItem>> fetchMeetings() async {
    final response = await _authedRequest('GET', '/api/meetings');
    final payload = await _jsonOrThrow(response) as List<dynamic>;
    return payload
        .whereType<Map<String, dynamic>>()
        .map(MeetingItem.fromJson)
        .toList();
  }

  Future<MeetingItem> createMeeting(Map<String, dynamic> payload) async {
    final response =
        await _authedRequest('POST', '/api/meetings', body: payload);
    final data = await _jsonOrThrow(response) as Map<String, dynamic>;
    return MeetingItem.fromJson(data);
  }

  Future<MeetingItem> updateMeetingByRef({
    required String meetingRef,
    required Map<String, dynamic> payload,
  }) async {
    final ref = meetingRef.trim();
    if (ref.isEmpty) {
      throw const ApiException(
        statusCode: 400,
        detail: 'Meeting reference is required',
        payload: null,
      );
    }
    final path = '/api/my/meetings/${Uri.encodeComponent(ref)}';
    final response = await _authedRequest('PATCH', path, body: payload);
    final data = await _jsonOrThrow(response) as Map<String, dynamic>;
    return MeetingItem.fromJson(data);
  }

  Future<void> deleteMeetingByRef(String meetingRef) async {
    final ref = meetingRef.trim();
    if (ref.isEmpty) {
      throw const ApiException(
        statusCode: 400,
        detail: 'Meeting reference is required',
        payload: null,
      );
    }
    final path = '/api/my/meetings/${Uri.encodeComponent(ref)}';
    final response = await _authedRequest('DELETE', path);
    await _jsonOrThrow(response);
  }

  Future<Map<String, dynamic>> joinMeetingByRoomName({
    required String roomName,
    String displayName = '',
    String meetingPassword = '',
  }) async {
    final name = roomName.trim();
    if (name.isEmpty) {
      throw const ApiException(
        statusCode: 400,
        detail: 'Room name is required',
        payload: null,
      );
    }
    final body = <String, dynamic>{'room_name': name};
    if (displayName.trim().isNotEmpty) {
      body['display_name'] = displayName.trim();
    }
    if (meetingPassword.trim().isNotEmpty) {
      body['meeting_password'] = meetingPassword.trim();
    }
    final response =
        await _authedRequest('POST', '/api/meetings/join', body: body);
    final data = await _jsonOrThrow(response) as Map<String, dynamic>;
    return data;
  }

  Future<Map<String, dynamic>> fetchJoinTokenJsonForMeetingRef(
      String meetingRef) async {
    final ref = meetingRef.trim();
    if (ref.isEmpty) {
      throw const ApiException(
        statusCode: 400,
        detail: 'Meeting reference is required',
        payload: null,
      );
    }
    final path = '/api/my/meetings/${Uri.encodeComponent(ref)}/join-token';
    final response =
        await _authedRequest('POST', path, body: const <String, dynamic>{});
    final payload = await _jsonOrThrow(response) as Map<String, dynamic>;
    return payload;
  }

  Future<Map<String, dynamic>> fetchRecordingEgressStatusByRef({
    required String meetingRef,
    int waitSeconds = 0,
  }) async {
    final pathBase = _meetingRecordingEgressPathByRef(meetingRef);
    final safeWait = waitSeconds.clamp(0, 30);
    final path = safeWait > 0 ? '$pathBase?wait_seconds=$safeWait' : pathBase;
    final response = await _authedRequest('GET', path);
    final payload = await _jsonOrThrow(response) as Map<String, dynamic>;
    return payload;
  }

  Future<Map<String, dynamic>> startRecordingEgressByRef({
    required String meetingRef,
    String layout = 'grid',
  }) async {
    final path = '${_meetingRecordingEgressPathByRef(meetingRef)}/start';
    final response = await _authedRequest(
      'POST',
      path,
      body: <String, dynamic>{'layout': layout},
    );
    final payload = await _jsonOrThrow(response) as Map<String, dynamic>;
    return payload;
  }

  Future<Map<String, dynamic>> stopRecordingEgressByRef({
    required String meetingRef,
  }) async {
    final path = '${_meetingRecordingEgressPathByRef(meetingRef)}/stop';
    final response =
        await _authedRequest('POST', path, body: const <String, dynamic>{});
    final payload = await _jsonOrThrow(response) as Map<String, dynamic>;
    return payload;
  }

  Future<List<MeetingMemberProfile>> fetchMeetingMembersByRef({
    required String meetingRef,
  }) async {
    final path =
        '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}/members';
    final response = await _authedRequest('GET', path);
    final payload = await _jsonOrThrow(response) as List<dynamic>;
    return payload
        .whereType<Map<String, dynamic>>()
        .map(MeetingMemberProfile.fromJson)
        .toList();
  }

  Future<List<ChatMessage>> fetchMeetingMessagesByRef({
    required String meetingRef,
    int limit = 50,
  }) async {
    final boundedLimit = limit.clamp(1, 200);
    final path =
        '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}/messages?limit=$boundedLimit';
    final response = await _authedRequest('GET', path);
    final payload = await _jsonOrThrow(response) as List<dynamic>;
    return payload
        .whereType<Map<String, dynamic>>()
        .map(ChatMessage.fromJson)
        .toList();
  }

  Future<ChatMessage> sendMeetingMessageByRef({
    required String meetingRef,
    required String content,
  }) async {
    final path =
        '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}/messages';
    final response = await _authedRequest(
      'POST',
      path,
      body: <String, dynamic>{'content': content},
    );
    final payload = await _jsonOrThrow(response) as Map<String, dynamic>;
    return ChatMessage.fromJson(payload);
  }

  Future<void> deleteMeetingMessageByRef({
    required String meetingRef,
    required int messageId,
  }) async {
    final path =
        '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}/messages/$messageId';
    final response = await _authedRequest('DELETE', path);
    await _jsonOrThrow(response);
  }

  Future<MeetingMemberProfile> raiseHandByRef({
    required String meetingRef,
    required String requestType,
  }) async {
    final path =
        '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}/members/raise-hand';
    final response = await _authedRequest(
      'POST',
      path,
      body: <String, dynamic>{'request': requestType},
    );
    final payload = await _jsonOrThrow(response) as Map<String, dynamic>;
    return MeetingMemberProfile.fromJson(payload);
  }

  Future<Map<String, dynamic>> muteAllMembersByRef({
    required String meetingRef,
  }) async {
    final path =
        '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}/members/mute-all';
    final response =
        await _authedRequest('POST', path, body: const <String, dynamic>{});
    final payload = await _jsonOrThrow(response) as Map<String, dynamic>;
    return payload;
  }

  Future<void> patchMeetingMemberActionByRef({
    required String meetingRef,
    required int userId,
    required String action,
    required Map<String, dynamic> payload,
  }) async {
    final normalizedAction = action.trim();
    if (normalizedAction.isEmpty) {
      throw const ApiException(
        statusCode: 400,
        detail: 'Member action is required',
        payload: null,
      );
    }
    final path =
        '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}/members/$userId/${Uri.encodeComponent(normalizedAction)}';
    final response = await _authedRequest('PATCH', path, body: payload);
    await _jsonOrThrow(response);
  }

  Future<void> deleteMeetingMemberByRef({
    required String meetingRef,
    required int userId,
    bool banAfterRemove = false,
  }) async {
    final banValue = banAfterRemove ? 'true' : 'false';
    final path =
        '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}/members/$userId?ban=$banValue';
    final response = await _authedRequest('DELETE', path);
    await _jsonOrThrow(response);
  }

  Future<List<WaitingRoomEntry>> fetchWaitingRoomEntriesByRef({
    required String meetingRef,
  }) async {
    final path =
        '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}/waiting-room';
    final response = await _authedRequest('GET', path);
    final payload = await _jsonOrThrow(response) as List<dynamic>;
    return payload
        .whereType<Map<String, dynamic>>()
        .map(WaitingRoomEntry.fromJson)
        .toList();
  }

  Future<void> reviewWaitingRoomEntryByRef({
    required String meetingRef,
    required int userId,
    required String status,
  }) async {
    final path =
        '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}/waiting-room/$userId';
    final response = await _authedRequest(
      'PATCH',
      path,
      body: <String, dynamic>{'status': status},
    );
    await _jsonOrThrow(response);
  }

  Future<void> hostLeaveWithTransferByRef({
    required String meetingRef,
    required int transferUserId,
  }) async {
    final path =
        '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}/host-leave';
    final response = await _authedRequest(
      'POST',
      path,
      body: <String, dynamic>{'transfer_user_id': transferUserId},
    );
    await _jsonOrThrow(response);
  }

  Future<void> endMeetingForAllByRef({
    required String meetingRef,
  }) async {
    final path =
        '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}';
    final response = await _authedRequest('DELETE', path);
    await _jsonOrThrow(response);
  }

  Future<Map<String, dynamic>> patchMeetingControlsByRef({
    required String meetingRef,
    required Map<String, dynamic> payload,
  }) async {
    final path =
        '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}/controls';
    final response = await _authedRequest(
      'PATCH',
      path,
      body: payload,
    );
    final data = await _jsonOrThrow(response) as Map<String, dynamic>;
    return data;
  }

  Future<JoinTokenPayload> fetchJoinTokenForMeetingRef(
      String meetingRef) async {
    final ref = meetingRef.trim();
    if (ref.isEmpty) {
      throw const ApiException(
        statusCode: 400,
        detail: 'Meeting reference is required',
        payload: null,
      );
    }
    final path = '/api/my/meetings/${Uri.encodeComponent(ref)}/join-token';
    final response = await _authedRequest('POST', path, body: const {});
    final payload = await _jsonOrThrow(response) as Map<String, dynamic>;
    return JoinTokenPayload.fromJson(payload);
  }

  String _meetingRecordingEgressPathByRef(String meetingRef) {
    return '/api/my/meetings/${Uri.encodeComponent(_requireRef(meetingRef))}/recordings/egress';
  }

  String _requireRef(String meetingRef) {
    final ref = meetingRef.trim();
    if (ref.isEmpty) {
      throw const ApiException(
        statusCode: 400,
        detail: 'Meeting reference is required',
        payload: null,
      );
    }
    return ref;
  }

  Future<JoinTokenPayload> fetchJoinTokenForShareCode({
    required String shareCode,
    String displayName = '',
    String meetingPassword = '',
  }) async {
    final code = shareCode.trim();
    if (code.isEmpty) {
      throw const ApiException(
        statusCode: 400,
        detail: 'Share code is required',
        payload: null,
      );
    }
    final path =
        '/api/public/meetings/share/${Uri.encodeComponent(code)}/join-token';
    final body = <String, dynamic>{};
    if (displayName.trim().isNotEmpty) {
      body['display_name'] = displayName.trim();
    }
    if (meetingPassword.trim().isNotEmpty) {
      body['meeting_password'] = meetingPassword.trim();
    }
    final response = await _authedRequest('POST', path, body: body);
    final payload = await _jsonOrThrow(response) as Map<String, dynamic>;
    return JoinTokenPayload.fromJson(payload);
  }

  Future<JoinTokenPayload> fetchJoinTokenFromRoomName({
    required String roomName,
    String displayName = '',
    String meetingPassword = '',
  }) async {
    final name = roomName.trim();
    if (name.isEmpty) {
      throw const ApiException(
        statusCode: 400,
        detail: 'Room name is required',
        payload: null,
      );
    }

    final joinBody = <String, dynamic>{'room_name': name};
    if (displayName.trim().isNotEmpty) {
      joinBody['display_name'] = displayName.trim();
    }
    if (meetingPassword.trim().isNotEmpty) {
      joinBody['meeting_password'] = meetingPassword.trim();
    }

    final joinResponse =
        await _authedRequest('POST', '/api/meetings/join', body: joinBody);
    final joinedData = await _jsonOrThrow(joinResponse) as Map<String, dynamic>;
    final meetingRef = (joinedData['meeting_ref'] ?? '').toString().trim();
    if (meetingRef.isNotEmpty) {
      return fetchJoinTokenForMeetingRef(meetingRef);
    }
    final shareCode = (joinedData['share_code'] ?? '').toString().trim();
    if (shareCode.isNotEmpty) {
      return fetchJoinTokenForShareCode(
        shareCode: shareCode,
        displayName: displayName,
        meetingPassword: meetingPassword,
      );
    }

    throw const ApiException(
      statusCode: 500,
      detail: 'Meeting join succeeded but join token target is missing',
      payload: null,
    );
  }

  Future<JoinTokenPayload> fetchJoinTokenFromTarget({
    required DesktopJoinTarget target,
    String displayName = '',
    String meetingPassword = '',
  }) async {
    ApiException? lastError;

    final ref = target.meetingRef?.trim() ?? '';
    if (ref.isNotEmpty) {
      try {
        return await fetchJoinTokenForMeetingRef(ref);
      } on ApiException catch (error) {
        lastError = error;
      }
    }

    final share = target.shareCode?.trim() ?? '';
    if (share.isNotEmpty) {
      try {
        return await fetchJoinTokenForShareCode(
          shareCode: share,
          displayName: displayName,
          meetingPassword: meetingPassword,
        );
      } on ApiException catch (error) {
        lastError = error;
      }
    }

    final roomName = target.roomName?.trim() ?? '';
    if (roomName.isNotEmpty) {
      try {
        return await fetchJoinTokenFromRoomName(
          roomName: roomName,
          displayName: displayName,
          meetingPassword: meetingPassword,
        );
      } on ApiException catch (error) {
        lastError = error;
      }
    }

    throw lastError ??
        const ApiException(
          statusCode: 400,
          detail: 'Unable to resolve a meeting target from the input',
          payload: null,
        );
  }

  Future<http.Response> _authedRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final headers = <String, String>{
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    };
    final uri = _uri(path);
    switch (method) {
      case 'POST':
        return http.post(
          uri,
          headers: headers,
          body: jsonEncode(body ?? const {}),
        );
      case 'PATCH':
        return http.patch(
          uri,
          headers: headers,
          body: jsonEncode(body ?? const {}),
        );
      case 'DELETE':
        return http.delete(uri, headers: headers);
      default:
        return http.get(uri, headers: headers);
    }
  }

  static Future<dynamic> _jsonOrThrow(http.Response response) async {
    if (response.statusCode >= 400) {
      throw _apiExceptionFromResponse(response);
    }
    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }
    return jsonDecode(response.body);
  }

  static ApiException _apiExceptionFromResponse(http.Response response) {
    String detail = 'Request failed (${response.statusCode})';
    Map<String, dynamic>? payloadMap;
    if (response.body.isNotEmpty) {
      try {
        final payload = jsonDecode(response.body);
        if (payload is Map<String, dynamic>) {
          payloadMap = payload;
          if (payload['detail'] != null) {
            detail = payload['detail'].toString();
          } else {
            detail = response.body;
          }
        } else {
          detail = response.body;
        }
      } catch (_) {
        detail = response.body;
      }
    }
    return ApiException(
      statusCode: response.statusCode,
      detail: detail,
      payload: payloadMap,
    );
  }
}
