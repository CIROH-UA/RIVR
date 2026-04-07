// lib/ui/2_presentation/features/map/widgets/map_control_buttons.dart

import 'package:flutter/cupertino.dart';

class MapControlButtons extends StatelessWidget {
  final VoidCallback onLayersPressed;
  final VoidCallback onRecenterPressed;
  final VoidCallback onStreamsPressed;
  final VoidCallback on3DTogglePressed;
  final bool is3DEnabled;
  final bool is3DAvailable;

  const MapControlButtons({
    super.key,
    required this.onLayersPressed,
    required this.onRecenterPressed,
    required this.onStreamsPressed,
    required this.on3DTogglePressed,
    required this.is3DEnabled,
    this.is3DAvailable = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Streams list button
        _buildControlButton(
          icon: CupertinoIcons.list_bullet,
          onPressed: onStreamsPressed,
          tooltip: 'Visible Streams',
        ),
        const SizedBox(height: 8),
        // Layers button
        _buildControlButton(
          icon: CupertinoIcons.layers_alt,
          onPressed: onLayersPressed,
          tooltip: 'Map Layers',
        ),
        const SizedBox(height: 8),
        // Recenter button
        _buildControlButton(
          icon: CupertinoIcons.location_fill,
          onPressed: onRecenterPressed,
          tooltip: 'Center on Location',
        ),
        const SizedBox(height: 8),
        // 3D Toggle button
        _build3DToggleButton(
          isEnabled: is3DEnabled,
          isAvailable: is3DAvailable,
          onPressed: on3DTogglePressed,
          tooltip: !is3DAvailable
              ? '3D not available for this layer'
              : is3DEnabled
                  ? 'Disable 3D Terrain'
                  : 'Enable 3D Terrain',
        ),
      ],
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: CupertinoColors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.systemGrey.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        child: Icon(icon, color: CupertinoColors.systemBlue, size: 20),
      ),
    );
  }

  Widget _build3DToggleButton({
    required bool isEnabled,
    required bool isAvailable,
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    final Color bgColor;
    final Color iconColor;

    if (!isAvailable) {
      bgColor = CupertinoColors.white.withValues(alpha: 0.95);
      iconColor = CupertinoColors.systemGrey3;
    } else if (isEnabled) {
      bgColor = CupertinoColors.systemBlue;
      iconColor = CupertinoColors.white;
    } else {
      bgColor = CupertinoColors.white.withValues(alpha: 0.95);
      iconColor = CupertinoColors.systemBlue;
    }

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.systemGrey.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: isAvailable ? onPressed : null,
        child: Icon(
          CupertinoIcons.view_3d,
          color: iconColor,
          size: 20,
        ),
      ),
    );
  }
}
