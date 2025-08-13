// lib/features/map/widgets/base_layer_modal.dart
import 'package:flutter/cupertino.dart';

enum MapBaseLayer {
  standard('Standard', 'mapbox://styles/mapbox/standard'),
  streets('Streets', 'mapbox://styles/mapbox/streets-v12'),
  satellite('Satellite', 'mapbox://styles/mapbox/satellite-v9'),
  satelliteStreets(
    'Satellite Streets',
    'mapbox://styles/mapbox/satellite-streets-v12',
  ),
  outdoors('Outdoors', 'mapbox://styles/mapbox/outdoors-v12'),
  light('Light', 'mapbox://styles/mapbox/light-v11'),
  dark('Dark', 'mapbox://styles/mapbox/dark-v11');

  const MapBaseLayer(this.displayName, this.styleUrl);

  final String displayName;
  final String styleUrl;

  IconData get icon {
    switch (this) {
      case MapBaseLayer.standard:
        return CupertinoIcons.map_fill; // Filled map icon for Standard
      case MapBaseLayer.streets:
        return CupertinoIcons.map;
      case MapBaseLayer.satellite:
        return CupertinoIcons.globe;
      case MapBaseLayer.satelliteStreets:
        return CupertinoIcons.location;
      case MapBaseLayer.outdoors:
        return CupertinoIcons.tree;
      case MapBaseLayer.light:
        return CupertinoIcons.sun_max;
      case MapBaseLayer.dark:
        return CupertinoIcons.moon;
    }
  }
}

class BaseLayerModal extends StatelessWidget {
  final MapBaseLayer currentLayer;
  final Function(MapBaseLayer) onLayerSelected;

  const BaseLayerModal({
    super.key,
    required this.currentLayer,
    required this.onLayerSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title with reduced top spacing
            Padding(
              padding: const EdgeInsets.only(top: 0, bottom: 16),
              child: Text(
                'Map Layers',
                style: CupertinoTheme.of(
                  context,
                ).textTheme.navLargeTitleTextStyle,
              ),
            ),

            // Layer options
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: MapBaseLayer.values.length,
                itemBuilder: (context, index) {
                  final layer = MapBaseLayer.values[index];
                  final isSelected = layer == currentLayer;

                  return CupertinoListTile(
                    leading: Icon(
                      layer.icon,
                      color: isSelected
                          ? CupertinoColors.systemBlue
                          : CupertinoColors.systemGrey,
                    ),
                    title: Text(layer.displayName),
                    trailing: isSelected
                        ? const Icon(
                            CupertinoIcons.check_mark,
                            color: CupertinoColors.systemBlue,
                          )
                        : null,
                    onTap: () {
                      onLayerSelected(layer);
                      Navigator.of(context).pop();
                    },
                  );
                },
              ),
            ),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

/// Show the base layer selection modal
void showBaseLayerModal(
  BuildContext context, {
  required MapBaseLayer currentLayer,
  required Function(MapBaseLayer) onLayerSelected,
}) {
  showCupertinoModalPopup<void>(
    context: context,
    builder: (BuildContext context) {
      return BaseLayerModal(
        currentLayer: currentLayer,
        onLayerSelected: onLayerSelected,
      );
    },
  );
}
