import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ta_app/services/background_service.dart';
import 'package:ta_app/services/notification_service.dart';
import 'package:ta_app/screens/home_page_screen.dart';

Future<void> main() async {
  print('🚀 App starting...');
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // Inisialisasi semua permission yang diperlukan
    print('🔐 Requesting permissions...');
    await _requestPermissions();
    print('✅ Permissions handled');

    // Inisialisasi notification service
    print('📱 Initializing notification service...');
    await NotificationService.initialize();
    print('✅ Notification service initialized');

    // Inisialisasi background service
    print('⚙️ Initializing background service...');
    await BackgroundService.initialize();
    print('✅ Background service initialized');

    print('🎉 App initialization completed successfully');
  } catch (e, stackTrace) {
    print('💥 App initialization failed: $e');
    print('StackTrace: $stackTrace');
  }

  runApp(const MyApp());
}

Future<void> _requestPermissions() async {
  try {
    // Request notification permission
    print('📢 Requesting notification permission...');
    final notificationStatus = await Permission.notification.request();
    print('Notification permission: $notificationStatus');

    // Request permission untuk background app refresh (iOS)
    if (await Permission.backgroundRefresh.isDenied) {
      print('🔄 Requesting background refresh permission...');
      final backgroundStatus = await Permission.backgroundRefresh.request();
      print('Background refresh permission: $backgroundStatus');
    }

    // Request permission untuk disable battery optimization (Android)
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      print('🔋 Requesting ignore battery optimization permission...');
      final batteryStatus =
          await Permission.ignoreBatteryOptimizations.request();
      print('Battery optimization permission: $batteryStatus');
    }

    // Request exact alarm permission (Android 12+)
    if (await Permission.scheduleExactAlarm.isDenied) {
      print('⏰ Requesting exact alarm permission...');
      final alarmStatus = await Permission.scheduleExactAlarm.request();
      print('Exact alarm permission: $alarmStatus');
    }

    // Request system alert window permission (untuk full screen notification)
    if (await Permission.systemAlertWindow.isDenied) {
      print('🪟 Requesting system alert window permission...');
      final alertStatus = await Permission.systemAlertWindow.request();
      print('System alert window permission: $alertStatus');
    }

    print('✅ All permissions requested');
  } catch (e) {
    print('❌ Error requesting permissions: $e');
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    print('📱 MyApp initState called');
    WidgetsBinding.instance.addObserver(this);

    // Start background service setelah app dimulai
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startBackgroundService();
    });
  }

  @override
  void dispose() {
    print('🗑️ MyApp disposing...');
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    print('🔄 App lifecycle changed to: $state');

    switch (state) {
      case AppLifecycleState.resumed:
        print('📱 App resumed - ensuring background service is running');
        _startBackgroundService();
        break;
      case AppLifecycleState.paused:
        print('⏸️ App paused - ensuring background service continues');
        _ensureBackgroundServiceRunning();
        break;
      case AppLifecycleState.inactive:
        print('😴 App inactive');
        break;
      case AppLifecycleState.detached:
        print('🔌 App detached - ensuring background service continues');
        _ensureBackgroundServiceRunning();
        break;
      case AppLifecycleState.hidden:
        print('👻 App hidden');
        break;
    }
  }

  Future<void> _startBackgroundService() async {
    try {
      print('🚀 Starting background service...');
      await BackgroundService.startPeriodicEnergyCheck();
      print('✅ Background service started successfully');

      // Test notification untuk memastikan notifikasi berfungsi
      print('🧪 Testing notification system...');
      // await _testNotificationSystem();

      // Test background task immediately
      print('🧪 Running test background task...');
      await BackgroundService.testBackgroundTask();
    } catch (e, stackTrace) {
      print('💥 Error starting background service: $e');
      print('StackTrace: $stackTrace');
    }
  }

  Future<void> _ensureBackgroundServiceRunning() async {
    try {
      print('🔧 Ensuring background service is running...');

      // Restart service untuk memastikan tetap aktif
      await BackgroundService.stopPeriodicEnergyCheck();
      await Future.delayed(const Duration(seconds: 2));
      await BackgroundService.startPeriodicEnergyCheck();

      print('✅ Background service ensured to be running');
    } catch (e, stackTrace) {
      print('💥 Error ensuring background service: $e');
      print('StackTrace: $stackTrace');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PMM Energy Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.indigo,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.indigo,
            foregroundColor: Colors.white,
            elevation: 2,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ),
      home: const HomePageScreen(),
    );
  }
}
