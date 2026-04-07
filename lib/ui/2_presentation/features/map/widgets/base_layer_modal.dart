// lib/ui/2_presentation/features/map/widgets/base_layer_modal.dart
import 'package:flutter/cupertino.dart';
import 'package:rivr/models/1_domain/shared/map_base_layer.dart';

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
