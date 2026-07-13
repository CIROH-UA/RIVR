// lib/ui/2_presentation/routing/route_observer.dart

import 'package:flutter/widgets.dart';

/// App-wide route observer. Registered in [CupertinoApp.navigatorObservers] so
/// pages can implement [RouteAware] and be told when they become visible again
/// (e.g. the favorites list revalidating its data after the forecast page pops).
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
