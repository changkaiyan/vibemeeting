enum ChatMessageMenuEntryKind {
  action,
}

enum ChatMessageMenuIcon {
  copy,
  recall,
}

class ChatMessageMenuEntrySpec {
  const ChatMessageMenuEntrySpec({
    required this.value,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.enabled = true,
    this.danger = false,
  }) : kind = ChatMessageMenuEntryKind.action;

  final ChatMessageMenuEntryKind kind;
  final String value;
  final String title;
  final String subtitle;
  final ChatMessageMenuIcon icon;
  final bool enabled;
  final bool danger;
}

class ChatMessageMenuBuilderInput {
  const ChatMessageMenuBuilderInput({
    required this.canRecall,
    required this.isRecalling,
  });

  final bool canRecall;
  final bool isRecalling;
}

List<ChatMessageMenuEntrySpec> buildChatMessageMenuSpecs(
  ChatMessageMenuBuilderInput input,
) {
  final items = <ChatMessageMenuEntrySpec>[
    const ChatMessageMenuEntrySpec(
      value: 'copy',
      title: '复制消息',
      subtitle: '复制该条聊天内容',
      icon: ChatMessageMenuIcon.copy,
    ),
  ];
  if (input.canRecall || input.isRecalling) {
    items.add(
      ChatMessageMenuEntrySpec(
        value: 'recall',
        title: input.isRecalling ? '撤回中...' : '撤回消息',
        subtitle: '从会议聊天中撤回该条消息',
        icon: ChatMessageMenuIcon.recall,
        enabled: !input.isRecalling,
        danger: true,
      ),
    );
  }
  return items;
}
