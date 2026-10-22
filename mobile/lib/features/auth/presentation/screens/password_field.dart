import 'package:flutter/material.dart';

import 'package:medical_appointments/l10n/gen/app_localizations.dart';

/// Obscured password input with a show/hide toggle.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.validator,
    this.errorText,
    this.onSubmitted,
    this.autofillHint = AutofillHints.password,
  });

  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;
  final String? errorText;
  final VoidCallback? onSubmitted;
  final String autofillHint;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TextFormField(
      controller: widget.controller,
      obscureText: _obscure,
      autofillHints: [widget.autofillHint],
      decoration: InputDecoration(
        labelText: widget.label,
        errorText: widget.errorText,
        suffixIcon: IconButton(
          tooltip: l10n.authTogglePassword,
          icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
      validator: widget.validator,
      onFieldSubmitted:
          widget.onSubmitted == null ? null : (_) => widget.onSubmitted!(),
    );
  }
}
