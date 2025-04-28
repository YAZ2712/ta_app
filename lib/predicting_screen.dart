import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class PredictingScreen extends StatefulWidget {
  const PredictingScreen({super.key});

  @override
  State<PredictingScreen> createState() => _PredictingScreenState();
}

class _PredictingScreenState extends State<PredictingScreen> {
  late final WebViewController _controller;

  // TODO: Replace this with the actual URL of your prediction website
  final String _predictionUrl =
      'https://sincere-moccasin-likely.ngrok-free.app/genergy_daily'; // <<<--- CHANGE THIS URL

  bool _isLoading = true; // Track loading state

  @override
  void initState() {
    super.initState();

    _controller =
        WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(const Color(0x00000000))
          ..setNavigationDelegate(
            NavigationDelegate(
              onProgress: (int progress) {
                debugPrint('WebView is loading (progress : $progress%)');
              },
              onPageStarted: (String url) {
                debugPrint('Page started loading: $url');
                if (mounted) {
                  setState(() {
                    _isLoading = true;
                  });
                }
              },
              onPageFinished: (String url) {
                debugPrint('Page finished loading: $url');
                if (mounted) {
                  setState(() {
                    _isLoading = false;
                  });
                }
              },
              onWebResourceError: (WebResourceError error) {
                debugPrint('''
Page resource error:
  code: ${error.errorCode}
  description: ${error.description}
  errorType: ${error.errorType}
  isForMainFrame: ${error.isForMainFrame}
          ''');
                if (mounted) {
                  setState(() {
                    _isLoading = false;
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Gagal memuat halaman: ${error.description}',
                      ),
                    ),
                  );
                }
              },
            ),
          )
          ..loadRequest(Uri.parse(_predictionUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 1. Remove the AppBar
      // appBar: AppBar(...) // <-- REMOVED

      // 2. Use a Stack to layer the WebView and the button
      body: SafeArea(
        // 3. Use SafeArea to avoid status bar overlap
        child: Stack(
          children: [
            // 4. The WebView occupies the full space
            WebViewWidget(controller: _controller),

            // 5. Show loading indicator if needed (optional)
            if (_isLoading) const Center(child: CircularProgressIndicator()),

            // 6. Positioned Floating Back Button
            Positioned(
              top: 10.0, // Adjust padding from the top edge of SafeArea
              left: 10.0, // Adjust padding from the left edge
              child: FloatingActionButton.small(
                // Use a small FAB for compactness
                backgroundColor: Colors.black.withOpacity(
                  0.5,
                ), // Semi-transparent background
                foregroundColor: Colors.white, // Icon color
                elevation: 4.0, // Add a little shadow
                onPressed: () async {
                  // Same back logic as before
                  if (await _controller.canGoBack()) {
                    await _controller.goBack();
                  } else {
                    // If no web history, pop the Flutter route
                    if (Navigator.canPop(context)) {
                      Navigator.pop(context);
                    }
                  }
                },
                child: const Icon(
                  Icons.arrow_back_ios_new,
                ), // Use a suitable back icon
              ),
            ),
          ],
        ),
      ),
    );
  }
}
