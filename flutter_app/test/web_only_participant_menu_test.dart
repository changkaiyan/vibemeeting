import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/participant_menu/participant_menu_builder.dart';

void main() {
  test('web participant menus no longer advertise native remote input controls',
      () {
    expect(
      ParticipantMenuIcon.values.map((icon) => icon.name),
      isNot(anyElement(startsWith('remoteControl'))),
    );
  });
}
