// test/services/3_datasources/shared/dtos/user_settings_dto_missing_fields_test.dart
//
// REGRESSION, build 838 (2026-09-25). A guest document created as a stub had
// no `userId`, and `fromJson` cast it unconditionally — so the throw came out
// as "Failed to update favorites" and the app was unusable for guests.
//
// A missing field must degrade to a blank value, never to an exception: the
// document id is always known by the caller.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/3_datasources/shared/dtos/user_settings_dto.dart';

void main() {
  test('a stub document parses instead of throwing', () {
    final dto = UserSettingsDto.fromJson(
      {'lastActiveAt': '2026-09-25T00:00:00.000Z'},
      fallbackUserId: 'guest-uid',
    );

    expect(dto.userId, 'guest-uid');
    expect(dto.email, '');
    expect(dto.favoriteReachIds, isEmpty);
    expect(dto.toEntity().userId, 'guest-uid');
  });

  test('a document with no dates still converts to an entity', () {
    // toEntity() parses the date strings, so a tolerant fromJson that left
    // them empty would simply move the crash one line down.
    final entity = UserSettingsDto.fromJson({}, fallbackUserId: 'u').toEntity();
    expect(entity.userId, 'u');
    expect(entity.createdAt.year, 1970);
  });

  test('an explicit userId still wins over the document id', () {
    final dto = UserSettingsDto.fromJson(
      {'userId': 'real-uid'},
      fallbackUserId: 'doc-id',
    );
    expect(dto.userId, 'real-uid');
  });
}
