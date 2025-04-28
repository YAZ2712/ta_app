import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:logging/logging.dart';

class ManualControlScreen extends StatefulWidget {
  final bool initialFanStatus;
  final bool initialLampStatus;
  final bool initialAcStatus;
  final bool initialDispenserStatus;
  final bool systemActive;

  const ManualControlScreen({
    super.key,
    this.initialFanStatus = false,
    this.initialLampStatus = false,
    this.initialAcStatus = false,
    this.initialDispenserStatus = false,
    this.systemActive = false,
  });

  @override
  State<ManualControlScreen> createState() => _ManualControlScreenState();
}

class _ManualControlScreenState extends State<ManualControlScreen> {
  late bool fanStatus;
  late bool lampStatus;
  late bool acStatus;
  late bool dispenserStatus;
  late bool isSystemActive;
  bool isSending = false; // Flag for API request in progress
  final logger = Logger('ManualControlScreen');

  @override
  void initState() {
    super.initState();
    fanStatus = widget.initialFanStatus;
    lampStatus = widget.initialLampStatus;
    acStatus = widget.initialAcStatus;
    dispenserStatus = widget.initialDispenserStatus;
    isSystemActive = widget.systemActive;
  }

  Future<void> updateDeviceStatus() async {
    if (isSending) return;

    setState(() {
      isSending = true;
    });

    try {
      // Create payload for Antares
      final payload = {
        'fan_status': fanStatus,
        'lamp_status': lampStatus,
        'ac_status': acStatus,
        'dispenser_status': dispenserStatus,
        'system_active': isSystemActive,
        'manual_control': true, // Flag to indicate manual control
      };

      // Convert payload to JSON string
      final jsonPayload = jsonEncode({
        'm2m:cin': {'con': jsonEncode(payload)},
      });

      // Send POST request to Antares
      final response = await http
          .post(
            Uri.parse(
              'https://platform.antares.id:8443/~/antares-cse/antares-id/TA-YAZ/COUNTER',
            ),
            headers: {
              'X-M2M-Origin': 'b1e8024f40e20d77:9f09d4019f441404',
              'Content-Type': 'application/json;ty=4',
              'Accept': 'application/json',
            },
            body: jsonPayload,
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        logger.info('Device status updated successfully');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kontrol berhasil diperbarui'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        logger.severe('Failed to update device status: ${response.statusCode}');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Gagal memperbarui kontrol perangkat'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      logger.severe('Error updating device status: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Terjadi kesalahan saat memperbarui status perangkat'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          isSending = false;
        });
      }
    }
  }

  Widget buildControlRow(String title, bool value, Function(bool) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
          ),
          Switch(value: value, onChanged: onChanged, activeColor: Colors.blue),
        ],
      ),
    );
  }

  Widget buildDeviceControlSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Kontrol Perangkat',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            buildControlRow('Kipas', fanStatus, (value) {
              setState(() {
                fanStatus = value;
              });
            }),
            const Divider(),
            buildControlRow('Lampu', lampStatus, (value) {
              setState(() {
                lampStatus = value;
              });
            }),
            const Divider(),
            buildControlRow('AC', acStatus, (value) {
              setState(() {
                acStatus = value;
              });
            }),
            const Divider(),
            buildControlRow('Dispenser', dispenserStatus, (value) {
              setState(() {
                dispenserStatus = value;
              });
            }),
          ],
        ),
      ),
    );
  }

  Widget buildSystemControlSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Kontrol Sistem',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Aktifkan Sistem',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                ),
                Switch(
                  value: isSystemActive,
                  onChanged: (value) {
                    setState(() {
                      isSystemActive = value;
                      // If system is being turned off, turn off all devices
                      if (!value) {
                        fanStatus = false;
                        lampStatus = false;
                        acStatus = false;
                        dispenserStatus = false;
                      }
                    });
                  },
                  activeColor: Colors.green,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isSystemActive
                  ? 'Sistem aktif - kontrol manual dapat digunakan'
                  : 'Sistem nonaktif - semua perangkat akan dimatikan',
              style: TextStyle(
                fontSize: 14,
                color: isSystemActive ? Colors.green[700] : Colors.red[700],
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kontrol Ruangan Manual'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () {
              showDialog(
                context: context,
                builder:
                    (context) => AlertDialog(
                      title: const Text('Bantuan Kontrol Manual'),
                      content: const SingleChildScrollView(
                        child: ListBody(
                          children: [
                            Text(
                              'Pada halaman ini Anda dapat mengendalikan perangkat secara manual:',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            SizedBox(height: 12),
                            Text(
                              '1. Aktifkan "Sistem" untuk menggunakan kontrol manual',
                            ),
                            Text(
                              '2. Gunakan tombol untuk menyalakan/mematikan setiap perangkat',
                            ),
                            Text(
                              '3. Tekan "Terapkan Perubahan" untuk mengirimkan perintah',
                            ),
                            SizedBox(height: 12),
                            Text(
                              'Catatan: Pengaturan ini akan menggantikan sistem otomatis sampai Anda menonaktifkan "Sistem".',
                              style: TextStyle(fontStyle: FontStyle.italic),
                            ),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Mengerti'),
                        ),
                      ],
                    ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              buildSystemControlSection(),
              const SizedBox(height: 16),
              buildDeviceControlSection(),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed:
                    isSystemActive
                        ? (isSending ? null : updateDeviceStatus)
                        : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child:
                    isSending
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Text(
                          'Terapkan Perubahan',
                          style: TextStyle(fontSize: 16),
                        ),
              ),
              const SizedBox(height: 16),
              Card(
                color: Colors.amber[50],
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.amber[800]),
                          const SizedBox(width: 8),
                          const Text(
                            'Informasi Penting',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Pengaturan manual akan menggantikan sistem otomatis. Untuk kembali ke mode otomatis, nonaktifkan sistem di halaman ini.',
                        style: TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
