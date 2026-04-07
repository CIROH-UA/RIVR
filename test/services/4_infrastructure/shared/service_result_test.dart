// test/services/4_infrastructure/shared/service_result_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';

void main() {
  group('ServiceResult — success', () {
    test('isSuccess is true and isFailure is false', () {
      final result = ServiceResult.success(42);
      expect(result.isSuccess, isTrue);
      expect(result.isFailure, isFalse);
    });

    test('data returns the wrapped value', () {
      final result = ServiceResult.success('hello');
      expect(result.data, 'hello');
    });

    test('errorMessage is null on success', () {
      final result = ServiceResult.success(42);
      expect(result.errorMessage, isNull);
    });

    test('exception is null on success', () {
      final result = ServiceResult.success(42);
      expect(result.exception, isNull);
    });

    test('errorType is null on success', () {
      final result = ServiceResult.success(42);
      expect(result.errorType, isNull);
    });
  });

  group('ServiceResult — failure', () {
    late ServiceResult<int> result;

    setUp(() {
      result = ServiceResult.failure(
        const ServiceException.network('No internet connection'),
      );
    });

    test('isSuccess is false and isFailure is true', () {
      expect(result.isSuccess, isFalse);
      expect(result.isFailure, isTrue);
    });

    test('errorMessage returns the exception message', () {
      expect(result.errorMessage, 'No internet connection');
    });

    test('errorType returns the exception type', () {
      expect(result.errorType, ServiceErrorType.network);
    });

    test('exception is populated', () {
      expect(result.exception, isNotNull);
      expect(result.exception!.type, ServiceErrorType.network);
    });

    test('accessing data throws StateError', () {
      expect(() => result.data, throwsStateError);
    });
  });

  group('ServiceResult — map', () {
    test('transforms success data', () {
      final result = ServiceResult.success(10);
      final mapped = result.map((n) => n * 2);

      expect(mapped.isSuccess, isTrue);
      expect(mapped.data, 20);
    });

    test('preserves failure on map', () {
      final result = ServiceResult<int>.failure(
        const ServiceException.validation('Bad input'),
      );
      final mapped = result.map((n) => n * 2);

      expect(mapped.isFailure, isTrue);
      expect(mapped.errorMessage, 'Bad input');
      expect(mapped.errorType, ServiceErrorType.validation);
    });

    test('changes type parameter on success', () {
      final result = ServiceResult.success(42);
      final mapped = result.map((n) => 'Number: $n');

      expect(mapped.isSuccess, isTrue);
      expect(mapped.data, 'Number: 42');
    });
  });

  group('ServiceResult — then (chaining)', () {
    test('chains two successful results', () async {
      final first = ServiceResult.success(5);
      final chained = await first.then(
        (n) async => ServiceResult.success(n * 3),
      );

      expect(chained.isSuccess, isTrue);
      expect(chained.data, 15);
    });

    test('short-circuits on first failure', () async {
      final first = ServiceResult<int>.failure(
        const ServiceException.network('Offline'),
      );

      var callbackCalled = false;
      final chained = await first.then((n) async {
        callbackCalled = true;
        return ServiceResult.success(n * 3);
      });

      expect(callbackCalled, isFalse);
      expect(chained.isFailure, isTrue);
      expect(chained.errorMessage, 'Offline');
    });

    test('propagates failure from chained operation', () async {
      final first = ServiceResult.success(5);
      final chained = await first.then(
        (n) async => ServiceResult<String>.failure(
          const ServiceException.notFound('Not found'),
        ),
      );

      expect(chained.isFailure, isTrue);
      expect(chained.errorMessage, 'Not found');
      expect(chained.errorType, ServiceErrorType.notFound);
    });

    test('chains three operations', () async {
      final step1 = ServiceResult.success(2);
      final step2 = await step1.then(
        (n) async => ServiceResult.success(n + 3),
      );
      final step3 = await step2.then(
        (n) async => ServiceResult.success(n * 10),
      );

      expect(step3.isSuccess, isTrue);
      expect(step3.data, 50);
    });
  });

  group('ServiceException — named constructors', () {
    test('network constructor sets correct type', () {
      const e = ServiceException.network('Connection failed');
      expect(e.type, ServiceErrorType.network);
      expect(e.message, 'Connection failed');
      expect(e.technicalDetail, isNull);
    });

    test('auth constructor sets correct type', () {
      const e = ServiceException.auth('Invalid credentials');
      expect(e.type, ServiceErrorType.authentication);
      expect(e.message, 'Invalid credentials');
    });

    test('validation constructor sets correct type', () {
      const e = ServiceException.validation('Reach ID cannot be empty');
      expect(e.type, ServiceErrorType.validation);
      expect(e.message, 'Reach ID cannot be empty');
    });

    test('notFound constructor sets correct type', () {
      const e = ServiceException.notFound('Reach not found');
      expect(e.type, ServiceErrorType.notFound);
      expect(e.message, 'Reach not found');
    });

    test('cache constructor sets correct type', () {
      const e = ServiceException.cache('Corrupted cache file');
      expect(e.type, ServiceErrorType.cache);
      expect(e.message, 'Corrupted cache file');
    });

    test('configuration constructor sets correct type', () {
      const e = ServiceException.configuration('Missing API key');
      expect(e.type, ServiceErrorType.configuration);
      expect(e.message, 'Missing API key');
    });

    test('unknown constructor sets correct type', () {
      const e = ServiceException.unknown('Something went wrong');
      expect(e.type, ServiceErrorType.unknown);
      expect(e.message, 'Something went wrong');
    });

    test('technical detail is preserved when provided', () {
      const e = ServiceException.network(
        'Connection failed',
        detail: 'SocketException: OS Error',
      );
      expect(e.technicalDetail, 'SocketException: OS Error');
    });

    test('toString includes type and message', () {
      const e = ServiceException.network('Offline');
      expect(e.toString(), contains('network'));
      expect(e.toString(), contains('Offline'));
    });
  });

  group('ServiceException — fromError factory', () {
    test('wraps a generic exception', () {
      final e = ServiceException.fromError(
        Exception('something broke'),
        context: 'loadForecast',
      );

      expect(e.type, ServiceErrorType.unknown);
      expect(e.message, isNotEmpty);
      expect(e.technicalDetail, contains('something broke'));
    });

    test('wraps a timeout-like exception as network error', () {
      final e = ServiceException.fromError(
        Exception('Connection timeout after 15s'),
      );

      // ErrorService.isNetworkError checks for 'timeout' in string
      expect(e.type, ServiceErrorType.network);
    });
  });

  group('ServiceResult — type inference', () {
    test('works with complex types', () {
      final result = ServiceResult.success(['a', 'b', 'c']);
      expect(result.data, hasLength(3));
    });

    test('works with nullable inner types', () {
      final result = ServiceResult<String?>.success(null);
      expect(result.isSuccess, isTrue);
    });

    test('works with void-like results', () {
      final result = ServiceResult<void>.success(null);
      expect(result.isSuccess, isTrue);
    });
  });
}
