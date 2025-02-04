import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flipsy/features/auth/bloc/auth_bloc.dart';
import 'package:flipsy/features/auth/screens/login_screen.dart';
import 'package:flipsy/features/auth/screens/signup_screen.dart';
import 'package:flipsy/services/auth_service.dart';
import 'package:flipsy/firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    print('Initializing Firebase...');
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    print('Firebase initialized successfully');
  } catch (e) {
    print('Error initializing Firebase: $e');
    if (!e.toString().contains('duplicate-app')) {
      rethrow;
    }
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<AuthService>(
          create: (context) => AuthService(),
        ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<AuthBloc>(
            create: (context) => AuthBloc(
              authService: context.read<AuthService>(),
            ),
          ),
        ],
        child: MaterialApp(
          title: 'Flipsy',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
            useMaterial3: true,
          ),
          home: BlocBuilder<AuthBloc, AuthState>(
            builder: (context, state) {
              if (state is AuthLoading) {
                return const Scaffold(
                  body: Center(
                    child: CircularProgressIndicator(),
                  ),
                );
              }

              if (state is Authenticated) {
                return Scaffold(
                  appBar: AppBar(
                    title: const Text('Flipsy'),
                    actions: [
                      IconButton(
                        icon: const Icon(Icons.logout),
                        onPressed: () {
                          context.read<AuthBloc>().add(SignOutRequested());
                        },
                        tooltip: 'Logout',
                      ),
                    ],
                  ),
                  body: const Center(
                    child: Text('Authenticated! Main app coming soon...'),
                  ),
                );
              }

              return const LoginScreen();
            },
          ),
        ),
      ),
    );
  }
}
