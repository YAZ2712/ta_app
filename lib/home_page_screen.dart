import 'package:flutter/material.dart';
import 'monitoring_screen.dart';
import 'predicting_screen.dart';
import 'history_screen.dart';
import 'counter_screen.dart';
import 'limitenergy_screen.dart';

class HomePageScreen extends StatelessWidget {
  const HomePageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF3CD), // warna krem background
      appBar: AppBar(
        title: const Text('HOME'),
        backgroundColor: const Color(0xFFFFA500), // orange
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 20),
            color: const Color(0xFFFFA500), // orange header
            child: const Column(
              children: [
                Icon(Icons.flash_on, color: Colors.yellow, size: 40),
                Text(
                  'PREDICTION SMART\nMETER',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 24,
                    color: Colors.black,
                  ),
                ),
                Icon(Icons.flash_on, color: Colors.yellow, size: 40),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildMenuCard(
                  context,
                  'Monitoring',
                  'assets/monitoring.png',
                  const MonitoringScreen(),
                ),
                _buildMenuCard(
                  context,
                  'Prediction',
                  'assets/predicting.png',
                  const PredictingScreen(),
                ),
                _buildMenuCard(
                  context,
                  'Control',
                  'assets/control.png',
                  const CounterScreen(),
                ),
                _buildMenuCard(
                  context,
                  'History',
                  'assets/history.png',
                  const HistoryScreen(),
                ),
                _buildMenuCard(
                  context,
                  'LimitEnergy',
                  'assets/limitenergy.png',
                  const LimitenergyScreen(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuCard(
    BuildContext context,
    String label,
    String imagePath,
    Widget targetScreen,
  ) {
    return Card(
      color: const Color(0xFFFFF3CD),
      margin: const EdgeInsets.symmetric(vertical: 10),
      elevation: 3,
      child: ListTile(
        leading: Image.asset(imagePath, width: 50),
        title: Text(
          label.toUpperCase(),
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => targetScreen),
          );
        },
      ),
    );
  }
}
