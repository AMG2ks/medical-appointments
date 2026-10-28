import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/config/constants.dart';
import '../../../../core/l10n/error_text.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/widgets/async_value_view.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../../auth/presentation/screens/form_validators.dart';
import '../../data/doctors_repository.dart';
import '../doctors_providers.dart';
import 'doctor_profile_screen.dart' show validateMinutes;
import 'doctor_texts.dart';

/// Admin: create a doctor. The server emails an invite code so the doctor can set a password.
class CreateDoctorScreen extends ConsumerStatefulWidget {
  const CreateDoctorScreen({super.key});

  @override
  ConsumerState<CreateDoctorScreen> createState() => _CreateDoctorScreenState();
}

class _CreateDoctorScreenState extends ConsumerState<CreateDoctorScreen> {
  static const _inlineFields = {
    'email',
    'first_name',
    'last_name',
    'phone',
    'specialty_id',
    'consultation_minutes',
    'bio',
    'preferred_language',
  };

  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _phone = TextEditingController();
  final _minutes = TextEditingController(text: '30');
  final _bio = TextEditingController();
  int? _specialtyId;
  String _language = supportedLanguageCodes.first;
  bool _busy = false;
  ApiException? _error;

  @override
  void dispose() {
    for (final c in [_email, _firstName, _lastName, _phone, _minutes, _bio]) {
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
          .read(doctorsRepositoryProvider)
          .createDoctor(
            email: _email.text.trim(),
            firstName: _firstName.text.trim(),
            lastName: _lastName.text.trim(),
            phone: _phone.text.trim(),
            preferredLanguage: _language,
            specialtyId: _specialtyId!,
            consultationMinutes: int.parse(_minutes.text.trim()),
            bio: _bio.text.trim(),
          );
      ref.invalidate(doctorsListProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).doctorsCreated)),
      );
      context.pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _busy = false;
      });
      showApiError(context, e, inlineFields: _inlineFields);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final specialtiesAsync = ref.watch(specialtiesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.doctorsCreateTitle)),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(l10n.doctorsCreateInfo),
              const SizedBox(height: 16),
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
                controller: _firstName,
                decoration: InputDecoration(
                  labelText: l10n.authFirstNameLabel,
                  errorText: fieldError(context, _error, 'first_name'),
                ),
                validator: (v) => validateRequired(l10n, v),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _lastName,
                decoration: InputDecoration(
                  labelText: l10n.authLastNameLabel,
                  errorText: fieldError(context, _error, 'last_name'),
                ),
                validator: (v) => validateRequired(l10n, v),
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
              DropdownButtonFormField<String>(
                value: _language,
                decoration: InputDecoration(
                  labelText: l10n.doctorsLanguageLabel,
                  errorText: fieldError(context, _error, 'preferred_language'),
                ),
                items: [
                  DropdownMenuItem(value: 'fr', child: Text(l10n.languageFr)),
                  DropdownMenuItem(value: 'en', child: Text(l10n.languageEn)),
                ],
                onChanged: (v) => setState(() => _language = v ?? _language),
              ),
              const SizedBox(height: 16),
              // Loading / error with retry: an empty dropdown would hide a failed load.
              AsyncValueView(
                value: specialtiesAsync,
                onRetry: () => ref.invalidate(specialtiesProvider),
                data:
                    (specialties) => DropdownButtonFormField<int>(
                      value: _specialtyId,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.doctorsSpecialtyLabel,
                        errorText: fieldError(context, _error, 'specialty_id'),
                      ),
                      items: [
                        for (final s in specialties)
                          DropdownMenuItem(
                            value: s.id,
                            child: Text(specialtyName(context, s)),
                          ),
                      ],
                      validator:
                          (v) => v == null ? l10n.validationRequired : null,
                      onChanged: (v) => setState(() => _specialtyId = v),
                    ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _minutes,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l10n.doctorsMinutesLabel,
                  errorText: fieldError(
                    context,
                    _error,
                    'consultation_minutes',
                  ),
                ),
                validator: (v) => validateMinutes(l10n, v),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _bio,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: l10n.doctorsBioLabel,
                  alignLabelWithHint: true,
                  errorText: fieldError(context, _error, 'bio'),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(l10n.doctorsCreateButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
