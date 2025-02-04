import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../video/screens/video_upload_screen.dart';
import '../../profile/screens/profile_screen.dart';
import '../../feed/screens/feed_screen.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _selectedIndex = 0;
  final GlobalKey<FeedScreenState> _feedKey = GlobalKey<FeedScreenState>();

  void _onItemTapped(int index) {
    if (index == 2) {
      // If upload button is tapped, show upload screen
      _onUploadTapped();
    } else {
      setState(() {
        _selectedIndex = index;
      });
    }
  }

  void _onUploadTapped() async {
    // Navigate to upload screen and wait for result
    final videoId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (context) => const VideoUploadScreen(),
      ),
    );

    // If we got a video ID back, ensure we're on the feed screen and jump to the video
    if (videoId != null && mounted) {
      setState(() {
        _selectedIndex = 0; // Switch to feed screen
      });

      // Use the GlobalKey to access the FeedScreen state
      _feedKey.currentState?.jumpToVideo(videoId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          FeedScreen(key: _feedKey, isVisible: _selectedIndex == 0), // Home
          const Center(child: Text('Discover')), // Discover
          const SizedBox.shrink(), // Upload (placeholder)
          const Center(child: Text('Inbox')), // Inbox
          const Center(child: Text('Profile')), // Profile
        ],
      ),
      bottomNavigationBar: Theme(
        data: Theme.of(context).copyWith(
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
        ),
        child: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: _onItemTapped,
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.black,
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.grey,
          showSelectedLabels: true,
          showUnselectedLabels: true,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.search),
              activeIcon: Icon(Icons.search),
              label: 'Discover',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.add_box_outlined),
              activeIcon: Icon(Icons.add_box),
              label: 'Upload',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.inbox_outlined),
              activeIcon: Icon(Icons.inbox),
              label: 'Inbox',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
