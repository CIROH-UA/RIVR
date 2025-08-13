// lib/features/map/widgets/map_control_buttons.dart

import 'package:flutter/cupertino.dart';

class MapControlButtons extends StatelessWidget {
  final VoidCallback onLayersPressed;
  final VoidCallback onRecenterPressed;
  final VoidCallback onStreamsPressed;
  final VoidCallback on3DTogglePressed; // NEW: 3D toggle callback
  final bool is3DEnabled; // NEW: 3D state

  const MapControlButtons({
    super.key,
    required this.onLayersPressed,
    required this.onRecenterPressed,
    required this.onStreamsPressed,
    required this.on3DTogglePressed, // NEW: Required callback
    required this.is3DEnabled, // NEW: Required state
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
          onPressed: on3DTogglePressed,
          tooltip: is3DEnabled ? 'Disable 3D Terrain' : 'Enable 3D Terrain',
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
        color: CupertinoColors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.systemGrey.withOpacity(0.3),
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

  // NEW: Special 3D toggle button with different styling when active
  Widget _build3DToggleButton({
    required bool isEnabled,
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: isEnabled
            ? CupertinoColors.systemBlue
            : CupertinoColors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.systemGrey.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        child: Icon(
          CupertinoIcons.view_3d,
          color: isEnabled ? CupertinoColors.white : CupertinoColors.systemBlue,
          size: 20,
        ),
      ),
    );
  }
}
