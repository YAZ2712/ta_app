// lib/services/notification_service.dart

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    try {
      print('🔔 Starting NotificationService initialization...');

      const AndroidInitializationSettings initializationSettingsAndroid =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      const InitializationSettings initializationSettings =
          InitializationSettings(android: initializationSettingsAndroid);

      await _notificationsPlugin.initialize(
        initializationSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          print('Notification tapped: ${response.payload}');
          _handleNotificationTap(response);
        },
      );

      await _requestPermissions();
      await _createNotificationChannels();

      print('✅ NotificationService initialized successfully');
    } catch (e, stackTrace) {
      print('❌ Error initializing notifications: $e');
      print('StackTrace: $stackTrace');
      rethrow;
    }
  }

  static Future<void> _requestPermissions() async {
    try {
      print('🔐 Requesting notification permissions...');

      // Request basic notification permission
      if (await Permission.notification.isDenied) {
        final status = await Permission.notification.request();
        print('Notification permission status: $status');
      }

      // Request Android-specific permissions
      final plugin =
          _notificationsPlugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >();

      if (plugin != null) {
        // Request exact alarm permission (Android 12+)
        final exactAlarmGranted = await plugin.requestExactAlarmsPermission();
        print('Exact alarm permission granted: $exactAlarmGranted');

        // Request permission to post notifications
        final granted = await plugin.requestNotificationsPermission();
        print('Android notification permission granted: $granted');
      }

      print('✅ All notification permissions handled');
    } catch (e) {
      print('❌ Error requesting permissions: $e');
    }
  }

  static Future<void> _createNotificationChannels() async {
    try {
      print('📱 Creating notification channels...');

      final plugin =
          _notificationsPlugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >();

      if (plugin != null) {
        // Channel untuk notifikasi kritis (100%)
        await plugin.createNotificationChannel(
          const AndroidNotificationChannel(
            'energy_limit_critical',
            'Limit Energi Kritis',
            description: 'Notifikasi kritis ketika limit energi tercapai 100%',
            importance: Importance.max,
            enableVibration: true,
            playSound: true,
            showBadge: true,
          ),
        );

        // Channel untuk peringatan tinggi (90%)
        await plugin.createNotificationChannel(
          const AndroidNotificationChannel(
            'energy_limit_warning',
            'Peringatan Energi Tinggi',
            description: 'Peringatan ketika limit energi mencapai 90%',
            importance: Importance.high,
            enableVibration: true,
            playSound: true,
            showBadge: true,
          ),
        );

        // Channel untuk info (80%)
        await plugin.createNotificationChannel(
          const AndroidNotificationChannel(
            'energy_limit_info',
            'Info Energi',
            description: 'Informasi ketika limit energi mencapai 80%',
            importance: Importance.defaultImportance,
            enableVibration: true,
            playSound: true,
            showBadge: true,
          ),
        );

        print('✅ Notification channels created successfully');
      }
    } catch (e) {
      print('❌ Error creating notification channels: $e');
    }
  }

  static Future<void> showEnergyLimitNotification({
    required String title,
    required String body,
    required double percentage,
    required double dailyEnergy,
    required double energyLimit,
  }) async {
    try {
      print('🔔 Preparing to show notification...');
      print('   Input - Title: $title');
      print('   Input - Body: $body');
      print('   Input - Percentage: ${percentage.toStringAsFixed(2)}%');
      print('   Input - Daily Energy: ${dailyEnergy.toStringAsFixed(4)} kWh');
      print('   Input - Energy Limit: ${energyLimit.toStringAsFixed(4)} kWh');

      Priority priority;
      Importance importance;
      String channelId;
      String channelName;
      bool fullScreenIntent = false;
      Int64List? vibrationPattern;
      int notificationId;

      if (percentage >= 100) {
        priority = Priority.max;
        importance = Importance.max;
        channelId = 'energy_limit_critical';
        channelName = 'Limit Energi Kritis';
        fullScreenIntent = true;
        vibrationPattern = Int64List.fromList([0, 1000, 500, 1000, 500, 1000]);
        notificationId = 1; // ID untuk notifikasi kritis
      } else if (percentage >= 90) {
        priority = Priority.high;
        importance = Importance.high;
        channelId = 'energy_limit_warning';
        channelName = 'Peringatan Energi Tinggi';
        vibrationPattern = Int64List.fromList([0, 1000, 500, 1000]);
        notificationId = 2; // ID untuk notifikasi peringatan
      } else {
        priority = Priority.defaultPriority;
        importance = Importance.defaultImportance;
        channelId = 'energy_limit_info';
        channelName = 'Info Energi';
        vibrationPattern = Int64List.fromList([0, 500]);
        notificationId = 3; // ID untuk notifikasi info
      }

      // Format data dengan presisi yang benar
      String formattedDailyEnergy = dailyEnergy.toStringAsFixed(1);
      String formattedEnergyLimit = energyLimit.toStringAsFixed(1);
      String formattedPercentage = percentage.toStringAsFixed(1);
      String currentTime = _getCurrentTimeString();

      // Create detailed notification content sesuai format dari gambar
      String detailedTitle = title;
      String detailedBody = body;

      // Format detail sesuai tampilan di gambar
      String detailsText =
          '\n\nPenggunaan: $formattedDailyEnergy kWh\nLimit: $formattedEnergyLimit kWh\nPersentase: $formattedPercentage%';

      print('📝 Formatted notification content:');
      print('   Formatted Daily Energy: $formattedDailyEnergy kWh');
      print('   Formatted Energy Limit: $formattedEnergyLimit kWh');
      print('   Formatted Percentage: $formattedPercentage%');
      print('   Current Time: $currentTime');

      // Create payload data
      Map<String, dynamic> payload = {
        'type': 'energy_limit',
        'percentage': percentage,
        'dailyEnergy': dailyEnergy,
        'energyLimit': energyLimit,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      // Create notification actions without const
      final List<AndroidNotificationAction> actions = [
        AndroidNotificationAction(
          'open_app',
          'Buka Aplikasi',
          titleColor: Color.fromARGB(255, 30, 136, 229),
        ),
        AndroidNotificationAction(
          'dismiss',
          'Tutup',
          titleColor: Color.fromARGB(255, 30, 136, 229),
        ),
      ];

      AndroidNotificationDetails androidNotificationDetails =
          AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: 'Notifikasi untuk limit energi harian',
            importance: importance,
            priority: priority,
            showWhen: true,
            when: DateTime.now().millisecondsSinceEpoch,
            enableVibration: true,
            playSound: true,
            vibrationPattern: vibrationPattern,
            fullScreenIntent: fullScreenIntent,
            category: AndroidNotificationCategory.alarm,
            visibility: NotificationVisibility.public,
            ongoing: percentage >= 100,
            autoCancel: percentage < 100,
            styleInformation: BigTextStyleInformation(
              '$detailedBody$detailsText',
              contentTitle: detailedTitle,
              summaryText: 'PMM Energy Monitor • $currentTime',
              htmlFormatContent: false,
              htmlFormatTitle: false,
            ),
            actions: actions,
          );

      final NotificationDetails notificationDetails = NotificationDetails(
        android: androidNotificationDetails,
      );

      await _notificationsPlugin.show(
        notificationId,
        detailedTitle,
        '$detailedBody$detailsText',
        notificationDetails,
        payload: jsonEncode(payload),
      );

      print('✅ Notification shown successfully');
      print('   Notification ID: $notificationId');
      print('   Channel: $channelId');
      print('   Priority: $priority');
    } catch (e, stackTrace) {
      print('❌ Error showing notification: $e');
      print('StackTrace: $stackTrace');
    }
  }

  static String _getCurrentTimeString() {
    final now = DateTime.now();
    final timeString =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return timeString;
  }

  static void _handleNotificationTap(NotificationResponse response) {
    try {
      print('🔔 Notification tapped with action: ${response.actionId}');
      print('   Payload: ${response.payload}');

      if (response.payload != null) {
        final payloadData = jsonDecode(response.payload!);
        print('   Parsed payload: $payloadData');
      }

      // Handle different actions
      switch (response.actionId) {
        case 'open_app':
          print('📱 Opening app...');
          // App will automatically open when notification is tapped
          break;
        case 'dismiss':
          print('❌ Dismissing notification...');
          // Notification will be dismissed automatically
          break;
        default:
          print('📱 Default action - opening app...');
          break;
      }
    } catch (e) {
      print('❌ Error handling notification tap: $e');
    }
  }

  // Method untuk cancel semua notifikasi
  static Future<void> cancelAllNotifications() async {
    try {
      await _notificationsPlugin.cancelAll();
      print('✅ All notifications cancelled');
    } catch (e) {
      print('❌ Error cancelling notifications: $e');
    }
  }

  // Method untuk cancel notifikasi berdasarkan ID
  static Future<void> cancelNotification(int id) async {
    try {
      await _notificationsPlugin.cancel(id);
      print('✅ Notification $id cancelled');
    } catch (e) {
      print('❌ Error cancelling notification $id: $e');
    }
  }
}
