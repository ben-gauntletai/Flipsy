import 'package:flutter/material.dart';
import '../../video/screens/video_upload_screen.dart';
import '../../profile/screens/profile_screen.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _selectedIndex = 0;

  static const List<Widget> _screens = [
    Center(child: Text('Home')), // Placeholder for Home/Feed screen
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
        children: _screens,
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Home',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.search),
            label: 'Search',
          ),
          BottomNavigationBarItem(
            icon: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(8),
              child: const Icon(
                Icons.add,
                color: Colors.white,
              ),
            ),
            label: 'Upload',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
