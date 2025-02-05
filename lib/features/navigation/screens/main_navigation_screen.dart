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

  static void jumpToVideo(BuildContext context, String videoId,
      {bool showBackButton = false}) {
    final state = context.findAncestorStateOfType<_MainNavigationScreenState>();
    state?.jumpToVideo(videoId, showBackButton: showBackButton);
  }

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _selectedIndex = 0;
  final GlobalKey<FeedScreenState> _feedKey = GlobalKey<FeedScreenState>();
  int? _previousIndex;

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  void _onVideoUploaded(String videoId) {
    setState(() {
      _selectedIndex = 0; // Switch to feed screen
    });
    // Use the GlobalKey to access the FeedScreen state
    _feedKey.currentState?.jumpToVideo(videoId);
  }

  void jumpToVideo(String videoId, {bool showBackButton = false}) {
    if (showBackButton) {
      _previousIndex = _selectedIndex;
    }
    setState(() {
      _selectedIndex = 0; // Switch to feed screen
    });
    _feedKey.currentState?.jumpToVideo(videoId);
  }

  void goBack() {
    if (_previousIndex != null) {
      setState(() {
        _selectedIndex = _previousIndex!;
        _previousIndex = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.watch<AuthBloc>().state;
    final currentUser = authState is Authenticated ? authState.user : null;

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          FeedScreen(
            key: _feedKey,
            isVisible: _selectedIndex == 0,
            showBackButton: _previousIndex != null,
            onBack: goBack,
          ), // Home
          const DiscoverScreen(), // Discover
          VideoUploadScreen(
              onVideoUploaded: _onVideoUploaded), // Upload screen with callback
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
