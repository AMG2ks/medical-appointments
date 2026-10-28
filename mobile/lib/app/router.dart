import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/appointments/presentation/appointments_routes.dart';
import '../features/appointments/presentation/screens/appointment_detail_screen.dart';
import '../features/appointments/presentation/screens/appointments_tabs_screen.dart';
import '../features/appointments/presentation/screens/booking_screen.dart';
import '../features/auth/data/models/user.dart';
import '../features/auth/presentation/auth_controller.dart';
import '../features/auth/presentation/screens/change_password_screen.dart';
import '../features/auth/presentation/screens/forgot_password_screen.dart';
import '../features/auth/presentation/screens/login_screen.dart';
import '../features/auth/presentation/screens/profile_screen.dart';
import '../features/auth/presentation/screens/register_screen.dart';
import '../features/auth/presentation/screens/reset_password_screen.dart';
import '../features/auth/presentation/screens/splash_screen.dart';
import '../features/doctors/presentation/screens/availability_screen.dart';
import '../features/doctors/presentation/screens/create_doctor_screen.dart';
import '../features/doctors/presentation/screens/doctor_detail_screen.dart';
import '../features/doctors/presentation/screens/doctor_profile_screen.dart';
import '../features/doctors/presentation/screens/doctors_list_screen.dart';
import '../features/doctors/presentation/screens/specialties_admin_screen.dart';
import '../features/doctors/presentation/screens/time_off_screen.dart';
import '../features/dashboard/presentation/screens/dashboard_screen.dart';
import '../features/notifications/presentation/screens/notifications_screen.dart';
import '../features/users_admin/presentation/users_admin_screen.dart';
import 'shells/admin_shell.dart';
import 'shells/doctor_shell.dart';
import 'shells/patient_shell.dart';

const publicRoutes = [
  '/login',
  '/register',
  '/forgot-password',
  '/reset-password',
];

String homeFor(UserRole role) => '/${role.name}';

bool _inArea(String location, UserRole role) =>
    location == '/${role.name}' || location.startsWith('/${role.name}/');

/// Where a user must be sent (null = stay). Pure, so it is easy to unit test.
/// Client-side routing is UX only: the backend permissions are the real protection.
String? authRedirect(AsyncValue<User?> auth, String location) {
  // Unknown (starting up, or the session check failed): the splash shows loading / retry.
  if (auth.isLoading || auth.hasError) {
    return location == '/splash' ? null : '/splash';
  }
  final user = auth.value;
  if (user == null) {
    return publicRoutes.contains(location) ? null : '/login';
  }
  if (publicRoutes.contains(location) || location == '/splash') {
    return homeFor(user.role);
  }
  final inOtherArea = UserRole.values.any(
    (role) => role != user.role && _inArea(location, role),
  );
  return inOtherArea ? homeFor(user.role) : null;
}

final routerProvider = Provider<GoRouter>((ref) {
  // Re-evaluate the redirect whenever the auth state changes.
  final refresh = ValueNotifier<int>(0);
  ref.listen(authControllerProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  // The booking flow lives on the root navigator, above the tab bar: it is a modal flow with
  // no tab of its own. Pushed inside the Doctors tab, it was still animating out in a hidden
  // (never laid out) tab navigator when `go` switched to the Appointments tab.
  final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect:
        (context, state) => authRedirect(
          ref.read(authControllerProvider),
          state.matchedLocation,
        ),
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, _) => const RegisterScreen()),
      GoRoute(
        path: '/forgot-password',
        builder: (_, _) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: '/reset-password',
        builder:
            (_, state) => ResetPasswordScreen(
              email: state.uri.queryParameters['email'] ?? '',
            ),
      ),
      GoRoute(
        path: '/change-password',
        builder: (_, _) => const ChangePasswordScreen(),
      ),
      // Role areas. Each module adds its tabs (branches) in its own PR.
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => PatientShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/patient',
                builder:
                    (_, _) => DoctorsListScreen(
                      detailPath: (id) => '/patient/doctors/$id',
                    ),
                routes: [
                  GoRoute(
                    path: 'doctors/:id',
                    builder:
                        (_, state) => DoctorDetailScreen(
                          doctorId: int.parse(state.pathParameters['id']!),
                          canBook: true,
                        ),
                    routes: [
                      // Opened by `bookingRoute(doctorId)`.
                      GoRoute(
                        path: 'book',
                        parentNavigatorKey: rootNavigatorKey,
                        builder:
                            (_, state) => BookingScreen(
                              doctorId: int.parse(state.pathParameters['id']!),
                            ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/patient/appointments',
                builder:
                    (_, _) => const MyAppointmentsScreen(
                      detailPath: patientAppointmentRoute,
                    ),
                routes: [
                  GoRoute(
                    path: ':id',
                    builder:
                        (_, state) => AppointmentDetailScreen(
                          appointmentId: int.parse(state.pathParameters['id']!),
                        ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/patient/notifications',
                builder: (_, _) => const NotificationsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/patient/profile',
                builder: (_, _) => const ProfileScreen(),
              ),
            ],
          ),
        ],
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => DoctorShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/doctor',
                builder:
                    (_, _) => const DoctorAgendaScreen(
                      detailPath: doctorAppointmentRoute,
                    ),
                routes: [
                  GoRoute(
                    path: 'appointments/:id',
                    builder:
                        (_, state) => AppointmentDetailScreen(
                          appointmentId: int.parse(state.pathParameters['id']!),
                        ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/doctor/availability',
                builder:
                    (_, _) => const AvailabilityScreen(
                      timeOffPath: '/doctor/availability/time-off',
                    ),
                routes: [
                  GoRoute(
                    path: 'time-off',
                    builder: (_, _) => const TimeOffScreen(),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/doctor/practice',
                builder: (_, _) => const DoctorProfileScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/doctor/notifications',
                builder: (_, _) => const NotificationsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/doctor/profile',
                builder: (_, _) => const ProfileScreen(),
              ),
            ],
          ),
        ],
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AdminShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/admin',
                builder: (_, _) => const DashboardScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/admin/users',
                builder: (_, _) => const UsersAdminScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/admin/doctors',
                builder:
                    (_, _) => DoctorsListScreen(
                      detailPath: (id) => '/admin/doctors/$id',
                      createPath: '/admin/doctors/new',
                    ),
                routes: [
                  // 'new' before ':id' so it is not read as a doctor id.
                  GoRoute(
                    path: 'new',
                    builder: (_, _) => const CreateDoctorScreen(),
                  ),
                  GoRoute(
                    path: ':id',
                    builder:
                        (_, state) => DoctorDetailScreen(
                          doctorId: int.parse(state.pathParameters['id']!),
                        ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/admin/specialties',
                builder: (_, _) => const SpecialtiesAdminScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/admin/profile',
                builder: (_, _) => const ProfileScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
