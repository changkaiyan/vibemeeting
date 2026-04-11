import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/chat_menu/chat_message_menu_builder.dart';

void main() {
  test('always includes copy action', () {
    final specs = buildChatMessageMenuSpecs(
      const ChatMessageMenuBuilderInput(
        canRecall: false,
        isRecalling: false,
      ),
    );

    expect(specs, hasLength(1));
    expect(specs.single.value, 'copy');
    expect(specs.single.title, '复制消息');
    expect(specs.single.enabled, isTrue);
  });

  test('includes enabled recall action when recall is allowed', () {
    final specs = buildChatMessageMenuSpecs(
      const ChatMessageMenuBuilderInput(
        canRecall: true,
        isRecalling: false,
      ),
    );

    final recall = specs.where((spec) => spec.value == 'recall').single;
    expect(recall.title, '撤回消息');
    expect(recall.enabled, isTrue);
    expect(recall.danger, isTrue);
  });

  test('keeps recall action visible but disabled while recalling', () {
    final specs = buildChatMessageMenuSpecs(
      const ChatMessageMenuBuilderInput(
        canRecall: false,
        isRecalling: true,
      ),
    );

    final recall = specs.where((spec) => spec.value == 'recall').single;
    expect(recall.title, '撤回中...');
    expect(recall.enabled, isFalse);
  });
}
