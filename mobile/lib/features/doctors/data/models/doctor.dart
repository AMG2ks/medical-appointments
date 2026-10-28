import 'specialty.dart';

/// A doctor card. `id` is the user id. [email] and [phone] are only filled for the doctor's
/// own profile and for the admin's create answer; the public card has neither.
class Doctor {
  const Doctor({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.specialty,
    required this.bio,
    required this.consultationMinutes,
    this.email,
    this.phone,
    this.invitePending = false,
  });

  final int id;
  final String firstName;
  final String lastName;
  final Specialty specialty;
  final String bio;
  final int consultationMinutes;
  final String? email;
  final String? phone;

  /// Admin only: the doctor has not set a password with the invite code yet.
  final bool invitePending;

  String get fullName => '$firstName $lastName'.trim();

  factory Doctor.fromJson(Map<String, dynamic> json) => Doctor(
    id: json['id'] as int,
    firstName: json['first_name'] as String,
    lastName: json['last_name'] as String,
    specialty: Specialty.fromJson(json['specialty'] as Map<String, dynamic>),
    bio: (json['bio'] as String?) ?? '',
    consultationMinutes: json['consultation_minutes'] as int,
    email: json['email'] as String?,
    phone: json['phone'] as String?,
    invitePending: (json['invite_pending'] as bool?) ?? false,
  );
}
