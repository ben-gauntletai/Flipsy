import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flipsy/features/auth/bloc/auth_bloc.dart';
import 'package:flipsy/features/auth/screens/login_screen.dart';
import 'package:flipsy/services/auth_service.dart';
import 'package:flipsy/firebase_options.dart';
import 'package:flipsy/features/navigation/screens/main_navigation_screen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'services/config_service.dart';
import 'package:firebase_app_check/firebase_app_check.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize environment variables
  await ConfigService().init();

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

  // Initialize AppCheck
  await FirebaseAppCheck.instance.activate(
    webProvider: ReCaptchaV3Provider('your-recaptcha-v3-site-key'),
    androidProvider: AndroidProvider.debug,
    appleProvider: AppleProvider.debug,
  );

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
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
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
                return const MainNavigationScreen();
              }

              return const LoginScreen();
            },
          ),
        ),
      ),
    );
  }
}
