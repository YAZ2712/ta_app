// lib/services/background_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    print('🔄 Background task started: $task at ${DateTime.now()}');

    try {
      switch (task) {
        case 'checkEnergyLimit':
        case 'checkEnergyLimitFrequent':
          await _checkEnergyLimitInBackground();
          break;
        default:
          print('⚠️ Unknown task: $task');
      }

      print('✅ Background task completed successfully: $task');
      return Future.value(true);
    } catch (e, stackTrace) {
      print('💥 Background task failed: $task');
      print('Error: $e');
      print('StackTrace: $stackTrace');
      return Future.value(false);
    }
  });
}

Future<void> _checkEnergyLimitInBackground() async {
  print('🌐 Starting energy limit check...');

  try {
    print('📡 Making HTTP request to Antares API...');

    final response = await http
        .get(
          Uri.parse(
            'https://platform.antares.id:8443/~/antares-cse/antares-id/TADKT-1/PMM/la',
          ),
          headers: {
            'X-M2M-Origin': 'fe5c7a15d8c13220:bfd764392a99a094',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 15));

    print('📊 HTTP Response Status: ${response.statusCode}');

    if (response.statusCode == 200) {
      print('✅ API response received successfully');

      try {
        final data = jsonDecode(response.body);
        print('📄 Raw API response: ${response.body}');

        if (data['m2m:cin']?['con'] != null) {
          dynamic conData = data['m2m:cin']['con'];
          Map<String, dynamic> deviceData;

          if (conData is String) {
            print('🔄 Parsing JSON string content...');
            deviceData = jsonDecode(conData);
          } else if (conData is Map) {
            print('🔄 Using Map content directly...');
            deviceData = Map<String, dynamic>.from(conData);
          } else {
            print('❌ Unexpected content type: ${conData.runtimeType}');
            return;
          }

          print('📊 Device data: $deviceData');

          // Baca data energi untuk informasi notifikasi
          double dailyEnergy =
              double.tryParse(deviceData['DailyEnergy']?.toString() ?? '0') ??
              0.0;
          double energyLimit =
              double.tryParse(deviceData['energyLimit2']?.toString() ?? '0') ??
              0.0;

          // Baca status flag dari Antares
          int statusLimit80 =
              int.tryParse(deviceData['statusLimit80']?.toString() ?? '0') ?? 0;
          int statusLimit90 =
              int.tryParse(deviceData['statusLimit90']?.toString() ?? '0') ?? 0;

          print('⚡ Daily Energy: $dailyEnergy kWh');
          print('🎯 Energy Limit: $energyLimit kWh');
          print('🚩 Status Limit 80%: $statusLimit80');
          print('🚩 Status Limit 90%: $statusLimit90');

          // Hitung persentase untuk informasi
          double percentage = 0.0;
          if (energyLimit > 0) {
            percentage = (dailyEnergy / energyLimit * 100);
            print('📈 Percentage: ${percentage.toStringAsFixed(2)}%');
          }

          // Simpan data untuk tracking perubahan
          await _saveEnergyData(
            dailyEnergy,
            energyLimit,
            percentage,
            statusLimit80,
            statusLimit90,
          );

          // Cek apakah perlu mengirim notifikasi berdasarkan status flag
          bool shouldNotify = await _shouldSendNotificationByStatus(
            statusLimit80,
            statusLimit90,
          );
          print('🔔 Should send notification: $shouldNotify');

          if (shouldNotify) {
            try {
              print('🔔 Preparing to send notification...');

              // Tentukan level notifikasi berdasarkan status flag
              int notificationLevel = _determineNotificationLevel(
                statusLimit80,
                statusLimit90,
              );
              print('   Notification Level: $notificationLevel');
              print('   Percentage: ${percentage.toStringAsFixed(2)}%');
              print('   Daily Energy: ${dailyEnergy.toStringAsFixed(4)} kWh');
              print('   Energy Limit: ${energyLimit.toStringAsFixed(4)} kWh');

              // Kirim notifikasi berdasarkan level
              await _initializeAndSendNotificationByStatus(
                notificationLevel: notificationLevel,
                percentage: percentage,
                dailyEnergy: dailyEnergy,
                energyLimit: energyLimit,
                statusLimit80: statusLimit80,
                statusLimit90: statusLimit90,
              );

              print('✅ Notification sent successfully');
            } catch (notificationError) {
              print('❌ Failed to send notification: $notificationError');
            }
          }

          // Jika status 90% aktif, aktifkan pengecekan lebih sering
          if (statusLimit90 == 1) {
            print('🔄 Enabling frequent check (90% status active)');
            await _enableFrequentCheck();
          } else if (statusLimit80 == 0 && statusLimit90 == 0) {
            print('⏸️ Disabling frequent check (all status inactive)');
            await _disableFrequentCheck();
          }
        } else {
          print('❌ No content found in API response');
        }
      } catch (parseError) {
        print('❌ Error parsing API response: $parseError');
      }
    } else {
      print('❌ API request failed with status: ${response.statusCode}');
      print('Response body: ${response.body}');
    }
  } catch (e, stackTrace) {
    print('💥 Network or general error in background task: $e');
    print('StackTrace: $stackTrace');
  }
}

