import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/theme/meeting_theme.dart';
import '../core/api_exception.dart';
import '../device_profile.dart';
import '../features/dashboard/models.dart';
import 'launch_uri.dart';
import 'native_api_client.dart';
import 'native_dashboard_logic.dart';
import 'native_join_target.dart';
import 'native_meeting_page.dart';

class WindowsLauncherPage extends StatefulWidget {
  const WindowsLauncherPage({super.key});

  @override
  State<WindowsLauncherPage> createState() => _WindowsLauncherPageState();
}

class _WindowsLauncherPageState extends State<WindowsLauncherPage> {
  static const Map<String, String> _meetingRecurrenceLabels = <String, String>{
    'once': '单次',
    'daily': '每天',
    'weekly': '每周',
    'monthly': '每月',
  };
  static const Map<String, String> _meetingTimezoneLabels = <String, String>{
    'Asia/Shanghai': '中国标准时间 (Asia/Shanghai)',
    'UTC': 'UTC',
    'Asia/Tokyo': '日本时间 (Asia/Tokyo)',
    'America/Los_Angeles': '美国西部 (America/Los_Angeles)',
    'America/New_York': '美国东部 (America/New_York)',
    'Europe/London': '英国时间 (Europe/London)',
  };

  final TextEditingController _serverController =
      TextEditingController(text: 'http://127.0.0.1:8000');
  final TextEditingController _livekitPublicUrlController =
      TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _quickJoinController = TextEditingController();
  final TextEditingController _joinPasswordController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _scheduledStartController =
      TextEditingController();
  final TextEditingController _durationController =
      TextEditingController(text: '30');
  final TextEditingController _maxParticipantsController =
      TextEditingController(text: '100');
  final TextEditingController _meetingPasswordController =
      TextEditingController();
  final TextEditingController _profileDisplayNameController =
      TextEditingController();
  final TextEditingController _profileAvatarUrlController =
      TextEditingController();

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

  bool _busy = false;
  String _status = '就绪';
  bool _statusIsError = false;
  String _accessToken = '';
  UserProfileData? _profile;
  List<MeetingItem> _meetings = const <MeetingItem>[];

  MeetingThemePalette get _palette => MeetingTheme.of(context);
  bool get _authed => _accessToken.trim().isNotEmpty;
  Uri get _baseUri => parseLauncherBaseUri(_serverController.text);

  DesktopMeetingApiClient _client() {
    return DesktopMeetingApiClient(
        baseUri: _baseUri, accessToken: _accessToken);
  }

  @override
  void dispose() {
    _serverController.dispose();
    _livekitPublicUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _quickJoinController.dispose();
    _joinPasswordController.dispose();
    _titleController.dispose();
    _descriptionController.dispose();
    _scheduledStartController.dispose();
    _durationController.dispose();
    _maxParticipantsController.dispose();
    _meetingPasswordController.dispose();
    _profileDisplayNameController.dispose();
    _profileAvatarUrlController.dispose();
    super.dispose();
  }

