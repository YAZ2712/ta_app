import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'limitenergy_screen.dart';

class MonitoringScreen extends StatefulWidget {
  const MonitoringScreen({super.key});

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

class AntaresMqttService {
  final String accessKey = 'fe5c7a15d8c13220:bfd764392a99a094';
  final String projectName = 'TADKT-1';
  final String deviceName = 'PMM';
  late MqttServerClient client;
  final Function(Map<String, dynamic>) onDataReceived;
  final Function(bool) onConnectionStatusChanged;
  final logger = Logger('AntaresMqttService');

  AntaresMqttService({
    required this.onDataReceived,
    required this.onConnectionStatusChanged,
  });

  Future<void> connect() async {
    try {
      client = MqttServerClient(
        'mqtt.antares.id',
        'dart_client_${DateTime.now().millisecondsSinceEpoch}',
      );
      client.port = 1883;
      client.keepAlivePeriod = 60;
      client.onConnected = _onConnected;
      client.onDisconnected = _onDisconnected;
      client.onSubscribed = _onSubscribed;
      client.logging(on: true);

      final connMessage = MqttConnectMessage()
          .withClientIdentifier(
            'dart_client_${DateTime.now().millisecondsSinceEpoch}',
          )
          .startClean()
          .withWillQos(MqttQos.atLeastOnce);

      client.connectionMessage = connMessage;

      await client.connect();
    } catch (e) {
      logger.severe('Connection exception: $e');
      await _reconnect();
    }
  }

  Future<void> _reconnect() async {
    logger.info('Attempting reconnect...');
    await Future.delayed(const Duration(seconds: 5));
    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      await connect();
    }
  }

  void _onSubscribed(String topic) {
    logger.info('Subscribed to $topic');
    client.updates?.listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final MqttPublishMessage message = c[0].payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(
        message.payload.message,
      );
      _processMqttData(payload);
    });
  }

  void _onConnected() {
    logger.info('Connected to Antares');
    onConnectionStatusChanged(true);

    final topic =
        '/oneM2M/resp/antares-cse/fe5c7a15d8c13220:bfd764392a99a094/json';

    client.subscribe(topic, MqttQos.atLeastOnce);
  }

  void _onDisconnected() {
    logger.warning('Disconnected from Antares');
    onConnectionStatusChanged(false);
    Future.delayed(const Duration(seconds: 5), () {
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        connect();
      }
    });
  }

  void _processMqttData(String payload) {
    try {
      final data = jsonDecode(payload);
      Map<String, dynamic>? contentData;

      if (data['m2m:rsp'] != null &&
          data['m2m:rsp']['m2m:cin'] != null &&
          data['m2m:rsp']['m2m:cin']['con'] != null) {
        final conData = data['m2m:rsp']['m2m:cin']['con'];
        if (conData is String) {
          contentData = jsonDecode(conData);
        } else {
          contentData = conData;
        }
      } else if (data['con'] != null) {
        final conData = data['con'];
        if (conData is String) {
          contentData = jsonDecode(conData);
        } else {
          contentData = conData;
        }
      } else if (data['voltage'] != null || data['power'] != null) {
        contentData = data;
      }

      if (contentData != null) {
        onDataReceived(contentData);
      }
    } catch (e) {
      logger.severe('Error processing MQTT data: $e');
    }
  }

  void disconnect() {
    client.disconnect();
  }
}

class _MonitoringScreenState extends State<MonitoringScreen> {
  final logger = Logger('MonitoringScreenState');
  DateTime now = DateTime.now();
  bool isLoading = false;
  bool _isConnectedToAntares = false;
  bool _isDisposed = false;
  // bool _isResetting = false; // <-- DIHAPUS
  bool _has80PercentNotified = false;
  bool _has90PercentNotified = false;
  bool _hasLimitReachedNotified = false;
  Timer? _timer;
  Timer? _httpPollingTimer;
  late AntaresMqttService _antaresService;

