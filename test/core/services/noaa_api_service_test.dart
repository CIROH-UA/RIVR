import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/core/services/noaa_api_service.dart';

void main() {
  group('ApiException', () {
    test('stores message', () {
      const exception = ApiException('Something went wrong');
      expect(exception.message, 'Something went wrong');
    });

    test('toString includes ApiException prefix', () {
      const exception = ApiException('Network error');
      expect(exception.toString(), 'ApiException: Network error');
    });

    test('can be caught as Exception', () {
      expect(
        () => throw const ApiException('test'),
        throwsA(isA<ApiException>()),
      );
    });

    test('can be caught as generic Exception type', () {
      Object? caught;
      try {
        throw const ApiException('test error');
      } on Exception catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught, isA<ApiException>());
      expect((caught as ApiException).message, 'test error');
    });

    test('handles empty message', () {
      const exception = ApiException('');
      expect(exception.message, '');
      expect(exception.toString(), 'ApiException: ');
    });
  });
}
