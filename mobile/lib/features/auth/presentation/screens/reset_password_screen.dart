import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/network/api_exception.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../data/auth_repository.dart';
import 'form_validators.dart';
import 'password_field.dart';

/// Also used by invited doctors to set their first password.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key, this.email = ''});

  final String email;

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  ApiException? _error;

  @override
  void dispose() {
    for (final c in [_email, _code, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          .confirmPasswordReset(
            email: _email.text.trim(),
            code: _code.text.trim(),
            newPassword: _password.text,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).authResetSuccess)),
      );
      context.go('/login');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      // `invalid_code` has no field: the snackbar shows it.
      showApiError(context, e, inlineFields: {'email', 'code', 'new_password'});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.authResetPasswordTitle)),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: l10n.authEmailLabel,
                  errorText: fieldError(context, _error, 'email'),
                ),
                validator: (v) => validateEmail(l10n, v),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: l10n.authCodeLabel,
                  errorText: fieldError(context, _error, 'code'),
                ),
                validator: (v) => validateRequired(l10n, v),
              ),
              const SizedBox(height: 8),
              PasswordField(
                controller: _password,
                label: l10n.authNewPasswordLabel,
                autofillHint: AutofillHints.newPassword,
                errorText: fieldError(context, _error, 'new_password'),
                validator: (v) => validateNewPassword(l10n, v),
              ),
              const SizedBox(height: 16),
              PasswordField(
                controller: _confirm,
                label: l10n.authConfirmPasswordLabel,
                autofillHint: AutofillHints.newPassword,
                validator: (v) => validateConfirm(l10n, v, _password.text),
                onSubmitted: _submit,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(l10n.authResetButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
