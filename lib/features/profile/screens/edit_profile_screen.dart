import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../auth/bloc/auth_bloc.dart';
import '../../../services/auth_service.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../../widgets/user_avatar.dart';
import '../../../widgets/loading_overlay.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({Key? key}) : super(key: key);

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final TextEditingController _displayNameController = TextEditingController();
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
      _displayNameController.text = state.user.displayName;
      _bioController.text = state.user.bio ?? '';
      _instagramController.text = state.user.instagramLink ?? '';
      _youtubeController.text = state.user.youtubeLink ?? '';
    }
  }

  @override
  void dispose() {
    _displayNameController.dispose();
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
      bool uploadComplete = false;

      // Upload new avatar if selected
      if (_imageFile != null) {
        print('EditProfileScreen: Starting avatar upload');
        try {
          final ref = FirebaseStorage.instance.ref().child(
              'avatars/${state.user.id}/${DateTime.now().millisecondsSinceEpoch}.jpg');

          final metadata = SettableMetadata(
            contentType: 'image/jpeg',
          );

          final uploadTask = ref.putData(
            await _imageFile!.readAsBytes(),
            metadata,
          );

          print('EditProfileScreen: Started upload task');

          // Show upload progress
          uploadTask.snapshotEvents.listen(
            (TaskSnapshot snapshot) {
              if (!uploadComplete && mounted) {
                final progress =
                    snapshot.bytesTransferred / snapshot.totalBytes;
                print(
                    'Upload progress: ${(progress * 100).toStringAsFixed(2)}%');
                context.read<AuthBloc>().add(ProfileUpdateProgress(progress));
              }
            },
            onError: (error) {
              print('EditProfileScreen: Error during upload progress: $error');
            },
            cancelOnError: true,
          );

          // Wait for the upload to complete
          final snapshot = await uploadTask;
          uploadComplete = true;
          print(
              'EditProfileScreen: Upload completed with state: ${snapshot.state}');

          // Get the download URL
          avatarURL = await snapshot.ref.getDownloadURL();
          print('EditProfileScreen: Got download URL: $avatarURL');

          // Clear the cached image
          if (avatarURL != null) {
            await CachedNetworkImage.evictFromCache(avatarURL);
          }
        } catch (e) {
          print('EditProfileScreen: Error uploading avatar: $e');
          rethrow;
        }
      }

      // Check if there are any changes to update
      final hasBioChange = _bioController.text.trim() != state.user.bio;
      final hasInstagramChange =
          _instagramController.text.trim() != state.user.instagramLink;
      final hasYoutubeChange =
          _youtubeController.text.trim() != state.user.youtubeLink;

      if (avatarURL != null ||
          hasBioChange ||
          hasInstagramChange ||
          hasYoutubeChange) {
        print('EditProfileScreen: Sending profile update request');

        final updateData = {
          if (hasBioChange) 'bio': _bioController.text.trim(),
          if (avatarURL != null) 'avatarURL': avatarURL,
          if (hasInstagramChange)
            'instagramLink': _instagramController.text.trim(),
          if (hasYoutubeChange) 'youtubeLink': _youtubeController.text.trim(),
        };
        print('EditProfileScreen: Update data: $updateData');

        // Add a small delay to show the 100% progress
        if (uploadComplete && mounted) {
          context.read<AuthBloc>().add(const ProfileUpdateProgress(1.0));
          await Future.delayed(const Duration(milliseconds: 300));
        }

        // Send the update request
        if (mounted) {
          context.read<AuthBloc>().add(
                ProfileUpdateRequested(
                  state.user.id,
                  updateData,
                ),
              );
        }
      } else {
        print('EditProfileScreen: No changes detected, skipping update');
        setState(() => _isLoading = false);
      }

      // Reset the image file after successful update
      if (mounted) {
        setState(() {
          _imageFile = null;
        });
      }
    } catch (e) {
      print('EditProfileScreen: Error updating profile: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Error updating profile: $e';
        });
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Error updating profile: $e'),
              backgroundColor: Colors.red,
            ),
          );
      }
    }
  }

  void _showSuccessMessage() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Profile updated successfully!'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  bool _hasUnsavedChanges() {
    final state = context.read<AuthBloc>().state;
    if (state is! Authenticated) return false;

    return _bioController.text.trim() != (state.user.bio ?? '') ||
        _imageFile != null ||
        _instagramController.text.trim() != (state.user.instagramLink ?? '') ||
        _youtubeController.text.trim() != (state.user.youtubeLink ?? '');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isLoading,
      child: BlocConsumer<AuthBloc, AuthState>(
        listenWhen: (previous, current) {
          if (previous is ProfileUpdating && current is Authenticated) {
            return true;
          }
          if (current is AuthError) {
            return true;
          }
          return false;
        },
        listener: (context, state) async {
          if (!mounted) return;

          if (state is Authenticated) {
            setState(() => _isLoading = false);
            _showSuccessMessage();
          } else if (state is AuthError) {
            setState(() {
              _isLoading = false;
              _error = state.message;
            });
            if (mounted) {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  SnackBar(
                    content: Text(state.message),
                    backgroundColor: Colors.red,
                  ),
                );
            }
          }
        },
        builder: (context, state) {
          final isUpdating = state is ProfileUpdating;
          final uploadProgress = isUpdating ? state.progress : null;

          final user = state is Authenticated
              ? state.user
              : state is ProfileUpdating
                  ? state.user
                  : null;

          if (user == null) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          return Stack(
            children: [
              Scaffold(
                backgroundColor: Colors.white,
                appBar: AppBar(
                  backgroundColor: Colors.white,
                  elevation: 0,
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.black87),
                    onPressed: isUpdating
                        ? null
                        : () {
                            if (_hasUnsavedChanges()) {
                              showDialog(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Discard Changes?'),
                                  content: const Text(
                                      'You have unsaved changes. Are you sure you want to discard them?'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('CANCEL'),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        Navigator.pop(context); // Close dialog
                                        Navigator.pop(
                                            context); // Go back to profile
                                      },
                                      child: const Text('DISCARD'),
                                    ),
                                  ],
                                ),
                              );
                            } else {
                              Navigator.pop(context);
                            }
                          },
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
                                          avatarURL: user.avatarURL,
                                          radius: 47.5,
                                          backgroundColor:
                                              user.avatarURL != null
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
                                label: 'Display Name',
                                controller: _displayNameController,
                                textCapitalization: TextCapitalization.words,
                                hintText: 'Enter your display name',
                                enabled: false,
                                showArrow: false,
                              ),
                              _buildTextField(
                                label: 'Bio',
                                controller: _bioController,
                                showArrow: true,
                                hintText: 'Add a bio to your profile',
                                showBottomDivider: false,
                                showBottomSpace: false,
                                textCapitalization:
                                    TextCapitalization.sentences,
                              ),
                              const Divider(height: 1, color: Colors.black12),
                              _buildTextField(
                                label: 'Instagram',
                                controller: _instagramController,
                                showArrow: true,
                                hintText: 'Add your Instagram username',
                                showTopSpace: true,
                                prefixIcon: Icon(
                                  FontAwesomeIcons.instagram,
                                  size: 20,
                                  color: Colors.grey[600],
                                ),
                              ),
                              _buildTextField(
                                label: 'YouTube',
                                controller: _youtubeController,
                                showArrow: true,
                                hintText: 'Add your YouTube channel',
                                prefixIcon: Icon(
                                  FontAwesomeIcons.youtube,
                                  size: 20,
                                  color: Colors.grey[600],
                                ),
                              ),
                              const SizedBox(height: 30),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: isUpdating ? null : _updateProfile,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green[700],
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 16),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    disabledBackgroundColor: Colors.grey,
                                  ),
                                  child: Text(
                                    isUpdating ? 'Saving...' : 'Save Changes',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 30),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (isUpdating)
                LoadingOverlay(
                  isLoading: true,
                  progress: uploadProgress,
                  message: uploadProgress != null && uploadProgress < 1.0
                      ? 'Uploading profile picture...'
                      : 'Updating profile...',
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    bool enabled = true,
    bool showArrow = false,
    String? hintText,
    String? helperText,
    bool showBottomDivider = true,
    bool showBottomSpace = true,
    bool showTopSpace = false,
    TextCapitalization textCapitalization = TextCapitalization.none,
    Widget? prefixIcon,
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
            if (prefixIcon != null)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 24,
                  child: Center(child: prefixIcon),
                ),
              ),
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                textCapitalization: textCapitalization,
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
                  helperText: helperText,
                  helperStyle: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 12,
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
}
