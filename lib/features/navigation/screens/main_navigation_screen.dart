import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../video/screens/video_upload_screen.dart';
import '../../profile/screens/profile_screen.dart';
import '../../feed/screens/feed_screen.dart';
import '../../discover/screens/discover_screen.dart';
import '../../auth/bloc/auth_bloc.dart';

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
      // More/Upload button
      Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (context) => const VideoUploadScreen(),
        ),
      ).then((videoId) {
        // If we got a video ID back, ensure we're on the feed screen and jump to the video
        if (videoId != null && mounted) {
          setState(() {
            _selectedIndex = 0; // Switch to feed screen
          });
          // Use the GlobalKey to access the FeedScreen state
          _feedKey.currentState?.jumpToVideo(videoId);
        }
      });
      return;
    }

    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.watch<AuthBloc>().state;
    final currentUser = authState is Authenticated ? authState.user : null;

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          FeedScreen(key: _feedKey, isVisible: _selectedIndex == 0), // Home
          const DiscoverScreen(), // Discover
          const SizedBox.shrink(), // Upload (placeholder)
          const Center(child: Text('Inbox')), // Inbox
          if (currentUser != null)
            ProfileScreen() // Current user's profile
          else
            const Center(child: CircularProgressIndicator()),
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
              icon: Icon(Icons.more_horiz),
              activeIcon: Icon(Icons.more_horiz),
              label: 'More',
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
