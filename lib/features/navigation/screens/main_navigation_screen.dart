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

  static void showUserProfile(BuildContext context, String userId) {
    final state = context.findAncestorStateOfType<_MainNavigationScreenState>();
    state?.showUserProfile(userId);
  }

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class NavigationHistoryEntry {
  final int screenIndex;
  final String? profileUserId;

  NavigationHistoryEntry({
    required this.screenIndex,
    this.profileUserId,
  });
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _selectedIndex = 0;
  final GlobalKey<FeedScreenState> _feedKey = GlobalKey<FeedScreenState>();
  String? _currentProfileUserId;
  final List<NavigationHistoryEntry> _navigationHistory = [];

  bool get canGoBack => _navigationHistory.isNotEmpty;

  void _onItemTapped(int index) {
    if (index == 4) {
      // Profile tab - clear history when directly navigating to own profile
      _navigationHistory.clear();
      _currentProfileUserId = null; // Reset to show current user's profile
    }
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

  void _addToHistory() {
    _navigationHistory.add(
      NavigationHistoryEntry(
        screenIndex: _selectedIndex,
        profileUserId: _currentProfileUserId,
      ),
    );
  }

  void jumpToVideo(String videoId, {bool showBackButton = false}) {
    if (showBackButton) {
      _addToHistory();
    }
    setState(() {
      _selectedIndex = 0; // Switch to feed screen
    });
    _feedKey.currentState?.jumpToVideo(videoId);
  }

  void showUserProfile(String userId) {
    _addToHistory();
    setState(() {
      _currentProfileUserId = userId;
      _selectedIndex = 4; // Switch to profile tab
    });
  }

  void goBack() {
    if (!canGoBack) {
      setState(() {
        // If we can't go back, clear any stale state
        _currentProfileUserId = null;
      });
      return;
    }

    final previousEntry = _navigationHistory.removeLast();
    setState(() {
      _selectedIndex = previousEntry.screenIndex;
      _currentProfileUserId = previousEntry.profileUserId;
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
          FeedScreen(
            key: _feedKey,
            isVisible: _selectedIndex == 0,
            showBackButton: canGoBack,
            onBack: goBack,
          ), // Home
          const DiscoverScreen(), // Discover
          VideoUploadScreen(
              onVideoUploaded: _onVideoUploaded), // Upload screen with callback
          const Center(child: Text('Inbox')), // Inbox
          if (currentUser != null)
            ProfileScreen(
              userId: _currentProfileUserId,
              showBackButton: _currentProfileUserId != null && canGoBack,
              onBack: goBack,
            ) // Profile screen (current user or other user)
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