// Fungsi untuk menentukan level notifikasi berdasarkan status flag
int _determineNotificationLevel(int statusLimit80, int statusLimit90) {
  if (statusLimit90 == 1) {
    return 90; // Prioritas tertinggi
  } else if (statusLimit80 == 1) {
    return 80;
  }
  return 0; // Tidak ada notifikasi
}

// Fungsi untuk cek apakah perlu kirim notifikasi berdasarkan status flag
Future<bool> _shouldSendNotificationByStatus(
  int statusLimit80,
  int statusLimit90,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final lastStatusLimit80 = prefs.getInt('last_status_limit_80') ?? 0;
    final lastStatusLimit90 = prefs.getInt('last_status_limit_90') ?? 0;
    final lastNotificationTime = prefs.getInt('last_notification_time') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    print('🔍 Checking notification conditions by status:');
    print('   Current Status 80%: $statusLimit80 (Last: $lastStatusLimit80)');
    print('   Current Status 90%: $statusLimit90 (Last: $lastStatusLimit90)');
    print(
      '   Last notification: ${DateTime.fromMillisecondsSinceEpoch(lastNotificationTime)}',
    );

    // Cooldown period: 5 menit untuk mencegah spam notifikasi
    const cooldownPeriod = 5 * 60 * 1000; // 5 menit dalam milliseconds
    final timeSinceLastNotification = now - lastNotificationTime;

    // Kirim notifikasi jika:
    // 1. Status 80% berubah dari 0 ke 1
    // 2. Status 90% berubah dari 0 ke 1
    // 3. Sudah melewati cooldown period sejak notifikasi terakhir

    bool statusChanged = false;
    String changeReason = "";

    // Cek perubahan status 90% (prioritas tertinggi)
    if (statusLimit90 == 1 && lastStatusLimit90 == 0) {
      statusChanged = true;
      changeReason = "Status 90% changed from 0 to 1";
    }
    // Cek perubahan status 80% (hanya jika 90% tidak berubah)
    else if (statusLimit80 == 1 && lastStatusLimit80 == 0) {
      statusChanged = true;
      changeReason = "Status 80% changed from 0 to 1";
    }

    if (statusChanged) {
      // Jika ada perubahan status, cek cooldown
      if (timeSinceLastNotification > cooldownPeriod) {
        print('✅ Status changed and cooldown passed: $changeReason');
        return true;
      } else {
        print('❌ Status changed but still in cooldown period: $changeReason');
        print(
          '   Time since last: ${timeSinceLastNotification}ms, Required: ${cooldownPeriod}ms',
        );
        return false;
      }
    }

    print('❌ No status change detected');
    return false;
  } catch (e) {
    print('❌ Error checking notification conditions by status: $e');
    // Dalam kasus error, tetap kirim notifikasi untuk safety
    return true;
  }
}

