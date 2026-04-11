enum ParticipantMenuEntryKind {
  section,
  action,
  divider,
}

enum ParticipantMenuIcon {
  badge,
  mic,
  micOff,
  hand,
  video,
  videoOff,
  screenShare,
  stopScreenShare,
  robot,
  keyboardVoice,
  cameraAlt,
  chatBubble,
  taskAlt,
  adminPanel,
  rename,
  personRemove,
  personRemoveAlt,
  personOff,
}

class ParticipantMenuEntrySpec {
  const ParticipantMenuEntrySpec.section(this.title)
      : kind = ParticipantMenuEntryKind.section,
        value = null,
        subtitle = null,
        icon = null,
        enabled = true,
        danger = false;

  const ParticipantMenuEntrySpec.divider()
      : kind = ParticipantMenuEntryKind.divider,
        value = null,
        title = '',
        subtitle = null,
        icon = null,
        enabled = true,
        danger = false;

  const ParticipantMenuEntrySpec.action({
    required this.value,
    required this.title,
    required this.icon,
    this.subtitle,
    this.enabled = true,
    this.danger = false,
  }) : kind = ParticipantMenuEntryKind.action;

  final ParticipantMenuEntryKind kind;
  final String? value;
  final String title;
  final String? subtitle;
  final ParticipantMenuIcon? icon;
  final bool enabled;
  final bool danger;
}

class ParticipantMenuBuilderInput {
  const ParticipantMenuBuilderInput({
    required this.isSelf,
    required this.isModerator,
    required this.hasPrivateMeetingApiScope,
    required this.userId,
    required this.isRealtimeBot,
    required this.roleKey,
    required this.micEnabled,
    required this.cameraEnabled,
    required this.mutedByHost,
    required this.videoBlockedByHost,
    required this.allowSelfUnmute,
    required this.allowMemberVideo,
    required this.allowChat,
    required this.allowScreenShare,
    required this.micRequestPending,
    required this.videoRequestPending,
    required this.screenShareRequestPending,
    required this.isScreenSharing,
  });

  final bool isSelf;
  final bool isModerator;
  final bool hasPrivateMeetingApiScope;
  final int? userId;
  final bool isRealtimeBot;
  final String roleKey;
  final bool micEnabled;
  final bool cameraEnabled;
  final bool mutedByHost;
  final bool videoBlockedByHost;
  final bool allowSelfUnmute;
  final bool allowMemberVideo;
  final bool allowChat;
  final bool allowScreenShare;
  final bool micRequestPending;
  final bool videoRequestPending;
  final bool screenShareRequestPending;
  final bool isScreenSharing;
}

