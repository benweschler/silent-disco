import 'package:flutter/material.dart';
import 'diagnostics.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Silent Disco LAN',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff5743c6)),
      useMaterial3: true,
    ),
    home: const DiagnosticsScreen(isHost: false),
  );
}
