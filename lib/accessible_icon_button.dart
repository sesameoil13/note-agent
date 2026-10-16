import 'package:flutter/material.dart';

/// Gives icon-only actions an explicit name and press action in native trees.
/// Tooltip text alone is exposed separately from a control's accessibility name.
class AccessibleIconButton extends StatelessWidget {
  const AccessibleIconButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final Widget icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: label,
    button: true,
    enabled: onPressed != null,
    onTap: onPressed,
    excludeSemantics: true,
    child: IconButton(tooltip: label, icon: icon, onPressed: onPressed),
  );
}
