part of '../page.dart';

extension _MeetingRemoteControlLogic on _MeetingRoomPageState {
  String? get _remoteControlLocalIdentity =>
      _room?.localParticipant?.identity.trim().isEmpty == true
          ? null
          : _room?.localParticipant?.identity.trim();

  bool get _canPublishRemoteControlData {
    final local = _room?.localParticipant;
    if (local == null) return false;
    final permissions = local.permissions;
    return permissions.canPublishData || permissions.canPublish;
  }

  bool _isRemoteControlActiveForIdentity(String identity) {
    return _remoteControlSessionId != null &&
        _remoteControlTargetIdentity != null &&
        _remoteControlTargetIdentity == identity;
  }

  bool _isRemoteControlPendingForIdentity(String identity) {
    return _remoteControlPendingTargetIdentity != null &&
        _remoteControlPendingTargetIdentity == identity;
  }

  Future<void> _sendRemoteControlMessage({
    required RemoteControlMessageKind kind,
    required Map<String, dynamic> payload,
    required List<String> destinationIdentities,
  }) async {
    final local = _room?.localParticipant;
    if (!_connected || local == null) return;
    await local.publishData(
      utf8.encode(jsonEncode(payload)),
      reliable: shouldSendRemoteControlReliably(kind),
      destinationIdentities: destinationIdentities,
      topic: remoteControlDataTopic,
    );
  }