  void _setStatus(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusIsError = isError;
    });
  }

  String _friendlyError(Object error) {
    if (error is ApiException) return error.detail;
    final text = error.toString();
    if (text.startsWith('Exception: ')) {
      return text.substring('Exception: '.length);
    }
    return text;
  }

  String _formatScheduledStart(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '-';
    var text = raw.replaceFirst('T', ' ');
    final dotIndex = text.indexOf('.');
    if (dotIndex > 0) text = text.substring(0, dotIndex);
    if (text.endsWith('Z')) text = text.substring(0, text.length - 1);
    return text;
  }

  String _scheduledInputValue(String? raw) {
    final parsed = parseDesktopDateTimeInput(raw ?? '');
    if (parsed == null) return '';
    return formatDesktopDateTimeForInput(parsed);
  }

  Future<void> _pickScheduledStartForController(
    TextEditingController controller, {
    void Function(VoidCallback fn)? setStateDialog,
  }) async {
    final now = DateTime.now();
    final initial = parseDesktopDateTimeInput(controller.text) ?? now;
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
    void update() {
      controller.text = formatDesktopDateTimeForInput(next);
    }

    if (setStateDialog != null) {
      setStateDialog(update);
    } else {
      setState(update);
    }
  }

  void _resetCreateDraft() {
    _titleController.clear();
    _descriptionController.clear();
    _scheduledStartController.text =
        formatDesktopDateTimeForInput(DateTime.now());
    _durationController.text = '30';
    _maxParticipantsController.text = '100';
    _meetingPasswordController.clear();
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
  }

  Future<void> _login() async {
    if (_busy) return;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      _setStatus('用户名和密码不能为空', isError: true);
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在登录...';
      _statusIsError = false;
    });
    try {
      final token = await DesktopMeetingApiClient.loginWithPassword(
        baseUri: _baseUri,
        username: username,
        password: password,
      );
      final client =
          DesktopMeetingApiClient(baseUri: _baseUri, accessToken: token);
      final profile = await client.fetchProfile();
      final meetings = await client.fetchMeetings();
      if (!mounted) return;
      setState(() {
        _accessToken = token;
        _profile = profile;
        _meetings = meetings;
        _status = '登录成功：${profile.defaultDisplayName}';
      });
    } catch (error) {
      _setStatus('登录失败：${_friendlyError(error)}', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshDashboardData({bool silentStatus = false}) async {
    if (!_authed || _busy) return;
    setState(() {
      _busy = true;
      if (!silentStatus) {
        _status = '正在刷新控制台...';
        _statusIsError = false;
      }
    });
    try {
      final profile = await _client().fetchProfile();
      final meetings = await _client().fetchMeetings();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _meetings = meetings;
      });
      if (!silentStatus) _setStatus('控制台已刷新');
    } catch (error) {
      _setStatus('刷新失败：${_friendlyError(error)}', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshMeetings() async {
    if (!_authed || _busy) return;
    setState(() {
      _busy = true;
      _status = '正在刷新会议列表...';
      _statusIsError = false;
    });
    try {
      final meetings = await _client().fetchMeetings();
      if (!mounted) return;
      setState(() => _meetings = meetings);
      _setStatus('会议列表已刷新');
    } catch (error) {
      _setStatus('刷新失败：${_friendlyError(error)}', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _createMeeting() async {
    if (_busy || !_authed) return false;
    final profile = _profile;
    final resolvedTitle = _titleController.text.trim().isEmpty
        ? defaultDesktopMeetingTitle(
            defaultDisplayName: profile?.defaultDisplayName ?? '',
            username: profile?.username ?? '',
          )
        : _titleController.text;
    setState(() {
      _busy = true;
      _status = '正在创建会议...';
      _statusIsError = false;
    });
    try {
      final payload = buildDesktopMeetingPayload(
        title: resolvedTitle,
        description: _descriptionController.text,
        scheduledStart: _scheduledStartController.text,
        meetingRecurrence: _meetingRecurrence,
        meetingTimezone: _meetingTimezone,
        duration: _durationController.text,
        maxParticipants: _maxParticipantsController.text,
        password: _meetingPasswordController.text,
        waitingRoom: _waitingRoomEnabled,
        allowGuestLinkJoin: _allowGuestLinkJoin,
        allowRecording: _allowRecording,
        allowScreenShare: _allowScreenShare,
        allowChat: _allowChat,
        allowSelfUnmute: _allowSelfUnmute,
        allowMemberVideo: _allowMemberVideo,
        muteOnEntry: _muteOnEntry,
      );
      final meeting = await _client().createMeeting(payload);
      await _refreshDashboardData(silentStatus: true);
      _resetCreateDraft();
      _setStatus('会议已创建：${meeting.title}');
      return true;
    } catch (error) {
      _setStatus('创建会议失败：${_friendlyError(error)}', isError: true);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteMeeting(MeetingItem item) async {
    if (_busy || !_authed) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除会议'),
            content: Text('确认永久删除“${item.title}”？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
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
    setState(() {
      _busy = true;
      _status = '正在删除会议...';
      _statusIsError = false;
    });
    try {
      await _client().deleteMeetingByRef(item.meetingRef);
      await _refreshDashboardData(silentStatus: true);
      _setStatus('会议已删除');
    } catch (error) {
      _setStatus('删除失败：${_friendlyError(error)}', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openMeeting({
    required DesktopJoinTarget target,
    required String title,
    String meetingPassword = '',
  }) async {
    if (_busy || !_authed) return;
    setState(() {
      _busy = true;
      _status = '正在准备入会...';
      _statusIsError = false;
    });
    try {
      final cachedProfile = _profile;
      UserProfileData? latestProfile;
      try {
        latestProfile = await _client().fetchProfile();
        if (mounted) {
          setState(() => _profile = latestProfile);
        }
      } catch (_) {
        latestProfile = null;
      }
      final joinDisplayName = resolveDesktopJoinProfileField(
        cachedValue: cachedProfile?.defaultDisplayName ?? '',
        latestValue: latestProfile?.defaultDisplayName ?? '',
      );
      final joinUsername = resolveDesktopJoinProfileField(
        cachedValue: cachedProfile?.username ?? '',
        latestValue: latestProfile?.username ?? '',
      );
      final payload = await _client().fetchJoinTokenFromTarget(
        target: target,
        displayName: joinDisplayName,
        meetingPassword: meetingPassword.trim().isEmpty
            ? _joinPasswordController.text.trim()
            : meetingPassword.trim(),
      );
      final resolvedLivekitUrl = resolveDesktopLivekitUrl(
        tokenPayloadUrl: payload.livekitUrl,
        publicUrlOverrideInput: _livekitPublicUrlController.text,
      );
      final effectivePayload = payload.copyWith(livekitUrl: resolvedLivekitUrl);
      if (!mounted) return;
      _setStatus('正在加入会议：${effectivePayload.roomName}');
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NativeMeetingPage(
            joinPayload: effectivePayload,
            meetingTitle:
                title.trim().isEmpty ? effectivePayload.roomName : title,
            baseUri: _baseUri,
            accessToken: _accessToken,
            currentUsername: joinUsername,
          ),
        ),
      );
      _setStatus('已离开会议');
    } catch (error) {
      if (error is ApiException &&
          (error.payload?['waiting_room_status'] ?? '').toString() ==
              'pending') {
        _setStatus('已进入等候室，等待主持人准入');
      } else {
        _setStatus('入会失败：${_friendlyError(error)}', isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinFromInput() async {
    final input = _quickJoinController.text.trim();
    if (input.isEmpty) {
      _setStatus('请输入会议引用 / 分享码 / 会议号', isError: true);
      return;
    }
    final target = resolveDesktopJoinTarget(input);
    await _openMeeting(
      target: target,
      title: input,
      meetingPassword: _joinPasswordController.text.trim(),
    );
  }

  Future<void> _openJoinDialog() async {
    final targetCtrl = TextEditingController(text: _quickJoinController.text);
    final passwordCtrl =
        TextEditingController(text: _joinPasswordController.text);
    try {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '加入会议',
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, animation, secondaryAnimation) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: _palette.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _palette.panelBorder),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 24,
                        offset: Offset(0, 16),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '加入会议',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '输入会议引用、分享码或会议号',
                        style: TextStyle(color: Color(0xFF667085)),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: targetCtrl,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: '会议引用 / 分享码 / 会议号',
                        ),
                        onSubmitted: (_) async {
                          final target = targetCtrl.text.trim();
                          if (target.isEmpty) return;
                          _quickJoinController.text = target;
                          _joinPasswordController.text = passwordCtrl.text;
                          if (context.mounted) Navigator.pop(context);
                          await _joinFromInput();
                        },
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: passwordCtrl,
                        decoration:
                            const InputDecoration(labelText: '会议密码（可选）'),
                        obscureText: true,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('取消'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: () async {
                                final target = targetCtrl.text.trim();
                                if (target.isEmpty) {
                                  _setStatus('请输入会议引用 / 分享码 / 会议号',
                                      isError: true);
                                  return;
                                }
                                _quickJoinController.text = target;
                                _joinPasswordController.text =
                                    passwordCtrl.text;
                                if (context.mounted) Navigator.pop(context);
                                await _joinFromInput();
                              },
                              child: const Text('立即入会'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
              child: child,
            ),
          );
        },
      );
    } finally {
      targetCtrl.dispose();
      passwordCtrl.dispose();
    }
  }

  Future<void> _showJoinToken(MeetingItem item) async {
    if (_busy || !_authed) return;
    setState(() {
      _busy = true;
      _status = '正在获取入会令牌...';
      _statusIsError = false;
    });
    try {
      final payload =
          await _client().fetchJoinTokenJsonForMeetingRef(item.meetingRef);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('入会令牌'),
          content: SizedBox(
            width: 620,
            child: SelectableText(
                const JsonEncoder.withIndent('  ').convert(payload)),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: const JsonEncoder.withIndent('  ').convert(payload),
                  ),
                );
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('复制'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      _setStatus('入会令牌已加载');
    } catch (error) {
      _setStatus('获取令牌失败：${_friendlyError(error)}', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openShareDialog(MeetingItem item) async {
    final link = buildDesktopMeetingShareUrl(
      baseUri: _baseUri,
      shareUrl: item.shareUrl,
      shareCode: item.shareCode,
    );
    if (link.isEmpty) {
      _setStatus('当前会议无法生成分享链接', isError: true);
      return;
    }
    final info = buildDesktopMeetingShareText(
      title: item.title,
      roomName: item.roomName,
      shareUrl: link,
      meetingPasswordForShare: item.meetingPasswordForShare,
      hasPassword: item.hasPassword,
    );
    final linkCopyText = buildDesktopMeetingShareLinkCopyText(
      shareUrl: link,
      meetingPasswordForShare: item.meetingPasswordForShare,
    );
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
              const Text('分享链接', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SelectableText(link),
              const SizedBox(height: 12),
              const Text(
                '分享文案',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              SelectableText(info),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: linkCopyText));
              if (context.mounted) Navigator.pop(context);
              _setStatus('分享链接已复制');
            },
            child: const Text('复制链接'),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: info));
              if (context.mounted) Navigator.pop(context);
              _setStatus('分享文案已复制');
            },
            child: const Text('复制文案'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _openProfileDialog() async {
    final profile = _profile;
    if (profile == null) return;
    _profileDisplayNameController.text = profile.defaultDisplayName;
    _profileAvatarUrlController.text = profile.avatarUrl;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑个人资料'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _profileDisplayNameController,
                decoration: const InputDecoration(labelText: '默认显示名称'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _profileAvatarUrlController,
                decoration: const InputDecoration(labelText: '头像 URL'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _busy
                ? null
                : () async {
                    final nextDisplayName =
                        _profileDisplayNameController.text.trim();
                    if (nextDisplayName.isEmpty) {
                      _setStatus('默认显示名称不能为空', isError: true);
                      return;
                    }
                    setState(() {
                      _busy = true;
                      _status = '正在更新资料...';
                      _statusIsError = false;
                    });
                    try {
                      final next = await _client().updateProfile(
                        avatarUrl: _profileAvatarUrlController.text,
                        defaultDisplayName: nextDisplayName,
                      );
                      if (!mounted) return;
                      setState(() => _profile = next);
                      _setStatus('资料已更新');
                      if (context.mounted) Navigator.pop(context);
                    } catch (error) {
                      _setStatus(
                        '更新资料失败：${_friendlyError(error)}',
                        isError: true,
                      );
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _openCreateDialog() async {
    _resetCreateDraft();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: const Text('创建会议'),
          content: SizedBox(
            width: 700,
            child: SingleChildScrollView(
              child: _buildCreateFormContent(setStateDialog: setStateDialog),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      final ok = await _createMeeting();
                      if (ok && dialogContext.mounted) {
                        Navigator.pop(dialogContext);
                      }
                    },
              icon: const Icon(Icons.add),
              label: const Text('创建'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditMeetingDialog(MeetingItem item) async {
    if (_busy || !_authed) return;
    final titleCtrl = TextEditingController(text: item.title);
    final descriptionCtrl = TextEditingController(text: item.description ?? '');
    final scheduledCtrl = TextEditingController(
      text: _scheduledInputValue(item.scheduledStart).isEmpty
          ? formatDesktopDateTimeForInput(DateTime.now())
          : _scheduledInputValue(item.scheduledStart),
    );
    final durationCtrl =
        TextEditingController(text: item.durationMinutes.toString());
    final maxCtrl =
        TextEditingController(text: item.maxParticipants.toString());
    final passwordCtrl = TextEditingController();
    String meetingRecurrence =
        _meetingRecurrenceLabels.containsKey(item.meetingRecurrence)
            ? item.meetingRecurrence
            : 'once';
    String meetingTimezone =
        _meetingTimezoneLabels.containsKey(item.meetingTimezone)
            ? item.meetingTimezone
            : 'Asia/Shanghai';
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
          builder: (context) => StatefulBuilder(
            builder: (context, setStateDialog) => AlertDialog(
              title: const Text('编辑会议'),
              content: SizedBox(
                width: 700,
                child: SingleChildScrollView(
                  child: _buildEditFormContent(
                    titleCtrl: titleCtrl,
                    descriptionCtrl: descriptionCtrl,
                    scheduledCtrl: scheduledCtrl,
                    durationCtrl: durationCtrl,
                    maxCtrl: maxCtrl,
                    passwordCtrl: passwordCtrl,
                    meetingRecurrence: meetingRecurrence,
                    meetingTimezone: meetingTimezone,
                    clearPassword: clearPassword,
                    waitingRoom: waitingRoom,
                    allowGuestLinkJoin: allowGuestLinkJoin,
                    allowRecording: allowRecording,
                    allowScreenShare: allowScreenShare,
                    allowChat: allowChat,
                    allowSelfUnmute: allowSelfUnmute,
                    allowMemberVideo: allowMemberVideo,
                    muteOnEntry: muteOnEntry,
                    hasPassword: item.hasPassword,
                    onMeetingRecurrenceChanged: (value) =>
                        setStateDialog(() => meetingRecurrence = value),
                    onMeetingTimezoneChanged: (value) =>
                        setStateDialog(() => meetingTimezone = value),
                    onClearPasswordChanged: (value) =>
                        setStateDialog(() => clearPassword = value),
                    onWaitingRoomChanged: (value) =>
                        setStateDialog(() => waitingRoom = value),
                    onAllowGuestLinkJoinChanged: (value) =>
                        setStateDialog(() => allowGuestLinkJoin = value),
                    onAllowRecordingChanged: (value) =>
                        setStateDialog(() => allowRecording = value),
                    onAllowScreenShareChanged: (value) =>
                        setStateDialog(() => allowScreenShare = value),
                    onAllowChatChanged: (value) =>
                        setStateDialog(() => allowChat = value),
                    onAllowSelfUnmuteChanged: (value) =>
                        setStateDialog(() => allowSelfUnmute = value),
                    onAllowMemberVideoChanged: (value) =>
                        setStateDialog(() => allowMemberVideo = value),
                    onMuteOnEntryChanged: (value) =>
                        setStateDialog(() => muteOnEntry = value),
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
          ),
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

    setState(() {
      _busy = true;
      _status = '正在更新会议...';
      _statusIsError = false;
    });
    try {
      final payload = buildDesktopMeetingUpdatePayload(
        title: titleCtrl.text,
        description: descriptionCtrl.text,
        scheduledStart: scheduledCtrl.text,
        meetingRecurrence: meetingRecurrence,
        meetingTimezone: meetingTimezone,
        duration: durationCtrl.text,
        maxParticipants: maxCtrl.text,
        password: passwordCtrl.text,
        clearPassword: clearPassword,
        waitingRoom: waitingRoom,
        allowGuestLinkJoin: allowGuestLinkJoin,
        allowRecording: allowRecording,
        allowScreenShare: allowScreenShare,
        allowChat: allowChat,
        allowSelfUnmute: allowSelfUnmute,
        allowMemberVideo: allowMemberVideo,
        muteOnEntry: muteOnEntry,
      );
      final updated = await _client().updateMeetingByRef(
        meetingRef: item.meetingRef,
        payload: payload,
      );
      if (!mounted) return;
      setState(() {
        _meetings = _meetings
            .map((entry) =>
                entry.meetingRef == updated.meetingRef ? updated : entry)
            .toList();
      });
      _setStatus('会议已更新');
    } catch (error) {
      _setStatus('更新失败：${_friendlyError(error)}', isError: true);
    } finally {
      titleCtrl.dispose();
      descriptionCtrl.dispose();
      scheduledCtrl.dispose();
      durationCtrl.dispose();
      maxCtrl.dispose();
      passwordCtrl.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyMeetingRoom(String roomName) async {
    await Clipboard.setData(ClipboardData(text: roomName));
    _setStatus('会议号已复制');
  }

  void _logout() {
    setState(() {
      _accessToken = '';
      _profile = null;
      _meetings = const <MeetingItem>[];
      _joinPasswordController.clear();
      _status = '已退出登录';
      _statusIsError = false;
    });
  }

  Widget _buildOptionTile({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return CheckboxListTile(
      value: value,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      onChanged: (next) => onChanged(next ?? false),
      title: Text(label),
    );
  }

  Widget _buildCreateFormContent({
    void Function(VoidCallback fn)? setStateDialog,
  }) {
    void updateOption(VoidCallback fn) {
      if (setStateDialog != null) {
        setStateDialog(fn);
      } else {
        setState(fn);
      }
    }

    return Column(
      children: [
        TextField(
          controller: _titleController,
          decoration: const InputDecoration(
            labelText: '会议标题（可选）',
            hintText: '留空时自动使用“显示名预定的会议”',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _descriptionController,
          decoration: const InputDecoration(labelText: '会议描述'),
        ),
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
            suffixIcon: Icon(Icons.calendar_today_outlined, size: 18),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue:
                    _meetingRecurrenceLabels.containsKey(_meetingRecurrence)
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
                onChanged: (value) =>
                    updateOption(() => _meetingRecurrence = value ?? 'once'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue:
                    _meetingTimezoneLabels.containsKey(_meetingTimezone)
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
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
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
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _meetingPasswordController,
          decoration: const InputDecoration(labelText: '会议密码（可选）'),
        ),
        const SizedBox(height: 4),
        _buildOptionTile(
          label: '启用等候室',
          value: _waitingRoomEnabled,
          onChanged: (v) => updateOption(() => _waitingRoomEnabled = v),
        ),
        _buildOptionTile(
          label: '允许访客通过链接加入',
          value: _allowGuestLinkJoin,
          onChanged: (v) => updateOption(() => _allowGuestLinkJoin = v),
        ),
        _buildOptionTile(
          label: '入会自动静音',
          value: _muteOnEntry,
          onChanged: (v) => updateOption(() => _muteOnEntry = v),
        ),
        _buildOptionTile(
          label: '允许录制',
          value: _allowRecording,
          onChanged: (v) => updateOption(() => _allowRecording = v),
        ),
        _buildOptionTile(
          label: '允许屏幕共享',
          value: _allowScreenShare,
          onChanged: (v) => updateOption(() => _allowScreenShare = v),
        ),
        _buildOptionTile(
          label: '允许聊天',
          value: _allowChat,
          onChanged: (v) => updateOption(() => _allowChat = v),
        ),
        _buildOptionTile(
          label: '允许成员自行解除静音',
          value: _allowSelfUnmute,
          onChanged: (v) => updateOption(() => _allowSelfUnmute = v),
        ),
        _buildOptionTile(
          label: '允许成员开启视频',
          value: _allowMemberVideo,
          onChanged: (v) => updateOption(() => _allowMemberVideo = v),
        ),
      ],
    );
  }

  Widget _buildEditFormContent({
    required TextEditingController titleCtrl,
    required TextEditingController descriptionCtrl,
    required TextEditingController scheduledCtrl,
    required TextEditingController durationCtrl,
    required TextEditingController maxCtrl,
    required TextEditingController passwordCtrl,
    required String meetingRecurrence,
    required String meetingTimezone,
    required bool clearPassword,
    required bool waitingRoom,
    required bool allowGuestLinkJoin,
    required bool allowRecording,
    required bool allowScreenShare,
    required bool allowChat,
    required bool allowSelfUnmute,
    required bool allowMemberVideo,
    required bool muteOnEntry,
    required bool hasPassword,
    required ValueChanged<String> onMeetingRecurrenceChanged,
    required ValueChanged<String> onMeetingTimezoneChanged,
    required ValueChanged<bool> onClearPasswordChanged,
    required ValueChanged<bool> onWaitingRoomChanged,
    required ValueChanged<bool> onAllowGuestLinkJoinChanged,
    required ValueChanged<bool> onAllowRecordingChanged,
    required ValueChanged<bool> onAllowScreenShareChanged,
    required ValueChanged<bool> onAllowChatChanged,
    required ValueChanged<bool> onAllowSelfUnmuteChanged,
    required ValueChanged<bool> onAllowMemberVideoChanged,
    required ValueChanged<bool> onMuteOnEntryChanged,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
            controller: titleCtrl,
            decoration: const InputDecoration(labelText: '会议标题')),
        const SizedBox(height: 10),
        TextField(
            controller: descriptionCtrl,
            decoration: const InputDecoration(labelText: '会议描述')),
        const SizedBox(height: 10),
        TextField(
          controller: scheduledCtrl,
          readOnly: true,
          onTap: () => _pickScheduledStartForController(scheduledCtrl),
          decoration: const InputDecoration(
            labelText: '开始时间',
            suffixIcon: Icon(Icons.calendar_today_outlined, size: 18),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: meetingRecurrence,
                decoration: const InputDecoration(labelText: '会议周期'),
                items: _meetingRecurrenceLabels.entries
                    .map(
                      (entry) => DropdownMenuItem<String>(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    onMeetingRecurrenceChanged(value ?? 'once'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: meetingTimezone,
                decoration: const InputDecoration(labelText: '时区'),
                items: _meetingTimezoneLabels.entries
                    .map(
                      (entry) => DropdownMenuItem<String>(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    onMeetingTimezoneChanged(value ?? 'Asia/Shanghai'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: durationCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '时长（分钟）'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: maxCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '人数上限'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: passwordCtrl,
          onChanged: (value) {
            if (clearPassword && value.trim().isNotEmpty) {
              onClearPasswordChanged(false);
            }
          },
          decoration: const InputDecoration(labelText: '新密码（可选）'),
        ),
        if (hasPassword)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed:
                  clearPassword ? null : () => onClearPasswordChanged(true),
              icon: Icon(clearPassword
                  ? Icons.check_circle_outline
                  : Icons.lock_reset_outlined),
              label: Text(clearPassword ? '将清空当前会议密码' : '清空当前会议密码'),
            ),
          ),
        _buildOptionTile(
            label: '启用等候室',
            value: waitingRoom,
            onChanged: onWaitingRoomChanged),
        _buildOptionTile(
            label: '允许访客通过链接加入',
            value: allowGuestLinkJoin,
            onChanged: onAllowGuestLinkJoinChanged),
        _buildOptionTile(
            label: '入会自动静音',
            value: muteOnEntry,
            onChanged: onMuteOnEntryChanged),
        _buildOptionTile(
            label: '允许录制',
            value: allowRecording,
            onChanged: onAllowRecordingChanged),
        _buildOptionTile(
            label: '允许屏幕共享',
            value: allowScreenShare,
            onChanged: onAllowScreenShareChanged),
        _buildOptionTile(
            label: '允许聊天', value: allowChat, onChanged: onAllowChatChanged),
        _buildOptionTile(
            label: '允许成员自行解除静音',
            value: allowSelfUnmute,
            onChanged: onAllowSelfUnmuteChanged),
        _buildOptionTile(
            label: '允许成员开启视频',
            value: allowMemberVideo,
            onChanged: onAllowMemberVideoChanged),
      ],
    );
  }

  Widget _buildLoginView(ThemeData theme) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: Card(
          color: _palette.surface,
          child: Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        _palette.heroGradientStart,
                        _palette.heroGradientEnd
                      ],
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '智能会议',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          color: _palette.heroText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Windows 原生客户端',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: _palette.heroMutedText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('登录', style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 16),
                      TextField(
                          controller: _serverController,
                          decoration:
                              const InputDecoration(labelText: '服务器地址')),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _livekitPublicUrlController,
                        decoration: const InputDecoration(
                          labelText: 'LiveKit 公网地址（可选）',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                          controller: _usernameController,
                          decoration: const InputDecoration(labelText: '用户名')),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: '密码'),
                        onSubmitted: (_) => _login(),
                      ),
                      const SizedBox(height: 18),
                      FilledButton(
                        onPressed: _busy ? null : _login,
                        child: Text(_busy ? '登录中...' : '登录'),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _status,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _statusIsError
                              ? _palette.danger
                              : _palette.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileLoginView(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_palette.pageBackground, _palette.primarySoft],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _palette.heroBorder),
                  gradient: LinearGradient(
                    colors: [
                      _palette.heroGradientStart,
                      _palette.heroGradientEnd
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '智能会议',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: _palette.heroText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Android 原生客户端',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: _palette.heroMutedText),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '手机端登录',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: _palette.heroMutedText),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Card(
                color: _palette.surface,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('登录', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _serverController,
                        decoration: const InputDecoration(labelText: '服务器地址'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _livekitPublicUrlController,
                        decoration: const InputDecoration(
                          labelText: 'LiveKit 公网地址（可选）',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _usernameController,
                        decoration: const InputDecoration(labelText: '用户名'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: '密码'),
                        onSubmitted: (_) => _login(),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _busy ? null : _login,
                        child: Text(_busy ? '登录中...' : '登录'),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _status,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _statusIsError
                              ? _palette.danger
                              : _palette.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSidebar(ThemeData theme) {
    final profile = _profile;
    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: _palette.surface,
        border: Border(right: BorderSide(color: _palette.panelBorder)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('智能会议',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                profile == null
                    ? '-'
                    : '${profile.defaultDisplayName} (${profile.username})',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: _palette.textMuted),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  onPressed: _busy ? null : _openProfileDialog,
                  icon: const Icon(Icons.person_outline),
                  label: const Text('编辑资料')),
              const SizedBox(height: 8),
              FilledButton.icon(
                  onPressed: _busy ? null : _openCreateDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('创建会议')),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                  onPressed: _busy ? null : _openJoinDialog,
                  icon: const Icon(Icons.video_call_outlined),
                  label: const Text('加入会议')),
              const SizedBox(height: 10),
              FilledButton(
                  onPressed: _busy ? null : _openJoinDialog,
                  child: const Text('快速入会')),
              const Spacer(),
              OutlinedButton.icon(
                  onPressed: _busy ? null : _refreshDashboardData,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新全部')),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                  onPressed: _busy ? null : _refreshMeetings,
                  icon: const Icon(Icons.list_alt_outlined),
                  label: const Text('刷新会议')),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                  onPressed: _busy ? null : _logout,
                  icon: const Icon(Icons.logout),
                  label: const Text('退出登录')),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _meetingFeatureChips(MeetingItem item) {
    final features = <String>[];
    if (item.waitingRoomEnabled) features.add('等候室');
    if (item.allowRecording) features.add('录制');
    if (item.allowScreenShare) features.add('屏幕共享');
    if (item.allowChat) features.add('聊天');
    if (item.allowSelfUnmute) features.add('成员自解静音');
    if (item.allowMemberVideo) features.add('成员视频');
    if (item.muteOnEntry) features.add('入会自动静音');
    return features
        .map(
          (feature) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
                color: const Color(0xFFEEF4FF),
                borderRadius: BorderRadius.circular(999)),
            child: Text(feature,
                style: const TextStyle(fontSize: 12, color: Color(0xFF344054))),
          ),
        )
        .toList();
  }

  Widget _buildMeetingCard(MeetingItem item) {
    final recurrence = _meetingRecurrenceLabels[item.meetingRecurrence] ??
        item.meetingRecurrence;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.title,
                style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontWeight: FontWeight.w700,
                    fontSize: 16)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                    child: Text('会议号：${item.roomName}',
                        style: const TextStyle(
                            color: Color(0xFF344054),
                            fontWeight: FontWeight.w600))),
                IconButton(
                    tooltip: '复制会议号',
                    onPressed: () => _copyMeetingRoom(item.roomName),
                    icon: const Icon(Icons.copy_outlined)),
              ],
            ),
            Text(
              '引用：${item.meetingRef}\n分享码：${item.shareCode}\n开始：${_formatScheduledStart(item.scheduledStart)}\n周期：$recurrence  时区：${item.meetingTimezone}\n时长：${item.durationMinutes}分钟  上限：${item.maxParticipants}人  密码：${item.hasPassword ? '已设置' : '无'}',
              style: const TextStyle(color: Color(0xFF475467), height: 1.4),
            ),
            if ((item.description ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(item.description!.trim(),
                  style: const TextStyle(color: Color(0xFF667085))),
            ],
            if (_meetingFeatureChips(item).isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _meetingFeatureChips(item)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _openMeeting(
                            target: DesktopJoinTarget(
                              meetingRef: item.meetingRef,
                              shareCode: item.shareCode,
                              roomName: item.roomName,
                            ),
                            title: item.title,
                          ),
                  child: const Text('加入'),
                ),
                OutlinedButton.icon(
                    onPressed: _busy ? null : () => _openShareDialog(item),
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('分享')),
                if (item.canEdit)
                  OutlinedButton.icon(
                      onPressed:
                          _busy ? null : () => _openEditMeetingDialog(item),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('编辑')),
                if (item.canDebugToken)
                  OutlinedButton.icon(
                      onPressed: _busy ? null : () => _showJoinToken(item),
                      icon: const Icon(Icons.vpn_key_outlined),
                      label: const Text('令牌')),
                if (item.canDelete)
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                        foregroundColor: const Color(0xFFB42318)),
                    onPressed: _busy ? null : () => _deleteMeeting(item),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('删除'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBanner(ThemeData theme) {
    final fg = _statusIsError ? _palette.danger : _palette.primaryStrong;
    final bg = _statusIsError ? _palette.dangerSurface : _palette.primarySoft;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: _statusIsError
                ? _palette.dangerBorder
                : _palette.primaryBorder),
      ),
      child: Row(
        children: [
          Icon(_statusIsError ? Icons.error_outline : Icons.info_outline,
              color: fg, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text(_status,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: fg, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  Widget _buildMobileHeader(ThemeData theme) {
    final profile = _profile;
    final subtitle =
        profile == null ? '手机端会议控制中心' : '欢迎，${profile.defaultDisplayName}';
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
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _palette.heroMutedText,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '刷新全部',
            onPressed: _busy ? null : _refreshDashboardData,
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
          IconButton(
            tooltip: '退出登录',
            onPressed: _busy ? null : _logout,
            icon: const Icon(Icons.logout, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileMeetingsTab(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('我的会议', style: theme.textTheme.titleLarge)),
            FilledButton.icon(
              onPressed: _busy ? null : _openCreateDialog,
              icon: const Icon(Icons.add),
              label: const Text('创建'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _meetings.isEmpty
              ? Center(child: Text('暂无会议', style: theme.textTheme.bodyMedium))
              : ListView.separated(
                  itemCount: _meetings.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      _buildMeetingCard(_meetings[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildMobileActionsTab() {
    return SingleChildScrollView(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '快捷操作',
                style: TextStyle(
                  color: Color(0xFF101828),
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '按移动端流程快速创建、入会和维护资料。',
                style: TextStyle(color: Color(0xFF475467), fontSize: 13),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _openCreateDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('创建会议'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _openJoinDialog,
                  icon: const Icon(Icons.video_call_outlined),
                  label: const Text('加入会议'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _openProfileDialog,
                  icon: const Icon(Icons.person_outline),
                  label: const Text('编辑资料'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _refreshMeetings,
                  icon: const Icon(Icons.list_alt_outlined),
                  label: const Text('刷新会议'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: _busy ? null : _logout,
                  icon: const Icon(Icons.logout),
                  label: const Text('退出登录'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileTabs(ThemeData theme) {
    return DefaultTabController(
      length: 2,
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
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TabBarView(
              children: [
                _buildMobileMeetingsTab(theme),
                _buildMobileActionsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileHomeView(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_palette.pageBackground, _palette.primarySoft],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
          child: Column(
            children: [
              _buildMobileHeader(theme),
              const SizedBox(height: 8),
              _buildStatusBanner(theme),
              const SizedBox(height: 8),
              Expanded(child: _buildMobileTabs(theme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomeView(ThemeData theme) {
    return Row(
      children: [
        _buildSidebar(theme),
        Expanded(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStatusBanner(theme),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                          child: Text('我的会议',
                              style: theme.textTheme.headlineSmall)),
                      FilledButton.icon(
                          onPressed: _busy ? null : _openCreateDialog,
                          icon: const Icon(Icons.add),
                          label: const Text('创建')),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _meetings.isEmpty
                        ? Center(
                            child:
                                Text('暂无会议', style: theme.textTheme.bodyMedium))
                        : ListView.separated(
                            itemCount: _meetings.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) =>
                                _buildMeetingCard(_meetings[index]),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final useMobileLayout =
        DeviceProfile.isPhoneWidth(context, breakpoint: 840);
    return Scaffold(
      backgroundColor: _palette.pageBackground,
      body: _authed
          ? (useMobileLayout
              ? _buildMobileHomeView(theme)
              : _buildHomeView(theme))
          : (useMobileLayout
              ? _buildMobileLoginView(theme)
              : _buildLoginView(theme)),
    );
  }
}
