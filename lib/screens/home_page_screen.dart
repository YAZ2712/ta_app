import 'package:flutter/material.dart';
import 'monitoring_screen.dart';
import 'predicting_screen.dart';
import 'history_screen.dart';
import 'counter_screen.dart';

class HomePageScreen extends StatelessWidget {
  const HomePageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [Color(0xFF667eea), Color(0xFF764ba2)],
          ),
        ),
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.of(context).size.height,
            ),
            child: Column(
              children: [
                // Hero Section
                Container(
                  height: 250,
                  width: double.infinity,
                  child: const SafeArea(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('⚡', style: TextStyle(fontSize: 48)),
                        SizedBox(height: 16),
                        Text(
                          'Smart Meter',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w300,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          'Intelligent Energy Management',
                          style: TextStyle(fontSize: 16, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ),

                // Menu Cards - Changed from SliverPadding to Padding
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 2,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: 1.1,
                    children: [
                      _buildMinimalCard(
                        context,
                        'Monitoring',
                        Icons.monitor_heart_outlined,
                        const Color(0xFF06B6D4), // cyan
                        const MonitoringScreen(),
                      ),
                      _buildMinimalCard(
                        context,
                        'Prediction',
                        Icons.auto_graph,
                        const Color(0xFF10B981), // emerald
                        const PredictingScreen(),
                      ),
                      _buildMinimalCard(
                        context,
                        'Control',
                        Icons.tune,
                        const Color(0xFFF59E0B), // amber
                        const CounterScreen(),
                      ),
                      _buildMinimalCard(
                        context,
                        'History',
                        Icons.history,
                        const Color(0xFFEF4444), // red
                        const HistoryScreen(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMinimalCard(
    BuildContext context,
    String title,
    IconData icon,
    Color color, // Added color parameter
    Widget screen,
  ) {
    return GestureDetector(
      onTap:
          () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => screen),
          ),
      child: Container(
        height: 120,
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 32,
              color: color,
            ), // Use white color for better contrast
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