  // Monitoring data
  double voltage = 0.0;
  double current = 0.0;
  double power = 0.0;
  double energy = 0.0;
  double totalEnergy = 0.0;
  double dailyEnergy = 0.0;
  double totalCO2 = 0.0;
  double totalCost = 0.0;

  // Limit Energy data
  double energyLimit = 0.0;
  bool isLimitActive = false;
  String limitStatus = 'Tidak Aktif';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && !_isDisposed) {
        setState(() {
          now = DateTime.now();
        });
      }
    });

    _initMqttService();
    fetchDataFromAntares();
    _setupHttpPollingTimer();

    _checkNotificationPermissions();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _timer?.cancel();
    _httpPollingTimer?.cancel();
    _antaresService.disconnect();
    super.dispose();
  }

  Future<void> _checkNotificationPermissions() async {
    try {
      final status = await Permission.notification.status;
      if (status.isDenied) {
        _showPermissionDialog();
      }
    } catch (e) {
      print('Error checking notification permissions: $e');
    }
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Izin Notifikasi'),
            content: const Text(
              'Aplikasi memerlukan izin notifikasi untuk mengirim peringatan limit energi saat aplikasi tidak dibuka.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Nanti'),
              ),
              ElevatedButton(
                onPressed: () async {
                  Navigator.pop(context);
                  await Permission.notification.request();
                },
                child: const Text('Berikan Izin'),
              ),
            ],
          ),
    );
  }

  void _setupHttpPollingTimer() {
    _httpPollingTimer?.cancel();
    _httpPollingTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted) {
        fetchDataFromAntares();
      }
    });
    logger.info('HTTP polling timer set up to fetch data every 5 seconds');
  }

  void _initMqttService() {
    _antaresService = AntaresMqttService(
      onDataReceived: (data) {
        if (!mounted) return;
        updateDataFromMqtt(data);
      },
      onConnectionStatusChanged: (isConnected) {
        if (!mounted) return;
        setState(() {
          _isConnectedToAntares = isConnected;
        });
      },
    );
    connectToMqtt();
  }

  void _showLimitPopupNotification(
    String title,
    String message,
    Color color,
    IconData icon,
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message, style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Penggunaan Hari Ini:',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        Text(
                          '${dailyEnergy.toStringAsFixed(1)} kWh',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text(
                          'Limit yang Ditetapkan:',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        Text(
                          '${energyLimit.toStringAsFixed(1)} kWh',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  void _showLimitNotificationWithAlert(
    String title,
    String message,
    Color color,
    IconData icon,
  ) {
    _showLimitPopupNotification(title, message, color, icon);
    HapticFeedback.heavyImpact();
  }

  void _checkAndShowLimitNotifications() {
    if (energyLimit <= 0) return;

    double percentage = (dailyEnergy / energyLimit * 100);

    if (percentage >= 80 && !_has80PercentNotified) {
      _has80PercentNotified = true;
      _has90PercentNotified = false;
      _hasLimitReachedNotified = false;

      _showLimitNotificationWithAlert(
        'Peringatan Limit Energi!',
        'Penggunaan energi Anda telah mencapai 80% dari batas harian yang ditetapkan. Mohon pertimbangkan untuk menghemat penggunaan energi.',
        Colors.orange,
        Icons.warning_amber,
      );
    } else if (percentage >= 90 && !_has90PercentNotified) {
      _has90PercentNotified = true;
      _has80PercentNotified = true;
      _hasLimitReachedNotified = false;

      _showLimitNotificationWithAlert(
        'Peringatan Kritis!',
        'PERHATIAN! Penggunaan energi telah mencapai 90%. Anda hampir mencapai batas harian. Segera kurangi penggunaan listrik!',
        Colors.deepOrange,
        Icons.warning,
      );
    } else if (percentage >= 100 && !_hasLimitReachedNotified) {
      _hasLimitReachedNotified = true;
      _has80PercentNotified = true;
      _has90PercentNotified = true;

      _showLimitNotificationWithAlert(
        'Limit Tercapai!',
        'BATAS MAKSIMAL TERCAPAI! Penggunaan energi harian Anda telah melebihi atau mencapai limit yang ditetapkan. Pertimbangkan untuk mematikan perangkat yang tidak perlu.',
        Colors.red,
        Icons.block,
      );
    } else if (percentage < 80) {
      _has80PercentNotified = false;
      _has90PercentNotified = false;
      _hasLimitReachedNotified = false;
    }
  }

  Future<void> connectToMqtt() async {
    try {
      await _antaresService.connect();
    } catch (_) {
      if (!_isDisposed) {
        await Future.delayed(const Duration(seconds: 10));
        connectToMqtt();
      }
    }
  }

  // --- KODE RESET DIHAPUS DARI SINI ---
  // Future<void> _sendResetCommand() async { ... } // <-- DIHAPUS
  // void _showResetConfirmationDialog() { ... } // <-- DIHAPUS
  // --- AKHIR PENGHAPUSAN ---

  void updateDataFromMqtt(Map<String, dynamic> data) {
    if (!mounted) return;

    logger.info('Updating UI with MQTT data: $data');
    if (mounted && !_isDisposed) {
      setState(() {
        if (data['Voltage'] != null) {
          voltage = double.tryParse(data['Voltage'].toString()) ?? voltage;
        }
        if (data['Current'] != null) {
          current = double.tryParse(data['Current'].toString()) ?? current;
        }
        if (data['Power'] != null) {
          power = double.tryParse(data['Power'].toString()) ?? power;
        }
        if (data['Energy'] != null) {
          energy = double.tryParse(data['Energy'].toString()) ?? energy;
        }
        if (data['TotalEnergy'] != null) {
          totalEnergy =
              double.tryParse(data['TotalEnergy'].toString()) ?? totalEnergy;
        }
        if (data['DailyEnergy'] != null) {
          dailyEnergy =
              double.tryParse(data['DailyEnergy'].toString()) ?? dailyEnergy;
        }

        if (data['energyLimit2'] != null) {
          energyLimit =
              double.tryParse(data['energyLimit2'].toString()) ?? energyLimit;
        } else if (data['EnergyLimit'] != null) {
          energyLimit =
              double.tryParse(data['EnergyLimit'].toString()) ?? energyLimit;
        } else if (data['energyLimit'] != null) {
          energyLimit =
              double.tryParse(data['energyLimit'].toString()) ?? energyLimit;
        }

        if (data['statusLimit80'] != null) {
          isLimitActive = data['statusLimit80'].toString() == '1';
        } else if (data['statusLimit90'] != null) {
          isLimitActive = data['statusLimit90'].toString() == '1';
        } else if (data['LimitStatus'] != null) {
          isLimitActive =
              data['LimitStatus'].toString().toLowerCase() == 'active' ||
              data['LimitStatus'].toString() == '1';
        }

        if (data['TotalCO2'] != null) {
          totalCO2 = double.tryParse(data['TotalCO2'].toString()) ?? totalCO2;
        } else if (data['TotalCO2'] != null) {
          totalCO2 = double.tryParse(data['TotalCO2'].toString()) ?? totalCO2;
        } else if (data['TotalCO2'] != null) {
          totalCO2 = double.tryParse(data['TotalCO2'].toString()) ?? totalCO2;
        }

        if (data['TotalCost'] != null) {
          totalCost =
              double.tryParse(data['TotalCost'].toString()) ?? totalCost;
        } else if (data['TotalCost'] != null) {
          totalCost =
              double.tryParse(data['TotalCost'].toString()) ?? totalCost;
        } else if (data['TotalCost'] != null) {
          totalCO2 = double.tryParse(data['TotalCost'].toString()) ?? totalCost;
        }

        _updateLimitStatus();
      });
    }
  }

  void _updateLimitStatus() {
    if (energyLimit <= 0) {
      limitStatus = 'Tidak Diatur';
      isLimitActive = false;
    } else if (!isLimitActive) {
      limitStatus = 'Tidak Aktif';
    } else if (dailyEnergy >= energyLimit) {
      limitStatus = 'Limit Tercapai';
    } else {
      limitStatus = 'Aktif';
    }

    _checkAndShowLimitNotifications();
  }

  Future<void> fetchDataFromAntares() async {
    if (isLoading || !mounted) return;

    setState(() => isLoading = true);
    try {
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
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        logger.info('Successfully fetched data from Antares');
        final data = jsonDecode(response.body);
        if (data['m2m:cin']?['con'] != null) {
          dynamic conData = data['m2m:cin']['con'];
          Map<String, dynamic> deviceData;

          if (conData is String) {
            try {
              deviceData = jsonDecode(conData);
              logger.info('Parsed JSON data from con string: $deviceData');
            } catch (e) {
              logger.warning('Failed to parse con as JSON: $e');
              deviceData = {'con': conData};
            }
          } else if (conData is Map) {
            deviceData = Map<String, dynamic>.from(conData);
            logger.info('Con is already a Map: $deviceData');
          } else {
            logger.warning('Unexpected con format: ${conData.runtimeType}');
            deviceData = {};
          }

          if (mounted && !_isDisposed) {
            setState(() {
              if (deviceData['Voltage'] != null) {
                voltage =
                    double.tryParse(deviceData['Voltage'].toString()) ??
                    voltage;
              }
              if (deviceData['Current'] != null) {
                current =
                    double.tryParse(deviceData['Current'].toString()) ??
                    current;
              }
              if (deviceData['Power'] != null) {
                power =
                    double.tryParse(deviceData['Power'].toString()) ?? power;
              }
              if (deviceData['Energy'] != null) {
                energy =
                    double.tryParse(deviceData['Energy'].toString()) ?? energy;
              }
              if (deviceData['TotalEnergy'] != null) {
                totalEnergy =
                    double.tryParse(deviceData['TotalEnergy'].toString()) ??
                    totalEnergy;
              }
              if (deviceData['DailyEnergy'] != null) {
                dailyEnergy =
                    double.tryParse(deviceData['DailyEnergy'].toString()) ??
                    dailyEnergy;
              }

              if (deviceData['energyLimit2'] != null) {
                energyLimit =
                    double.tryParse(deviceData['energyLimit2'].toString()) ??
                    energyLimit;
                logger.info('Found energyLimit2: $energyLimit');
              } else if (deviceData['EnergyLimit'] != null) {
                energyLimit =
                    double.tryParse(deviceData['EnergyLimit'].toString()) ??
                    energyLimit;
                logger.info('Found EnergyLimit: $energyLimit');
              } else if (deviceData['energyLimit'] != null) {
                energyLimit =
                    double.tryParse(deviceData['energyLimit'].toString()) ??
                    energyLimit;
                logger.info('Found energyLimit: $energyLimit');
              }

              if (deviceData['statusLimit80'] != null) {
                isLimitActive = deviceData['statusLimit80'].toString() == '1';
                logger.info('Found statusLimit80: $isLimitActive');
              } else if (deviceData['statusLimit90'] != null) {
                isLimitActive = deviceData['statusLimit90'].toString() == '1';
                logger.info('Found statusLimit90: $isLimitActive');
              } else if (deviceData['LimitStatus'] != null) {
                isLimitActive =
                    deviceData['LimitStatus'].toString().toLowerCase() ==
                        'active' ||
                    deviceData['LimitStatus'].toString() == '1';
                logger.info('Found LimitStatus: $isLimitActive');
              }

              if (deviceData['TotalCO2'] != null) {
                totalCO2 =
                    double.tryParse(deviceData['TotalCO2'].toString()) ??
                    totalCO2;
              } else if (deviceData['TotalCO2'] != null) {
                totalCO2 =
                    double.tryParse(deviceData['TotalCO2'].toString()) ??
                    totalCO2;
              } else if (deviceData['TotalCO2'] != null) {
                totalCO2 =
                    double.tryParse(deviceData['TotalCO2'].toString()) ??
                    totalCO2;
              }

              if (deviceData['TotalCost'] != null) {
                totalCost =
                    double.tryParse(deviceData['TotalCost'].toString()) ??
                    totalCost;
              } else if (deviceData['TotalCost'] != null) {
                totalCost =
                    double.tryParse(deviceData['TotalCost'].toString()) ??
                    totalCost;
              } else if (deviceData['total_biaya'] != null) {
                totalCost =
                    double.tryParse(deviceData['total_biaya'].toString()) ??
                    totalCost;
              }

              _updateLimitStatus();

              logger.info(
                'Updated energyLimit: $energyLimit, isLimitActive: $isLimitActive, limitStatus: $limitStatus',
              );
            });
          }
        }
      } else {
        logger.severe('Failed to fetch data: ${response.statusCode}');
      }
    } catch (e) {
      logger.severe('Fetch error: $e');
    } finally {
      if (mounted && !_isDisposed) {
        setState(() => isLoading = false);
      }
    }
  }

  Widget buildInfoCard({
    required IconData icon,
    required String title,
    required String value,
    required String unit,
    Color? iconColor,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: iconColor?.withOpacity(0.2) ?? Colors.grey[200],
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor ?? Colors.black, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$value $unit',
                    style: const TextStyle(fontSize: 16, color: Colors.black87),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildLimitEnergyCard() {
    Color statusColor;
    IconData statusIcon;

    switch (limitStatus) {
      case 'Aktif':
        statusColor = Colors.green;
        statusIcon = Icons.check_circle;
        break;
      case 'Limit Tercapai':
        statusColor = Colors.red;
        statusIcon = Icons.warning;
        break;
      case 'Tidak Aktif':
        statusColor = Colors.orange;
        statusIcon = Icons.pause_circle;
        break;
      default:
        statusColor = Colors.grey;
        statusIcon = Icons.info;
    }

    double percentage =
        energyLimit > 0 ? (dailyEnergy / energyLimit * 100).clamp(0, 100) : 0;

    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'LIMIT ENERGI HARIAN',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Flexible(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      buildNotificationIndicator(),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(statusIcon, color: statusColor, size: 16),
                          const SizedBox(width: 4),
                          Text(
                            limitStatus,
                            style: TextStyle(
                              color: statusColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            if (energyLimit > 0) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Penggunaan: ${dailyEnergy.toStringAsFixed(1)} kWh',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  Text(
                    'Limit: ${energyLimit.toStringAsFixed(1)} kWh',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: percentage / 100,
                backgroundColor: Colors.grey[300],
                valueColor: AlwaysStoppedAnimation<Color>(
                  percentage >= 100
                      ? Colors.red
                      : percentage >= 80
                      ? Colors.orange
                      : Colors.green,
                ),
                minHeight: 8,
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  '${percentage.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color:
                        percentage >= 100
                            ? Colors.red
                            : percentage >= 80
                            ? Colors.orange
                            : Colors.green,
                  ),
                ),
              ),
            ] else ...[
              const Center(
                child: Text(
                  'Limit energi belum diatur',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
              ),
            ],

            const SizedBox(height: 16),

            if (energyLimit > 0) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      Text(
                        'SISA LIMIT',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      Text(
                        '${(energyLimit - dailyEnergy).clamp(0, double.infinity).toStringAsFixed(1)} kWh',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color:
                              dailyEnergy >= energyLimit
                                  ? Colors.red
                                  : Colors.green,
                        ),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      Text(
                        'ESTIMASI WAKTU',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      Text(
                        power > 0 && dailyEnergy < energyLimit
                            ? '${((energyLimit - dailyEnergy) / (power / 1000)).toStringAsFixed(0)} jam'
                            : '---',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget buildNotificationIndicator() {
    if (energyLimit <= 0) return const SizedBox.shrink();

    double percentage = (dailyEnergy / energyLimit * 100);

    if (percentage >= 100) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, color: Colors.white, size: 16),
            SizedBox(width: 4),
            Text(
              '',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    } else if (percentage >= 90) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning, color: Colors.white, size: 16),
            SizedBox(width: 4),
            Text(
              'KRITIS 90%+',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    } else if (percentage >= 80) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber, color: Colors.white, size: 16),
            SizedBox(width: 4),
            Text(
              'PERINGATAN 80%+',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget buildPowerDetails() {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'DETAIL DAYA',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Column(
                  children: [
                    Text(
                      'TEGANGAN',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    Row(
                      children: [
                        Text(
                          voltage.toStringAsFixed(1),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text(' V'),
                      ],
                    ),
                  ],
                ),
                Column(
                  children: [
                    Text(
                      'ARUS',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    Row(
                      children: [
                        Text(
                          current.toStringAsFixed(2),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text(' A'),
                      ],
                    ),
                  ],
                ),
                Column(
                  children: [
                    Text(
                      'DAYA',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    Row(
                      children: [
                        Text(
                          power.toStringAsFixed(1),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text(' W'),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget buildConnectionStatusIndicator() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _isConnectedToAntares ? Icons.cloud_done : Icons.cloud_off,
          color: _isConnectedToAntares ? Colors.green : Colors.red,
          size: 20,
        ),
        const SizedBox(width: 4),
        Text(
          _isConnectedToAntares ? 'Terhubung' : 'Tidak terhubung',
          style: TextStyle(
            color: _isConnectedToAntares ? Colors.green : Colors.red,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MONITORING'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          buildConnectionStatusIndicator(),
          const SizedBox(width: 8),
          IconButton(
            icon:
                isLoading
                    ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                    : const Icon(Icons.refresh),
            onPressed: isLoading ? null : fetchDataFromAntares,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                elevation: 3,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'WAKTU SEKARANG',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo[800],
                        ),
                      ),
                      Text(
                        DateFormat('HH:mm:ss').format(now),
                        style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              buildPowerDetails(),
              const SizedBox(height: 16),
              buildLimitEnergyCard(),
              const SizedBox(height: 16),

              // --- INILAH BAGIAN YANG DIUBAH ---
              // Widget Row yang berisi dua tombol kini diganti dengan satu tombol saja.
              SizedBox(
                width: double.infinity, // Membuat tombol memenuhi lebar layar
                height: 50,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const LimitenergyScreen(),
                      ),
                    ).then((_) {
                      // Ambil data terbaru setelah kembali dari halaman limit
                      fetchDataFromAntares();
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    backgroundColor: Colors.indigo,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text(
                    'Atur Limit',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),

              // --- AKHIR DARI BAGIAN YANG DIUBAH ---
              const SizedBox(height: 16),

              buildInfoCard(
                icon: Icons.bolt,
                title: 'TOTAL ENERGI / HARI',
                value: dailyEnergy.toStringAsFixed(1),
                unit: 'kWh',
                iconColor: Colors.amber[700],
              ),
              const SizedBox(height: 12),
              buildInfoCard(
                icon: Icons.watch_later_outlined,
                title: 'TOTAL ENERGI',
                value: totalEnergy.toStringAsFixed(1),
                unit: 'kWh',
                iconColor: Colors.blue[700],
              ),
              const SizedBox(height: 12),
              buildInfoCard(
                icon: Icons.cloud_outlined,
                title: 'TOTAL CO₂',
                value: totalCO2.toStringAsFixed(1),
                unit: 'kg',
                iconColor: Colors.green[700],
              ),
              const SizedBox(height: 12),
              buildInfoCard(
                icon: Icons.attach_money,
                title: 'TOTAL BIAYA',
                value: NumberFormat.currency(
                  locale: 'id',
                  symbol: 'Rp',
                  decimalDigits: 0,
                ).format(totalCost),
                unit: '',
                iconColor: Colors.purple[700],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
