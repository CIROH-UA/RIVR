import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/features/map/selected_reach.dart';
import 'package:rivr/models/1_domain/shared/flow_classification.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';

SelectedReach _reach({int? mapFloodCategoryIndex}) => SelectedReach(
      reachId: '10376293',
      streamOrder: 5,
      latitude: 40.2,
      longitude: -111.6,
      source: ForecastSource.nwm,
      mapFloodCategoryIndex: mapFloodCategoryIndex,
      selectedAt: DateTime.utc(2026, 8, 20),
    );

void main() {
  group('mapFloodCategory', () {
    // The daily build script writes `cat` as RP_CATEGORY = [(25,4), (10,3),
    // (5,2), (2,1)] — the same ladder, in the same order, as
    // kFloodCategories. That alignment is load-bearing and completely
    // implicit: nothing in either codebase references the other. Reorder or
    // insert a category on either side and every coloured river gets
    // confidently mislabelled, with no error anywhere. This is the test that
    // fails first.
    test('tileset cat values map onto the app ladder', () {
      expect(_reach(mapFloodCategoryIndex: 1).mapFloodCategory, 'Action');
      expect(_reach(mapFloodCategoryIndex: 2).mapFloodCategory, 'Moderate');
      expect(_reach(mapFloodCategoryIndex: 3).mapFloodCategory, 'Major');
      expect(_reach(mapFloodCategoryIndex: 4).mapFloodCategory, 'Extreme');
    });

    test('the ladder has exactly the five categories the build assumes', () {
      expect(kFloodCategories, [
        'Normal',
        'Action',
        'Moderate',
        'Major',
        'Extreme',
      ]);
    });

    test('an uncoloured reach has no category', () {
      expect(_reach().mapFloodCategory, isNull);
      expect(_reach(mapFloodCategoryIndex: null).mapFloodCategory, isNull);
    });

    // 0 is 'Normal' in the ladder but the tileset never emits it — reaches
    // below the 2-year gate are not written at all. Treating it as a category
    // would paint a "Forecast peak: Normal" strip that explains nothing.
    test('category 0 is not a peak worth reporting', () {
      expect(_reach(mapFloodCategoryIndex: 0).mapFloodCategory, isNull);
    });

    test('a value outside the ladder is rejected, not crashed on', () {
      expect(_reach(mapFloodCategoryIndex: 5).mapFloodCategory, isNull);
      expect(_reach(mapFloodCategoryIndex: 99).mapFloodCategory, isNull);
      expect(_reach(mapFloodCategoryIndex: -1).mapFloodCategory, isNull);
    });
  });

  // These copy methods are written by hand, field by field. Adding a field to
  // the class does not add it here, and the failure is silent: the strip just
  // stops appearing once a river name or geocoded location arrives, which is
  // to say on almost every real tap.
  group('copy methods preserve the map category', () {
    test('withRiverName', () {
      final r = _reach(mapFloodCategoryIndex: 3).withRiverName('Provo River');
      expect(r.mapFloodCategoryIndex, 3);
      expect(r.mapFloodCategory, 'Major');
      expect(r.riverName, 'Provo River');
    });

    test('withLocation', () {
      final r = _reach(mapFloodCategoryIndex: 2)
          .withLocation(city: 'Provo', state: 'UT');
      expect(r.mapFloodCategoryIndex, 2);
      expect(r.formattedLocation, 'Provo, UT');
    });

    test('chained through both', () {
      final r = _reach(mapFloodCategoryIndex: 4)
          .withRiverName('Provo River')
          .withLocation(city: 'Provo', state: 'UT');
      expect(r.mapFloodCategory, 'Extreme');
    });

    test('withMapFloodCategory sets and clears', () {
      expect(_reach().withMapFloodCategory(2).mapFloodCategory, 'Moderate');
      expect(
        _reach(mapFloodCategoryIndex: 2).withMapFloodCategory(null)
            .mapFloodCategory,
        isNull,
      );
    });
  });

  group('fromVectorTile', () {
    test('carries the flood category when the map supplies one', () {
      final r = SelectedReach.fromVectorTile(
        properties: const {'station_id': 10376293, 'streamOrder': 5},
        latitude: 40.2,
        longitude: -111.6,
        mapFloodCategoryIndex: 2,
      );
      expect(r.reachId, '10376293');
      expect(r.mapFloodCategory, 'Moderate');
    });

    test('defaults to uncoloured', () {
      final r = SelectedReach.fromVectorTile(
        properties: const {'station_id': 10376293, 'streamOrder': 5},
        latitude: 40.2,
        longitude: -111.6,
      );
      expect(r.mapFloodCategoryIndex, isNull);
    });
  });
}
