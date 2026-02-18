import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivr/core/providers/favorites_provider.dart';
import 'package:rivr/core/providers/reach_data_provider.dart';
import 'package:rivr/core/providers/theme_provider.dart';
import 'package:rivr/features/auth/providers/auth_provider.dart';

/// Wraps a widget in the app's provider tree and CupertinoApp for widget testing.
///
/// Usage:
/// ```dart
/// await tester.pumpWidget(pumpApp(MyWidget()));
/// ```
Widget pumpApp(
  Widget child, {
  AuthProvider? authProvider,
  ThemeProvider? themeProvider,
  ReachDataProvider? reachDataProvider,
  FavoritesProvider? favoritesProvider,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(
        value: authProvider ?? AuthProvider(),
      ),
      ChangeNotifierProvider<ThemeProvider>.value(
        value: themeProvider ?? ThemeProvider(),
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
