import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/features/auth/utils/email_validator.dart';

void main() {
  group('validateEmail', () {
    group('returns null for valid emails', () {
      final validEmails = [
        'user@example.com',
        'john.doe@example.com',
        'user+tag@example.com',
        'user@subdomain.example.com',
        'firstname.lastname@company.co.uk',
        'user123@test.org',
        'a@bc.de',
        'test@example.museum',
      ];

      for (final email in validEmails) {
        test(email, () {
          expect(validateEmail(email), isNull);
        });
      }
    });

    group('rejects emails with internal spaces', () {
      final spacedEmails = [
        'enock37. @gmail.com',
        'user @example.com',
        'us er@example.com',
        'user@exam ple.com',
      ];

      for (final email in spacedEmails) {
        test('"$email"', () {
          expect(validateEmail(email), 'Please enter a valid email');
        });
      }
    });

    test('trims leading/trailing whitespace before validating', () {
      // Leading/trailing spaces are trimmed, so this is valid
      expect(validateEmail(' user@example.com '), isNull);
    });

    group('rejects emails with missing or short TLD', () {
      final shortTldEmails = [
        'user@domain',
        'user@domain.c',
      ];

      for (final email in shortTldEmails) {
        test('"$email"', () {
          expect(validateEmail(email), 'Please enter a valid email');
        });
      }
    });

    group('rejects other malformed emails', () {
      final malformedEmails = [
        'notanemail',
        '@example.com',
        'user@',
        'user@.com',
        'user@-example.com',
        '',
      ];

      for (final email in malformedEmails) {
        test('"$email"', () {
          expect(validateEmail(email), isNotNull);
        });
      }
    });

    test('returns error for null', () {
      expect(validateEmail(null), 'Email is required');
    });

    test('returns error for empty string', () {
      expect(validateEmail(''), 'Email is required');
    });

    test('returns error for whitespace only', () {
      expect(validateEmail('   '), 'Email is required');
    });
  });
}
