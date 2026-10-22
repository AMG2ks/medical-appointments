import '../../../../core/utils/date_format.dart';

enum UserRole {
  patient,
  doctor,
  admin;

  static UserRole fromJson(String value) =>
      UserRole.values.firstWhere((r) => r.name == value);
}

class PatientProfile {
  const PatientProfile({this.dateOfBirth});

  final DateTime? dateOfBirth;

  factory PatientProfile.fromJson(Map<String, dynamic> json) {
    final raw = json['date_of_birth'] as String?;
    return PatientProfile(
      dateOfBirth: raw == null ? null : DateTime.parse(raw),
    );
  }

  /// Dates travel as `YYYY-MM-DD`.
  Map<String, dynamic> toJson() => {
    'date_of_birth': dateOfBirth == null ? null : apiDate(dateOfBirth!),
  };
}

/// `UserOut` of the API.
class User {
  const User({
    required this.id,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.phone,
    required this.role,
    required this.preferredLanguage,
    required this.isActive,
    required this.dateJoined,
    this.patientProfile,
  });

  final int id;
  final String email;
  final String firstName;
  final String lastName;
  final String phone;
  final UserRole role;
  final String preferredLanguage;
  final bool isActive;
  final DateTime dateJoined;
  final PatientProfile? patientProfile;

  String get fullName => '$firstName $lastName'.trim();

  factory User.fromJson(Map<String, dynamic> json) {
    final profile = json['patient_profile'] as Map<String, dynamic>?;
    return User(
      id: json['id'] as int,
      email: json['email'] as String,
      firstName: json['first_name'] as String,
      lastName: json['last_name'] as String,
      phone: json['phone'] as String,
      role: UserRole.fromJson(json['role'] as String),
      preferredLanguage: json['preferred_language'] as String,
      isActive: json['is_active'] as bool,
      dateJoined: DateTime.parse(json['date_joined'] as String),
      patientProfile: profile == null ? null : PatientProfile.fromJson(profile),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'first_name': firstName,
    'last_name': lastName,
    'phone': phone,
    'role': role.name,
    'preferred_language': preferredLanguage,
    'is_active': isActive,
    'date_joined': dateJoined.toIso8601String(),
    'patient_profile': patientProfile?.toJson(),
  };
}
