// test/services/4_infrastructure/fcm/notification_route_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/services/4_infrastructure/fcm/fcm_service.dart';
import 'package:rivr/ui/2_presentation/routing/app_routes.dart';
import 'package:rivr/ui/2_presentation/routing/route_args.dart';

void main() {
  group('notificationRoute', () {
    test('weekly_outlook type opens the Weekly Outlook page (no args)', () {
      final route = notificationRoute({'type': 'weekly_outlook'});
      expect(route, isNotNull);
      expect(route!.name, AppRoutes.weeklyOutlook);
      expect(route.args, isNull);
    });

    test('flood alert with a reachId opens that reach forecast', () {
      final route = notificationRoute({
        'type': 'flood_alert',
        'reachId': '21609641',
        'source': 'nwm',
      });
      expect(route!.name, AppRoutes.forecast);
      final args = route.args as ReachArgs;
      expect(args.reachId, '21609641');
      expect(args.source, ForecastSource.nwm);
    });

    test('reachId with a geoglows source routes with that source', () {
      final route = notificationRoute({
        'reachId': '670068119',
        'source': 'geoglows',
      });
      final args = route!.args as ReachArgs;
      expect(args.reachId, '670068119');
      expect(args.source, ForecastSource.geoglows);
    });

    test('missing source defaults to NWM', () {
      final route = notificationRoute({'reachId': '123'});
      final args = route!.args as ReachArgs;
      expect(args.source, ForecastSource.nwm);
    });

    test('weekly_outlook wins even if a reachId is also present', () {
      final route = notificationRoute({
        'type': 'weekly_outlook',
        'reachId': '999',
      });
      expect(route!.name, AppRoutes.weeklyOutlook);
    });

    test('empty or unrecognized payload routes nowhere', () {
      expect(notificationRoute({}), isNull);
      expect(notificationRoute({'reachId': ''}), isNull);
      expect(notificationRoute({'type': 'something_else'}), isNull);
    });
  });
}