// Fungsi untuk inisialisasi dan mengirim notifikasi berdasarkan status
Future<void> _initializeAndSendNotificationByStatus({
  required int notificationLevel,
  required double percentage,
  required double dailyEnergy,
  required double energyLimit,
  required int statusLimit80,
  required int statusLimit90,
}) async {
  try {
    print('📱 Initializing notification plugin in background...');

    // Inisialisasi plugin notifikasi langsung di background isolate
    final FlutterLocalNotificationsPlugin notificationsPlugin =
        FlutterLocalNotificationsPlugin();

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);

    await notificationsPlugin.initialize(initializationSettings);

    // Tentukan konten notifikasi berdasarkan level
    String title;
    String body;
    String channelId;
    Priority priority;
    Importance importance;

    if (notificationLevel == 90) {
      title = 'PERINGATAN KRITIS!';
      body =
          'Status limit 90% telah aktif! Penggunaan energi mendekati batas maksimum.';
      channelId = 'energy_limit_warning';
      priority = Priority.max;
      importance = Importance.max;
    } else if (notificationLevel == 80) {
      title = 'Peringatan Limit Energi';
      body =
          'Status limit 80% telah aktif! Harap perhatikan penggunaan energi.';
      channelId = 'energy_limit_info';
      priority = Priority.high;
      importance = Importance.high;
    } else {
      print('⚠️ Invalid notification level: $notificationLevel');
      return;
    }

    // Buat channel jika belum ada
    await _createNotificationChannel(
      notificationsPlugin,
      channelId,
      importance,
    );

    // Format data untuk notifikasi
    String formattedDailyEnergy = dailyEnergy.toStringAsFixed(4);
    String formattedEnergyLimit = energyLimit.toStringAsFixed(2);
    String formattedPercentage = percentage.toStringAsFixed(1);
    String currentTime = _getCurrentTimeString();

    String detailedBody =
        '$body\n\n'
        '📊 Detail Status:\n'
        '• Status Limit 80%: ${statusLimit80 == 1 ? "AKTIF" : "TIDAK AKTIF"}\n'
        '• Status Limit 90%: ${statusLimit90 == 1 ? "AKTIF" : "TIDAK AKTIF"}\n'
        '• Energi Harian: $formattedDailyEnergy kWh\n'
        '• Batas Limit: $formattedEnergyLimit kWh\n'
        '• Persentase: $formattedPercentage%\n\n'
        '⏰ $currentTime';

    AndroidNotificationDetails androidNotificationDetails =
        AndroidNotificationDetails(
          channelId,
          _getChannelName(channelId),
          channelDescription: 'Notifikasi untuk status limit energi',
          importance: importance,
          priority: priority,
          showWhen: true,
          when: DateTime.now().millisecondsSinceEpoch,
          enableVibration: true,
          playSound: true,
          fullScreenIntent: notificationLevel == 90,
          category: AndroidNotificationCategory.alarm,
          visibility: NotificationVisibility.public,
          ongoing: notificationLevel == 90,
          autoCancel: notificationLevel != 90,
          styleInformation: BigTextStyleInformation(
            detailedBody,
            contentTitle: title,
            summaryText: 'PMM Energy Monitor',
            htmlFormatContent: false,
            htmlFormatTitle: false,
          ),
          actions: <AndroidNotificationAction>[
            const AndroidNotificationAction(
              'open_app',
              '📱 Buka Aplikasi',
              showsUserInterface: true,
              cancelNotification: false,
            ),
            const AndroidNotificationAction(
              'dismiss',
              '❌ Tutup',
              cancelNotification: true,
            ),
          ],
        );

    NotificationDetails notificationDetails = NotificationDetails(
      android: androidNotificationDetails,
    );

    // Generate unique ID berdasarkan level dan timestamp
    int notificationId =
        (notificationLevel * 1000) +
        (DateTime.now().millisecondsSinceEpoch % 1000).toInt();

    print('📤 Sending notification with ID: $notificationId');
    print('   Title: $title');
    print('   Level: $notificationLevel');
    print('   Status 80%: $statusLimit80');
    print('   Status 90%: $statusLimit90');
    print('   Percentage: $formattedPercentage%');

    await notificationsPlugin.show(
      notificationId,
      title,
      body,
      notificationDetails,
      payload: jsonEncode({
        'type': 'energy_limit_status',
        'level': notificationLevel,
        'statusLimit80': statusLimit80,
        'statusLimit90': statusLimit90,
        'percentage': percentage,
        'dailyEnergy': dailyEnergy,
        'energyLimit': energyLimit,
        'timestamp': DateTime.now().toIso8601String(),
      }),
    );

    // Update last notification dan status setelah berhasil mengirim
    await _updateLastNotificationByStatus(
      notificationLevel,
      statusLimit80,
      statusLimit90,
    );

    print('✅ Background notification sent successfully');
  } catch (e, stackTrace) {
    print('❌ Error in background notification: $e');
    print('StackTrace: $stackTrace');
    rethrow;
  }
}