List<ParticipantMenuEntrySpec> buildParticipantMenuSpecs(
  ParticipantMenuBuilderInput input,
) {
  final items = <ParticipantMenuEntrySpec>[];

  if (input.isSelf) {
    items.add(const ParticipantMenuEntrySpec.section('我的控制'));
    items.add(
      const ParticipantMenuEntrySpec.action(
        value: 'rename_self',
        title: '修改本次显示名',
        icon: ParticipantMenuIcon.badge,
      ),
    );
    if (!input.allowSelfUnmute) {
      items.add(
        ParticipantMenuEntrySpec.action(
          value: 'request_mic',
          title: input.micRequestPending ? '开麦申请已提交' : '申请开麦',
          subtitle: input.micRequestPending ? '等待主持人审批' : '提交后主持人可一键批准',
          icon: ParticipantMenuIcon.hand,
          enabled: !input.micRequestPending,
        ),
      );
    }
    if (!input.allowMemberVideo) {
      items.add(
        ParticipantMenuEntrySpec.action(
          value: 'request_video',
          title: input.videoRequestPending ? '开视频申请已提交' : '申请开视频',
          subtitle: input.videoRequestPending ? '等待主持人审批' : '提交后主持人可一键批准',
          icon: ParticipantMenuIcon.video,
          enabled: !input.videoRequestPending,
        ),
      );
    }
    if (!input.allowScreenShare) {
      items.add(
        ParticipantMenuEntrySpec.action(
          value: 'request_share',
          title: input.screenShareRequestPending ? '屏幕共享申请已提交' : '申请屏幕共享',
          subtitle: input.screenShareRequestPending ? '等待主持人审批' : '提交后主持人可一键批准',
          icon: ParticipantMenuIcon.screenShare,
          enabled: !input.screenShareRequestPending,
        ),
      );
    }
    return items;
  }

  if (!(input.isModerator && input.hasPrivateMeetingApiScope)) {
    return items;
  }

  if (input.isRealtimeBot) {
    items.add(const ParticipantMenuEntrySpec.section('AI 控制'));
    items.add(
      ParticipantMenuEntrySpec.action(
        value: input.mutedByHost ? 'unmute' : 'mute',
        title: input.mutedByHost ? '允许 AI 发言' : '静音 AI 发言',
        subtitle: input.mutedByHost ? '当前：已静音' : '当前：可发言',
        icon: input.mutedByHost
            ? ParticipantMenuIcon.mic
            : ParticipantMenuIcon.micOff,
      ),
    );
    items.add(
      const ParticipantMenuEntrySpec.action(
        value: 'ai_control',
        title: '打开 AI 管控',
        subtitle: '配置模型参数并测试连通性',
        icon: ParticipantMenuIcon.robot,
      ),
    );
    return items;
  }

  if (input.roleKey == 'host') {
    return items;
  }

  final isGuest = input.userId == null;
  final muteSubtitle = isGuest
      ? (input.micEnabled ? '当前：麦克风开启' : '当前：麦克风关闭')
      : (input.mutedByHost ? '当前：主持人已静音' : '当前：成员可发言');
  final videoSubtitle = isGuest
      ? (input.cameraEnabled ? '当前：摄像头开启' : '当前：摄像头关闭')
      : (input.videoBlockedByHost ? '当前：主持人已关闭视频' : '当前：成员可开视频');

  items.add(const ParticipantMenuEntrySpec.section('即时控制'));
  items.add(
    ParticipantMenuEntrySpec.action(
      value: input.mutedByHost ? 'unmute' : 'mute',
      title: input.mutedByHost ? '允许开麦' : '静音成员',
      subtitle: muteSubtitle,
      icon: input.mutedByHost
          ? ParticipantMenuIcon.mic
          : ParticipantMenuIcon.micOff,
    ),
  );
  items.add(
    ParticipantMenuEntrySpec.action(
      value: input.videoBlockedByHost ? 'video_on' : 'video_off',
      title: input.videoBlockedByHost ? '允许开视频' : '关闭成员视频',
      subtitle: videoSubtitle,
      icon: input.videoBlockedByHost
          ? ParticipantMenuIcon.video
          : ParticipantMenuIcon.videoOff,
    ),
  );
  if (input.isScreenSharing) {
    items.add(
      const ParticipantMenuEntrySpec.action(
        value: 'stop_share',
        title: '结束屏幕共享',
        icon: ParticipantMenuIcon.stopScreenShare,
      ),
    );
  }

  items.add(const ParticipantMenuEntrySpec.divider());
  items.add(const ParticipantMenuEntrySpec.section('权限设置'));
  items.add(
    ParticipantMenuEntrySpec.action(
      value: input.allowSelfUnmute
          ? 'mic_permission_block'
          : 'mic_permission_allow',
      title: input.allowSelfUnmute ? '禁止开麦（权限）' : '允许开麦（权限）',
      icon: ParticipantMenuIcon.keyboardVoice,
    ),
  );
  items.add(
    ParticipantMenuEntrySpec.action(
      value: input.allowMemberVideo
          ? 'video_permission_block'
          : 'video_permission_allow',
      title: input.allowMemberVideo ? '禁止开视频（权限）' : '允许开视频（权限）',
      icon: ParticipantMenuIcon.cameraAlt,
    ),
  );
  items.add(
    ParticipantMenuEntrySpec.action(
      value:
          input.allowChat ? 'chat_permission_block' : 'chat_permission_allow',
      title: input.allowChat ? '禁止聊天（权限）' : '允许聊天（权限）',
      subtitle: isGuest ? '访客聊天权限跟随会议设置' : null,
      icon: ParticipantMenuIcon.chatBubble,
      enabled: !isGuest,
    ),
  );
  items.add(
    ParticipantMenuEntrySpec.action(
      value: input.allowScreenShare
          ? 'share_permission_block'
          : 'share_permission_allow',
      title: input.allowScreenShare ? '禁止共享（权限）' : '允许共享（权限）',
      icon: ParticipantMenuIcon.screenShare,
    ),
  );
  if (input.micRequestPending && !input.allowSelfUnmute) {
    items.add(
      const ParticipantMenuEntrySpec.action(
        value: 'mic_permission_allow',
        title: '通过开麦申请',
        icon: ParticipantMenuIcon.taskAlt,
      ),
    );
  }
  if (input.videoRequestPending && !input.allowMemberVideo) {
    items.add(
      const ParticipantMenuEntrySpec.action(
        value: 'video_permission_allow',
        title: '通过视频申请',
        icon: ParticipantMenuIcon.taskAlt,
      ),
    );
  }

  items.add(const ParticipantMenuEntrySpec.divider());
  if (input.screenShareRequestPending && !input.allowScreenShare) {
    items.add(
      const ParticipantMenuEntrySpec.action(
        value: 'share_permission_allow',
        title: '通过屏幕共享申请',
        icon: ParticipantMenuIcon.taskAlt,
      ),
    );
  }
  items.add(const ParticipantMenuEntrySpec.section('成员管理'));
  if (!isGuest) {
    if (input.roleKey == 'cohost') {
      items.add(
        const ParticipantMenuEntrySpec.action(
          value: 'set_participant',
          title: '取消联席主持人',
          icon: ParticipantMenuIcon.personRemoveAlt,
        ),
      );
    } else if (input.roleKey == 'participant') {
      items.add(
        const ParticipantMenuEntrySpec.action(
          value: 'set_cohost',
          title: '设为联席主持人',
          icon: ParticipantMenuIcon.adminPanel,
        ),
      );
    }
  }
  items.add(
    const ParticipantMenuEntrySpec.action(
      value: 'rename_member',
      title: '成员改名',
      icon: ParticipantMenuIcon.rename,
    ),
  );
  if (isGuest) {
    items.add(
      const ParticipantMenuEntrySpec.action(
        value: 'remove_guest',
        title: '移出成员',
        icon: ParticipantMenuIcon.personRemove,
        danger: true,
      ),
    );
  } else {
    items.add(
      const ParticipantMenuEntrySpec.action(
        value: 'remove',
        title: '移出成员',
        subtitle: '仅移出，允许重新加入会议',
        icon: ParticipantMenuIcon.personRemoveAlt,
        danger: true,
      ),
    );
    items.add(
      const ParticipantMenuEntrySpec.action(
        value: 'remove_ban',
        title: '移出并封禁',
        subtitle: '移出后禁止再次进入本会议',
        icon: ParticipantMenuIcon.personOff,
        danger: true,
      ),
    );
  }
  return items;
}
