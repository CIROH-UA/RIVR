// lib/features/auth/presentation/widgets/live_validation_field.dart

import 'package:flutter/cupertino.dart';
import 'dart:async';

class LiveValidationField extends StatefulWidget {
  final TextEditingController controller;
  final String placeholder;
  final bool obscureText;
  final TextInputType keyboardType;
  final IconData? prefixIcon;
  final Widget? suffixIcon;
  final String? Function(String?)? validator;
  final void Function(String)? onChanged;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final void Function(String)? onSubmitted;

  const LiveValidationField({
    super.key,
    required this.controller,
    required this.placeholder,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
    this.prefixIcon,
    this.suffixIcon,
    this.validator,
    this.onChanged,
    this.focusNode,
    this.textInputAction,
    this.onSubmitted,
  });

  @override
  State<LiveValidationField> createState() => _LiveValidationFieldState();
}

class _LiveValidationFieldState extends State<LiveValidationField> {
  String? _errorText;
  bool _hasBeenTouched = false;
  bool _isFocused = false;
  Timer? _debounceTimer;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_onFocusChange);

    // Validate initial value if present
    if (widget.controller.text.isNotEmpty) {
      _validate(widget.controller.text);
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _onFocusChange() {
    final hasFocus = _focusNode.hasFocus;

    // Validate when focus is lost and field has been touched
    if (_isFocused && !hasFocus && _hasBeenTouched) {
      _debounceTimer?.cancel();
      _validate(widget.controller.text);
    }

    setState(() {
      _isFocused = hasFocus;
    });
  }

  void _onTextChanged(String value) {
    if (widget.onChanged != null) {
      widget.onChanged!(value);
    }

    setState(() {
      _hasBeenTouched = true;
    });

    // Debounced validation
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) {
        _validate(value);
      }
    });
  }

  void _validate(String value) {
    if (widget.validator == null) return;

    final error = widget.validator!(value);
    if (mounted) {
      setState(() {
        _errorText = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = CupertinoTheme.of(context).primaryColor;

    final isValid =
        _hasBeenTouched &&
        _errorText == null &&
        widget.controller.text.isNotEmpty;
    final hasError = _hasBeenTouched && _errorText != null;

    final borderColor = hasError
        ? CupertinoColors.systemRed
        : (_isFocused ? primaryColor : CupertinoColors.systemGrey4);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              color: CupertinoColors.systemGrey6.color,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor, width: _isFocused ? 2 : 1),
            ),
            child: Row(
              children: [
                // Prefix icon
                if (widget.prefixIcon != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Icon(
                      widget.prefixIcon,
                      color: _isFocused
                          ? primaryColor
                          : CupertinoColors.systemGrey,
                      size: 20,
                    ),
                  ),

                // Text field
                Expanded(
                  child: CupertinoTextField(
                    controller: widget.controller,
                    focusNode: _focusNode,
                    obscureText: widget.obscureText,
                    keyboardType: widget.keyboardType,
                    textInputAction: widget.textInputAction,
                    onSubmitted: widget.onSubmitted,
                    onChanged: _onTextChanged,
                    placeholder: widget.placeholder,
                    decoration: const BoxDecoration(),
                    padding: EdgeInsets.only(
                      left: widget.prefixIcon != null ? 8 : 12,
                      right: 8,
                      top: 12,
                      bottom: 12,
                    ),
                  ),
                ),

                // Suffix icon or validation indicator
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child:
                      widget.suffixIcon ??
                      (_hasBeenTouched
                          ? Icon(
                              isValid
                                  ? CupertinoIcons.checkmark_circle_fill
                                  : (hasError
                                        ? CupertinoIcons.xmark_circle_fill
                                        : null),
                              color: isValid
                                  ? CupertinoColors.systemGreen
                                  : CupertinoColors.systemRed,
                              size: 20,
                            )
                          : null),
                ),
              ],
            ),
          ),

          // Error message
          if (hasError)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 6),
              child: Text(
                _errorText!,
                style: const TextStyle(
                  color: CupertinoColors.systemRed,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
