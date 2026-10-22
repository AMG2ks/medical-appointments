import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/widgets/language_switch.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../auth_controller.dart';
import 'form_validators.dart';
import 'password_field.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  ApiException? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // On success the router redirects to the role's home.
      await ref
          .read(authControllerProvider.notifier)
          .login(_email.text.trim(), _password.text);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      showApiError(context, e, inlineFields: {'email', 'password'});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.authLoginTitle),
        actions: const [
          Padding(padding: EdgeInsets.only(right: 12), child: LanguageSwitch()),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: InputDecoration(
                      labelText: l10n.authEmailLabel,
                      errorText: fieldError(context, _error, 'email'),
                    ),
                    validator: (v) => validateEmail(l10n, v),
                  ),
                  const SizedBox(height: 16),
                  PasswordField(
                    controller: _password,
                    label: l10n.authPasswordLabel,
                    errorText: fieldError(context, _error, 'password'),
                    validator: (v) => validateRequired(l10n, v),
                    onSubmitted: _submit,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child:
                        _busy
                            ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                            : Text(l10n.authLoginButton),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => context.push('/forgot-password'),
              child: Text(l10n.authForgotPasswordLink),
            ),
            TextButton(
              onPressed: () => context.push('/register'),
              child: Text(l10n.authRegisterLink),
            ),
          ],
        ),
      ),
    );
  }
}