// Fungsi untuk menyimpan data energi dan status
Future<void> _saveEnergyData(
  double dailyEnergy,
  double energyLimit,
  double percentage,
  int statusLimit80,
  int statusLimit90,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('last_daily_energy', dailyEnergy);
    await prefs.setDouble('last_energy_limit', energyLimit);
    await prefs.setDouble('last_percentage', percentage);
    await prefs.setInt('current_status_limit_80', statusLimit80);
    await prefs.setInt('current_status_limit_90', statusLimit90);
    await prefs.setInt(
      'last_check_time',
      DateTime.now().millisecondsSinceEpoch,
    );
    print('💾 Energy data and status saved successfully');
  } catch (e) {
    print('❌ Failed to save energy data: $e');
  }
}

// Update waktu dan status notifikasi terakhir
Future<void> _updateLastNotificationByStatus(
  int level,
  int statusLimit80,
  int statusLimit90,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('last_notification_level', level);
    await prefs.setInt('last_status_limit_80', statusLimit80);
    await prefs.setInt('last_status_limit_90', statusLimit90);
    await prefs.setInt(
      'last_notification_time',
      DateTime.now().millisecondsSinceEpoch,
    );
    print(
      '📝 Last notification updated: level $level, status 80%: $statusLimit80, status 90%: $statusLimit90 at ${DateTime.now()}',
    );
  } catch (e) {
    print('❌ Failed to update last notification: $e');
  }
}

// Fungsi untuk membuat notification channel
Future<void> _createNotificationChannel(
  FlutterLocalNotificationsPlugin plugin,
  String channelId,
  Importance importance,
) async {
  try {
    final androidPlugin =
        plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();

    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        AndroidNotificationChannel(
          channelId,
          _getChannelName(channelId),
          description: _getChannelDescription(channelId),
          importance: importance,
          enableVibration: true,
          playSound: true,
          showBadge: true,
        ),
      );
      print('✅ Notification channel created: $channelId');
    }
  } catch (e) {
    print('❌ Error creating notification channel: $e');
  }
}

String _getChannelName(String channelId) {
  switch (channelId) {
    case 'energy_limit_critical':
      return 'Limit Energi Kritis';
    case 'energy_limit_warning':
      return 'Peringatan Energi Tinggi';
    case 'energy_limit_info':
      return 'Info Energi';
    default:
      return 'PMM Energy Monitor';
  }
}

String _getChannelDescription(String channelId) {
  switch (channelId) {
    case 'energy_limit_critical':
      return 'Notifikasi kritis ketika status limit energi aktif';
    case 'energy_limit_warning':
      return 'Peringatan ketika status limit 90% aktif';
    case 'energy_limit_info':
      return 'Informasi ketika status limit 80% aktif';
    default:
      return 'Notifikasi untuk status limit energi';
  }
}

String _getCurrentTimeString() {
  final now = DateTime.now();
  return '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
}

