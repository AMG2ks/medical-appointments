import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/l10n/locale_controller.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/utils/date_format.dart';
import '../../../../core/widgets/language_switch.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../auth_controller.dart';
import 'form_validators.dart';
import 'password_field.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  static const _inlineFields = {
    'first_name',
    'last_name',
    'email',
    'phone',
    'date_of_birth',
    'password',
  };

  final _formKey = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  DateTime? _birthDate;
  bool _busy = false;
  ApiException? _error;

  @override
  void dispose() {
    for (final c in [
      _firstName,
      _lastName,
      _email,
      _phone,
      _password,
      _confirm,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(now.year - 30),
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (picked != null) setState(() => _birthDate = picked);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final body = <String, dynamic>{
      'email': _email.text.trim(),
      'password': _password.text,
      'first_name': _firstName.text.trim(),
      'last_name': _lastName.text.trim(),
      if (_phone.text.trim().isNotEmpty) 'phone': _phone.text.trim(),
      if (_birthDate != null) 'date_of_birth': apiDate(_birthDate!),
      // The account's language decides the language of its emails.
      'preferred_language': ref.read(localeControllerProvider).languageCode,
    };
    try {
      await ref.read(authControllerProvider.notifier).register(body);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      showApiError(context, e, inlineFields: _inlineFields);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.authRegisterTitle),
        actions: const [
          Padding(padding: EdgeInsets.only(right: 12), child: LanguageSwitch()),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              TextFormField(
                controller: _firstName,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: l10n.authFirstNameLabel,
                  errorText: fieldError(context, _error, 'first_name'),
                ),
                validator: (v) => validateRequired(l10n, v),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _lastName,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: l10n.authLastNameLabel,
                  errorText: fieldError(context, _error, 'last_name'),
                ),
                validator: (v) => validateRequired(l10n, v),
              ),
              const SizedBox(height: 16),
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
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: l10n.authPhoneLabel,
                  errorText: fieldError(context, _error, 'phone'),
                ),
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: l10n.authBirthDateLabel,
                    errorText: fieldError(context, _error, 'date_of_birth'),
                    suffixIcon: const Icon(Icons.calendar_today),
                  ),
                  child: Text(
                    _birthDate == null ? '' : formatDate(context, _birthDate!),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              PasswordField(
                controller: _password,
                label: l10n.authPasswordLabel,
                autofillHint: AutofillHints.newPassword,
                errorText: fieldError(context, _error, 'password'),
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
                child:
                    _busy
                        ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : Text(l10n.authRegisterButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
