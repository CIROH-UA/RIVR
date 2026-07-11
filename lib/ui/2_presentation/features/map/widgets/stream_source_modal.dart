// lib/ui/2_presentation/features/map/widgets/stream_source_modal.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/services/4_infrastructure/map/map_preference_service.dart';

/// Bottom sheet for toggling which stream networks are drawn on the map.
/// Mirrors [BaseLayerModal] but uses on/off switches (the layers are not
/// mutually exclusive). Changes apply live via [onChanged].
class StreamSourceModal extends StatefulWidget {
  final StreamLayerVisibility initial;
  final ValueChanged<StreamLayerVisibility> onChanged;

  const StreamSourceModal({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  @override
  State<StreamSourceModal> createState() => _StreamSourceModalState();
}

class _StreamSourceModalState extends State<StreamSourceModal> {
  late StreamLayerVisibility _layers = widget.initial;

  // Match the on-map stream colors so a row reads as its layer.
  static const Color _nwmColor = Color(0xFF191970); // Midnight blue
  static const Color _geoglowsColor = Color(0xFF1E88A8); // Brand teal

  void _update(StreamLayerVisibility next) {
    setState(() => _layers = next);
    widget.onChanged(next);
  }

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
            Padding(
              padding: const EdgeInsets.only(top: 0, bottom: 8),
              child: Text(
                'Stream Data',
                style: CupertinoTheme.of(
                  context,
                ).textTheme.navLargeTitleTextStyle,
              ),
            ),
            _row(
              context,
              color: _nwmColor,
              title: 'NWM (US)',
              subtitle: 'National Water Model',
              value: _layers.nwm,
              onChanged: (v) => _update(_layers.copyWith(nwm: v)),
            ),
            _row(
              context,
              color: _geoglowsColor,
              title: 'GEOGLOWS · outside US',
              subtitle: 'Global rivers beyond the US',
              value: _layers.geoglowsWorld,
              onChanged: (v) => _update(_layers.copyWith(geoglowsWorld: v)),
            ),
            _row(
              context,
              color: _geoglowsColor,
              title: 'GEOGLOWS · US area',
              subtitle: 'Overlaps NWM — for comparison',
              value: _layers.geoglowsUs,
              onChanged: (v) => _update(_layers.copyWith(geoglowsUs: v)),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required Color color,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return CupertinoListTile(
      leading: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: CupertinoSwitch(value: value, onChanged: onChanged),
    );
  }
}

/// Show the stream-source selection modal.
void showStreamSourceModal(
  BuildContext context, {
  required StreamLayerVisibility initial,
  required ValueChanged<StreamLayerVisibility> onChanged,
}) {
  showCupertinoModalPopup<void>(
    context: context,
    builder: (BuildContext context) {
      return StreamSourceModal(initial: initial, onChanged: onChanged);
    },
  );
}