// Aktifkan pengecekan lebih sering ketika status 90% aktif
Future<void> _enableFrequentCheck() async {
  try {
    await Workmanager().registerPeriodicTask(
      'checkEnergyLimitFrequent',
      'checkEnergyLimitFrequent',
      frequency: const Duration(minutes: 5),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
    print('⏰ Frequent check enabled (5 minutes)');
  } catch (e) {
    print('❌ Failed to enable frequent check: $e');
  }
}

// Nonaktifkan pengecekan sering
Future<void> _disableFrequentCheck() async {
  try {
    await Workmanager().cancelByUniqueName('checkEnergyLimitFrequent');
    print('⏸️ Frequent check disabled');
  } catch (e) {
    print('❌ Failed to disable frequent check: $e');
  }
}

class BackgroundService {
  static Future<void> initialize() async {
    try {
      print('🚀 Initializing BackgroundService...');
      await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
      print('✅ BackgroundService initialized successfully');
    } catch (e) {
      print('❌ Failed to initialize BackgroundService: $e');
      rethrow;
    }
  }

  static Future<void> startPeriodicEnergyCheck() async {
    try {
      print('⏰ Starting periodic energy check...');

      // Cancel existing tasks first
      await stopPeriodicEnergyCheck();
      await Future.delayed(const Duration(seconds: 2));

      // Start normal check every 10 minutes
      await Workmanager().registerPeriodicTask(
        'checkEnergyLimit',
        'checkEnergyLimit',
        frequency: const Duration(minutes: 10),
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: false,
          requiresCharging: false,
          requiresDeviceIdle: false,
        ),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );

      print('✅ Periodic energy check started successfully');
    } catch (e) {
      print('❌ Failed to start periodic energy check: $e');
      rethrow;
    }
  }

  static Future<void> stopPeriodicEnergyCheck() async {
    try {
      print('⏹️ Stopping periodic energy checks...');
      await Workmanager().cancelByUniqueName('checkEnergyLimit');
      await Workmanager().cancelByUniqueName('checkEnergyLimitFrequent');
      print('✅ Periodic energy checks stopped');
    } catch (e) {
      print('❌ Failed to stop periodic energy check: $e');
    }
  }

  // Fungsi untuk reset tracking harian
  static Future<void> resetDailyTracking() async {
    try {
      print('🔄 Resetting daily tracking...');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('last_notification_level');
      await prefs.remove('last_notification_time');
      await prefs.remove('last_status_limit_80');
      await prefs.remove('last_status_limit_90');
      print('✅ Daily tracking reset successfully');
    } catch (e) {
      print('❌ Failed to reset daily tracking: $e');
    }
  }

  // Fungsi untuk test background task secara manual
  static Future<void> testBackgroundTask() async {
    try {
      print('🧪 Testing background task manually...');
      await _checkEnergyLimitInBackground();
      print('✅ Manual background task test completed');
    } catch (e) {
      print('❌ Manual background task test failed: $e');
    }
  }

  // Fungsi untuk force reset notification tracking (untuk testing)
  static Future<void> forceResetNotificationTracking() async {
    try {
      print('🔄 Force resetting notification tracking for testing...');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('last_notification_level');
      await prefs.remove('last_notification_time');
      await prefs.remove('last_status_limit_80');
      await prefs.remove('last_status_limit_90');
      print('✅ Notification tracking force reset completed');
    } catch (e) {
      print('❌ Failed to force reset notification tracking: $e');
    }
  }

  // Fungsi untuk mendapatkan status limit terakhir
  static Future<Map<String, dynamic>> getLastStatusInfo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return {
        'lastStatusLimit80': prefs.getInt('last_status_limit_80') ?? 0,
        'lastStatusLimit90': prefs.getInt('last_status_limit_90') ?? 0,
        'currentStatusLimit80': prefs.getInt('current_status_limit_80') ?? 0,
        'currentStatusLimit90': prefs.getInt('current_status_limit_90') ?? 0,
        'lastNotificationLevel': prefs.getInt('last_notification_level') ?? 0,
        'lastNotificationTime': prefs.getInt('last_notification_time') ?? 0,
      };
    } catch (e) {
      print('❌ Failed to get last status info: $e');
      return {};
    }
  }
}
