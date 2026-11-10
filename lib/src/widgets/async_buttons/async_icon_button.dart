import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../custom_circular_progress_indicator.dart';

class AsyncIconButton extends StatefulWidget {
  const AsyncIconButton({
    super.key,
    required this.onPressed,
    required this.icon,
    this.tooltip,
    this.color,
    this.visualDensity,
  });

  final AsyncCallback? onPressed;
  final Widget icon;
  final String? tooltip;
  final Color? color;
  final VisualDensity? visualDensity;

  @override
  State<AsyncIconButton> createState() => _AsyncIconButtonState();
}

class _AsyncIconButtonState extends State<AsyncIconButton> {
  bool _isLoading = false;

  Future<void> _run() async {
    if (_isLoading || widget.onPressed == null) return;
    setState(() => _isLoading = true);
    try {
      await widget.onPressed!();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: _isLoading || widget.onPressed == null ? null : _run,
        tooltip: widget.tooltip,
        color: widget.color,
        visualDensity: widget.visualDensity,
        icon: _isLoading ? const MiniCircularProgressIndicator() : widget.icon,
      );
}
