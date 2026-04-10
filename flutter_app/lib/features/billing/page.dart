import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../core/api_exception.dart';
import '../../device_profile.dart';
import 'models.dart';

class BillingAdminPage extends StatefulWidget {
  const BillingAdminPage({super.key, this.preferMobileLayout = false});

  final bool preferMobileLayout;

  @override
  State<BillingAdminPage> createState() => _BillingAdminPageState();
}

class _BillingAdminPageState extends State<BillingAdminPage> {
  String _accessToken = '';
  bool _loading = false;
  String _status = '系统就绪';
  bool _statusIsError = false;
  List<BillingPlanItem> _plans = const [];
  List<BillingUserItem> _users = const [];
  BillingAuthOptionsItem? _authOptions;
  bool _savingAuthOptions = false;
  bool _exportingUsers = false;

  @override
  void initState() {
    super.initState();
    _loadOverview();
  }

  Uri _uri(String path) => Uri.base.resolve(path);

  void _setStatus(String text, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _status = text;
      _statusIsError = isError;
    });
  }

  String _friendlyError(Object error) {
    if (error is ApiException) return error.detail;
    final raw = error.toString();
    if (raw.startsWith('Exception: ')) {
      return raw.substring('Exception: '.length);
    }
    return raw;
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
            headers: headers, body: jsonEncode(body ?? <String, dynamic>{}));
        break;
      case 'PATCH':
        res = await http.patch(uri,
            headers: headers, body: jsonEncode(body ?? <String, dynamic>{}));
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
    if (response.body.isEmpty) return <String, dynamic>{};
    return jsonDecode(response.body);
  }

  Future<void> _loadOverview() async {
    if (mounted) setState(() => _loading = true);
    try {
      final res = await _request('GET', '/api/billing/overview');
      final data = await _jsonOrThrow(res) as Map<String, dynamic>;
      final plansRaw = data['plans'];
      final usersRaw = data['users'];
      final authOptionsRaw = data['auth_options'];
      final plans = <BillingPlanItem>[];
      final users = <BillingUserItem>[];
      BillingAuthOptionsItem? authOptions;
      if (plansRaw is List) {
        for (final row in plansRaw) {
          if (row is Map<String, dynamic>) {
            plans.add(BillingPlanItem.fromJson(row));
          }
        }
      }
      if (usersRaw is List) {
        for (final row in usersRaw) {
          if (row is Map<String, dynamic>) {
            users.add(BillingUserItem.fromJson(row));
          }
        }
      }
      if (authOptionsRaw is Map<String, dynamic>) {
        authOptions = BillingAuthOptionsItem.fromJson(authOptionsRaw);
      }
      authOptions ??= _authOptions ??
          BillingAuthOptionsItem(
            allowTechcloudOauthLogin: true,
            allowLocalRegister: true,
            allowLocalLogin: true,
            techcloudOauthConfigured: false,
            effectiveTechcloudOauthLogin: false,
            updatedByUsername: '',
            updatedAt: '',
          );
      if (!mounted) return;
      setState(() {
        _plans = plans;
        _users = users;
        _authOptions = authOptions;
      });
      _setStatus('计费数据已刷新');
    } catch (e) {
      _setStatus('加载计费数据失败：${_friendlyError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fileNameFromContentDisposition(http.Response response, String fallback) {
    final header = response.headers['content-disposition'] ?? '';
    final match = RegExp(r'filename="?([^"]+)"?').firstMatch(header);
    if (match == null) return fallback;
    final value = (match.group(1) ?? '').trim();
    if (value.isEmpty) return fallback;
    return value;
  }

  String _formatIsoDateTime(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '-';
    final parsed = DateTime.tryParse(text);
    if (parsed == null) return text;
    final local = parsed.toLocal();
    final two = (int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  Future<void> _saveAuthOptions(BillingAuthOptionsItem next) async {
    if (_savingAuthOptions) return;
    if (mounted) setState(() => _savingAuthOptions = true);
    try {
      final res = await _request(
        'PATCH',
        '/api/system/auth-options',
        body: next.toUpdatePayload(),
      );
      final data = await _jsonOrThrow(res) as Map<String, dynamic>;
      final updated = BillingAuthOptionsItem.fromJson(data);
      if (!mounted) return;
      setState(() {
        _authOptions = updated;
      });
      _setStatus('登录选项已更新');
    } catch (e) {
      _setStatus('更新登录选项失败：${_friendlyError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _savingAuthOptions = false);
    }
  }

  Future<void> _exportUsersCsv() async {
    if (_exportingUsers) return;
    if (mounted) setState(() => _exportingUsers = true);
    try {
      final res = await _request('GET', '/api/billing/users/export');
      if (res.statusCode >= 400) {
        await _jsonOrThrow(res);
      }
      final fileName = _fileNameFromContentDisposition(
        res,
        'billing-users-export.csv',
      );
      final blob = html.Blob(
        [res.bodyBytes],
        'text/csv;charset=utf-8',
      );
      final blobUrl = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: blobUrl)
        ..download = fileName
        ..style.display = 'none';
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      html.Url.revokeObjectUrl(blobUrl);
      _setStatus('用户信息已导出：$fileName');
    } catch (e) {
      _setStatus('导出用户信息失败：${_friendlyError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _exportingUsers = false);
    }
  }

  String _formatBytes(int value) {
    if (value < 1024) return '${value}B';
    const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
    var size = value.toDouble();
    var index = -1;
    while (size >= 1024 && index < units.length - 1) {
      size /= 1024;
      index += 1;
    }
    final fixed = size >= 100 ? 0 : 1;
    return '${size.toStringAsFixed(fixed)}${units[index]}';
  }

  String _formatSeconds(int value) {
    final hours = value ~/ 3600;
    final minutes = (value % 3600) ~/ 60;
    final seconds = value % 60;
    if (hours > 0) return '${hours}h ${minutes}m ${seconds}s';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${seconds}s';
  }

  String _formatLimitInt(int? value) {
    if (value == null) return '无限制';
    return value.toString();
  }

  String _formatLimitBytes(int? value) {
    if (value == null) return '无限制';
    return _formatBytes(value);
  }

  String _formatLimitSeconds(int? value) {
    if (value == null) return '无限制';
    return _formatSeconds(value);
  }

  String _formatPlanLimitInt(int value) {
    if (value <= 0) return '无限制';
    return value.toString();
  }

  String _formatPlanLimitBytes(int value) {
    if (value <= 0) return '无限制';
    return _formatBytes(value);
  }

  String _formatPlanLimitSeconds(int value) {
    if (value <= 0) return '无限制';
    return _formatSeconds(value);
  }

  int _parsePlanLimitValue(String raw, {required int fallback}) {
    final text = raw.trim();
    if (text.isEmpty) return 0;
    final lowered = text.toLowerCase();
    if (lowered == '无限' ||
        lowered == '无限制' ||
        lowered == 'unlimited' ||
        lowered == 'inf' ||
        lowered == 'none' ||
        lowered == '∞') {
      return 0;
    }
    return int.tryParse(text) ?? fallback;
  }

  Future<void> _createOrEditPlan({BillingPlanItem? plan}) async {
    final nameCtrl = TextEditingController(text: plan?.name ?? '');
    final descriptionCtrl = TextEditingController(text: plan?.description ?? '');
    final activeRoomsCtrl =
        TextEditingController(text: (plan?.maxActiveRooms ?? 1) <= 0 ? '无限制' : (plan?.maxActiveRooms ?? 1).toString());
    final participantsCtrl = TextEditingController(
      text: (plan?.maxRoomParticipants ?? 100) <= 0 ? '无限制' : (plan?.maxRoomParticipants ?? 100).toString(),
    );
    final roomUsedSecondsCtrl = TextEditingController(
      text: (plan?.maxRoomUsedSeconds ?? 0) <= 0 ? '无限制' : (plan?.maxRoomUsedSeconds ?? 0).toString(),
    );
    final currentRoomUsedSecondsCtrl = TextEditingController(
      text: (plan?.maxCurrentRoomUsedSeconds ?? 0) <= 0 ? '无限制' : (plan?.maxCurrentRoomUsedSeconds ?? 0).toString(),
    );
    final storageCtrl = TextEditingController(
      text: (plan?.maxRecordingStorageBytes ?? 0) <= 0 ? '无限制' : (plan?.maxRecordingStorageBytes ?? 0).toString(),
    );
    final meetingCountCtrl = TextEditingController(
      text: (plan?.maxMeetingCount ?? 10) <= 0 ? '无限制' : (plan?.maxMeetingCount ?? 10).toString(),
    );

    final save = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(plan == null ? '新建套餐' : '编辑套餐'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(labelText: '套餐名称'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: descriptionCtrl,
                      decoration: const InputDecoration(labelText: '描述（可选）'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: activeRoomsCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '最大活跃房间数'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: participantsCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '单房间最大人数上限'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: roomUsedSecondsCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '房间累计使用时长上限（秒）'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: currentRoomUsedSecondsCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '当前单房间最大在会时长上限（秒）'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: storageCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '录制存储上限（字节）'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: meetingCountCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '最大会议数'),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('保存'),
              ),
            ],
          ),
        ) ??
        false;

    if (!save) {
      nameCtrl.dispose();
      descriptionCtrl.dispose();
      activeRoomsCtrl.dispose();
      participantsCtrl.dispose();
      roomUsedSecondsCtrl.dispose();
      currentRoomUsedSecondsCtrl.dispose();
      storageCtrl.dispose();
      meetingCountCtrl.dispose();
      return;
    }

    try {
      final payload = <String, dynamic>{
        'name': nameCtrl.text.trim(),
        'description': descriptionCtrl.text.trim(),
        'max_active_rooms': _parsePlanLimitValue(
          activeRoomsCtrl.text,
          fallback: plan?.maxActiveRooms ?? 1,
        ),
        'max_room_participants': _parsePlanLimitValue(
          participantsCtrl.text,
          fallback: plan?.maxRoomParticipants ?? 100,
        ),
        'max_room_used_seconds': _parsePlanLimitValue(
          roomUsedSecondsCtrl.text,
          fallback: plan?.maxRoomUsedSeconds ?? 0,
        ),
        'max_current_room_used_seconds':
            _parsePlanLimitValue(
          currentRoomUsedSecondsCtrl.text,
          fallback: plan?.maxCurrentRoomUsedSeconds ?? 0,
        ),
        'max_recording_storage_bytes': _parsePlanLimitValue(
          storageCtrl.text,
          fallback: plan?.maxRecordingStorageBytes ?? 0,
        ),
        'max_meeting_count': _parsePlanLimitValue(
          meetingCountCtrl.text,
          fallback: plan?.maxMeetingCount ?? 10,
        ),
      };
      if (plan == null) {
        final res = await _request('POST', '/api/billing/plans', body: payload);
        await _jsonOrThrow(res);
        _setStatus('套餐已创建');
      } else {
        final res = await _request('PATCH', '/api/billing/plans/${plan.id}',
            body: payload);
        await _jsonOrThrow(res);
        _setStatus('套餐已更新');
      }
      await _loadOverview();
    } catch (e) {
      _setStatus('保存套餐失败：${_friendlyError(e)}', isError: true);
    } finally {
      nameCtrl.dispose();
      descriptionCtrl.dispose();
      activeRoomsCtrl.dispose();
      participantsCtrl.dispose();
      roomUsedSecondsCtrl.dispose();
      currentRoomUsedSecondsCtrl.dispose();
      storageCtrl.dispose();
      meetingCountCtrl.dispose();
    }
  }

  Future<void> _createOrEditPlanPretty({BillingPlanItem? plan}) async {
    final nameCtrl = TextEditingController(text: plan?.name ?? '');
    final descriptionCtrl = TextEditingController(text: plan?.description ?? '');
    final activeRoomsCtrl = TextEditingController(
      text: (plan?.maxActiveRooms ?? 1) <= 0 ? 'unlimited' : (plan?.maxActiveRooms ?? 1).toString(),
    );
    final participantsCtrl = TextEditingController(
      text: (plan?.maxRoomParticipants ?? 100) <= 0 ? 'unlimited' : (plan?.maxRoomParticipants ?? 100).toString(),
    );
    final roomUsedSecondsCtrl = TextEditingController(
      text: (plan?.maxRoomUsedSeconds ?? 0) <= 0 ? 'unlimited' : (plan?.maxRoomUsedSeconds ?? 0).toString(),
    );
    final currentRoomUsedSecondsCtrl = TextEditingController(
      text: (plan?.maxCurrentRoomUsedSeconds ?? 0) <= 0 ? 'unlimited' : (plan?.maxCurrentRoomUsedSeconds ?? 0).toString(),
    );
    final storageCtrl = TextEditingController(
      text: (plan?.maxRecordingStorageBytes ?? 0) <= 0 ? 'unlimited' : (plan?.maxRecordingStorageBytes ?? 0).toString(),
    );
    final meetingCountCtrl = TextEditingController(
      text: (plan?.maxMeetingCount ?? 10) <= 0 ? 'unlimited' : (plan?.maxMeetingCount ?? 10).toString(),
    );

    Widget limitField({
      required TextEditingController controller,
      required String label,
      required IconData icon,
    }) {
      return TextField(
        controller: controller,
        keyboardType: TextInputType.text,
        decoration: InputDecoration(
          labelText: label,
          helperText: '填 0 / unlimited / 无限制 表示不限制',
          prefixIcon: Icon(icon, size: 18),
        ),
      );
    }

    final save = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => Dialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF155EEF), Color(0xFF175CD3)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                    ),
                    child: Text(
                      plan == null ? '新建计费套餐' : '编辑计费套餐',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFF),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFFDDE6FF)),
                            ),
                            child: Column(
                              children: [
                                TextField(
                                  controller: nameCtrl,
                                  decoration: const InputDecoration(
                                    labelText: '套餐名称',
                                    prefixIcon: Icon(Icons.sell_outlined, size: 18),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: descriptionCtrl,
                                  maxLines: 2,
                                  decoration: const InputDecoration(
                                    labelText: '描述（可选）',
                                    prefixIcon: Icon(Icons.notes_outlined, size: 18),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFCFDFF),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFFDDE6FF)),
                            ),
                            child: Column(
                              children: [
                                limitField(
                                  controller: activeRoomsCtrl,
                                  label: '最大活跃房间数',
                                  icon: Icons.meeting_room_outlined,
                                ),
                                const SizedBox(height: 10),
                                limitField(
                                  controller: participantsCtrl,
                                  label: '单房间最大人数',
                                  icon: Icons.groups_2_outlined,
                                ),
                                const SizedBox(height: 10),
                                limitField(
                                  controller: meetingCountCtrl,
                                  label: '最大会议数',
                                  icon: Icons.event_note_outlined,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFCFDFF),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFFDDE6FF)),
                            ),
                            child: Column(
                              children: [
                                limitField(
                                  controller: roomUsedSecondsCtrl,
                                  label: '累计房间使用时长上限（秒）',
                                  icon: Icons.av_timer_outlined,
                                ),
                                const SizedBox(height: 10),
                                limitField(
                                  controller: currentRoomUsedSecondsCtrl,
                                  label: '当前单房间最大在会时长上限（秒）',
                                  icon: Icons.timer_outlined,
                                ),
                                const SizedBox(height: 10),
                                limitField(
                                  controller: storageCtrl,
                                  label: '录制存储上限（字节）',
                                  icon: Icons.storage_outlined,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ) ??
        false;

    if (!save) {
      nameCtrl.dispose();
      descriptionCtrl.dispose();
      activeRoomsCtrl.dispose();
      participantsCtrl.dispose();
      roomUsedSecondsCtrl.dispose();
      currentRoomUsedSecondsCtrl.dispose();
      storageCtrl.dispose();
      meetingCountCtrl.dispose();
      return;
    }

    try {
      final payload = <String, dynamic>{
        'name': nameCtrl.text.trim(),
        'description': descriptionCtrl.text.trim(),
        'max_active_rooms': _parsePlanLimitValue(
          activeRoomsCtrl.text,
          fallback: plan?.maxActiveRooms ?? 1,
        ),
        'max_room_participants': _parsePlanLimitValue(
          participantsCtrl.text,
          fallback: plan?.maxRoomParticipants ?? 100,
        ),
        'max_room_used_seconds': _parsePlanLimitValue(
          roomUsedSecondsCtrl.text,
          fallback: plan?.maxRoomUsedSeconds ?? 0,
        ),
        'max_current_room_used_seconds': _parsePlanLimitValue(
          currentRoomUsedSecondsCtrl.text,
          fallback: plan?.maxCurrentRoomUsedSeconds ?? 0,
        ),
        'max_recording_storage_bytes': _parsePlanLimitValue(
          storageCtrl.text,
          fallback: plan?.maxRecordingStorageBytes ?? 0,
        ),
        'max_meeting_count': _parsePlanLimitValue(
          meetingCountCtrl.text,
          fallback: plan?.maxMeetingCount ?? 10,
        ),
      };
      if (plan == null) {
        final res = await _request('POST', '/api/billing/plans', body: payload);
        await _jsonOrThrow(res);
        _setStatus('套餐已创建');
      } else {
        final res = await _request('PATCH', '/api/billing/plans/${plan.id}', body: payload);
        await _jsonOrThrow(res);
        _setStatus('套餐已更新');
      }
      await _loadOverview();
    } catch (e) {
      _setStatus('保存套餐失败：${_friendlyError(e)}', isError: true);
    } finally {
      nameCtrl.dispose();
      descriptionCtrl.dispose();
      activeRoomsCtrl.dispose();
      participantsCtrl.dispose();
      roomUsedSecondsCtrl.dispose();
      currentRoomUsedSecondsCtrl.dispose();
      storageCtrl.dispose();
      meetingCountCtrl.dispose();
    }
  }

  Future<void> _deletePlan(BillingPlanItem plan) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除套餐'),
            content: Text('确认删除套餐“${plan.name}”？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    try {
      final res = await _request('DELETE', '/api/billing/plans/${plan.id}');
      await _jsonOrThrow(res);
      _setStatus('套餐已删除');
      await _loadOverview();
    } catch (e) {
      _setStatus('删除套餐失败：${_friendlyError(e)}', isError: true);
    }
  }

  Future<void> _openAssignPlanDialog(BillingUserItem user) async {
    int? selectedPlanId = user.planId;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setStateDialog) => AlertDialog(
              title: Text('分配套餐：${user.username}'),
              content: SizedBox(
                width: 420,
                child: DropdownButtonFormField<int?>(
                  value: selectedPlanId,
                  decoration: const InputDecoration(labelText: '选择套餐'),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('无套餐（不限制）'),
                    ),
                    ..._plans.map(
                      (plan) => DropdownMenuItem<int?>(
                        value: plan.id,
                        child: Text(plan.name),
                      ),
                    ),
                  ],
                  onChanged: (value) => setStateDialog(() => selectedPlanId = value),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        ) ??
        false;
    if (!confirmed) return;

    try {
      final res = await _request(
        'PATCH',
        '/api/billing/users/${user.userId}/plan',
        body: {'plan_id': selectedPlanId},
      );
      await _jsonOrThrow(res);
      _setStatus('用户套餐已更新');
      await _loadOverview();
    } catch (e) {
      _setStatus('分配套餐失败：${_friendlyError(e)}', isError: true);
    }
  }

  Widget _buildStatusBanner() {
    final icon =
        _statusIsError ? Icons.error_outline : Icons.check_circle_outline;
    final bg =
        _statusIsError ? const Color(0xFFFEE4E2) : const Color(0xFFEFF4FF);
    final fg =
        _statusIsError ? const Color(0xFFB42318) : const Color(0xFF175CD3);
    final border =
        _statusIsError ? const Color(0xFFFECACA) : const Color(0xFFCCDBFF);
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

  Widget _buildPlanCard(BillingPlanItem plan) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFCFDFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFDDE6FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  plan.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF101828),
                  ),
                ),
              ),
              IconButton(
                tooltip: '编辑套餐',
                onPressed: () => _createOrEditPlanPretty(plan: plan),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: '删除套餐',
                onPressed: () => _deletePlan(plan),
                icon: const Icon(Icons.delete_outline, color: Color(0xFFB42318)),
              ),
            ],
          ),
          if (plan.description.trim().isNotEmpty) ...[
            Text(
              plan.description.trim(),
              style: const TextStyle(color: Color(0xFF475467)),
            ),
            const SizedBox(height: 6),
          ],
          Text('活跃房间上限：${_formatPlanLimitInt(plan.maxActiveRooms)}'),
          Text('单房间人数上限：${_formatPlanLimitInt(plan.maxRoomParticipants)}'),
          Text('累计房间使用时长上限：${_formatPlanLimitSeconds(plan.maxRoomUsedSeconds)}'),
          Text(
              '当前单房间最大在会时长上限：${_formatPlanLimitSeconds(plan.maxCurrentRoomUsedSeconds)}'),
          Text('录制存储上限：${_formatPlanLimitBytes(plan.maxRecordingStorageBytes)}'),
          Text('会议数上限：${_formatPlanLimitInt(plan.maxMeetingCount)}'),
        ],
      ),
    );
  }

  Widget _buildAuthOptionSwitch({
    required String title,
    required String subtitle,
    required bool value,
    required bool enabled,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 0),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: Color(0xFF101828),
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: Color(0xFF667085)),
      ),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }

  Widget _buildAuthOptionsPanel() {
    final options = _authOptions;
    if (options == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: const [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Expanded(child: Text('正在加载登录选项...')),
            ],
          ),
        ),
      );
    }
    final canSave = !_savingAuthOptions;
    final techcloudSubtitle = options.techcloudOauthConfigured
        ? '控制中国科技云 OAuth 登录入口。'
        : '科技云 OAuth 未配置 client_id/client_secret/redirect_uri。';
    final updatedByText = options.updatedByUsername.trim().isEmpty
        ? '系统默认'
        : options.updatedByUsername.trim();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '登录选项',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _exportingUsers ? null : _exportUsersCsv,
                  icon: _exportingUsers
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined, size: 18),
                  label: const Text('导出用户信息'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildAuthOptionSwitch(
              title: '允许科技云用户登录',
              subtitle: techcloudSubtitle,
              value: options.allowTechcloudOauthLogin,
              enabled: canSave && options.techcloudOauthConfigured,
              onChanged: (value) {
                _saveAuthOptions(
                  options.copyWith(allowTechcloudOauthLogin: value),
                );
              },
            ),
            _buildAuthOptionSwitch(
              title: '允许本地注册',
              subtitle: '控制 /accounts/register 与 /api/auth/register。',
              value: options.allowLocalRegister,
              enabled: canSave,
              onChanged: (value) {
                _saveAuthOptions(
                  options.copyWith(allowLocalRegister: value),
                );
              },
            ),
            _buildAuthOptionSwitch(
              title: '允许本地用户名密码登录',
              subtitle: '控制 /accounts/login 与 /api/auth/login。',
              value: options.allowLocalLogin,
              enabled: canSave,
              onChanged: (value) {
                _saveAuthOptions(
                  options.copyWith(allowLocalLogin: value),
                );
              },
            ),
            const SizedBox(height: 6),
            Text(
              '最近更新：$updatedByText · ${_formatIsoDateTime(options.updatedAt)}',
              style: const TextStyle(
                color: Color(0xFF667085),
                fontSize: 12.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlansPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '套餐管理',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => _createOrEditPlanPretty(),
                  icon: const Icon(Icons.add),
                  label: const Text('新建套餐'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _plans.isEmpty
                  ? const Center(child: Text('暂无套餐'))
                  : ListView.separated(
                      itemCount: _plans.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, index) => _buildPlanCard(_plans[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserCard(BillingUserItem user) {
    final usage = user.usage;
    final limits = user.limits;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFDDE6FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${user.username} (#${user.userId})',
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF101828),
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _openAssignPlanDialog(user),
                icon: const Icon(Icons.assignment_ind_outlined, size: 18),
                label: const Text('分配套餐'),
              ),
            ],
          ),
          Text(
            user.email.trim().isEmpty ? '-' : user.email,
            style: const TextStyle(color: Color(0xFF667085)),
          ),
          const SizedBox(height: 4),
          Text(
            user.isSuperuser
                ? '超级管理员（不受限制）'
                : '当前套餐：${user.planName ?? '无套餐（不限制）'}',
            style: const TextStyle(color: Color(0xFF344054)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metricPill(
                '活跃房间',
                '${usage['active_room_count'] ?? 0}/${_formatLimitInt(limits['max_active_rooms'])}',
              ),
              _metricPill(
                '房间峰值',
                '${usage['room_peak_count'] ?? 0}',
              ),
              _metricPill(
                '人数上限使用',
                '${usage['max_room_participants_used'] ?? 0}/${_formatLimitInt(limits['max_room_participants'])}',
              ),
              _metricPill(
                '会议总数',
                '${usage['meeting_count'] ?? 0}/${_formatLimitInt(limits['max_meeting_count'])}',
              ),
              _metricPill(
                '累计房间使用时长',
                '${_formatSeconds(usage['cumulative_room_used_seconds'] ?? usage['room_used_seconds'] ?? 0)}/${_formatLimitSeconds(limits['max_room_used_seconds'])}',
              ),
              _metricPill(
                '当前单房间最大在会时长',
                '${_formatSeconds(usage['current_room_max_used_seconds'] ?? 0)}/${_formatLimitSeconds(limits['max_current_room_used_seconds'])}',
              ),
              _metricPill(
                '录制存储',
                '${_formatBytes(usage['recording_storage_used_bytes'] ?? 0)}/${_formatLimitBytes(limits['max_recording_storage_bytes'])}',
              ),
            ],
          ),
          if (user.exceededKeys.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: user.exceededKeys
                  .map(
                    (key) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEE4E2),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: const Color(0xFFFECACA)),
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
    );
  }

  Widget _metricPill(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFDDE6FF)),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(
          color: Color(0xFF344054),
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildUsersPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '用户使用量',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _users.isEmpty
                  ? const Center(child: Text('暂无用户'))
                  : ListView.separated(
                      itemCount: _users.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, index) => _buildUserCard(_users[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopBody() {
    return Column(
      children: [
        _buildAuthOptionsPanel(),
        const SizedBox(height: 10),
        Expanded(
          child: Row(
            children: [
              Expanded(flex: 4, child: _buildPlansPanel()),
              const SizedBox(width: 12),
              Expanded(flex: 6, child: _buildUsersPanel()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMobileBody() {
    return Column(
      children: [
        _buildAuthOptionsPanel(),
        const SizedBox(height: 8),
        Expanded(
          child: DefaultTabController(
            length: 2,
            child: Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFDDE6FF)),
                  ),
                  child: const TabBar(
                    tabs: [
                      Tab(text: '套餐', icon: Icon(Icons.sell_outlined)),
                      Tab(text: '用户', icon: Icon(Icons.people_outline)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: TabBarView(
                    children: [
                      _buildPlansPanel(),
                      _buildUsersPanel(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final useMobileLayout = widget.preferMobileLayout ||
        DeviceProfile.isPhoneWidth(context, breakpoint: 900);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '计费管理',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF155EEF), Color(0xFF175CD3)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '返回控制台',
            onPressed: () => html.window.location.assign('/dashboard'),
            icon: const Icon(Icons.dashboard_outlined, color: Colors.white),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _loadOverview,
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF5F8FF), Color(0xFFEEF4FF)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1500),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  _buildStatusBanner(),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : (useMobileLayout
                            ? _buildMobileBody()
                            : _buildDesktopBody()),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
