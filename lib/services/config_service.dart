import 'package:flutter_dotenv/flutter_dotenv.dart';

class ConfigService {
  static final ConfigService _instance = ConfigService._internal();
  factory ConfigService() => _instance;

  ConfigService._internal();

  Future<void> init() async {
    await dotenv.load(fileName: ".env");
  }

  String get openAIApiKey => dotenv.env['OPENAI_API_KEY'] ?? '';
}
