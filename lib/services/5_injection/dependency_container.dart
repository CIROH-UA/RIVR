import 'package:rivr/services/5_injection/shared_dependencies.dart';
import 'package:rivr/services/5_injection/settings_dependencies.dart';
import 'package:rivr/services/5_injection/auth_dependencies.dart';
import 'package:rivr/services/5_injection/forecast_dependencies.dart';
import 'package:rivr/services/5_injection/favorites_dependencies.dart';
import 'package:rivr/services/5_injection/map_dependencies.dart';

/// Register all dependencies in correct order.
/// Call this once in main() before runApp().
void setupDependencies() {
  setupSharedDependencies();
  setupSettingsDependencies(); // before auth (auth repo needs settings service)
  setupAuthDependencies();
  setupForecastDependencies();
  setupFavoritesDependencies(); // after forecast (favorites repo needs forecast service)
  setupMapDependencies();
}
