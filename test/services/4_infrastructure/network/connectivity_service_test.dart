import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rivr/services/4_infrastructure/network/connectivity_service.dart';

// The whole point of this service is that a live network interface is NOT the
// same as a working internet connection. These pin the probe that tells them
// apart, and the empty-list trap that used to report a false offline.

const _wifi = [ConnectivityResult.wifi];
const _none = [ConnectivityResult.none];

http.Client respondWith(int status, {String body = ''}) =>
    MockClient((_) async => http.Response(body, status));

void main() {
  _escapeChecks();
  final service = ConnectivityService.instance;

  tearDown(() => service.debugSetClient(http.Client()));

  group('an interface is not the internet', () {
    // The reason this rewrite happened. Airport wi-fi answers the probe with
    // its own login page — HTTP 200 with a body — instead of an empty 204. The
    // old interface-only check called this "online" and the user watched a
    // working app load nothing.
    test('a captive portal login page is not internet', () async {
      service.debugSetClient(
        respondWith(200, body: '<html>Sign in to continue</html>'),
      );
      expect(await service.offlineFor(_wifi), isTrue);
    });

    test('a real 204 is internet', () async {
      service.debugSetClient(respondWith(204));
      expect(await service.offlineFor(_wifi), isFalse);
    });

    test('a redirect to a portal is not internet', () async {
      service.debugSetClient(respondWith(302));
      expect(await service.offlineFor(_wifi), isTrue);
    });

    test('a server error is not internet', () async {
      service.debugSetClient(respondWith(500));
      expect(await service.offlineFor(_wifi), isTrue);
    });

    test('a transport failure is not internet', () async {
      service.debugSetClient(
        MockClient((_) async => throw http.ClientException('no route')),
      );
      expect(await service.offlineFor(_wifi), isTrue);
    });
  });

  group('no interface at all', () {
    test('is conclusive, and skips the probe entirely', () async {
      var called = false;
      service.debugSetClient(MockClient((_) async {
        called = true;
        return http.Response('', 204);
      }));

      expect(await service.offlineFor(_none), isTrue);
      expect(called, isFalse, reason: 'nothing to probe over');
    });

    // Iterable.every is vacuously true for an empty list, so the previous
    // `results.every((r) => r == none)` reported OFFLINE when the platform
    // returned nothing — a false banner over a working app.
    test('an empty list is not treated as offline', () async {
      service.debugSetClient(respondWith(204));
      expect(await service.offlineFor(const []), isFalse);
    });

    test('mixed interfaces count as having one', () async {
      service.debugSetClient(respondWith(204));
      expect(
        await service.offlineFor(
          const [ConnectivityResult.none, ConnectivityResult.mobile],
        ),
        isFalse,
      );
    });

    test('vpn counts as an interface', () async {
      service.debugSetClient(respondWith(204));
      expect(await service.offlineFor(const [ConnectivityResult.vpn]), isFalse);
    });
  });

  group('probe caching', () {
    test('rapid checks do not each hit the network', () async {
      var calls = 0;
      service.debugSetClient(MockClient((_) async {
        calls++;
        return http.Response('', 204);
      }));

      await service.offlineFor(_wifi);
      await service.offlineFor(_wifi);
      await service.offlineFor(_wifi);

      expect(calls, 1, reason: 'result should be cached briefly');
    });

    // Losing the interface must invalidate the cache, or reconnecting would
    // keep reporting the stale pre-drop verdict for the cache window.
    test('dropping to no interface clears the cache', () async {
      var calls = 0;
      service.debugSetClient(MockClient((_) async {
        calls++;
        return http.Response('', 204);
      }));

      await service.offlineFor(_wifi);
      expect(calls, 1);

      await service.offlineFor(_none);
      await service.offlineFor(_wifi);
      expect(calls, 2, reason: 'must re-probe after a drop');
    });
  });
}

// Does anything inside offlineFor actually escape?
//
// The `await` in isCurrentlyOffline was added because CI's analyzer flagged
// unawaited_return_in_try_block. That lint is right in principle — a bare
// return hands the future back before the try closes — but it is worth knowing
// whether any real path could exercise it, rather than assuming one does.
void _escapeChecks() {
  final service = ConnectivityService.instance;

  group('offlineFor is total — nothing escapes it', () {
    tearDown(() => service.debugSetClient(http.Client()));

    test('a throwing client does not propagate', () async {
      service.debugSetClient(
        MockClient((_) async => throw http.ClientException('boom')),
      );
      await expectLater(service.offlineFor(_wifi), completion(isTrue));
    });

    // Dart's bare `catch (_)` catches Error as well as Exception, so even a
    // programming error inside the probe is absorbed.
    test('a thrown Error does not propagate either', () async {
      service.debugSetClient(MockClient((_) async => throw StateError('bad')));
      await expectLater(service.offlineFor(_wifi), completion(isTrue));
    });

    test('a timeout does not propagate', () async {
      service.debugSetClient(MockClient((_) async {
        await Future<void>.delayed(const Duration(seconds: 30));
        return http.Response('', 204);
      }));
      await expectLater(service.offlineFor(_wifi), completion(isTrue));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });
}
