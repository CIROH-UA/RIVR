import 'package:flutter/cupertino.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';
import 'package:rivr/core/providers/favorites_provider.dart';
import 'package:rivr/core/providers/reach_data_provider.dart';
import 'package:rivr/core/services/flow_unit_preference_service.dart';
import 'package:rivr/core/services/i_flow_unit_preference_service.dart';
import 'package:rivr/features/auth/providers/auth_provider.dart';

/// Sets up GetIt service locator for tests.
/// Call in setUpAll() and pair with tearDownServiceLocator() in tearDownAll().
void setupTestServiceLocator() {
  final sl = GetIt.instance;
  if (!sl.isRegistered<IFlowUnitPreferenceService>()) {
    sl.registerLazySingleton<IFlowUnitPreferenceService>(
      () => FlowUnitPreferenceService(),
    );
  }
}

/// Resets GetIt service locator after tests.
void tearDownServiceLocator() {
  GetIt.instance.reset();
}

/// Wraps a widget in the app's provider tree and CupertinoApp for widget testing.
///
/// Usage:
/// ```dart
/// await tester.pumpWidget(pumpApp(MyWidget()));
/// ```
Widget pumpApp(
  Widget child, {
  AuthProvider? authProvider,
  ReachDataProvider? reachDataProvider,
  FavoritesProvider? favoritesProvider,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(
        value: authProvider ?? AuthProvider(),
      ),
      ChangeNotifierProvider<ReachDataProvider>.value(
        value: reachDataProvider ?? ReachDataProvider(),
      ),
      ChangeNotifierProvider<FavoritesProvider>.value(
        value: favoritesProvider ?? FavoritesProvider(),
      ),
    ],
    child: CupertinoApp(
      home: child,
    ),
  );
}
