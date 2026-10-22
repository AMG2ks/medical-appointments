import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/utils/date_format.dart';
import '../../../../core/widgets/language_switch.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../data/models/user.dart';
import '../auth_controller.dart';
import 'form_validators.dart';

String roleLabel(AppLocalizations l10n, UserRole role) => switch (role) {
  UserRole.patient => l10n.roleOptionPatient,
  UserRole.doctor => l10n.roleOptionDoctor,
  UserRole.admin => l10n.roleOptionAdmin,
};

/// Used by the profile tab of the three role areas.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  static const _inlineFields = {
    'first_name',
    'last_name',
    'phone',
    'patient_profile.date_of_birth',
  };

  final _formKey = GlobalKey<FormState>();
  late final User _user = ref.read(currentUserProvider)!;
  late final _firstName = TextEditingController(text: _user.firstName);
  late final _lastName = TextEditingController(text: _user.lastName);
  late final _phone = TextEditingController(text: _user.phone);
  late DateTime? _birthDate = _user.patientProfile?.dateOfBirth;
  bool _busy = false;
  ApiException? _error;

  @override
  void dispose() {
    for (final c in [_firstName, _lastName, _phone]) {
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

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final patch = <String, dynamic>{
      'first_name': _firstName.text.trim(),
      'last_name': _lastName.text.trim(),
      'phone': _phone.text.trim(),
      if (_user.role == UserRole.patient)
        'patient_profile': PatientProfile(dateOfBirth: _birthDate).toJson(),
    };
    try {
      await ref.read(authControllerProvider.notifier).updateProfile(patch);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).profileSaved)),
      );
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
    // Re-read so a language change made elsewhere does not leave stale data.
    final user = ref.watch(currentUserProvider) ?? _user;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.profileTitle)),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(user.email),
                subtitle: Text(roleLabel(l10n, user.role)),
              ),
              const SizedBox(height: 8),
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
              if (user.role == UserRole.patient) ...[
                const SizedBox(height: 16),
                InkWell(
                  onTap: _pickDate,
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: l10n.authBirthDateLabel,
                      errorText: fieldError(
                        context,
                        _error,
                        'patient_profile.date_of_birth',
                      ),
                      suffixIcon: const Icon(Icons.calendar_today),
                    ),
                    child: Text(
                      _birthDate == null
                          ? ''
                          : formatDate(context, _birthDate!),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: Text(l10n.profileSaveButton),
              ),
              const Divider(height: 40),
              Text(
                l10n.profileLanguage,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerLeft,
                child: LanguageSwitch(),
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () => context.push('/change-password'),
                child: Text(l10n.authChangePasswordTitle),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed:
                    () => ref.read(authControllerProvider.notifier).logout(),
                child: Text(l10n.profileLogoutButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
