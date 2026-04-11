import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../app/theme/meeting_theme.dart';
import '../../core/api_exception.dart';
import '../../device_profile.dart';
import '../billing/models.dart';
import 'models.dart';

class DashboardPage extends StatefulWidget {
  final bool preferMobileLayout;

  const DashboardPage({
    super.key,
    this.preferMobileLayout = false,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  static const Map<String, String> _meetingRecurrenceLabels = <String, String>{
    'once': '一次',
    'daily': '每天',
    'weekly': '每周',
    'monthly': '每月',
  };
  static const Map<String, String> _meetingTimezoneLabels = <String, String>{
    'Asia/Shanghai': '东八区 (Asia/Shanghai)',
    'UTC': 'UTC',
    'Asia/Tokyo': '日本 (Asia/Tokyo)',
    'America/Los_Angeles': '美西 (America/Los_Angeles)',
    'America/New_York': '美东 (America/New_York)',
    'Europe/London': '英国 (Europe/London)',
  };

  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _scheduledStartController = TextEditingController();
  final _durationController = TextEditingController(text: '30');
  final _maxParticipantsController = TextEditingController(text: '100');
  final _passwordController = TextEditingController();

  final _joinRoomController = TextEditingController();
  final _joinPasswordController = TextEditingController();
  final _profileDisplayNameController = TextEditingController();
  final _profileAvatarUrlController = TextEditingController();
  final _recordingSearchController = TextEditingController();
  final _recordingStorageController = TextEditingController();

  bool _waitingRoomEnabled = false;
  String _meetingRecurrence = 'once';
  String _meetingTimezone = 'Asia/Shanghai';
  bool _allowGuestLinkJoin = true;
  bool _allowRecording = true;
  bool _allowScreenShare = true;
  bool _allowChat = true;
  bool _allowSelfUnmute = true;
  bool _allowMemberVideo = true;
  bool _muteOnEntry = false;

  String _status = '系统就绪';
  bool _statusIsError = false;
  String _accessToken = '';
  UserProfileData? _profile;
  List<MeetingItem> _meetings = [];
  List<RecordingItem> _recordings = [];
  bool _loading = false;
  bool _loadingRecordings = false;
  final Set<int> _deletingRecordingIds = <int>{};
  bool _savingRecordingStorage = false;
  String _recordingStorageRoot = '';
  String _recordingStorageUpdatedBy = '';
  String _recordingStorageUpdatedAt = '';

  MeetingThemePalette get _palette => MeetingTheme.of(context);

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _scheduledStartController.dispose();
    _durationController.dispose();
    _maxParticipantsController.dispose();
    _passwordController.dispose();
    _joinRoomController.dispose();
    _joinPasswordController.dispose();
    _profileDisplayNameController.dispose();
    _profileAvatarUrlController.dispose();
    _recordingSearchController.dispose();
    _recordingStorageController.dispose();
    super.dispose();
  }

  Uri _uri(String path) => Uri.base.resolve(path);

  void _setStatus(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusIsError = isError;
    });
  }

  String _friendlyError(Object error) {
    if (error is ApiException) {
      return error.detail;
    }
    final text = error.toString();
    if (text.startsWith('Exception: ')) {
      return text.substring('Exception: '.length);
    }
    return text;
  }

  bool _isWaitingRoomPendingError(Object error) {
    if (error is! ApiException) return false;
    final status = (error.payload?['waiting_room_status'] ?? '').toString();
    return error.statusCode == 403 && status == 'pending';
  }

  String _formatScheduledStart(String? raw) {
    if (raw == null || raw.isEmpty) return '未设置';
    var text = raw.replaceFirst('T', ' ');
    final dotIndex = text.indexOf('.');
    if (dotIndex > 0) {
      text = text.substring(0, dotIndex);
    }
    if (text.endsWith('Z')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  String _meetingRecurrenceLabel(String value) {
    final key = value.trim();
    return _meetingRecurrenceLabels[key] ?? key;
  }

  String _meetingTimezoneLabel(String value) {
    final key = value.trim();
    return _meetingTimezoneLabels[key] ?? key;
  }

  String _twoDigits(int value) => value.toString().padLeft(2, '0');

  String _formatDateTimeForInput(DateTime value) {
    return '${value.year}-${_twoDigits(value.month)}-${_twoDigits(value.day)} '
        '${_twoDigits(value.hour)}:${_twoDigits(value.minute)}';
  }

  DateTime? _parseDateTimeInput(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final direct = DateTime.tryParse(text);
    if (direct != null) return direct.toLocal();
    final normalized = text.replaceAll('/', '-');
    final match = RegExp(
      r'^(\d{4})-(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{1,2})$',
    ).firstMatch(normalized);
    if (match == null) return null;
    final year = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    final day = int.tryParse(match.group(3)!);
    final hour = int.tryParse(match.group(4)!);
    final minute = int.tryParse(match.group(5)!);
    if (year == null ||
        month == null ||
        day == null ||
        hour == null ||
        minute == null) {
      return null;
    }
    return DateTime(year, month, day, hour, minute);
  }

  String _scheduledInputValue(String? raw) {
    final parsed = _parseDateTimeInput(raw ?? '');
    if (parsed == null) return '';
    return _formatDateTimeForInput(parsed);
  }

  String? _scheduledStartPayloadValue(String raw) {
    final parsed = _parseDateTimeInput(raw);
    if (parsed == null) {
      final trimmed = raw.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return parsed.toIso8601String();
  }

  Future<void> _pickScheduledStartForController(
    TextEditingController controller, {
    void Function(VoidCallback fn)? setStateDialog,
  }) async {
    final now = DateTime.now();
    final initial = _parseDateTimeInput(controller.text) ?? now;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 10),
    );
    if (pickedDate == null || !mounted) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (pickedTime == null) return;
    final next = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );
    final update = () {
      controller.text = _formatDateTimeForInput(next);
    };
    if (setStateDialog != null) {
      setStateDialog(update);
    } else {
      setState(update);
    }
  }

  String _defaultMeetingTitle() {
    final profileName = (_profile?.defaultDisplayName ?? '').trim();
    final username = (_profile?.username ?? '').trim();
    final displayName = profileName.isNotEmpty
        ? profileName
        : (username.isNotEmpty ? username : '用户');
    return '${displayName}预定的会议';
  }

  Future<void> _bootstrap() async {
    try {
      await _ensureJwt(force: true);
      await _loadProfile();
      await _loadMeetings();
      if (_profile?.isAdmin ?? false) {
        await _loadRecordingStorageConfig(silent: true);
      }
      await _loadRecordings(silent: true);
    } catch (e) {
      _setStatus('初始化失败：${_friendlyError(e)}', isError: true);
    }
  }

  Future<String> _ensureJwt({bool force = false}) async {
    if (!force && _accessToken.isNotEmpty) return _accessToken;
    final res = await http.get(_uri('/auth/jwt'));
    if (res.statusCode >= 400) {
      throw Exception('登录会话已失效，请重新登录');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    _accessToken = (data['access_token'] ?? '').toString();
    if (_accessToken.isEmpty) {
      throw Exception('无法获取访问令牌');
    }
    return _accessToken;
  }

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool retry = true,
  }) async {
    final token = await _ensureJwt();
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    final uri = _uri(path);
    http.Response res;
    switch (method) {
      case 'POST':
        res = await http.post(uri,
            headers: headers, body: jsonEncode(body ?? {}));
        break;
      case 'PATCH':
        res = await http.patch(uri,
            headers: headers, body: jsonEncode(body ?? {}));
        break;
      case 'DELETE':
        res = await http.delete(uri, headers: headers);
        break;
      default:
        res = await http.get(uri, headers: headers);
        break;
    }
    if (res.statusCode == 401 && retry) {
      await _ensureJwt(force: true);
      return _request(method, path, body: body, retry: false);
    }
    return res;
  }

  Future<dynamic> _jsonOrThrow(http.Response response) async {
    if (response.statusCode >= 400) {
      String detail = '请求失败（${response.statusCode}）';
      Map<String, dynamic>? payloadMap;
      if (response.body.isNotEmpty) {
        try {
          final payload = jsonDecode(response.body);
          if (payload is Map<String, dynamic> && payload['detail'] != null) {
            payloadMap = payload;
            detail = payload['detail'].toString();
          } else {
            detail = response.body;
          }
        } catch (_) {
          detail = response.body;
        }
      }
      throw ApiException(
        statusCode: response.statusCode,
        detail: detail,
        payload: payloadMap,
      );
    }
    if (response.body.isEmpty) return {};
    return jsonDecode(response.body);
  }

  Future<void> _loadProfile() async {
    final res = await _request('GET', '/api/profile');
    final data = await _jsonOrThrow(res) as Map<String, dynamic>;
    if (!mounted) return;
    setState(() {
      _profile = UserProfileData.fromJson(data);
    });
  }

  Future<bool> _saveProfile({
    required String avatarUrl,
    required String defaultDisplayName,
  }) async {
    final displayName = defaultDisplayName.trim();
    if (displayName.isEmpty) {
      _setStatus('默认显示名称不能为空', isError: true);
      return false;
    }
    try {
      final res = await _request(
        'PATCH',
        '/api/profile',
        body: {
          'avatar_url': avatarUrl.trim(),
          'default_display_name': displayName,
        },
      );
      final data = await _jsonOrThrow(res) as Map<String, dynamic>;
      if (!mounted) return false;
      setState(() {
        _profile = UserProfileData.fromJson(data);
      });
      _setStatus('个人资料已更新');
      return true;
    } catch (e) {
      _setStatus('更新个人资料失败：${_friendlyError(e)}', isError: true);
      return false;
    }
  }

  Future<void> _loadMeetings() async {
    setState(() => _loading = true);
    try {
      final res = await _request('GET', '/api/meetings');
      final list = await _jsonOrThrow(res) as List<dynamic>;
      setState(() {
        _meetings = list
            .map((e) => MeetingItem.fromJson(e as Map<String, dynamic>))
            .toList();
      });
      _setStatus('会议列表已刷新');
    } catch (e) {
      _setStatus('加载会议失败：${_friendlyError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshDashboardData() async {
    await _loadMeetings();
    await _loadRecordings(silent: true);
    if (_profile?.isAdmin ?? false) {
      await _loadRecordingStorageConfig(silent: true);
    }
  }

  Future<void> _loadRecordingStorageConfig({bool silent = false}) async {
    if (!(_profile?.isAdmin ?? false)) return;
    try {
      final res = await _request('GET', '/api/system/recording-storage');
      final data = await _jsonOrThrow(res) as Map<String, dynamic>;
      if (!mounted) return;
      final root = (data['storage_root'] ?? '').toString();
      setState(() {
        _recordingStorageRoot = root;
        _recordingStorageUpdatedBy =
            (data['updated_by_username'] ?? '').toString();
        _recordingStorageUpdatedAt = (data['updated_at'] ?? '').toString();
        _recordingStorageController.text = root;
      });
      if (!silent) {
        _setStatus('录制存放目录已刷新');
      }
    } catch (e) {
      if (!silent) {
        _setStatus('加载录制目录失败：${_friendlyError(e)}', isError: true);
      }
    }
  }

  Future<void> _saveRecordingStorageConfig() async {
    final root = _recordingStorageController.text.trim();
    if (root.isEmpty) {
      _setStatus('录制存放目录不能为空', isError: true);
      return;
    }
    setState(() => _savingRecordingStorage = true);
    try {
      final res = await _request(
        'PATCH',
        '/api/system/recording-storage',
        body: {'storage_root': root},
      );
      final data = await _jsonOrThrow(res) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _recordingStorageRoot = (data['storage_root'] ?? '').toString();
        _recordingStorageUpdatedBy =
            (data['updated_by_username'] ?? '').toString();
        _recordingStorageUpdatedAt = (data['updated_at'] ?? '').toString();
        _recordingStorageController.text = _recordingStorageRoot;
      });
      _setStatus('录制存放目录已保存');
    } catch (e) {
      _setStatus('保存录制目录失败：${_friendlyError(e)}', isError: true);
    } finally {
      if (mounted) {
        setState(() => _savingRecordingStorage = false);
      }
    }
  }

  Future<void> _loadRecordings({bool silent = false}) async {
    setState(() => _loadingRecordings = true);
    try {
      final keyword = _recordingSearchController.text.trim();
      final query =
          keyword.isEmpty ? '' : '?q=${Uri.encodeQueryComponent(keyword)}';
      final res = await _request('GET', '/api/recordings$query');
      final payload = await _jsonOrThrow(res) as List<dynamic>;
      if (!mounted) return;
      setState(() {
        _recordings = payload
            .map((row) => RecordingItem.fromJson(row as Map<String, dynamic>))
            .toList();
      });
      if (!silent) {
        _setStatus('录制列表已刷新');
      }
    } catch (e) {
      if (!silent) {
        _setStatus('加载录制列表失败：${_friendlyError(e)}', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _loadingRecordings = false);
      }
    }
  }

  Future<void> _downloadRecording(RecordingItem item) async {
    try {
      final res = await _request('GET', item.downloadPath);
      if (res.statusCode >= 400) {
        await _jsonOrThrow(res);
        return;
      }
      final blob = html.Blob(
        [res.bodyBytes],
        item.mimeType.trim().isEmpty
            ? 'application/octet-stream'
            : item.mimeType,
      );
      final url = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: url)
        ..download = item.fileName
        ..style.display = 'none';
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      html.Url.revokeObjectUrl(url);
      _setStatus('开始下载：${item.fileName}');
    } catch (e) {
      _setStatus('下载录制失败：${_friendlyError(e)}', isError: true);
    }
  }

  Future<void> _deleteRecording(RecordingItem item) async {
    if (_deletingRecordingIds.contains(item.id)) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('删除录制'),
            content: Text('确认删除录制文件“${item.fileName}”？删除后不可恢复。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFB42318),
                ),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;

    if (!mounted) return;
    setState(() => _deletingRecordingIds.add(item.id));
    try {
      final res = await _request('DELETE', '/api/recordings/${item.id}');
      await _jsonOrThrow(res);
      if (!mounted) return;
      setState(() {
        _recordings.removeWhere((row) => row.id == item.id);
        _deletingRecordingIds.remove(item.id);
      });
      _setStatus('录制已删除：${item.fileName}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _deletingRecordingIds.remove(item.id));
      _setStatus('删除录制失败：${_friendlyError(e)}', isError: true);
    }
  }

  String _formatRecordingSize(int sizeBytes) {
    if (sizeBytes < 1024) return '${sizeBytes}B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = sizeBytes.toDouble();
    var index = -1;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index += 1;
    }
    final decimals = value >= 100 ? 0 : 1;
    return '${value.toStringAsFixed(decimals)}${units[index]}';
  }

  String _formatRecordingDuration(int? durationSeconds) {
    if (durationSeconds == null || durationSeconds <= 0) return '-';
    final total = durationSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    if (hours > 0) {
      return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
    return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }

  String _formatBillingSeconds(int value) {
    final hours = value ~/ 3600;
    final minutes = (value % 3600) ~/ 60;
    final seconds = value % 60;
    if (hours > 0) return '${hours}h ${minutes}m ${seconds}s';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${seconds}s';
  }

  String _formatBillingLimitInt(int? value) {
    if (value == null) return '无限制';
    return value.toString();
  }

  String _formatBillingLimitBytes(int? value) {
    if (value == null) return '无限制';
    return _formatRecordingSize(value);
  }

  String _formatBillingLimitSeconds(int? value) {
    if (value == null) return '无限制';
    return _formatBillingSeconds(value);
  }

  Future<void> _openMyBillingDialog() async {
    try {
      final res = await _request('GET', '/api/billing/me');
      final payload = await _jsonOrThrow(res) as Map<String, dynamic>;
      final bill = BillingUserItem.fromJson(payload);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('我的套餐与使用情况'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    bill.isSuperuser
                        ? '当前身份：超级管理员（不受套餐限制）'
                        : '当前套餐：${bill.planName ?? '无套餐（不限制）'}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '活跃房间：${bill.usage['active_room_count'] ?? 0}/${_formatBillingLimitInt(bill.limits['max_active_rooms'])}',
                  ),
                  Text(
                    '房间峰值：${bill.usage['room_peak_count'] ?? 0}',
                  ),
                  Text(
                    '人数上限使用：${bill.usage['max_room_participants_used'] ?? 0}/${_formatBillingLimitInt(bill.limits['max_room_participants'])}',
                  ),
                  Text(
                    '会议总数：${bill.usage['meeting_count'] ?? 0}/${_formatBillingLimitInt(bill.limits['max_meeting_count'])}',
                  ),
                  Text(
                    '累计房间使用时长：${_formatBillingSeconds(bill.usage['cumulative_room_used_seconds'] ?? bill.usage['room_used_seconds'] ?? 0)}/${_formatBillingLimitSeconds(bill.limits['max_room_used_seconds'])}',
                  ),
                  Text(
                    '当前单房间最大在会时长：${_formatBillingSeconds(bill.usage['current_room_max_used_seconds'] ?? 0)}/${_formatBillingLimitSeconds(bill.limits['max_current_room_used_seconds'])}',
                  ),
                  Text(
                    '录制存储：${_formatRecordingSize(bill.usage['recording_storage_used_bytes'] ?? 0)}/${_formatBillingLimitBytes(bill.limits['max_recording_storage_bytes'])}',
                  ),
                  if (bill.exceededKeys.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: bill.exceededKeys
                          .map(
                            (key) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEE4E2),
                                borderRadius: BorderRadius.circular(999),
                                border:
                                    Border.all(color: const Color(0xFFFECACA)),
                              ),
                              child: Text(
                                key,
                                style: const TextStyle(
                                  color: Color(0xFFB42318),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      _setStatus('加载我的套餐信息失败：${_friendlyError(e)}', isError: true);
    }
  }

  Future<void> _openMyBillingDialogPretty() async {
    try {
      final res = await _request('GET', '/api/billing/me');
      final payload = await _jsonOrThrow(res) as Map<String, dynamic>;
      final bill = BillingUserItem.fromJson(payload);
      if (!mounted) return;
      final usage = bill.usage;
      final limits = bill.limits;
      final exceeded = bill.exceededKeys.toSet();
      final keyLabels = <String, String>{
        'max_active_rooms': '活跃房间',
        'max_room_participants': '单房间人数',
        'max_meeting_count': '会议总数',
        'max_room_used_seconds': '累计时长',
        'max_current_room_used_seconds': '单房间最大在会时长',
        'max_recording_storage_bytes': '录制存储',
      };

      Widget usageTile({
        required IconData icon,
        required String title,
        required String value,
        required bool isExceeded,
      }) {
        final borderColor =
            isExceeded ? const Color(0xFFFDA29B) : const Color(0xFFDDE6FF);
        final bgColor =
            isExceeded ? const Color(0xFFFFF1F0) : const Color(0xFFF8FAFF);
        final iconColor =
            isExceeded ? const Color(0xFFB42318) : const Color(0xFF175CD3);
        return Container(
          width: 270,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: iconColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: iconColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: TextStyle(
                  color: _palette.textStrong,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      }

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        _palette.heroGradientStart,
                        _palette.heroGradientEnd,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(18)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '我的套餐与使用情况',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        bill.isSuperuser
                            ? '当前身份：超级管理员（不受套餐限制）'
                            : '当前套餐：${bill.planName ?? '无套餐（不限制）'}',
                        style: TextStyle(
                          color: _palette.heroMutedText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            usageTile(
                              icon: Icons.meeting_room_outlined,
                              title: '活跃房间',
                              value:
                                  '${usage['active_room_count'] ?? 0}/${_formatBillingLimitInt(limits['max_active_rooms'])}',
                              isExceeded: exceeded.contains('max_active_rooms'),
                            ),
                            usageTile(
                              icon: Icons.groups_2_outlined,
                              title: '单房间人数上限使用',
                              value:
                                  '${usage['max_room_participants_used'] ?? 0}/${_formatBillingLimitInt(limits['max_room_participants'])}',
                              isExceeded:
                                  exceeded.contains('max_room_participants'),
                            ),
                            usageTile(
                              icon: Icons.event_note_outlined,
                              title: '会议总数',
                              value:
                                  '${usage['meeting_count'] ?? 0}/${_formatBillingLimitInt(limits['max_meeting_count'])}',
                              isExceeded:
                                  exceeded.contains('max_meeting_count'),
                            ),
                            usageTile(
                              icon: Icons.av_timer_outlined,
                              title: '累计房间使用时长',
                              value:
                                  '${_formatBillingSeconds(usage['cumulative_room_used_seconds'] ?? usage['room_used_seconds'] ?? 0)}/${_formatBillingLimitSeconds(limits['max_room_used_seconds'])}',
                              isExceeded:
                                  exceeded.contains('max_room_used_seconds'),
                            ),
                            usageTile(
                              icon: Icons.timer_outlined,
                              title: '当前单房间最大在会时长',
                              value:
                                  '${_formatBillingSeconds(usage['current_room_max_used_seconds'] ?? 0)}/${_formatBillingLimitSeconds(limits['max_current_room_used_seconds'])}',
                              isExceeded: exceeded
                                  .contains('max_current_room_used_seconds'),
                            ),
                            usageTile(
                              icon: Icons.storage_outlined,
                              title: '录制存储',
                              value:
                                  '${_formatRecordingSize(usage['recording_storage_used_bytes'] ?? 0)}/${_formatBillingLimitBytes(limits['max_recording_storage_bytes'])}',
                              isExceeded: exceeded
                                  .contains('max_recording_storage_bytes'),
                            ),
                            usageTile(
                              icon: Icons.stacked_line_chart_outlined,
                              title: '房间峰值',
                              value: '${usage['room_peak_count'] ?? 0}',
                              isExceeded: false,
                            ),
                          ],
                        ),
                        if (bill.exceededKeys.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Text(
                            '已超限项目',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: _palette.danger,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: bill.exceededKeys
                                .map(
                                  (key) => Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: _palette.dangerSurface,
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: _palette.dangerBorder,
                                      ),
                                    ),
                                    child: Text(
                                      keyLabels[key] ?? key,
                                      style: TextStyle(
                                        color: _palette.danger,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                    child: TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('关闭'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      _setStatus('加载我的套餐信息失败：${_friendlyError(e)}', isError: true);
    }
  }

  Map<String, dynamic> _meetingPayload({
    required String title,
    required String description,
    required String scheduledStart,
    required String meetingRecurrence,
    required String meetingTimezone,
    required String duration,
    required String maxParticipants,
    required String password,
    required bool waitingRoom,
    required bool allowGuestLinkJoin,
    required bool allowRecording,
    required bool allowScreenShare,
    required bool allowChat,
    required bool allowSelfUnmute,
    required bool allowMemberVideo,
    required bool muteOnEntry,
  }) {
    final scheduledStartValue = _scheduledStartPayloadValue(scheduledStart);
    return <String, dynamic>{
      'title': title.trim(),
      'description': description.trim().isEmpty ? null : description.trim(),
      'scheduled_start': scheduledStartValue,
      'meeting_recurrence':
          meetingRecurrence.trim().isEmpty ? 'once' : meetingRecurrence.trim(),
      'meeting_timezone': meetingTimezone.trim().isEmpty
          ? 'Asia/Shanghai'
          : meetingTimezone.trim(),
      'duration_minutes': int.tryParse(duration.trim()) ?? 30,
      'max_participants': int.tryParse(maxParticipants.trim()) ?? 100,
      'meeting_password': password.trim().isEmpty ? null : password.trim(),
      'waiting_room_enabled': waitingRoom,
      'allow_guest_link_join': allowGuestLinkJoin,
      'allow_recording': allowRecording,
      'allow_screen_share': allowScreenShare,
      'allow_chat': allowChat,
      'allow_self_unmute': allowSelfUnmute,
      'allow_member_video': allowMemberVideo,
      'mute_on_entry': muteOnEntry,
    };
  }

  Future<bool> _createMeeting() async {
    final resolvedTitle = _titleController.text.trim().isEmpty
        ? _defaultMeetingTitle()
        : _titleController.text;
    try {
      final payload = _meetingPayload(
        title: resolvedTitle,
        description: _descriptionController.text,
        scheduledStart: _scheduledStartController.text,
        meetingRecurrence: _meetingRecurrence,
        meetingTimezone: _meetingTimezone,
        duration: _durationController.text,
        maxParticipants: _maxParticipantsController.text,
        password: _passwordController.text,
        waitingRoom: _waitingRoomEnabled,
        allowGuestLinkJoin: _allowGuestLinkJoin,
        allowRecording: _allowRecording,
        allowScreenShare: _allowScreenShare,
        allowChat: _allowChat,
        allowSelfUnmute: _allowSelfUnmute,
        allowMemberVideo: _allowMemberVideo,
        muteOnEntry: _muteOnEntry,
      );
      final res = await _request('POST', '/api/meetings', body: payload);
      final data = await _jsonOrThrow(res) as Map<String, dynamic>;
      _setStatus('会议已创建：${data['title']}');
      _titleController.clear();
      _descriptionController.clear();
      _scheduledStartController.text = _formatDateTimeForInput(DateTime.now());
      _durationController.text = '30';
      _maxParticipantsController.text = '100';
      _passwordController.clear();
      setState(() {
        _waitingRoomEnabled = false;
        _meetingRecurrence = 'once';
        _meetingTimezone = 'Asia/Shanghai';
        _allowGuestLinkJoin = true;
        _allowRecording = true;
        _allowScreenShare = true;
        _allowChat = true;
        _allowSelfUnmute = true;
        _allowMemberVideo = true;
        _muteOnEntry = false;
      });
      await _loadMeetings();
      return true;
    } catch (e) {
      _setStatus('创建会议失败：${_friendlyError(e)}', isError: true);
      return false;
    }
  }

  Future<bool> _joinMeeting() async {
    final roomName = _joinRoomController.text.trim();
    final password = _joinPasswordController.text.trim();
    try {
      if (roomName.isEmpty) throw Exception('请填写会议号');
      final payload = <String, dynamic>{
        'room_name': roomName,
      };
      if (password.isNotEmpty) {
        payload['meeting_password'] = password;
      }
      final defaultDisplayName = (_profile?.defaultDisplayName ?? '').trim();
      if (defaultDisplayName.isNotEmpty) {
        payload['display_name'] = defaultDisplayName;
      }
      final res = await _request('POST', '/api/meetings/join', body: payload);
      final data = await _jsonOrThrow(res) as Map<String, dynamic>;
      _setStatus('已加入会议：${data['title']}');
      final entryUrl = _meetingEntryUrlFromData(data);
      if (entryUrl.isEmpty) {
        throw Exception('未获取到会议入口标识，请刷新后重试');
      }
      html.window.location.assign(entryUrl);
      return true;
    } catch (e) {
      if (_isWaitingRoomPendingError(e)) {
        final entryUrl = _meetingEntryUrlFromWaitingRoomError(e, roomName);
        if (entryUrl.isNotEmpty) {
          _setStatus('会议已进入等候室，正在跳转到会议主界面等待主持人准入...');
          html.window.location.assign(entryUrl);
          return true;
        }
        _setStatus(
          '会议已进入等候室等待，但未能定位会议入口，请从会议列表进入该会议。',
          isError: true,
        );
        return false;
      }
      _setStatus('加入会议失败：${_friendlyError(e)}', isError: true);
      return false;
    }
  }

  String _meetingEntryUrlFromWaitingRoomError(Object error, String roomName) {
    if (error is ApiException) {
      final payload = error.payload;
      if (payload != null) {
        final fromPayload = _meetingEntryUrlFromData(payload);
        if (fromPayload.isNotEmpty) {
          return fromPayload;
        }
      }
    }
    if (roomName.trim().isEmpty) {
      return '';
    }
    for (final item in _meetings) {
      if (item.roomName.trim() != roomName.trim()) {
        continue;
      }
      final fromMeeting = _meetingEntryUrl(item);
      if (fromMeeting.isNotEmpty) {
        return fromMeeting;
      }
    }
    return '';
  }

  Future<void> _copyMeetingNumber(String roomName) async {
    await Clipboard.setData(ClipboardData(text: roomName));
    _setStatus('会议号已复制：$roomName');
  }

  String _meetingOutlookIcsPath(MeetingItem item) {
    final ref = item.meetingRef.trim();
    if (ref.isEmpty) {
      return '';
    }
    return '/api/my/meetings/${Uri.encodeComponent(ref)}/outlook.ics';
  }

  String _outlookIcsFileName(MeetingItem item, Map<String, String> headers) {
    final disposition = (headers['content-disposition'] ?? '').trim();
    if (disposition.isNotEmpty) {
      final match = RegExp(
        r'''filename\*?=(?:UTF-8'')?"?([^\";]+)"?''',
        caseSensitive: false,
      ).firstMatch(disposition);
      if (match != null) {
        final raw = (match.group(1) ?? '').trim();
        if (raw.isNotEmpty) {
          final decoded = Uri.decodeComponent(raw);
          if (decoded.toLowerCase().endsWith('.ics')) {
            return decoded;
          }
          return '$decoded.ics';
        }
      }
    }
    final roomName =
        item.roomName.trim().isEmpty ? 'meeting' : item.roomName.trim();
    final safe = roomName
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    final baseName = safe.isEmpty ? 'meeting' : safe;
    return '$baseName.ics';
  }

  Future<void> _exportMeetingToOutlook(MeetingItem item) async {
    final icsPath = _meetingOutlookIcsPath(item);
    if (icsPath.isEmpty) {
      _setStatus('会议标识不存在，请刷新列表后重试', isError: true);
      return;
    }
    try {
      final response = await _request('GET', icsPath);
      if (response.statusCode >= 400) {
        await _jsonOrThrow(response);
      }
      if (response.bodyBytes.isEmpty) {
        throw Exception('导出的日程文件为空');
      }
      final fileName = _outlookIcsFileName(item, response.headers);
      final blob =
          html.Blob([response.bodyBytes], 'text/calendar;charset=utf-8');
      final blobUrl = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: blobUrl)
        ..download = fileName
        ..style.display = 'none';
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      html.Url.revokeObjectUrl(blobUrl);
      _setStatus('Outlook 日程文件已导出');
    } catch (e) {
      _setStatus('导出 Outlook 失败：${_friendlyError(e)}', isError: true);
    }
  }

  String _meetingShareUrl(MeetingItem item) {
    final fromApi = item.shareUrl.trim();
    if (fromApi.isNotEmpty) {
      final parsed = Uri.tryParse(fromApi);
      if (parsed != null) {
        if (parsed.hasScheme) {
          return fromApi;
        }
        if (fromApi.startsWith('/')) {
          return Uri.base.resolve(fromApi).toString();
        }
      }
    }
    final code = item.shareCode.trim();
    if (code.isNotEmpty) {
      return Uri.base.resolve('/m/$code').toString();
    }
    return '';
  }

  String _meetingShareUrlFromData(Map<String, dynamic> data) {
    final fromApi = (data['share_url'] ?? '').toString().trim();
    if (fromApi.isNotEmpty) {
      final parsed = Uri.tryParse(fromApi);
      if (parsed != null) {
        if (parsed.hasScheme) {
          return fromApi;
        }
        if (fromApi.startsWith('/')) {
          return Uri.base.resolve(fromApi).toString();
        }
      }
    }
    final code = (data['share_code'] ?? '').toString().trim();
    if (code.isNotEmpty) {
      return Uri.base.resolve('/m/$code').toString();
    }
    return '';
  }

  String _meetingEntryUrl(MeetingItem item) {
    final ref = item.meetingRef.trim();
    if (ref.isNotEmpty) {
      return '/my/meetings/${Uri.encodeComponent(ref)}?autojoin=1';
    }
    final shareUrl = _meetingShareUrl(item);
    if (shareUrl.isNotEmpty) {
      return shareUrl;
    }
    return '';
  }

  String _meetingEntryUrlFromData(Map<String, dynamic> data) {
    final meetingRef = (data['meeting_ref'] ?? '').toString().trim();
    if (meetingRef.isNotEmpty) {
      return '/my/meetings/${Uri.encodeComponent(meetingRef)}?autojoin=1';
    }
    final shareUrl = _meetingShareUrlFromData(data);
    if (shareUrl.isNotEmpty) {
      return shareUrl;
    }
    return '';
  }

  String _meetingShareText(MeetingItem item) {
    final link = _meetingShareUrl(item);
    final meetingPassword = item.meetingPasswordForShare.trim();
    final lines = <String>[
      '会议：${item.title}',
      '会议号：${item.roomName}',
    ];
    if (link.isNotEmpty) {
      lines.add('分享链接：$link');
    }
    if (meetingPassword.isNotEmpty) {
      lines.add('会议密码：$meetingPassword');
    } else if (item.hasPassword) {
      lines.add('此会议已设置密码，请联系主持人获取。');
    }
    return lines.join('\n');
  }

  Future<void> _showMeetingShareDialog(MeetingItem item) async {
    final link = _meetingShareUrl(item);
    final meetingPassword = item.meetingPasswordForShare.trim();
    final info = _meetingShareText(item);
    final linkCopyText =
        meetingPassword.isEmpty ? link : '$link\n会议密码：$meetingPassword';
    if (link.isEmpty) {
      _setStatus('当前会议暂时无法生成分享链接', isError: true);
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('会议分享'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '分享链接',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              SelectableText(link),
              const SizedBox(height: 12),
              const Text(
                '分享信息',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              SelectableText(info),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: linkCopyText));
              if (!mounted) return;
              Navigator.pop(context);
              if (meetingPassword.isNotEmpty) {
                _setStatus('分享链接和密码已复制');
              } else {
                _setStatus('分享链接已复制');
              }
            },
            child: const Text('复制链接'),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: info));
              if (!mounted) return;
              Navigator.pop(context);
              _setStatus('会议信息已复制');
            },
            child: const Text('复制信息'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteMeeting(MeetingItem item) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认删除会议'),
            content: Text('会议“${item.title}”将被永久删除，且无法恢复。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消')),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB42318)),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    try {
      final rawRef = item.meetingRef.trim();
      if (rawRef.isEmpty) {
        _setStatus('会议标识不存在，请刷新列表后重试', isError: true);
        return;
      }
      final ref = Uri.encodeComponent(rawRef);
      final res = await _request('DELETE', '/api/my/meetings/$ref');
      await _jsonOrThrow(res);
      _setStatus('会议已删除');
      await _loadMeetings();
    } catch (e) {
      _setStatus('删除会议失败：${_friendlyError(e)}', isError: true);
    }
  }

  Future<void> _showJoinToken(MeetingItem item) async {
    try {
      final rawRef = item.meetingRef.trim();
      if (rawRef.isEmpty) {
        _setStatus('会议标识不存在，请刷新列表后重试', isError: true);
        return;
      }
      final ref = Uri.encodeComponent(rawRef);
      final res =
          await _request('POST', '/api/my/meetings/$ref/join-token', body: {});
      final data = await _jsonOrThrow(res) as Map<String, dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('入会令牌'),
          content: SizedBox(
            width: 520,
            child: SelectableText(
                const JsonEncoder.withIndent('  ').convert(data)),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'))
          ],
        ),
      );
    } catch (e) {
      _setStatus('获取入会令牌失败：${_friendlyError(e)}', isError: true);
    }
  }

  Future<void> _editMeeting(MeetingItem item) async {
    final titleCtrl = TextEditingController(text: item.title);
    final descriptionCtrl = TextEditingController(text: item.description ?? '');
    final initialScheduledStart = _scheduledInputValue(item.scheduledStart);
    final scheduledCtrl = TextEditingController(
      text: initialScheduledStart.isEmpty
          ? _formatDateTimeForInput(DateTime.now())
          : initialScheduledStart,
    );
    final durationCtrl =
        TextEditingController(text: item.durationMinutes.toString());
    final maxCtrl =
        TextEditingController(text: item.maxParticipants.toString());
    final passwordCtrl = TextEditingController();
    String meetingRecurrence = item.meetingRecurrence.trim().isEmpty
        ? 'once'
        : item.meetingRecurrence.trim();
    if (!_meetingRecurrenceLabels.containsKey(meetingRecurrence)) {
      meetingRecurrence = 'once';
    }
    String meetingTimezone = item.meetingTimezone.trim().isEmpty
        ? 'Asia/Shanghai'
        : item.meetingTimezone.trim();
    if (!_meetingTimezoneLabels.containsKey(meetingTimezone)) {
      meetingTimezone = 'Asia/Shanghai';
    }
    bool clearPassword = false;
    bool waitingRoom = item.waitingRoomEnabled;
    bool allowGuestLinkJoin = item.allowGuestLinkJoin;
    bool allowRecording = item.allowRecording;
    bool allowScreenShare = item.allowScreenShare;
    bool allowChat = item.allowChat;
    bool allowSelfUnmute = item.allowSelfUnmute;
    bool allowMemberVideo = item.allowMemberVideo;
    bool muteOnEntry = item.muteOnEntry;

    final saved = await showDialog<bool>(
          context: context,
          builder: (context) {
            return StatefulBuilder(
              builder: (context, setStateDialog) => AlertDialog(
                title: const Text('编辑会议'),
                content: SizedBox(
                  width: 620,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                            controller: titleCtrl,
                            decoration:
                                const InputDecoration(labelText: '会议标题')),
                        const SizedBox(height: 10),
                        TextField(
                          controller: descriptionCtrl,
                          decoration: const InputDecoration(labelText: '会议描述'),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: scheduledCtrl,
                          readOnly: true,
                          onTap: () => _pickScheduledStartForController(
                            scheduledCtrl,
                            setStateDialog: setStateDialog,
                          ),
                          decoration: const InputDecoration(
                            labelText: '开始时间',
                            hintText: '点击选择日期和时间',
                            suffixIcon:
                                Icon(Icons.calendar_today_outlined, size: 18),
                          ),
                        ),
                        const SizedBox(height: 10),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final isNarrow = constraints.maxWidth < 560;
                            final recurrenceField =
                                DropdownButtonFormField<String>(
                              value: meetingRecurrence,
                              decoration:
                                  const InputDecoration(labelText: '会议周期'),
                              items: _meetingRecurrenceLabels.entries
                                  .map(
                                    (entry) => DropdownMenuItem<String>(
                                      value: entry.key,
                                      child: Text(entry.value),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) => setStateDialog(
                                () => meetingRecurrence = value ?? 'once',
                              ),
                            );
                            final timezoneField =
                                DropdownButtonFormField<String>(
                              value: meetingTimezone,
                              decoration:
                                  const InputDecoration(labelText: '时区'),
                              items: _meetingTimezoneLabels.entries
                                  .map(
                                    (entry) => DropdownMenuItem<String>(
                                      value: entry.key,
                                      child: Text(entry.value),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) => setStateDialog(
                                () =>
                                    meetingTimezone = value ?? 'Asia/Shanghai',
                              ),
                            );
                            if (isNarrow) {
                              return Column(
                                children: [
                                  recurrenceField,
                                  const SizedBox(height: 10),
                                  timezoneField,
                                ],
                              );
                            }
                            return Row(
                              children: [
                                Expanded(child: recurrenceField),
                                const SizedBox(width: 12),
                                Expanded(child: timezoneField),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: durationCtrl,
                                keyboardType: TextInputType.number,
                                decoration:
                                    const InputDecoration(labelText: '时长（分钟）'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: maxCtrl,
                                keyboardType: TextInputType.number,
                                decoration:
                                    const InputDecoration(labelText: '人数上限'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: passwordCtrl,
                          onChanged: (value) {
                            if (clearPassword && value.trim().isNotEmpty) {
                              setStateDialog(() => clearPassword = false);
                            }
                          },
                          decoration:
                              const InputDecoration(labelText: '新密码（可选）'),
                        ),
                        if (item.hasPassword)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              onPressed: clearPassword
                                  ? null
                                  : () => setStateDialog(() {
                                        clearPassword = true;
                                        passwordCtrl.clear();
                                      }),
                              icon: Icon(
                                clearPassword
                                    ? Icons.check_circle_outline
                                    : Icons.lock_reset_outlined,
                              ),
                              label: Text(
                                clearPassword ? '已设置清空密码' : '清空当前会议密码',
                              ),
                            ),
                          ),
                        CheckboxListTile(
                          value: waitingRoom,
                          onChanged: (v) =>
                              setStateDialog(() => waitingRoom = v ?? false),
                          title: const Text('启用等候室'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        CheckboxListTile(
                          value: allowGuestLinkJoin,
                          onChanged: (v) => setStateDialog(
                              () => allowGuestLinkJoin = v ?? false),
                          title: const Text('允许访客通过链接加入'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        CheckboxListTile(
                          value: muteOnEntry,
                          onChanged: (v) =>
                              setStateDialog(() => muteOnEntry = v ?? false),
                          title: const Text('入会自动静音'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        CheckboxListTile(
                          value: allowRecording,
                          onChanged: (v) =>
                              setStateDialog(() => allowRecording = v ?? false),
                          title: const Text('允许录制'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        CheckboxListTile(
                          value: allowScreenShare,
                          onChanged: (v) => setStateDialog(
                              () => allowScreenShare = v ?? false),
                          title: const Text('允许屏幕共享'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        CheckboxListTile(
                          value: allowChat,
                          onChanged: (v) =>
                              setStateDialog(() => allowChat = v ?? false),
                          title: const Text('允许聊天'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        CheckboxListTile(
                          value: allowSelfUnmute,
                          onChanged: (v) => setStateDialog(
                              () => allowSelfUnmute = v ?? false),
                          title: const Text('允许成员自我解除静音'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        CheckboxListTile(
                          value: allowMemberVideo,
                          onChanged: (v) => setStateDialog(
                              () => allowMemberVideo = v ?? false),
                          title: const Text('允许成员开启视频'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('保存')),
                ],
              ),
            );
          },
        ) ??
        false;

    if (!saved) {
      titleCtrl.dispose();
      descriptionCtrl.dispose();
      scheduledCtrl.dispose();
      durationCtrl.dispose();
      maxCtrl.dispose();
      passwordCtrl.dispose();
      return;
    }

    try {
      final payload = _meetingPayload(
        title: titleCtrl.text,
        description: descriptionCtrl.text,
        scheduledStart: scheduledCtrl.text,
        meetingRecurrence: meetingRecurrence,
        meetingTimezone: meetingTimezone,
        duration: durationCtrl.text,
        maxParticipants: maxCtrl.text,
        password: passwordCtrl.text,
        waitingRoom: waitingRoom,
        allowGuestLinkJoin: allowGuestLinkJoin,
        allowRecording: allowRecording,
        allowScreenShare: allowScreenShare,
        allowChat: allowChat,
        allowSelfUnmute: allowSelfUnmute,
        allowMemberVideo: allowMemberVideo,
        muteOnEntry: muteOnEntry,
      );
      if (clearPassword) {
        payload['meeting_password'] = '';
      } else if (passwordCtrl.text.trim().isEmpty) {
        payload.remove('meeting_password');
      }
      final rawRef = item.meetingRef.trim();
      if (rawRef.isEmpty) {
        _setStatus('会议标识不存在，请刷新列表后重试', isError: true);
        return;
      }
      final ref = Uri.encodeComponent(rawRef);
      final res =
          await _request('PATCH', '/api/my/meetings/$ref', body: payload);
      await _jsonOrThrow(res);
      _setStatus('会议已更新');
      await _loadMeetings();
    } catch (e) {
      _setStatus('更新会议失败：${_friendlyError(e)}', isError: true);
    } finally {
      titleCtrl.dispose();
      descriptionCtrl.dispose();
      scheduledCtrl.dispose();
      durationCtrl.dispose();
      maxCtrl.dispose();
      passwordCtrl.dispose();
    }
  }

  Widget _buildSectionTitle(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFF0F172A),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 13,
            color: Color(0xFF475467),
          ),
        ),
      ],
    );
  }

  Widget _buildConfigOption({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return CheckboxListTile(
      value: value,
      onChanged: (v) => onChanged(v ?? false),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(
        label,
        style: const TextStyle(fontSize: 14, color: Color(0xFF344054)),
      ),
    );
  }

  Widget _buildCreateFormContent({
    void Function(VoidCallback fn)? setStateDialog,
  }) {
    void updateOption(VoidCallback fn) {
      if (setStateDialog != null) {
        setStateDialog(fn);
        return;
      }
      setState(fn);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _titleController,
          decoration: const InputDecoration(
            labelText: '会议标题（可选）',
            hintText: '为空时自动使用“显示名预定的会议”',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
            controller: _descriptionController,
            decoration: const InputDecoration(labelText: '会议描述')),
        const SizedBox(height: 10),
        TextField(
          controller: _scheduledStartController,
          readOnly: true,
          onTap: () => _pickScheduledStartForController(
            _scheduledStartController,
            setStateDialog: setStateDialog,
          ),
          decoration: const InputDecoration(
            labelText: '开始时间',
            hintText: '点击选择日期和时间',
            suffixIcon: Icon(Icons.calendar_today_outlined, size: 18),
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 560;
            final recurrenceField = DropdownButtonFormField<String>(
              value: _meetingRecurrenceLabels.containsKey(_meetingRecurrence)
                  ? _meetingRecurrence
                  : 'once',
              decoration: const InputDecoration(labelText: '会议周期'),
              items: _meetingRecurrenceLabels.entries
                  .map(
                    (entry) => DropdownMenuItem<String>(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
              onChanged: (value) => updateOption(
                () => _meetingRecurrence = value ?? 'once',
              ),
            );
            final timezoneField = DropdownButtonFormField<String>(
              value: _meetingTimezoneLabels.containsKey(_meetingTimezone)
                  ? _meetingTimezone
                  : 'Asia/Shanghai',
              decoration: const InputDecoration(labelText: '时区'),
              items: _meetingTimezoneLabels.entries
                  .map(
                    (entry) => DropdownMenuItem<String>(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
              onChanged: (value) => updateOption(
                () => _meetingTimezone = value ?? 'Asia/Shanghai',
              ),
            );
            if (isNarrow) {
              return Column(
                children: [
                  recurrenceField,
                  const SizedBox(height: 10),
                  timezoneField,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: recurrenceField),
                const SizedBox(width: 12),
                Expanded(child: timezoneField),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 560;
            if (isNarrow) {
              return Column(
                children: [
                  TextField(
                    controller: _durationController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '时长（分钟）'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _maxParticipantsController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '人数上限'),
                  ),
                ],
              );
            }
            return Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _durationController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '时长（分钟）'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _maxParticipantsController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '人数上限'),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        TextField(
            controller: _passwordController,
            decoration: const InputDecoration(labelText: '会议密码（可选）')),
        const SizedBox(height: 6),
        _buildConfigOption(
          label: '启用等候室',
          value: _waitingRoomEnabled,
          onChanged: (v) => updateOption(() => _waitingRoomEnabled = v),
        ),
        _buildConfigOption(
          label: '允许访客通过链接加入',
          value: _allowGuestLinkJoin,
          onChanged: (v) => updateOption(() => _allowGuestLinkJoin = v),
        ),
        _buildConfigOption(
          label: '入会自动静音',
          value: _muteOnEntry,
          onChanged: (v) => updateOption(() => _muteOnEntry = v),
        ),
        _buildConfigOption(
          label: '允许录制',
          value: _allowRecording,
          onChanged: (v) => updateOption(() => _allowRecording = v),
        ),
        _buildConfigOption(
          label: '允许屏幕共享',
          value: _allowScreenShare,
          onChanged: (v) => updateOption(() => _allowScreenShare = v),
        ),
        _buildConfigOption(
          label: '允许聊天',
          value: _allowChat,
          onChanged: (v) => updateOption(() => _allowChat = v),
        ),
        _buildConfigOption(
          label: '允许成员自我解除静音',
          value: _allowSelfUnmute,
          onChanged: (v) => updateOption(() => _allowSelfUnmute = v),
        ),
        _buildConfigOption(
          label: '允许成员开启视频',
          value: _allowMemberVideo,
          onChanged: (v) => updateOption(() => _allowMemberVideo = v),
        ),
      ],
    );
  }

  Widget _buildJoinFormContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _joinRoomController,
          decoration: const InputDecoration(
            labelText: '会议号',
            hintText: '例如：room-a1b2c3d4',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
            controller: _joinPasswordController,
            decoration: const InputDecoration(labelText: '会议密码（如有）')),
      ],
    );
  }

  Future<void> _openCreateDialog() async {
    _scheduledStartController.text = _formatDateTimeForInput(DateTime.now());
    _meetingRecurrence = 'once';
    _meetingTimezone = 'Asia/Shanghai';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: const Text('创建会议'),
          content: SizedBox(
            width: 680,
            child: SingleChildScrollView(
              child: _buildCreateFormContent(setStateDialog: setStateDialog),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消')),
            FilledButton.icon(
              onPressed: () async {
                final ok = await _createMeeting();
                if (ok && dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('创建会议'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openJoinDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('加入会议'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(child: _buildJoinFormContent()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          FilledButton.icon(
            onPressed: () async {
              final ok = await _joinMeeting();
              if (ok && dialogContext.mounted) {
                Navigator.pop(dialogContext);
              }
            },
            icon: const Icon(Icons.video_call_outlined),
            label: const Text('立即入会'),
          ),
        ],
      ),
    );
  }

  Future<void> _openProfileDialog() async {
    final profile = _profile;
    if (profile == null) {
      await _loadProfile();
    }
    final latest = _profile;
    _profileDisplayNameController.text = latest?.defaultDisplayName ?? '';
    _profileAvatarUrlController.text = latest?.avatarUrl ?? '';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑个人资料'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _profileDisplayNameController,
                  decoration: const InputDecoration(
                    labelText: '默认显示名称',
                    hintText: '入会时默认显示给他人的名字',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _profileAvatarUrlController,
                  decoration: const InputDecoration(
                    labelText: '头像 URL',
                    hintText: 'https://example.com/avatar.png',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext);
              }
              await _openMyBillingDialogPretty();
            },
            child: const Text('查看套餐与用量'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final ok = await _saveProfile(
                avatarUrl: _profileAvatarUrlController.text,
                defaultDisplayName: _profileDisplayNameController.text,
              );
              if (ok && dialogContext.mounted) {
                Navigator.pop(dialogContext);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileAvatar({
    required String avatarUrl,
    required String fallbackText,
    double radius = 24,
  }) {
    final trimmed = fallbackText.trim();
    final initial =
        trimmed.isEmpty ? '?' : trimmed.substring(0, 1).toUpperCase();
    if (avatarUrl.trim().isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: const Color(0xFFD9E6FF),
        foregroundColor: const Color(0xFF175CD3),
        child:
            Text(initial, style: const TextStyle(fontWeight: FontWeight.w700)),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFFD9E6FF),
      backgroundImage: NetworkImage(avatarUrl),
      onBackgroundImageError: (_, __) {},
    );
  }

  Widget _buildProfilePanel() {
    final profile = _profile;
    if (profile == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: const [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('正在加载个人资料...'),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle('个人资料', '会议控制台与会议页共用此档案'),
            const SizedBox(height: 12),
            Row(
              children: [
                _buildProfileAvatar(
                  avatarUrl: profile.avatarUrl,
                  fallbackText: profile.defaultDisplayName,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.defaultDisplayName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      Text(
                        '@${profile.username}',
                        style: const TextStyle(
                            fontSize: 12.5, color: Color(0xFF667085)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              profile.email,
              style: const TextStyle(fontSize: 13, color: Color(0xFF475467)),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _openProfileDialog,
              icon: const Icon(Icons.person_outline),
              label: const Text('编辑头像与默认显示名'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openMyBillingDialogPretty,
              icon: const Icon(Icons.workspace_premium_outlined),
              label: const Text('查看套餐与用量'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionLauncherPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Expanded(
              child: _buildSectionTitle('快捷操作', '创建会议和加入会议已收纳为弹窗，页面更聚焦会议列表'),
            ),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: _openCreateDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('创建会议'),
                ),
                OutlinedButton.icon(
                  onPressed: _openJoinDialog,
                  icon: const Icon(Icons.login),
                  label: const Text('加入会议'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaPill(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF4FF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFCCDBFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF175CD3)),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF175CD3)),
          ),
        ],
      ),
    );
  }

  Widget _buildMeetingCard(MeetingItem item) {
    final features = <String>[
      if (item.waitingRoomEnabled) '等候室',
      if (item.muteOnEntry) '入会静音',
      if (item.allowGuestLinkJoin) '允许访客链接入会' else '访客链接入会已禁用',
      if (item.allowRecording) '可录制',
      if (item.allowScreenShare) '可共享',
      if (item.allowChat) '可聊天',
      if (item.allowSelfUnmute) '可自解静音',
      if (item.allowMemberVideo) '可开视频',
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FBFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDDE6FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child:
                    _buildMetaPill(Icons.meeting_room_outlined, item.roomName),
              ),
              IconButton(
                tooltip: '复制会议号',
                onPressed: () => _copyMeetingNumber(item.roomName),
                icon: const Icon(Icons.copy_outlined, color: Color(0xFF175CD3)),
              ),
            ],
          ),
          if ((item.description ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              item.description!.trim(),
              style: const TextStyle(color: Color(0xFF475467), fontSize: 13.5),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildMetaPill(
                  Icons.schedule, _formatScheduledStart(item.scheduledStart)),
              _buildMetaPill(
                Icons.repeat,
                _meetingRecurrenceLabel(item.meetingRecurrence),
              ),
              _buildMetaPill(
                Icons.public_outlined,
                _meetingTimezoneLabel(item.meetingTimezone),
              ),
              _buildMetaPill(
                  Icons.timelapse_outlined, '${item.durationMinutes} 分钟'),
              _buildMetaPill(
                  Icons.group_outlined, '上限 ${item.maxParticipants}'),
              _buildMetaPill(
                  Icons.lock_outline, item.hasPassword ? '已设密码' : '无密码'),
            ],
          ),
          if (features.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: features
                  .map(
                    (f) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEEF4FF),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        f,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF344054)),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (item.canDebugToken)
                FilledButton.tonalIcon(
                  onPressed: () => _showJoinToken(item),
                  icon: const Icon(Icons.vpn_key_outlined),
                  label: const Text('令牌调试'),
                ),
              if (item.canEdit)
                FilledButton.icon(
                  onPressed: () => _editMeeting(item),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('编辑'),
                ),
              OutlinedButton.icon(
                onPressed: () => _showMeetingShareDialog(item),
                icon: const Icon(Icons.share_outlined),
                label: const Text('分享'),
              ),
              OutlinedButton.icon(
                onPressed: () => _exportMeetingToOutlook(item),
                icon: const Icon(Icons.calendar_month_outlined),
                label: const Text('导出Outlook'),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    html.window.location.assign(_meetingEntryUrl(item)),
                icon: const Icon(Icons.open_in_new),
                label: const Text('进入会议'),
              ),
              if (item.canDelete)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB42318)),
                  onPressed: () => _deleteMeeting(item),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMeetingListPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildSectionTitle('会议列表', '仅展示你创建过或参加过的会议'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _loadMeetings,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _meetings.isEmpty
                      ? Center(
                          child: Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFF),
                              borderRadius: BorderRadius.circular(14),
                              border:
                                  Border.all(color: const Color(0xFFDDE6FF)),
                            ),
                            child: const Text(
                              '暂无关联会议，可通过上方快捷操作创建或加入。',
                              style: TextStyle(color: Color(0xFF475467)),
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _meetings.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, i) =>
                              _buildMeetingCard(_meetings[i]),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordingStoragePanel() {
    if (!(_profile?.isAdmin ?? false)) {
      return const SizedBox.shrink();
    }
    final updatedLabel = _recordingStorageUpdatedAt.trim().isEmpty
        ? '未更新'
        : _formatScheduledStart(_recordingStorageUpdatedAt);
    final updatedBy = _recordingStorageUpdatedBy.trim().isEmpty
        ? '-'
        : _recordingStorageUpdatedBy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle('录制存储目录', '超级管理员配置后，所有录制按用户分文件夹保存'),
            const SizedBox(height: 10),
            TextField(
              controller: _recordingStorageController,
              decoration: const InputDecoration(
                labelText: '服务器存放目录',
                hintText: '例如：D:\\recordings\\meetings',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _savingRecordingStorage
                      ? null
                      : _saveRecordingStorageConfig,
                  icon: _savingRecordingStorage
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_savingRecordingStorage ? '保存中...' : '保存目录'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _savingRecordingStorage
                      ? null
                      : () => _loadRecordingStorageConfig(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '当前：${_recordingStorageRoot.isEmpty ? "(未设置)" : _recordingStorageRoot}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF475467),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '最后更新：$updatedLabel（$updatedBy）',
              style: const TextStyle(fontSize: 12, color: Color(0xFF667085)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordingPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildSectionTitle('会议录制', '可按关键字检索会议名/文件名并下载'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _loadRecordings,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _recordingSearchController,
                    decoration: const InputDecoration(
                      hintText: '输入关键词检索录制',
                    ),
                    onSubmitted: (_) => _loadRecordings(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _loadRecordings,
                  icon: const Icon(Icons.search),
                  label: const Text('检索'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _loadingRecordings
                  ? const Center(child: CircularProgressIndicator())
                  : _recordings.isEmpty
                      ? Center(
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFF),
                              borderRadius: BorderRadius.circular(12),
                              border:
                                  Border.all(color: const Color(0xFFDDE6FF)),
                            ),
                            child: const Text(
                              '暂无录制文件',
                              style: TextStyle(color: Color(0xFF475467)),
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _recordings.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (_, index) {
                            final item = _recordings[index];
                            final owner = item.ownerDisplayName.trim().isEmpty
                                ? item.ownerUsername
                                : item.ownerDisplayName;
                            final meetingTitle =
                                item.meetingTitle.trim().isEmpty
                                    ? 'Untitled meeting'
                                    : item.meetingTitle.trim();
                            final meetingDisplayId = item.meetingDisplayId > 0
                                ? item.meetingDisplayId.toString()
                                : '-';
                            final roomName = item.meetingRoomName.trim().isEmpty
                                ? '-'
                                : item.meetingRoomName.trim();
                            final deleting =
                                _deletingRecordingIds.contains(item.id);
                            return Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF9FBFF),
                                borderRadius: BorderRadius.circular(12),
                                border:
                                    Border.all(color: const Color(0xFFDDE6FF)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Room: $roomName',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFF0F172A),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 6,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Text(
                                        '$meetingTitle (#$meetingDisplayId)',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Color(0xFF344054),
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (item.meetingDeleted)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFFFF4ED),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                            border: Border.all(
                                              color: const Color(0xFFFDDCAB),
                                            ),
                                          ),
                                          child: const Text(
                                            'Meeting deleted',
                                            style: TextStyle(
                                              color: Color(0xFFB54708),
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Recorder: $owner  Size: ${_formatRecordingSize(item.sizeBytes)}  Duration: ${_formatRecordingDuration(item.durationSeconds)}',
                                    style: const TextStyle(
                                      color: Color(0xFF667085),
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (item.id < 0) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      '${item.meetingTitle}（会议号 ${item.meetingRoomName}）',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFF475467),
                                        fontSize: 12.5,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '录制人：$owner  大小：${_formatRecordingSize(item.sizeBytes)}  时长：${_formatRecordingDuration(item.durationSeconds)}',
                                      style: const TextStyle(
                                        color: Color(0xFF667085),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '时间：${_formatScheduledStart(item.createdAt)}',
                                          style: const TextStyle(
                                            color: Color(0xFF98A2B3),
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: deleting
                                            ? null
                                            : () => _downloadRecording(item),
                                        icon:
                                            const Icon(Icons.download_outlined),
                                        label: const Text('下载'),
                                      ),
                                      const SizedBox(width: 6),
                                      OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor:
                                              const Color(0xFFB42318),
                                          side: const BorderSide(
                                            color: Color(0xFFFDA29B),
                                          ),
                                        ),
                                        onPressed: deleting
                                            ? null
                                            : () => _deleteRecording(item),
                                        icon: deleting
                                            ? const SizedBox(
                                                width: 14,
                                                height: 14,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                ),
                                              )
                                            : const Icon(
                                                Icons.delete_outline_rounded),
                                        label: Text(deleting ? '删除中...' : '删除'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBanner() {
    final icon =
        _statusIsError ? Icons.error_outline : Icons.check_circle_outline;
    final bg = _statusIsError ? _palette.dangerSurface : _palette.primarySoft;
    final fg = _statusIsError ? _palette.danger : _palette.primaryStrong;
    final border =
        _statusIsError ? _palette.dangerBorder : _palette.primaryBorder;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _status,
              style: TextStyle(color: fg, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResponsiveLayout() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final actionPanel = _buildActionLauncherPanel();
        final profilePanel = _buildProfilePanel();
        final listPanel = _buildMeetingListPanel();
        final recordingPanel = _buildRecordingPanel();
        final recordingStoragePanel = _buildRecordingStoragePanel();
        final showStoragePanel = _profile?.isAdmin ?? false;
        if (constraints.maxWidth >= 980) {
          return Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: actionPanel),
                  const SizedBox(width: 12),
                  SizedBox(width: 360, child: profilePanel),
                ],
              ),
              if (showStoragePanel) ...[
                const SizedBox(height: 12),
                recordingStoragePanel,
              ],
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: [
                    Expanded(flex: 6, child: listPanel),
                    const SizedBox(width: 12),
                    Expanded(flex: 5, child: recordingPanel),
                  ],
                ),
              ),
            ],
          );
        }
        return Column(
          children: [
            profilePanel,
            const SizedBox(height: 12),
            actionPanel,
            if (showStoragePanel) ...[
              const SizedBox(height: 12),
              recordingStoragePanel,
            ],
            const SizedBox(height: 12),
            Expanded(
              child: Column(
                children: [
                  Expanded(flex: 6, child: listPanel),
                  const SizedBox(height: 12),
                  Expanded(flex: 5, child: recordingPanel),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDesktopScaffold() {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 74,
        titleSpacing: 20,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                _palette.heroGradientStart,
                _palette.heroGradientEnd,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              '智能会议控制台',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.white),
            ),
            const SizedBox(height: 2),
            Text(
              '会议创建、入会、编辑与会控管理',
              style: TextStyle(fontSize: 12.5, color: _palette.heroMutedText),
            ),
          ],
        ),
        actions: [
          if (_profile != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Row(
                  children: [
                    _buildProfileAvatar(
                      avatarUrl: _profile!.avatarUrl,
                      fallbackText: _profile!.defaultDisplayName,
                      radius: 14,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _profile!.defaultDisplayName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          IconButton(
            tooltip: '编辑资料',
            onPressed: _openProfileDialog,
            icon: const Icon(Icons.person_outline, color: Colors.white),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _refreshDashboardData,
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
          if (_profile?.isAdmin ?? false)
            IconButton(
              tooltip: '计费管理',
              onPressed: () => html.window.location.assign('/billing'),
              icon: const Icon(Icons.payments_outlined, color: Colors.white),
            ),
          TextButton.icon(
            onPressed: () => html.window.location.assign('/auth/logout'),
            icon: const Icon(Icons.logout, color: Colors.white, size: 18),
            label: const Text('退出', style: TextStyle(color: Colors.white)),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [_palette.pageBackground, _palette.primarySoft],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1500),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildStatusBanner(),
                  const SizedBox(height: 12),
                  Expanded(child: _buildResponsiveLayout()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileActionLauncherPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
              '快捷操作',
              '在手机上快速创建会议或加入会议。',
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _openCreateDialog,
                icon: const Icon(Icons.add),
                label: const Text('创建会议'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _openJoinDialog,
                icon: const Icon(Icons.login),
                label: const Text('加入会议'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileTabs() {
    final showStoragePanel = _profile?.isAdmin ?? false;
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: _palette.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _palette.panelBorder),
            ),
            child: const TabBar(
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: [
                Tab(text: '会议', icon: Icon(Icons.event_note_outlined)),
                Tab(text: '操作', icon: Icon(Icons.flash_on_outlined)),
                Tab(text: '录制', icon: Icon(Icons.video_library_outlined)),
                Tab(text: '我的', icon: Icon(Icons.person_outline)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TabBarView(
              children: [
                _buildMeetingListPanel(),
                SingleChildScrollView(
                  child: Column(
                    children: [
                      _buildMobileActionLauncherPanel(),
                      if (showStoragePanel) ...[
                        const SizedBox(height: 10),
                        _buildRecordingStoragePanel(),
                      ],
                    ],
                  ),
                ),
                _buildRecordingPanel(),
                SingleChildScrollView(child: _buildProfilePanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileHeader() {
    final profile = _profile;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _palette.heroBorder),
        gradient: LinearGradient(
          colors: [_palette.heroGradientStart, _palette.heroGradientEnd],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '智能会议控制台',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  profile == null
                      ? '手机端会议控制中心'
                      : '欢迎，${profile.defaultDisplayName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _palette.heroMutedText,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '编辑资料',
            onPressed: _openProfileDialog,
            icon: const Icon(Icons.person_outline, color: Colors.white),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _refreshDashboardData,
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
          if (profile?.isAdmin ?? false)
            IconButton(
              tooltip: '计费管理',
              onPressed: () => html.window.location.assign('/billing'),
              icon: const Icon(Icons.payments_outlined, color: Colors.white),
            ),
          IconButton(
            tooltip: '退出登录',
            onPressed: () => html.window.location.assign('/auth/logout'),
            icon: const Icon(Icons.logout, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileScaffold() {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF5F8FF), Color(0xFFEEF4FF)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            child: Column(
              children: [
                _buildMobileHeader(),
                const SizedBox(height: 8),
                _buildStatusBanner(),
                const SizedBox(height: 8),
                Expanded(child: _buildMobileTabs()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final useMobileLayout = widget.preferMobileLayout ||
        DeviceProfile.isPhoneWidth(context, breakpoint: 840);
    if (useMobileLayout) {
      return _buildMobileScaffold();
    }
    return _buildDesktopScaffold();
  }
}
