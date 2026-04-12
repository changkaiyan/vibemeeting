part of '../page.dart';

extension _MeetingRoomWorkspaceWidgets on _MeetingRoomPageState {
  Widget _buildWorkspacePanel({List<Widget>? headerActions}) {
    final workspaceAvailable = _hasPrivateMeetingApiScope;
    final sttLabel = _workspaceSttActive
        ? (_workspaceSttStopping ? '实时字幕停止中...' : '实时字幕采集中')
        : '实时字幕空闲';
    final codex = _workspaceAgentSessionFor('codex');
    final claude = _workspaceAgentSessionFor('claude');
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
            children: [
              Expanded(
                child: MeetingTitleText(
                  '会议工作区',
                  style: TextStyle(
                    color: _palette.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (headerActions != null && headerActions.isNotEmpty) ...[
                Wrap(spacing: 4, runSpacing: 4, children: headerActions),
                const SizedBox(width: 4),
              ],
              IconButton(
                tooltip: '刷新工作区',
                onPressed: (_connected && workspaceAvailable)
                    ? () => unawaited(_loadWorkspace())
                    : null,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 4),
          MeetingMetaText(
            workspaceAvailable
                ? '在真实会议页里查看实时字幕、Agent、上下文和输出'
                : '访客分享页暂不支持会议工作区能力，请使用已登录成员入口',
            style: TextStyle(color: _palette.textMuted, fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          if (!workspaceAvailable)
            Expanded(
              child: Center(
                child: MeetingMetaText(
                  '当前页面没有私有会议 API 访问范围，无法启用工作区。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _palette.textMuted, fontSize: 12.5),
                ),
              ),
            )
          else if (!_connected)
            Expanded(
              child: Center(
                child: MeetingMetaText(
                  '先加入会议，然后再启用实时字幕和 Agent 工作区。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _palette.textMuted, fontSize: 12.5),
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                children: [
                  _buildWorkspaceSectionCard(
                    title: '实时字幕',
                    subtitle: sttLabel,
                    trailing: Wrap(
                      spacing: 6,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _workspaceSttActive
                              ? null
                              : _handleStartWorkspaceRealtimeSttTap,
                          icon: const Icon(Icons.subtitles_outlined, size: 16),
                          label: const Text('开始'),
                        ),
                        FilledButton.icon(
                          onPressed: _workspaceSttActive
                              ? _handleStopWorkspaceRealtimeSttTap
                              : null,
                          icon:
                              const Icon(Icons.stop_circle_outlined, size: 16),
                          label: const Text('停止'),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: _palette.warningSurface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: _palette.warningBorder),
                          ),
                          child: MeetingMetaText(
                            '当前实时字幕以停止后生成 final transcript 为主。点击“开始”后开始采集麦克风音频，点击“停止”后会把本轮识别结果刷新到 Live Transcript 和 Current Context。',
                            style: TextStyle(
                              color: _palette.warning,
                              fontSize: 12,
                              height: 1.45,
                            ),
                          ),
                        ),
                        if (_showWorkspaceSttDebugPanel)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: _palette.surfaceMuted,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: _palette.panelBorder),
                            ),
                            child: MeetingDebugText(
                              'Recorder debug: state=$_workspaceSttDebugState · action=$_workspaceSttDebugLastAction · start taps=$_workspaceSttDebugStartTapCount · stop taps=$_workspaceSttDebugStopTapCount · ws=$_workspaceSttDebugWsState · audio tracks=$_workspaceSttDebugAudioTrackCount · mime=${_workspaceSttDebugMimeType.isEmpty ? '-' : _workspaceSttDebugMimeType} · blob events=$_workspaceSttDebugBlobEventCount · last blob=$_workspaceSttDebugLastBlobSize bytes',
                              style: TextStyle(
                                color: _palette.textSecondary,
                                fontSize: 12,
                                height: 1.45,
                              ),
                            ),
                          ),
                        if (_showWorkspaceSttDebugPanel)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: _palette.dangerSurface,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: _palette.dangerSoft),
                            ),
                            child: MeetingErrorText(
                              'Last error: ${workspaceSttErrorLabel(_workspaceSttDebugLastError)}',
                              style: TextStyle(
                                color: _palette.danger,
                                fontSize: 12,
                                height: 1.45,
                              ),
                            ),
                          ),
                        if (_workspacePartialText.trim().isNotEmpty)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: _palette.surfaceMuted,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: _palette.panelBorder),
                            ),
                            child: MeetingStatusText(
                              '实时识别中: ${_workspacePartialText.trim()}',
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                        TextField(
                          controller: _workspaceTranscriptController,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            hintText: '手动补充会议记录或会议笔记',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.icon(
                            onPressed: _addWorkspaceManualTranscript,
                            icon: const Icon(Icons.note_add_outlined, size: 16),
                            label: const Text('添加记录'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildWorkspaceSectionCard(
                    title: 'My Agents',
                    subtitle:
                        'Bring your local Codex / Claude into the meeting.',
                    child: Column(
                      children: [
                        _buildWorkspaceAgentCard(
                          displayName: 'Alice / Codex',
                          session: codex,
                          onConnect: () => _connectWorkspaceAgent('codex'),
                          onSummarize: () =>
                              _runWorkspaceAgentAction('codex', 'summarize'),
                          onTodos: () => _runWorkspaceAgentAction(
                            'codex',
                            'extract_todos',
                          ),
                          onDraftApi: () =>
                              _runWorkspaceAgentAction('codex', 'draft_api'),
                        ),
                        const SizedBox(height: 8),
                        _buildWorkspaceAgentCard(
                          displayName: 'Bob / Claude',
                          session: claude,
                          onConnect: () => _connectWorkspaceAgent('claude'),
                          onSummarize: () =>
                              _runWorkspaceAgentAction('claude', 'summarize'),
                          onTodos: () => _runWorkspaceAgentAction(
                            'claude',
                            'extract_todos',
                          ),
                          onDraftApi: () =>
                              _runWorkspaceAgentAction('claude', 'draft_api'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildWorkspaceSectionCard(
                    title: 'Current Context',
                    subtitle: _workspaceContext == null
                        ? 'No context yet.'
                        : (_workspaceContext!.topicLabel.isEmpty
                            ? 'Current discussion'
                            : _workspaceContext!.topicLabel),
                    child: _buildWorkspaceContextBody(),
                  ),
                  const SizedBox(height: 10),
                  _buildWorkspaceSectionCard(
                    title: 'Live Transcript',
                    subtitle: _workspaceTranscripts.isEmpty
                        ? 'No transcript yet.'
                        : '共 ${_workspaceTranscripts.length} 条',
                    child: _buildWorkspaceTranscriptBody(),
                  ),
                  const SizedBox(height: 10),
                  _buildWorkspaceSectionCard(
                    title: 'Outputs',
                    subtitle: _workspaceArtifacts.isEmpty
                        ? 'No outputs yet.'
                        : '最近 ${_workspaceArtifacts.length} 条输出',
                    child: _buildWorkspaceArtifactBody(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWorkspaceSectionCard({
    required String title,
    required String subtitle,
    Widget? trailing,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _palette.surfaceMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _palette.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MeetingTitleText(
                      title,
                      style: TextStyle(
                        color: _palette.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    MeetingMetaText(
                      subtitle,
                      style: TextStyle(
                        color: _palette.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _buildWorkspaceAgentCard({
    required String displayName,
    required WorkspaceAgentSession? session,
    required VoidCallback onConnect,
    required VoidCallback onSummarize,
    required VoidCallback onTodos,
    required VoidCallback onDraftApi,
  }) {
    final status = session?.presenceStatus ?? 'offline';
    final task = session?.currentTaskTitle.trim() ?? '';
    final reply = session?.latestShortReply.trim() ?? '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _palette.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _palette.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: MeetingTitleText(
                  displayName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _palette.primarySoft,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: MeetingMetaText(
                  status,
                  style: TextStyle(
                    color: _palette.primaryStrong,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (task.isNotEmpty) ...[
            const SizedBox(height: 6),
            MeetingMetaText(
              '任务: $task',
              style: TextStyle(color: _palette.textMuted, fontSize: 12),
            ),
          ],
          if (reply.isNotEmpty) ...[
            const SizedBox(height: 4),
            MeetingBodyText(
              reply,
              style: TextStyle(
                color: _palette.textSecondary,
                fontSize: 12.5,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              OutlinedButton(onPressed: onConnect, child: const Text('连接')),
              OutlinedButton(onPressed: onSummarize, child: const Text('总结')),
              OutlinedButton(onPressed: onTodos, child: const Text('待办')),
              OutlinedButton(
                onPressed: onDraftApi,
                child: const Text('Draft API'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWorkspaceContextBody() {
    final context = _workspaceContext;
    if (context == null) {
      return MeetingMetaText(
        'No context yet.',
        style: TextStyle(color: _palette.textMuted, fontSize: 12.5),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MeetingMetaText(
          '当前上下文会自动汇总最近的 transcript；点击下面按钮可直接把这份上下文发给 agent。',
          style: TextStyle(color: _palette.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        MeetingBodyText(
          context.summaryText.trim().isEmpty
              ? 'No rolling summary yet.'
              : context.summaryText.trim(),
          style: const TextStyle(fontSize: 12.5, height: 1.45),
        ),
        if (context.decisions.isNotEmpty) ...[
          const SizedBox(height: 8),
          const MeetingTitleText(
            'Decisions',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          ...context.decisions.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: MeetingBodyText(
                '• $item',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ),
        ],
        if (context.todos.isNotEmpty) ...[
          const SizedBox(height: 8),
          const MeetingTitleText(
            'Todos',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          ...context.todos.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: MeetingBodyText(
                '• $item',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            OutlinedButton(
              onPressed: () => _runWorkspaceAgentAction('codex', 'ask'),
              child: const Text('发送当前上下文给 Alice'),
            ),
            OutlinedButton(
              onPressed: () => _runWorkspaceAgentAction('claude', 'ask'),
              child: const Text('发送当前上下文给 Bob'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildWorkspaceTranscriptBody() {
    if (_workspaceTranscripts.isEmpty) {
      return MeetingMetaText(
        'No transcript yet.',
        style: TextStyle(color: _palette.textMuted, fontSize: 12.5),
      );
    }
    return Column(
      children: _workspaceTranscripts.map((item) {
        final speaker = item.speakerName.trim().isNotEmpty
            ? item.speakerName.trim()
            : (item.speakerIdentity.trim().isNotEmpty
                ? item.speakerIdentity.trim()
                : 'Speaker');
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _palette.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _palette.panelBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: MeetingTitleText(
                      speaker,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  MeetingMetaText(
                    '${item.source}${item.isFinal ? '' : ' · partial'}',
                    style: TextStyle(
                      color: _palette.textMuted,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              MeetingBodyText(
                item.text,
                style: const TextStyle(fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 8),
              MeetingMetaText(
                '可将这条 transcript 单独发给 agent；如果要发整段上下文，请用上面的 Current Context 区域。',
                style: TextStyle(color: _palette.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  OutlinedButton(
                    onPressed: () => _runWorkspaceAgentAction(
                      'codex',
                      'ask',
                      chunkIds: <int>[item.id],
                    ),
                    child: const Text('发送这条给 Alice'),
                  ),
                  OutlinedButton(
                    onPressed: () => _runWorkspaceAgentAction(
                      'claude',
                      'ask',
                      chunkIds: <int>[item.id],
                    ),
                    child: const Text('发送这条给 Bob'),
                  ),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildWorkspaceArtifactBody() {
    if (_workspaceArtifacts.isEmpty) {
      return MeetingMetaText(
        'No outputs yet.',
        style: TextStyle(color: _palette.textMuted, fontSize: 12.5),
      );
    }
    return Column(
      children: _workspaceArtifacts.map((artifact) {
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _palette.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _palette.panelBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: MeetingTitleText(
                      artifact.title.isEmpty
                          ? 'Untitled output'
                          : artifact.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  MeetingMetaText(
                    artifact.artifactType,
                    style: TextStyle(
                      color: _palette.textMuted,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              MeetingBodyText(
                artifact.content,
                style: const TextStyle(fontSize: 12.5, height: 1.45),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
