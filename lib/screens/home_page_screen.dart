import 'package:flutter/material.dart';
import 'monitoring_screen.dart';
import 'predicting_screen.dart';
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
        child: SafeArea(
          child: Column(
            children: [
              // Hero Section - Reduced height
              SizedBox(
                height: 200,
                width: double.infinity,
                child: const Column(
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

              // Spacer to push content to center
              // const Spacer(),

              // Menu Cards - Centered layout
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // First row - 2 cards
                      Row(
                        children: [
                          Expanded(
                            child: _buildMinimalCard(
                              context,
                              'Monitoring',
                              Icons.monitor_heart_outlined,
                              const Color(0xFF06B6D4),
                              const MonitoringScreen(),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _buildMinimalCard(
                              context,
                              'Prediction',
                              Icons.auto_graph,
                              const Color(0xFF10B981),
                              const PredictingScreen(),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Second row - 1 card centered
                      Row(
                        children: [
                          const Spacer(),
                          Expanded(
                            child: _buildMinimalCard(
                              context,
                              'Control',
                              Icons.tune,
                              const Color(0xFFF59E0B),
                              const CounterScreen(),
                            ),
                          ),
                          const Spacer(),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Bottom spacer
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMinimalCard(
    BuildContext context,
    String title,
    IconData icon,
    Color color,
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
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 32, color: color),
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
