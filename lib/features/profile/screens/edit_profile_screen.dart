import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../../auth/bloc/auth_bloc.dart';
import '../../../services/auth_service.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../../widgets/user_avatar.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({Key? key}) : super(key: key);

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();
  final TextEditingController _instagramController = TextEditingController();
  final TextEditingController _youtubeController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _authService = AuthService();
  File? _imageFile;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final state = context.read<AuthBloc>().state;
    if (state is Authenticated) {
      _nameController.text = state.user.displayName;
      _bioController.text = state.user.bio ?? '';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    _bioController.dispose();
    _instagramController.dispose();
    _youtubeController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 75,
      );

      if (image != null) {
        setState(() {
          _imageFile = File(image.path);
          _error = null;
        });

        // Show confirmation dialog
        if (!mounted) return;
        final bool? shouldUpdate = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Update Profile Picture'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                        'Do you want to use this photo as your profile picture?'),
                    const SizedBox(height: 16),
                    ClipOval(
                      child: Image.file(
                        _imageFile!,
                        width: 100,
                        height: 100,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('CANCEL'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('UPDATE'),
                ),
              ],
            );
          },
        );

        if (shouldUpdate == true) {
          await _updateProfile();
        } else {
          // Reset image file if user cancels
          setState(() {
            _imageFile = null;
          });
        }
      }
    } catch (e) {
      setState(() {
        _error = 'Error picking image: $e';
      });
    }
  }

  Future<void> _updateProfile() async {
    final state = context.read<AuthBloc>().state;
    if (state is! Authenticated) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      String? avatarURL;

      // Upload new avatar if selected
      if (_imageFile != null) {
        print('EditProfileScreen: Starting avatar upload');
        try {
          final ref = FirebaseStorage.instance.ref().child(
              'avatars/${state.user.id}/${DateTime.now().millisecondsSinceEpoch}.jpg');

          // Create metadata
          final metadata = SettableMetadata(
            contentType: 'image/jpeg',
          );

          print('EditProfileScreen: Created metadata');

          // Upload file with metadata
          final uploadTask = ref.putData(
            await _imageFile!.readAsBytes(),
            metadata,
          );

          print('EditProfileScreen: Started upload task');

          // Show upload progress
          uploadTask.snapshotEvents.listen(
            (TaskSnapshot snapshot) {
              final progress = snapshot.bytesTransferred / snapshot.totalBytes;
              print('Upload progress: ${(progress * 100).toStringAsFixed(2)}%');
            },
            onError: (error) {
              print('EditProfileScreen: Error during upload progress: $error');
            },
          );

          // Wait for the upload to complete
          final snapshot = await uploadTask;
          print(
              'EditProfileScreen: Upload completed with state: ${snapshot.state}');

          // Get the download URL
          avatarURL = await snapshot.ref.getDownloadURL();
          print('EditProfileScreen: Got download URL: $avatarURL');
        } catch (e) {
          print('EditProfileScreen: Error uploading avatar: $e');
          rethrow;
        }
      }

      // Update profile using AuthBloc
      if (avatarURL != null ||
          _nameController.text.trim() != state.user.displayName ||
          _bioController.text.trim() != state.user.bio) {
        print('EditProfileScreen: Sending profile update request');
        print(
            'EditProfileScreen: Current display name: ${state.user.displayName}');
        print(
            'EditProfileScreen: New display name: ${_nameController.text.trim()}');
        print('EditProfileScreen: Current bio: ${state.user.bio}');
        print('EditProfileScreen: New bio: ${_bioController.text.trim()}');
        print('EditProfileScreen: New avatar URL: $avatarURL');

        final updateData = {
          'displayName': _nameController.text.trim(),
          'bio': _bioController.text.trim(),
          if (avatarURL != null) 'avatarURL': avatarURL,
        };
        print('EditProfileScreen: Update data: $updateData');

        context.read<AuthBloc>().add(
              ProfileUpdateRequested(
                state.user.id,
                updateData,
              ),
            );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile updated successfully!')),
          );
          Navigator.pop(context);
        }
      } else {
        print('EditProfileScreen: No changes detected, skipping update');
      }
    } catch (e) {
      print('EditProfileScreen: Error updating profile: $e');
      setState(() {
        _error = 'Error updating profile: $e';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating profile: $e')),
        );
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AuthBloc>().state;
    if (state is! Authenticated) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Edit profile',
          style: TextStyle(
            color: Colors.black87,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            color: Colors.grey[200],
            height: 1,
          ),
        ),
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 15),
              // Photo Options Row
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Change Photo Button
                  Column(
                    children: [
                      GestureDetector(
                        onTap: _pickImage,
                        child: Stack(
                          children: [
                            if (_imageFile != null)
                              ClipOval(
                                child: Image.file(
                                  _imageFile!,
                                  width: 95,
                                  height: 95,
                                  fit: BoxFit.cover,
                                ),
                              )
                            else
                              UserAvatar(
                                avatarURL: state.user.avatarURL,
                                radius: 47.5,
                                backgroundColor: state.user.avatarURL != null
                                    ? null
                                    : Colors.green[700],
                                showBorder: true,
                              ),
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.green[700],
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.camera_alt,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Change photo',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 25),
              // Form Fields
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    _buildTextField(
                      label: 'Name',
                      controller: _nameController,
                    ),
                    _buildTextField(
                      label: 'Username',
                      controller: _usernameController,
                      enabled: false,
                      hintText: state.user.displayName.toLowerCase(),
                    ),
                    _buildTextField(
                      label: 'Bio',
                      controller: _bioController,
                      showArrow: true,
                      hintText: 'Add a bio to your profile',
                      showBottomDivider: false,
                      showBottomSpace: false,
                    ),
                    const Divider(height: 1, color: Colors.black12),
                    _buildTextField(
                      label: 'Instagram',
                      controller: _instagramController,
                      showArrow: true,
                      hintText: 'Add Instagram to your profile',
                      showTopSpace: true,
                    ),
                    _buildTextField(
                      label: 'YouTube',
                      controller: _youtubeController,
                      showArrow: true,
                      hintText: 'Add YouTube to your profile',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    bool enabled = true,
    bool showArrow = false,
    String? hintText,
    bool showBottomDivider = true,
    bool showBottomSpace = true,
    bool showTopSpace = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTopSpace) const SizedBox(height: 20),
        Text(
          label,
          style: const TextStyle(
            color: Colors.black87,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                style: const TextStyle(
                  fontSize: 15,
                  color: Colors.black87,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 6),
                  border: InputBorder.none,
                  hintText: hintText,
                  hintStyle: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 15,
                  ),
                ),
              ),
            ),
            if (showArrow)
              Icon(
                Icons.chevron_right,
                color: Colors.grey[400],
                size: 22,
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (showBottomDivider) Divider(height: 1, color: Colors.grey[300]),
        if (showBottomSpace) const SizedBox(height: 20),
      ],
    );
  }

  // Show loading overlay
  Widget _buildLoadingOverlay() {
    if (!_isLoading) return const SizedBox.shrink();
    return Container(
      color: Colors.black54,
      child: const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
        ),
      ),
    );
  }
}
