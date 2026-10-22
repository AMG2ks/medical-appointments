import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/network/api_exception.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../data/auth_repository.dart';
import 'form_validators.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _busy = false;
  ApiException? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final email = _email.text.trim();
    try {
      await ref.read(authRepositoryProvider).requestPasswordReset(email);
      if (mounted) {
        context.push(
          '/reset-password?email=${Uri.encodeQueryComponent(email)}',
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      showApiError(context, e, inlineFields: {'email'});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.authForgotPasswordTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(l10n.authForgotPasswordHint),
            const SizedBox(height: 16),
            Form(
              key: _formKey,
              child: TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: l10n.authEmailLabel,
                  errorText: fieldError(context, _error, 'email'),
                ),
                validator: (v) => validateEmail(l10n, v),
                onFieldSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(l10n.authSendCodeButton),
            ),
            TextButton(
              onPressed: () => context.push('/reset-password'),
              child: Text(l10n.authHaveCodeLink),
            ),
          ],
        ),
      ),
    );
  }
}
