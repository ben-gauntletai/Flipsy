import 'dart:async';
import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flipsy/features/auth/models/user_model.dart';
import 'package:flipsy/services/auth_service.dart';

// Events
abstract class AuthEvent extends Equatable {
  const AuthEvent();

  @override
  List<Object?> get props => [];
}

class AuthCheckRequested extends AuthEvent {}

class SignInRequested extends AuthEvent {
  final String email;
  final String password;

  const SignInRequested(this.email, this.password);

  @override
  List<Object?> get props => [email, password];
}

class SignUpRequested extends AuthEvent {
  final String email;
  final String password;
  final String displayName;

  const SignUpRequested(this.email, this.password, this.displayName);

  @override
  List<Object?> get props => [email, password, displayName];
}

class SignOutRequested extends AuthEvent {}

class ProfileUpdateRequested extends AuthEvent {
  final String userId;
  final Map<String, dynamic> data;

  const ProfileUpdateRequested(this.userId, this.data);

  @override
  List<Object?> get props => [userId, data];
}

// States
abstract class AuthState extends Equatable {
  const AuthState();

  @override
  List<Object?> get props => [];
}

class AuthInitial extends AuthState {}

class AuthLoading extends AuthState {}

class Authenticated extends AuthState {
  final UserModel user;

  const Authenticated(this.user);

  @override
  List<Object?> get props => [user];
}

class Unauthenticated extends AuthState {}

class AuthError extends AuthState {
  final String message;

  const AuthError(this.message);

  @override
  List<Object?> get props => [message];
}

// Bloc
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final AuthService _authService;
  StreamSubscription<User?>? _authStateSubscription;

  AuthBloc({required AuthService authService})
      : _authService = authService,
        super(AuthInitial()) {
    on<AuthCheckRequested>(_onAuthCheckRequested);
    on<SignInRequested>(_onSignInRequested);
    on<SignUpRequested>(_onSignUpRequested);
    on<SignOutRequested>(_onSignOutRequested);
    on<ProfileUpdateRequested>(_onProfileUpdateRequested);

    // Listen to auth state changes
    _authStateSubscription = _authService.authStateChanges.listen((user) async {
      if (user != null) {
        try {
          print('AuthBloc: User authenticated with uid: ${user.uid}');

          // Only load profile if we're not already authenticated
          if (state is! Authenticated) {
            print('AuthBloc: Loading user profile');
            final userProfile = await _authService.getUserProfile(user.uid);

            if (userProfile != null) {
              print('AuthBloc: User profile loaded successfully');
              emit(Authenticated(userProfile));
            } else {
              print('AuthBloc: User profile not found for uid: ${user.uid}');
              // If no profile exists, sign out and show error
              await _authService.signOut();
              emit(const AuthError(
                  'Profile not found. Please try signing in again.'));
            }
          } else {
            print('AuthBloc: Already authenticated, skipping profile load');
          }
        } catch (e) {
          print('AuthBloc: Error loading user profile: $e');
          // If there's an error loading the profile, sign out and show error
          await _authService.signOut();
          emit(const AuthError(
              'Error loading profile. Please try signing in again.'));
        }
      } else {
        print('AuthBloc: No authenticated user');
        if (state is! AuthLoading) {
          emit(Unauthenticated());
        }
      }
    });

    // Check initial auth state
    add(AuthCheckRequested());
  }

  Future<void> _onAuthCheckRequested(
    AuthCheckRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(AuthLoading());
    final currentUser = _authService.currentUser;
    if (currentUser != null) {
      await _loadUserProfile(currentUser.uid);
    } else {
      emit(Unauthenticated());
    }
  }

  Future<void> _onSignInRequested(
    SignInRequested event,
    Emitter<AuthState> emit,
  ) async {
    print('AuthBloc: Starting sign in request');
    emit(AuthLoading());
    try {
      await _authService.signInWithEmailAndPassword(
        email: event.email,
        password: event.password,
      );
      print('AuthBloc: Sign in successful');
      // The auth state listener will handle the state update
    } catch (e) {
      print('AuthBloc: Sign in error caught: ${e.toString()}');
      String errorMessage = e.toString().toLowerCase();
      if (errorMessage.contains('recaptcha') ||
          errorMessage.contains('incorrect') ||
          errorMessage.contains('malformed') ||
          errorMessage.contains('invalid')) {
        print('AuthBloc: Emitting invalid credentials error');
        emit(const AuthError('Invalid email or password'));
      } else {
        print('AuthBloc: Emitting general error');
        emit(AuthError(errorMessage));
      }
    }
  }

  Future<void> _onSignUpRequested(
    SignUpRequested event,
    Emitter<AuthState> emit,
  ) async {
    print('AuthBloc: Starting sign up request');
    emit(AuthLoading());

    try {
      print('AuthBloc: Creating user with email: ${event.email}');
      final userProfile = await _authService.signUpWithEmailAndPassword(
        email: event.email,
        password: event.password,
        displayName: event.displayName,
      );
      print('AuthBloc: User created successfully');
      emit(Authenticated(userProfile));
    } catch (e) {
      print('AuthBloc: Error in signup: $e');
      String errorMessage = e.toString().toLowerCase();

      if (errorMessage.contains('already in use') ||
          errorMessage.contains('already-exists')) {
        emit(const AuthError('This email is already registered'));
      } else if (errorMessage.contains('weak-password')) {
        emit(const AuthError('Please choose a stronger password'));
      } else if (errorMessage.contains('invalid-email')) {
        emit(const AuthError('Please enter a valid email address'));
      } else if (errorMessage.contains('display name') ||
          errorMessage.contains('already taken')) {
        // Pass through the original error message for display name issues
        emit(AuthError(e.toString().replaceAll('Exception: ', '')));
      } else {
        emit(const AuthError(
            'An error occurred during signup. Please try again.'));
      }
    }
  }

  Future<void> _onSignOutRequested(
    SignOutRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(AuthLoading());
    try {
      await _authService.signOut();
      emit(Unauthenticated());
    } catch (e) {
      emit(AuthError(e.toString()));
    }
  }

  Future<void> _onProfileUpdateRequested(
    ProfileUpdateRequested event,
    Emitter<AuthState> emit,
  ) async {
    try {
      await _authService.updateUserProfile(event.userId, event.data);
      final updatedProfile = await _authService.getUserProfile(event.userId);
      if (updatedProfile != null) {
        emit(Authenticated(updatedProfile));
      }
    } catch (e) {
      emit(AuthError(e.toString()));
    }
  }

  Future<void> _loadUserProfile(String userId) async {
    try {
      final userProfile = await _authService.getUserProfile(userId);
      if (userProfile != null) {
        emit(Authenticated(userProfile));
      } else {
        emit(Unauthenticated());
      }
    } catch (e) {
      emit(AuthError(e.toString()));
    }
  }

  @override
  Future<void> close() {
    _authStateSubscription?.cancel();
    return super.close();
  }
}
