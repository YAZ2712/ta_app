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

          double dailyEnergy =
              double.tryParse(deviceData['DailyEnergy']?.toString() ?? '0') ??
              0.0;
          double energyLimit =
              double.tryParse(deviceData['energyLimit2']?.toString() ?? '0') ??
              0.0;

          print('⚡ Daily Energy: $dailyEnergy kWh');
          print('🎯 Energy Limit: $energyLimit kWh');

          if (energyLimit > 0) {
            double percentage = (dailyEnergy / energyLimit * 100);
            print('📈 Percentage: ${percentage.toStringAsFixed(2)}%');

            // Simpan data untuk tracking perubahan
            await _saveEnergyData(dailyEnergy, energyLimit, percentage);

            // Cek apakah perlu mengirim notifikasi dengan logic yang lebih sederhana
            bool shouldNotify = await _shouldSendNotificationImproved(
              percentage,
            );
            print('🔔 Should send notification: $shouldNotify');

            if (shouldNotify) {
              try {
                print('🔔 Preparing to send notification...');
                print('   Percentage: ${percentage.toStringAsFixed(2)}%');
                print('   Daily Energy: ${dailyEnergy.toStringAsFixed(4)} kWh');
                print('   Energy Limit: ${energyLimit.toStringAsFixed(4)} kWh');

                // Inisialisasi notification langsung di background isolate
                await _initializeAndSendNotification(
                  percentage: percentage,
                  dailyEnergy: dailyEnergy,
                  energyLimit: energyLimit,
                );

                print('✅ Notification sent successfully');
              } catch (notificationError) {
                print('❌ Failed to send notification: $notificationError');
              }
            }

            // Jika mendekati 75% atau lebih, aktifkan pengecekan lebih sering
            if (percentage >= 75 && percentage < 100) {
              print('🔄 Enabling frequent check (75%+ usage)');
              await _enableFrequentCheck();
            } else if (percentage < 75) {
              print('⏸️ Disabling frequent check (<75% usage)');
              await _disableFrequentCheck();
            }
          } else {
            print('⚠️ Energy limit is 0 or invalid');
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

// Fungsi untuk inisialisasi dan mengirim notifikasi langsung di background isolate
Future<void> _initializeAndSendNotification({
  required double percentage,
  required double dailyEnergy,
  required double energyLimit,
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

    // Tentukan level notifikasi berdasarkan persentase
    String title;
    String body;
    String channelId;
    Priority priority;
    Importance importance;
    int notificationLevel;

    if (percentage >= 100) {
      title = 'LIMIT ENERGI TERCAPAI!';
      body = 'Penggunaan energi harian telah melebihi batas!';
      channelId = 'energy_limit_critical';
      priority = Priority.max;
      importance = Importance.max;
      notificationLevel = 100;
    } else if (percentage >= 90) {
      title = 'PERINGATAN KRITIS!';
      body = 'Penggunaan energi telah mencapai 90% dari batas harian.';
      channelId = 'energy_limit_warning';
      priority = Priority.high;
      importance = Importance.high;
      notificationLevel = 90;
    } else if (percentage >= 80) {
      title = 'Peringatan Limit Energi';
      body = 'Penggunaan energi telah mencapai 80% dari batas harian.';
      channelId = 'energy_limit_info';
      priority = Priority.defaultPriority;
      importance = Importance.defaultImportance;
      notificationLevel = 80;
    } else {
      print(
        '⚠️ Percentage ${percentage.toStringAsFixed(1)}% below notification threshold',
      );
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
        '📊 Detail Penggunaan:\n'
        '• Energi Harian: $formattedDailyEnergy kWh\n'
        '• Batas Limit: $formattedEnergyLimit kWh\n'
        '• Persentase: $formattedPercentage%\n\n'
        '⏰ $currentTime';

    AndroidNotificationDetails androidNotificationDetails =
        AndroidNotificationDetails(
          channelId,
          _getChannelName(channelId),
          channelDescription: 'Notifikasi untuk limit energi harian',
          importance: importance,
          priority: priority,
          showWhen: true,
          when: DateTime.now().millisecondsSinceEpoch,
          enableVibration: true,
          playSound: true,
          fullScreenIntent: percentage >= 100,
          category: AndroidNotificationCategory.alarm,
          visibility: NotificationVisibility.public,
          ongoing: percentage >= 100,
          autoCancel: percentage < 100,
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

    // Generate unique ID
    int notificationId =
        (percentage.toInt() * 1000) +
        (DateTime.now().millisecondsSinceEpoch % 1000).toInt();

    print('📤 Sending notification with ID: $notificationId');
    print('   Title: $title');
    print('   Percentage: $formattedPercentage%');
    print('   Daily Energy: $formattedDailyEnergy kWh');
    print('   Energy Limit: $formattedEnergyLimit kWh');

    await notificationsPlugin.show(
      notificationId,
      title,
      body,
      notificationDetails,
      payload: jsonEncode({
        'type': 'energy_limit',
        'percentage': percentage,
        'dailyEnergy': dailyEnergy,
        'energyLimit': energyLimit,
        'timestamp': DateTime.now().toIso8601String(),
      }),
    );

    // Update last notification setelah berhasil mengirim
    await _updateLastNotification(notificationLevel);

    print('✅ Background notification sent successfully');
  } catch (e, stackTrace) {
    print('❌ Error in background notification: $e');
    print('StackTrace: $stackTrace');
    rethrow;
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
      return 'Notifikasi kritis ketika limit energi tercapai 100%';
    case 'energy_limit_warning':
      return 'Peringatan ketika limit energi mencapai 90%';
    case 'energy_limit_info':
      return 'Informasi ketika limit energi mencapai 80%';
    default:
      return 'Notifikasi untuk limit energi harian';
  }
}

String _getCurrentTimeString() {
  final now = DateTime.now();
  return '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
}

// Fungsi untuk menyimpan data energi
Future<void> _saveEnergyData(
  double dailyEnergy,
  double energyLimit,
  double percentage,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('last_daily_energy', dailyEnergy);
    await prefs.setDouble('last_energy_limit', energyLimit);
    await prefs.setDouble('last_percentage', percentage);
    await prefs.setInt(
      'last_check_time',
      DateTime.now().millisecondsSinceEpoch,
    );
    print('💾 Energy data saved successfully');
  } catch (e) {
    print('❌ Failed to save energy data: $e');
  }
}

// Fungsi yang diperbaiki untuk menentukan apakah perlu mengirim notifikasi
Future<bool> _shouldSendNotificationImproved(double currentPercentage) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final lastNotificationLevel = prefs.getInt('last_notification_level') ?? 0;
    final lastNotificationTime = prefs.getInt('last_notification_time') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    print('🔍 Checking notification conditions:');
    print('   Current: ${currentPercentage.toStringAsFixed(1)}%');
    print('   Last level: $lastNotificationLevel');
    print(
      '   Last time: ${DateTime.fromMillisecondsSinceEpoch(lastNotificationTime)}',
    );

    // Cooldown period: 15 menit untuk level yang sama
    const cooldownPeriod = 15 * 60 * 1000; // 15 menit dalam milliseconds
    final timeSinceLastNotification = now - lastNotificationTime;

    // Tentukan level notifikasi saat ini
    int currentLevel = 0;
    if (currentPercentage >= 100) {
      currentLevel = 100;
    } else if (currentPercentage >= 90) {
      currentLevel = 90;
    } else if (currentPercentage >= 80) {
      currentLevel = 80;
    }

    // Jika tidak ada level yang tercapai, jangan kirim notifikasi
    if (currentLevel == 0) {
      print('❌ No notification level reached');
      return false;
    }

    // Kirim notifikasi jika:
    // 1. Belum pernah mengirim notifikasi untuk level ini
    // 2. Sudah melewati cooldown period untuk level yang sama
    // 3. Level meningkat dari sebelumnya
    if (lastNotificationLevel < currentLevel) {
      print('✅ Level increased from $lastNotificationLevel to $currentLevel');
      return true;
    } else if (lastNotificationLevel == currentLevel &&
        timeSinceLastNotification > cooldownPeriod) {
      print('✅ Cooldown period passed for level $currentLevel');
      return true;
    }

    print(
      '❌ Notification blocked - Level: $currentLevel, Last: $lastNotificationLevel, Time since last: ${timeSinceLastNotification}ms',
    );
    return false;
  } catch (e) {
    print('❌ Error checking notification conditions: $e');
    // Dalam kasus error, tetap kirim notifikasi untuk safety
    return true;
  }
}

// Update waktu notifikasi terakhir
Future<void> _updateLastNotification(int level) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('last_notification_level', level);
    await prefs.setInt(
      'last_notification_time',
      DateTime.now().millisecondsSinceEpoch,
    );
    print('📝 Last notification updated: level $level at ${DateTime.now()}');
  } catch (e) {
    print('❌ Failed to update last notification: $e');
  }
}

// Aktifkan pengecekan lebih sering ketika mendekati limit
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
      print('✅ Notification tracking force reset completed');
    } catch (e) {
      print('❌ Failed to force reset notification tracking: $e');
    }
  }
}
