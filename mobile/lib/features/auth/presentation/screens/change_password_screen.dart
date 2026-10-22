import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/network/api_exception.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../data/auth_repository.dart';
import 'form_validators.dart';
import 'password_field.dart';

class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  ApiException? _error;

  @override
  void dispose() {
    for (final c in [_old, _new, _confirm]) {
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
      // The repository stores the new token pair: this device stays logged in.
      await ref
          .read(authRepositoryProvider)
          .changePassword(_old.text, _new.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).authPasswordChanged),
        ),
      );
      context.pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      showApiError(context, e, inlineFields: {'old_password', 'new_password'});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.authChangePasswordTitle)),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              PasswordField(
                controller: _old,
                label: l10n.authOldPasswordLabel,
                errorText: fieldError(context, _error, 'old_password'),
                validator: (v) => validateRequired(l10n, v),
              ),
              const SizedBox(height: 16),
              PasswordField(
                controller: _new,
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
                validator: (v) => validateConfirm(l10n, v, _new.text),
                onSubmitted: _submit,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(l10n.authChangePasswordButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
