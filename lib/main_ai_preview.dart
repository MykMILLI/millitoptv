import 'package:flutter/material.dart';
import 'features/millitop_ai/ai_screen.dart';
import 'features/millitop_ai/ai_service.dart';
import 'features/millitop_ai/backend_ai_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AiPreviewApp());
}

class AiPreviewApp extends StatelessWidget {
  const AiPreviewApp({super.key});

  static final AiService _service = BackendAiService.pairedDevice();

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MILLITOP AI Live Preview',
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: const Color(0xFF6AE2C1),
    ),
    home: MillitopAiScreen(
      profileId: 'local-preview',
      service: _service,
      demoMode: false,
    ),
  );
}
