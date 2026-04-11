part of '../page.dart';

extension _MeetingRoomLayoutPanels on _MeetingRoomPageState {
  Widget _buildParticipantExportButton() {
    return Tooltip(
      message: '导出当前在会成员（已注册成员与访客）',
      child: TextButton.icon(
        onPressed: _exportParticipantRosterCsv,
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: _palette.primary,
          backgroundColor: _palette.primarySoft,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: BorderSide(color: _palette.primaryBorder),
          ),
        ),
        icon: const Icon(Icons.download_outlined, size: 15),
        label: const Text(
          '导出名单',
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildParticipantPanel() {
    final rows = _collectParticipantRows();
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
          Text(
            '参会成员',
            style: TextStyle(
              color: _palette.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${rows.length} 人在线',
            style: TextStyle(color: _palette.textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 2),
          Text(
            '双击成员可放大对应画面',
            style: TextStyle(color: _palette.textMuted, fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          if (_canUseModeratorControls) ...[
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _exportParticipantRosterCsv,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: _palette.primary,
                  backgroundColor: _palette.primarySoft,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                    side: BorderSide(color: _palette.primaryBorder),
                  ),
                ),
                icon: const Icon(Icons.download_outlined, size: 15),
                label: const Text('导出入会名单'),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (_isModerator) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: _waitingRoomEntries.isEmpty
                    ? _palette.primarySoft
                    : _palette.warningSurface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _waitingRoomEntries.isEmpty
                      ? _palette.panelBorder
                      : _palette.warningBorder,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _waitingRoomEntries.isEmpty
                        ? Icons.meeting_room_outlined
                        : Icons.notifications_active,
                    size: 16,
                    color: _waitingRoomEntries.isEmpty
                        ? _palette.primaryStrong
                        : _palette.warning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _waitingRoomEntries.isEmpty
                          ? '等候室暂无待审核成员'
                          : '等候室有 ${_waitingRoomEntries.length} 人等待审核',
                      style: TextStyle(
                        color: _palette.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                  if (_waitingRoomEntries.isNotEmpty)
                    TextButton(
                      onPressed: _openModeratorControlDialog,
                      child: const Text('立即处理'),
                    ),
                ],
              ),
            ),
            if (_waitingRoomEntries.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: _waitingRoomEntries.length > 2 ? 104 : 52,
                child: ListView.builder(
                  itemCount: _waitingRoomEntries.length,
                  itemBuilder: (_, index) {
                    final entry = _waitingRoomEntries[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _palette.panelBorder),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              entry.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                          TextButton(
                            onPressed: () => unawaited(
                              _quickReviewWaitingEntry(entry, 'rejected'),
                            ),
                            child: const Text('拒绝'),
                          ),
                          FilledButton(
                            onPressed: () => unawaited(
                              _quickReviewWaitingEntry(entry, 'approved'),
                            ),
                            child: const Text('通过'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      _waitingForAdmission ? '等候室等待中，主持人审核后自动入会' : '尚未连接',
                      style: TextStyle(
                        color: _waitingForAdmission
                            ? _palette.warning
                            : _palette.textMuted,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) =>
                        Divider(color: _palette.panelBorder, height: 12),
                    itemBuilder: (_, i) {
                      final row = rows[i];
                      final highlighted = row.identity == _spotlightIdentity;
                      final localIdentity = _room?.localParticipant?.identity;
                      final isSelf = localIdentity != null &&
                          localIdentity == row.identity;
                      final menuItems =
                          _participantMenuItemsRefined(row, isSelf);
                      final pendingActionChips = <Widget>[];
                      if (_isModerator && !isSelf && !row.isRealtimeBot) {
                        if (row.micRequestPending && !row.allowSelfUnmute) {
                          pendingActionChips.add(
                            _buildPendingRequestChip(
                              label: '开麦申请',
                              onApprove: () => unawaited(
                                _handleParticipantMenuAction(
                                  row,
                                  'mic_permission_allow',
                                  isSelf,
                                ),
                              ),
                            ),
                          );
                        }
                        if (row.videoRequestPending && !row.allowMemberVideo) {
                          pendingActionChips.add(
                            _buildPendingRequestChip(
                              label: '视频申请',
                              onApprove: () => unawaited(
                                _handleParticipantMenuAction(
                                  row,
                                  'video_permission_allow',
                                  isSelf,
                                ),
                              ),
                            ),
                          );
                        }
                        if (row.screenShareRequestPending &&
                            !row.allowScreenShare) {
                          pendingActionChips.add(
                            _buildPendingRequestChip(
                              label: '共享申请',
                              onApprove: () => unawaited(
                                _handleParticipantMenuAction(
                                  row,
                                  'share_permission_allow',
                                  isSelf,
                                ),
                              ),
                            ),
                          );
                        }
                      }
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTap: row.isRealtimeBot
                            ? null
                            : () => _focusParticipantTile(
                                  row.identity,
                                  allowToggle: false,
                                ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            color: highlighted
                                ? _palette.primarySoft
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              _buildParticipantAvatar(
                                displayName: row.displayName,
                                avatarUrl: row.avatarUrl,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      row.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: _palette.textPrimary,
                                        fontSize: 13,
                                      ),
                                    ),
                                    if (pendingActionChips.isNotEmpty) ...[
                                      const SizedBox(height: 3),
                                      Wrap(
                                        spacing: 4,
                                        runSpacing: 3,
                                        children: pendingActionChips,
                                      ),
                                    ],
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Icon(
                                          row.micEnabled
                                              ? Icons.graphic_eq_rounded
                                              : Icons.mic_off,
                                          size: 12,
                                          color: row.micEnabled
                                              ? (row.isSpeaking
                                                  ? _palette.success
                                                  : _palette.textMuted)
                                              : _palette.dangerSoft,
                                        ),
                                        const SizedBox(width: 6),
                                        ParticipantAudioLevelBar(
                                          level: row.audioLevel,
                                          isActive: row.micEnabled &&
                                              (row.isSpeaking ||
                                                  row.audioLevel > 0.02),
                                          width: 56,
                                          height: 5,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                row.role,
                                style: TextStyle(
                                  color: _palette.heroMutedText,
                                  fontSize: 11.5,
                                ),
                              ),
                              if (menuItems.isNotEmpty)
                                PopupMenuButton<String>(
                                  tooltip: '成员菜单',
                                  color: _palette.surfaceRaised,
                                  elevation: 10,
                                  position: PopupMenuPosition.under,
                                  offset: const Offset(-10, 8),
                                  constraints: const BoxConstraints(
                                    minWidth: 240,
                                    maxWidth: 288,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    side: BorderSide(
                                      color: _palette.primaryBorder,
                                    ),
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
                                      color: _palette.primaryStrong,
                                    ),
                                  ),
                                  onSelected: (value) {
                                    unawaited(
                                      _handleParticipantMenuAction(
                                        row,
                                        value,
                                        isSelf,
                                      ),
                                    );
                                  },
                                  itemBuilder: (context) => menuItems,
                                ),
                              const SizedBox(width: 8),
                              Icon(
                                row.micEnabled ? Icons.mic : Icons.mic_off,
                                size: 13,
                                color: row.micEnabled
                                    ? _palette.success
                                    : _palette.dangerSoft,
                              ),
                              const SizedBox(width: 6),
                              Icon(
                                row.cameraEnabled
                                    ? Icons.videocam
                                    : Icons.videocam_off,
                                size: 13,
                                color: row.cameraEnabled
                                    ? _palette.success
                                    : _palette.dangerSoft,
                              ),
                              if (row.isScreenSharing) ...[
                                const SizedBox(width: 6),
                                Icon(
                                  Icons.screen_share,
                                  size: 13,
                                  color: _palette.warning,
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildDesktopCommunicationHeaderActions({
    required bool forChat,
  }) {
    final isChatExpanded = _desktopChatPanelExpanded;
    final isWorkspaceExpanded = _desktopWorkspacePanelExpanded;
    final targetExpanded = forChat ? isChatExpanded : isWorkspaceExpanded;
    final targetLabel = forChat ? '聊天' : '工作区';
    final otherExpanded = forChat ? isWorkspaceExpanded : isChatExpanded;
    final switchLabel = forChat ? '看工作区' : '看聊天';
    return [
      MeetingPanelHeaderActionBar(
        panelLabel: targetLabel,
        isFullscreen: false,
        onToggleFullscreen: () =>
            _openCommunicationPanelFullscreen(forChat: forChat),
      ),
      Tooltip(
        message: targetExpanded ? '还原$targetLabel' : '放大$targetLabel',
        child: IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: () {
            setState(() {
              if (forChat) {
                _desktopChatPanelExpanded = !_desktopChatPanelExpanded;
                if (_desktopChatPanelExpanded) {
                  _desktopWorkspacePanelExpanded = false;
                }
              } else {
                _desktopWorkspacePanelExpanded =
                    !_desktopWorkspacePanelExpanded;
                if (_desktopWorkspacePanelExpanded) {
                  _desktopChatPanelExpanded = false;
                }
              }
            });
          },
          icon: Icon(
            targetExpanded ? Icons.fullscreen_exit : Icons.open_in_full,
            size: 18,
            color: _palette.primaryStrong,
          ),
        ),
      ),
      if (otherExpanded)
        TextButton(
          onPressed: () {
            setState(() {
              if (forChat) {
                _desktopWorkspacePanelExpanded = false;
              } else {
                _desktopChatPanelExpanded = false;
              }
            });
          },
          child: Text(switchLabel),
        ),
    ];
  }

  Widget _buildCommunicationPanel() {
    if (_desktopChatPanelExpanded) {
      return _buildChatPanel(
        headerActions: _buildDesktopCommunicationHeaderActions(forChat: true),
      );
    }
    if (_desktopWorkspacePanelExpanded) {
      return _buildWorkspacePanel(
        headerActions: _buildDesktopCommunicationHeaderActions(forChat: false),
      );
    }
    return Column(
      children: [
        Expanded(
          flex: 4,
          child: _buildChatPanel(
            headerActions: _buildDesktopCommunicationHeaderActions(
              forChat: true,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          flex: 5,
          child: _buildWorkspacePanel(
            headerActions: _buildDesktopCommunicationHeaderActions(
              forChat: false,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDock() {
    final canSelfUnmute = _localCanSelfUnmute;
    final canOpenVideo = _localCanMemberVideo;
    final canShareScreen = _localCanScreenShare;
    final canRecord = _canRecordMeeting && !_recordingUploading;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _palette.panelBorder),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        alignment: WrapAlignment.center,
        children: [
          FilledButton.icon(
            onPressed: (_connected && (_micEnabled || canSelfUnmute))
                ? _toggleMic
                : null,
            icon: Icon(_micEnabled ? Icons.mic : Icons.mic_off),
            label: Text(_micEnabled ? '静音' : '取消静音'),
          ),
          FilledButton.icon(
            onPressed: (_connected && (_cameraEnabled || canOpenVideo))
                ? _toggleCamera
                : null,
            icon: Icon(_cameraEnabled ? Icons.videocam : Icons.videocam_off),
            label: Text(_cameraEnabled ? '关闭摄像头' : '开启摄像头'),
          ),
          FilledButton.icon(
            onPressed:
                (_connected && canShareScreen) ? _toggleScreenShare : null,
            icon: Icon(
              _screenShareEnabled
                  ? Icons.stop_screen_share
                  : Icons.screen_share,
              color: (_screenShareEnabled && _screenShareAudioEnabled)
                  ? _palette.success
                  : null,
            ),
            label: Text(
              canShareScreen
                  ? (_screenShareEnabled ? '停止共享' : '共享屏幕')
                  : '共享已禁用',
            ),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor:
                  _recordingActive ? _palette.danger : _palette.primary,
            ),
            onPressed: canRecord
                ? (_recordingActive
                    ? _stopMeetingRecording
                    : _startMeetingRecording)
                : null,
            icon: Icon(
              _recordingUploading
                  ? Icons.cloud_upload_outlined
                  : (_recordingActive
                      ? Icons.stop_circle_outlined
                      : Icons.fiber_manual_record),
              color: _recordingActive ? Colors.white : null,
            ),
            label: Text(
              _recordingUploading
                  ? '上传录制中...'
                  : (_recordingActive
                      ? '停止录制'
                      : (_allowRecording ? '开始录制' : '录制已禁用')),
            ),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _palette.danger,
            ),
            onPressed: _connected ? _handleLeaveButtonPressed : null,
            icon: const Icon(Icons.call_end),
            label: Text(_isHost && _requiresAuth ? '结束会议' : '离开会议'),
          ),
        ],
      ),
    );
  }
}
