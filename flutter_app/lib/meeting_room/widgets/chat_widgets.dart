part of '../page.dart';

extension _MeetingRoomChatWidgets on _MeetingRoomPageState {
  List<PopupMenuEntry<String>> _chatMessageMenuItems({
    required bool canRecall,
    required bool isRecalling,
  }) {
    final items = <PopupMenuEntry<String>>[
      _chatMessageMenuActionItemRefined(
        value: 'copy',
        title: '复制消息',
        subtitle: '复制该条聊天内容',
        icon: Icons.content_copy_outlined,
      ),
    ];
    if (canRecall || isRecalling) {
      items.add(
        _chatMessageMenuActionItemRefined(
          value: 'recall',
          title: isRecalling ? '撤回中...' : '撤回消息',
          subtitle: '从会议聊天中撤回该条消息',
          icon: Icons.undo_outlined,
          enabled: !isRecalling,
          danger: true,
        ),
      );
    }
    return items;
  }

  Widget _buildChatMessageBubble(_ChatMessage message) {
    final isMine = _isMyMessage(message);
    final senderName = _displayNameForMessage(message);
    final canRecall = _canRecallMessage(message);
    final isRecalling = _recallingMessageIds.contains(message.id);
    final bubbleColor = isMine ? const Color(0xFF95EC69) : Colors.white;
    final borderColor =
        isMine ? const Color(0xFF7BD453) : const Color(0xFFDDE6FF);
    final timeLabel = _messageTimeLabel(message.createdAt);
    final nameColor =
        isMine ? const Color(0xFF175CD3) : const Color(0xFF667085);
    final avatarBg = isMine ? const Color(0xFFCFF8B1) : const Color(0xFFE8EEFF);
    final avatarFg = isMine ? const Color(0xFF175CD3) : const Color(0xFF344054);

    Widget buildAvatar() {
      return CircleAvatar(
        radius: 14,
        backgroundColor: avatarBg,
        foregroundColor: avatarFg,
        child: Text(
          _initialForName(senderName),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      );
    }

    Widget buildMessageMenu() {
      return PopupMenuButton<String>(
        tooltip: '消息菜单',
        color: const Color(0xFFFCFDFF),
        elevation: 10,
        position: PopupMenuPosition.under,
        offset: const Offset(-10, 8),
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFFD6E4FF)),
        ),
        padding: EdgeInsets.zero,
        icon: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: const Color(0xFFEAF1FF),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.more_horiz,
            size: 17,
            color:
                isRecalling ? const Color(0xFF98A2B3) : const Color(0xFF175CD3),
          ),
        ),
        onSelected: (value) {
          if (value == 'copy') {
            unawaited(_copyChatMessage(message));
            return;
          }
          if (value == 'recall') {
            unawaited(_confirmRecallMessage(message));
          }
        },
        itemBuilder: (context) => _chatMessageMenuItems(
          canRecall: canRecall,
          isRecalling: isRecalling,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isMine) ...[
            buildAvatar(),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!isMine)
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 3),
                    child: MeetingMetaText(
                      senderName,
                      style: TextStyle(
                        color: nameColor,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (isMine) buildMessageMenu(),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: bubbleColor,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(14),
                            topRight: const Radius.circular(14),
                            bottomLeft: Radius.circular(isMine ? 14 : 4),
                            bottomRight: Radius.circular(isMine ? 4 : 14),
                          ),
                          border: Border.all(color: borderColor),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x12000000),
                              blurRadius: 8,
                              offset: Offset(0, 3),
                            ),
                          ],
                        ),
                        child: MeetingBodyText(
                          message.content,
                          style: const TextStyle(
                            color: Color(0xFF101828),
                            fontSize: 13.5,
                            height: 1.38,
                          ),
                        ),
                      ),
                    ),
                    if (!isMine) buildMessageMenu(),
                  ],
                ),
                if (timeLabel.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: MeetingMetaText(
                      timeLabel,
                      style: const TextStyle(
                        color: Color(0xFF98A2B3),
                        fontSize: 10.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (isMine) ...[
            const SizedBox(width: 8),
            buildAvatar(),
          ],
        ],
      ),
    );
  }

  Widget _buildChatPanel({List<Widget>? headerActions}) {
    final chatEnabled = _connected && _chatWriteEnabled;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDDE6FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: MeetingTitleText(
                  '会议聊天',
                  style: TextStyle(
                    color: Color(0xFF101828),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (headerActions != null && headerActions.isNotEmpty)
                Wrap(spacing: 4, runSpacing: 4, children: headerActions),
            ],
          ),
          const SizedBox(height: 4),
          const MeetingMetaText(
            '成员可撤回 3 分钟内消息，主持人与联席主持人可撤回任意消息',
            style: TextStyle(color: Color(0xFF667085), fontSize: 11.5),
          ),
          if (!_allowChat) ...[
            const SizedBox(height: 4),
            const MeetingMetaText(
              '当前会议已禁用聊天',
              style: TextStyle(color: Color(0xFF667085), fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF7FAFF),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFDDE6FF)),
              ),
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
              child: _messages.isEmpty
                  ? const Center(
                      child: MeetingMetaText(
                        '暂无聊天消息',
                        style:
                            TextStyle(color: Color(0xFF98A2B3), fontSize: 12.5),
                      ),
                    )
                  : ListView.builder(
                      controller: _chatScrollController,
                      itemCount: _messages.length,
                      itemBuilder: (_, index) =>
                          _buildChatMessageBubble(_messages[index]),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              PopupMenuButton<String>(
                tooltip: '发送表情',
                enabled: chatEnabled,
                onSelected: _appendEmoji,
                color: const Color(0xFFFCFDFF),
                surfaceTintColor: Colors.transparent,
                elevation: 8,
                shadowColor: const Color(0x1A101828),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFFD6E4FF)),
                ),
                constraints: const BoxConstraints(minWidth: 186, maxWidth: 220),
                itemBuilder: (context) => _chatEmojiMenuItems(),
                icon: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: chatEnabled
                        ? const Color(0xFFEAF1FF)
                        : const Color(0xFFF2F4F7),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: chatEnabled
                          ? const Color(0xFFD6E4FF)
                          : const Color(0xFFE4E7EC),
                    ),
                  ),
                  child: Icon(
                    Icons.emoji_emotions_outlined,
                    color: chatEnabled
                        ? const Color(0xFF175CD3)
                        : const Color(0xFF98A2B3),
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _chatController,
                  enabled: chatEnabled,
                  style: const TextStyle(color: Color(0xFF101828)),
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  decoration: const InputDecoration(
                    hintText: '输入消息，支持表情',
                    hintStyle:
                        TextStyle(color: Color(0xFF98A2B3), fontSize: 12.5),
                    filled: true,
                    fillColor: Color(0xFFF8FAFF),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) {
                    if (chatEnabled) {
                      _sendChat();
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: chatEnabled ? _sendChat : null,
                child: const Text('发送'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