  Future<void> _requestRemoteControl(ParticipantRowData row) async {
    final localIdentity = _remoteControlLocalIdentity;
    final targetIdentity = row.identity.trim();
    if (localIdentity == null || targetIdentity.isEmpty) return;
    if (targetIdentity == localIdentity) {
      _setStatus('\u4e0d\u80fd\u63a7\u5236\u81ea\u5df1\u7684\u8bbe\u5907');
      return;
    }
    if (_isRemoteControlActiveForIdentity(targetIdentity)) {
      _setStatus('\u5df2\u5728\u63a7\u5236\u8be5\u6210\u5458');
      return;
    }
    if (_isRemoteControlPendingForIdentity(targetIdentity)) {
      _setStatus(
          '\u8bf7\u6c42\u5df2\u53d1\u9001\uff0c\u7b49\u5f85\u5bf9\u65b9\u786e\u8ba4');
      return;
    }
    if (!_canPublishRemoteControlData) {
      _setStatus(
          '\u5f53\u524d\u4f1a\u8bae\u6743\u9650\u4e0d\u5141\u8bb8\u53d1\u9001\u63a7\u5236\u6d88\u606f');
      return;
    }
    if (_remoteControlSessionId != null) {
      await _stopRemoteControl(
        notifyPeer: true,
        reason: 'controller_switch',
        silent: true,
      );
    }
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 20)}';
    setState(() {
      _remoteControlPendingTargetIdentity = targetIdentity;
      _remoteControlPendingRequestId = requestId;
    });
    try {
      await _sendRemoteControlMessage(
        kind: RemoteControlMessageKind.request,
        payload: buildRemoteControlRequestMessage(
          requestId: requestId,
          controllerIdentity: localIdentity,
          targetIdentity: targetIdentity,
        ),
        destinationIdentities: <String>[targetIdentity],
      );
      _setStatus(
        '\u5df2\u5411 ${row.displayName} \u53d1\u9001\u8fdc\u7a0b\u63a7\u5236\u8bf7\u6c42',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _remoteControlPendingTargetIdentity = null;
        _remoteControlPendingRequestId = null;
      });
      _setStatus(
        '\u8fdc\u7a0b\u63a7\u5236\u8bf7\u6c42\u53d1\u9001\u5931\u8d25\uff1a${_friendlyError(error)}',
      );
    }
  }

  Future<void> _stopRemoteControl({
    bool notifyPeer = true,
    String reason = '',
    bool silent = false,
  }) async {
    final localIdentity = _remoteControlLocalIdentity;
    final requestId = _remoteControlSessionId;
    final targetIdentity = _remoteControlTargetIdentity;
    if (localIdentity != null &&
        requestId != null &&
        targetIdentity != null &&
        notifyPeer) {
      try {
        await _sendRemoteControlMessage(
          kind: RemoteControlMessageKind.stop,
          payload: buildRemoteControlStopMessage(
            requestId: requestId,
            controllerIdentity: localIdentity,
            targetIdentity: targetIdentity,
            reason: reason,
          ),
          destinationIdentities: <String>[targetIdentity],
        );
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _remoteControlSessionId = null;
      _remoteControlTargetIdentity = null;
      _remoteControlPendingTargetIdentity = null;
      _remoteControlPendingRequestId = null;
      _remoteControlLastPointerMoveAt = null;
      _remoteControlLastPointerButton = 'left';
    });
    if (!silent) {
      _setStatus('\u8fdc\u7a0b\u63a7\u5236\u5df2\u7ed3\u675f');
    }
  }

  Future<void> _handleRemoteControlDataReceived(
      lk.DataReceivedEvent event) async {
    if (event.topic != remoteControlDataTopic) return;
    final senderIdentity = event.participant?.identity.trim() ?? '';
    if (senderIdentity.isEmpty) return;
    final parsed = parseRemoteControlMessage(utf8.decode(event.data));
    if (parsed == null) return;
    final localIdentity = _remoteControlLocalIdentity;
    if (localIdentity == null) return;

    switch (parsed.kind) {
      case RemoteControlMessageKind.request:
        if (parsed.targetIdentity != localIdentity ||
            parsed.controllerIdentity != senderIdentity) {
          return;
        }
        await _sendRemoteControlMessage(
          kind: RemoteControlMessageKind.response,
          payload: buildRemoteControlResponseMessage(
            requestId: parsed.requestId,
            controllerIdentity: parsed.controllerIdentity,
            targetIdentity: parsed.targetIdentity,
            approved: false,
            reason: 'web_target_unsupported',
          ),
          destinationIdentities: <String>[parsed.controllerIdentity],
        );
        _setStatus(
          '\u5f53\u524d\u6d4f\u89c8\u5668\u7aef\u4e0d\u652f\u6301\u88ab\u63a7\uff0c\u8bf7\u76ee\u6807\u6210\u5458\u4f7f\u7528 Native \u5ba2\u6237\u7aef',
        );
        return;
      case RemoteControlMessageKind.response:
        if (parsed.controllerIdentity != localIdentity ||
            parsed.targetIdentity != senderIdentity) {
          return;
        }
        if (_remoteControlPendingRequestId != parsed.requestId ||
            _remoteControlPendingTargetIdentity != parsed.targetIdentity) {
          return;
        }
        if (!mounted) return;
        setState(() {
          _remoteControlPendingRequestId = null;
          _remoteControlPendingTargetIdentity = null;
        });
        if (parsed.approved == true) {
          if (!mounted) return;
          setState(() {
            _remoteControlSessionId = parsed.requestId;
            _remoteControlTargetIdentity = parsed.targetIdentity;
            _remoteControlLastPointerMoveAt = null;
            _remoteControlLastPointerButton = 'left';
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _remoteControlFocusNode.requestFocus();
          });
          _setStatus(
            '\u8fdc\u7a0b\u63a7\u5236\u5df2\u8fde\u63a5\uff1a${_displayNameForIdentity(parsed.targetIdentity)}',
          );
        } else {
          final reason = parsed.reason?.trim() ?? '';
          _setStatus(
            reason.isEmpty
                ? '\u5bf9\u65b9\u5df2\u62d2\u7edd\u8fdc\u7a0b\u63a7\u5236'
                : '\u5bf9\u65b9\u5df2\u62d2\u7edd\u8fdc\u7a0b\u63a7\u5236\uff1a$reason',
          );
        }
        return;
      case RemoteControlMessageKind.stop:
        final requestId = _remoteControlSessionId;
        if (requestId == null || requestId != parsed.requestId) {
          return;
        }
        if (parsed.controllerIdentity != localIdentity ||
            parsed.targetIdentity != senderIdentity) {
          return;
        }
        await _stopRemoteControl(notifyPeer: false, silent: true);
        _setStatus('\u5bf9\u65b9\u5df2\u7ed3\u675f\u8fdc\u7a0b\u63a7\u5236');
        return;
      case RemoteControlMessageKind.pointer:
      case RemoteControlMessageKind.wheel:
      case RemoteControlMessageKind.key:
        return;
    }
  }

  Future<void> _sendRemotePointerEvent({
    required String event,
    required Offset localPosition,
    required Size size,
    String button = '',
  }) async {
    final requestId = _remoteControlSessionId;
    final targetIdentity = _remoteControlTargetIdentity;
    final controllerIdentity = _remoteControlLocalIdentity;
    if (requestId == null ||
        targetIdentity == null ||
        controllerIdentity == null) {
      return;
    }
    if (size.width <= 1 || size.height <= 1) return;
    if (event == 'move') {
      final now = DateTime.now();
      final last = _remoteControlLastPointerMoveAt;
      if (last != null && now.difference(last).inMilliseconds < 12) {
        return;
      }
      _remoteControlLastPointerMoveAt = now;
    }
    final normalizedX = (localPosition.dx / size.width).clamp(0.0, 1.0);
    final normalizedY = (localPosition.dy / size.height).clamp(0.0, 1.0);
    final finalButton =
        button.trim().isEmpty ? _remoteControlLastPointerButton : button.trim();
    if (button.trim().isNotEmpty) {
      _remoteControlLastPointerButton = button.trim();
    }
    await _sendRemoteControlMessage(
      kind: RemoteControlMessageKind.pointer,
      payload: buildRemoteControlPointerMessage(
        requestId: requestId,
        controllerIdentity: controllerIdentity,
        targetIdentity: targetIdentity,
        event: event,
        x: normalizedX,
        y: normalizedY,
        button: finalButton,
      ),
      destinationIdentities: <String>[targetIdentity],
    );
  }

  Future<void> _sendRemoteWheelEvent(PointerScrollEvent event) async {
    final requestId = _remoteControlSessionId;
    final targetIdentity = _remoteControlTargetIdentity;
    final controllerIdentity = _remoteControlLocalIdentity;
    if (requestId == null ||
        targetIdentity == null ||
        controllerIdentity == null) {
      return;
    }
    final dx = event.scrollDelta.dx.round();
    final dy = event.scrollDelta.dy.round();
    if (dx == 0 && dy == 0) return;
    await _sendRemoteControlMessage(
      kind: RemoteControlMessageKind.wheel,
      payload: buildRemoteControlWheelMessage(
        requestId: requestId,
        controllerIdentity: controllerIdentity,
        targetIdentity: targetIdentity,
        deltaX: dx,
        deltaY: dy,
      ),
      destinationIdentities: <String>[targetIdentity],
    );
  }

  Future<void> _sendRemoteKeyEvent(KeyEvent event) async {
    final requestId = _remoteControlSessionId;
    final targetIdentity = _remoteControlTargetIdentity;
    final controllerIdentity = _remoteControlLocalIdentity;
    if (requestId == null ||
        targetIdentity == null ||
        controllerIdentity == null) {
      return;
    }
    final phase = event is KeyUpEvent ? 'up' : 'down';
    final hidUsage = event.physicalKey.usbHidUsage;
    if (hidUsage == 0) return;
    await _sendRemoteControlMessage(
      kind: RemoteControlMessageKind.key,
      payload: buildRemoteControlKeyMessage(
        requestId: requestId,
        controllerIdentity: controllerIdentity,
        targetIdentity: targetIdentity,
        phase: phase,
        hidUsage: hidUsage,
        keyLabel: event.logicalKey.keyLabel,
      ),
      destinationIdentities: <String>[targetIdentity],
    );
  }

  String _pointerButtonFromButtons(int buttons) {
    if ((buttons & 1) == 1) return 'left';
    if ((buttons & 2) == 2) return 'right';
    if ((buttons & 4) == 4) return 'middle';
    return _remoteControlLastPointerButton;
  }

  Widget _buildRemoteControlOverlay(ParticipantTileData tile) {
    if (!_isRemoteControlActiveForIdentity(tile.identity)) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return KeyboardListener(
            focusNode: _remoteControlFocusNode,
            onKeyEvent: (event) => unawaited(_sendRemoteKeyEvent(event)),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                _remoteControlFocusNode.requestFocus();
                unawaited(
                  _sendRemotePointerEvent(
                    event: 'down',
                    localPosition: event.localPosition,
                    size: size,
                    button: _pointerButtonFromButtons(event.buttons),
                  ),
                );
              },
              onPointerMove: (event) {
                unawaited(
                  _sendRemotePointerEvent(
                    event: 'move',
                    localPosition: event.localPosition,
                    size: size,
                  ),
                );
              },
              onPointerUp: (event) {
                unawaited(
                  _sendRemotePointerEvent(
                    event: 'up',
                    localPosition: event.localPosition,
                    size: size,
                    button: _pointerButtonFromButtons(event.buttons),
                  ),
                );
              },
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  unawaited(_sendRemoteWheelEvent(event));
                }
              },
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: const Color(0xFF2E90FA),
                    width: 2,
                  ),
                ),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              '\u8fdc\u7a0b\u63a7\u5236\u4e2d\uff1a\u70b9\u51fb\u753b\u9762\u540e\u53ef\u7528\u952e\u9f20\u8fdb\u884c\u64cd\u4f5c',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: () => unawaited(
                            _stopRemoteControl(reason: 'controller_stop'),
                          ),
                          child: const Text('\u7ed3\u675f\u63a7\u5236'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
