import '../../../appointments/data/models/appointment.dart';

/// Users of one role: how many accounts, how many of them are active.
class UserCounts {
  const UserCounts({required this.total, required this.active});

  final int total;
  final int active;

  factory UserCounts.fromJson(Map<String, dynamic> json) =>
      UserCounts(total: json['total'] as int, active: json['active'] as int);
}

/// `GET dashboard/stats/` (admin). `today` / `thisWeek` count appointments starting then in
/// the clinic's time zone; [byStatus] covers all appointments ever.
class DashboardStats {
  const DashboardStats({
    required this.patients,
    required this.doctors,
    required this.appointmentsTotal,
    required this.appointmentsToday,
    required this.appointmentsThisWeek,
    required this.byStatus,
  });

  final UserCounts patients;
  final UserCounts doctors;
  final int appointmentsTotal;
  final int appointmentsToday;
  final int appointmentsThisWeek;
  final Map<AppointmentStatus, int> byStatus;

  factory DashboardStats.fromJson(Map<String, dynamic> json) {
    final appointments = json['appointments'] as Map<String, dynamic>;
    final byStatus = appointments['by_status'] as Map<String, dynamic>;
    return DashboardStats(
      patients: UserCounts.fromJson(json['patients'] as Map<String, dynamic>),
      doctors: UserCounts.fromJson(json['doctors'] as Map<String, dynamic>),
      appointmentsTotal: appointments['total'] as int,
      appointmentsToday: appointments['today'] as int,
      appointmentsThisWeek: appointments['this_week'] as int,
      byStatus: {
        for (final status in AppointmentStatus.values)
          if (status != AppointmentStatus.unknown)
            status: (byStatus[status.apiValue] as int?) ?? 0,
      },
    );
  }
}
