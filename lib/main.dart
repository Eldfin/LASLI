import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'src/measurement_controller.dart';
import 'src/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isIOS) {
    try {
      await FlutterBluePlus.setOptions(
        showPowerAlert: true,
        restoreState: true,
      );
    } catch (_) {
      // The app remains usable if iOS cannot initialize Bluetooth yet.
    }
  }
  FlutterBluePlus.setOperationQueueMode(OperationQueueMode.perDevice);
  runApp(const LasliApp());
}

class LasliApp extends StatelessWidget {
  const LasliApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LASLI',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6EA8FF),
          brightness: Brightness.dark,
          surface: const Color(0xFF07111F),
        ).copyWith(
          primary: const Color(0xFF7AA7FF),
          secondary: const Color(0xFF5EE0B5),
          surface: const Color(0xFF07111F),
          surfaceContainerHighest: const Color(0xFF13243A),
          outlineVariant: const Color(0xFF2B405C),
        ),
        scaffoldBackgroundColor: const Color(0xFF07111F),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B1728),
          foregroundColor: Color(0xFFE8EEF9),
          elevation: 0,
          centerTitle: false,
        ),
        tabBarTheme: const TabBarThemeData(
          indicatorColor: Color(0xFF7AA7FF),
          labelColor: Color(0xFFE8EEF9),
          unselectedLabelColor: Color(0xFF8EA3BE),
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFF0F1D31),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
        useMaterial3: true,
      ),
      home: const LasliHomePage(),
    );
  }
}

class LasliHomePage extends StatefulWidget {
  const LasliHomePage({super.key});

  @override
  State<LasliHomePage> createState() => _LasliHomePageState();
}

class _LasliHomePageState extends State<LasliHomePage>
    with WidgetsBindingObserver {
  late final MeasurementController controller;

  @override
  void initState() {
    super.initState();
    controller = MeasurementController();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(controller.requestInitialPlatformPermissions());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(controller.handleAppLifecycleState(state));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return LasliDashboard(controller: controller);
      },
    );
  }
}
