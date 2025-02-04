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

  static const List<Widget> _screens = [
    FeedScreen(), // Feed screen
    Center(child: Text('Search')), // Placeholder for Search screen
    Center(child: Text('Upload')), // Placeholder for Upload screen
    ProfileScreen(), // Profile screen
  ];

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

  void _onUploadTapped() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const VideoUploadScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          FeedScreen(isVisible: _selectedIndex == 0), // Feed screen
          const Center(child: Text('Search')), // Placeholder for Search screen
          const Center(child: Text('Upload')), // Placeholder for Upload screen
          const ProfileScreen(), // Profile screen
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: const BoxDecoration(
          color: Colors.black,
          border: Border(
            top: BorderSide(
              color: Colors.white12,
              width: 0.5,
            ),
          ),
        ),
        child: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          currentIndex: _selectedIndex,
          onTap: _onItemTapped,
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.white54,
          backgroundColor: Colors.transparent,
          selectedFontSize: 11,
          unselectedFontSize: 11,
          iconSize: 24,
          elevation: 0,
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.home_filled),
              activeIcon: Icon(Icons.home_filled),
              label: 'Home',
            ),
            const BottomNavigationBarItem(
              icon: FaIcon(FontAwesomeIcons.compass, size: 22),
              activeIcon: FaIcon(FontAwesomeIcons.solidCompass, size: 22),
              label: 'Discover',
            ),
            BottomNavigationBarItem(
              icon: Container(
                width: 44,
                height: 30,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.purple.shade600,
                      Colors.pink.shade500,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(
                  child: Icon(
                    Icons.add,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
              label: '',
            ),
            const BottomNavigationBarItem(
              icon: FaIcon(FontAwesomeIcons.inbox, size: 22),
              activeIcon: FaIcon(FontAwesomeIcons.boxOpen, size: 22),
              label: 'Inbox',
            ),
            const BottomNavigationBarItem(
              icon: FaIcon(FontAwesomeIcons.user, size: 22),
              activeIcon: FaIcon(FontAwesomeIcons.circleUser, size: 22),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
