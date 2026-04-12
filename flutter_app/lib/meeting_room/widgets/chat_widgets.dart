part of '../page.dart';

extension _MeetingRoomChatWidgets on _MeetingRoomPageState {
  List<PopupMenuEntry<String>> _chatMessageMenuItems({
    required bool canRecall,
    required bool isRecalling,
  }) {
    final specs = buildChatMessageMenuSpecs(
      ChatMessageMenuBuilderInput(
        canRecall: canRecall,
        isRecalling: isRecalling,
      ),
    );
    return specs
        .map(
          (spec) => _chatMessageMenuActionItemRefined(
            value: spec.value,
            title: spec.title,
            subtitle: spec.subtitle,
            icon: _chatMessageMenuIconData(spec.icon),
            enabled: spec.enabled,
            danger: spec.danger,
          ),
        )
        .toList();
  }

  Widget _buildChatMessageBubble(ChatMessage message) {
    final isMine = _isMyMessage(message);
    final senderName = _displayNameForMessage(message);
    final canRecall = _canRecallMessage(message);
    final isRecalling = _recallingMessageIds.contains(message.id);
    final bubbleColor = isMine
        ? Color.alphaBlend(
            _palette.success.withValues(alpha: 0.20),
            _palette.surface,
          )
        : _palette.surface;
    final borderColor = isMine ? _palette.success : _palette.panelBorder;
    final timeLabel = _messageTimeLabel(message.createdAt);
    final nameColor = isMine ? _palette.primaryStrong : _palette.textMuted;
    final avatarBg = isMine
        ? Color.alphaBlend(
            _palette.success.withValues(alpha: 0.18),
            _palette.surface,
          )
        : _palette.primarySoft;
    final avatarFg = isMine ? _palette.primaryStrong : _palette.textSecondary;

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
        color: _palette.surfaceRaised,
        elevation: 10,
        position: PopupMenuPosition.under,
        offset: const Offset(-10, 8),
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: _palette.primaryBorder),
        ),
        padding: EdgeInsets.zero,
        icon: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: _palette.primarySoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.more_horiz,
            size: 17,
            color: isRecalling ? _palette.textMuted : _palette.primaryStrong,
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
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.07),
                              blurRadius: 8,
                              offset: Offset(0, 3),
                            ),
                          ],
                        ),
                        child: MeetingBodyText(
                          message.content,
                          style: TextStyle(
                            color: _palette.textPrimary,
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
                      style: TextStyle(
                        color: _palette.textMuted,
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
        color: _palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _palette.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: MeetingTitleText(
                  '会议聊天',
                  style: TextStyle(
                    color: _palette.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (headerActions != null && headerActions.isNotEmpty)
                Wrap(spacing: 4, runSpacing: 4, children: headerActions),
            ],
          ),
          const SizedBox(height: 4),
          MeetingMetaText(
            '成员可撤回 3 分钟内消息，主持人与联席主持人可撤回任意消息',
            style: TextStyle(color: _palette.textMuted, fontSize: 11.5),
          ),
          if (!_allowChat) ...[
            const SizedBox(height: 4),
            MeetingMetaText(
              '当前会议已禁用聊天',
              style: TextStyle(color: _palette.textMuted, fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: _palette.surfaceMuted,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _palette.panelBorder),
              ),
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
              child: _messages.isEmpty
                  ? Center(
                      child: MeetingMetaText(
                        '暂无聊天消息',
                        style: TextStyle(
                          color: _palette.textMuted,
                          fontSize: 12.5,
                        ),
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
                color: _palette.surfaceRaised,
                surfaceTintColor: Colors.transparent,
                elevation: 8,
                shadowColor: Colors.black.withValues(alpha: 0.10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: _palette.primaryBorder),
                ),
                constraints: const BoxConstraints(minWidth: 186, maxWidth: 220),
                itemBuilder: (context) => _chatEmojiMenuItems(),
                icon: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: chatEnabled
                        ? _palette.primarySoft
                        : _palette.surfaceMuted,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: chatEnabled
                          ? _palette.primaryBorder
                          : _palette.panelBorder,
                    ),
                  ),
                  child: Icon(
                    Icons.emoji_emotions_outlined,
                    color: chatEnabled
                        ? _palette.primaryStrong
                        : _palette.textMuted,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _chatController,
                  enabled: chatEnabled,
                  style: TextStyle(color: _palette.textPrimary),
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  decoration: InputDecoration(
                    hintText: '输入消息，支持表情',
                    hintStyle: TextStyle(
                      color: _palette.textMuted,
                      fontSize: 12.5,
                    ),
                    filled: true,
                    fillColor: _palette.surfaceMuted,
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
