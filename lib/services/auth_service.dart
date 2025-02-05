import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flipsy/features/auth/models/user_model.dart';
import 'dart:async';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  // Get current user
  User? get currentUser => _auth.currentUser;

  // Stream of auth state changes
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // Sign in with email and password
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      return credential;
    } catch (e) {
      throw _handleAuthException(e);
    }
  }

  // Check if display name is available
  Future<bool> isDisplayNameAvailable(String displayName) async {
    try {
      print('AuthService: Checking if display name is available: $displayName');
      final querySnapshot = await _firestore
          .collection('users')
          .where('displayName', isEqualTo: displayName)
          .get();

      final isAvailable = querySnapshot.docs.isEmpty;
      print(
          'AuthService: Display name ${isAvailable ? 'is' : 'is not'} available');
      return isAvailable;
    } catch (e) {
      print('AuthService: Error checking display name availability: $e');
      throw Exception('Failed to check display name availability: $e');
    }
  }

  // Sign up with email and password using Cloud Function
  Future<UserModel> signUpWithEmailAndPassword({
    required String email,
    required String password,
    required String displayName,
  }) async {
    print('AuthService: Starting user creation via Cloud Function');
    try {
      // Check if display name is available first
      print('AuthService: Checking display name availability: $displayName');
      final isAvailable = await isDisplayNameAvailable(displayName);
      if (!isAvailable) {
        print('AuthService: Display name is already taken: $displayName');
        throw Exception('This display name is already taken');
      }

      print('AuthService: Getting Firebase Functions instance');
      final callable = _functions.httpsCallable('createUser');
      print('AuthService: Calling createUser function with email: $email');

      final result = await callable.call({
        'email': email,
        'password': password,
        'displayName': displayName,
      });

      print('AuthService: Cloud Function result: ${result.data}');

      // Extract the UID from the Cloud Function result
      final uid = (result.data as Map<String, dynamic>)['uid'] as String;
      print('AuthService: Extracted UID from result: $uid');

      // Wait for the user profile to be available in Firestore
      print('AuthService: Waiting for user profile to be created in Firestore');
      final userProfile = await _waitForUserProfile(uid);
      print('AuthService: User profile retrieved successfully');

      // Now attempt to sign in
      try {
        print('AuthService: Attempting to sign in after profile verification');
        await _auth.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
        print('AuthService: Sign in successful');
      } catch (signInError) {
        print('AuthService: Error signing in after creation: $signInError');
        // Even if sign in fails, we continue since we have the profile
      }

      return userProfile;
    } catch (e) {
      print('AuthService: Error in signUpWithEmailAndPassword: $e');
      if (e is FirebaseFunctionsException) {
        print(
            'AuthService: Firebase Functions error details - Code: ${e.code}, Message: ${e.message}, Details: ${e.details}');
      }
      throw _handleAuthException(e);
    }
  }

  // Wait for user profile to be available in Firestore with better error handling
  Future<UserModel> _waitForUserProfile(String uid) async {
    print('AuthService: Waiting for user profile to be available');
    final completer = Completer<UserModel>();
    int attempts = 0;
    const maxAttempts = 10;
    const delayMs = 500; // 500ms delay between attempts

    Future<void> checkProfile() async {
      try {
        attempts++;
        print('AuthService: Checking for profile attempt $attempts');
        final profile = await getUserProfile(uid);

        if (profile != null) {
          print('AuthService: Profile found after $attempts attempts');
          completer.complete(profile);
        } else if (attempts >= maxAttempts) {
          print('AuthService: Max attempts reached, profile not found');
          completer.completeError(
              Exception('Failed to create user profile. Please try again.'));
        } else {
          print(
              'AuthService: Profile not found, waiting ${delayMs}ms before next attempt');
          await Future.delayed(const Duration(milliseconds: delayMs));
          await checkProfile();
        }
      } catch (e) {
        print('AuthService: Error checking profile: $e');
        if (attempts >= maxAttempts) {
          completer.completeError(e);
        } else {
          await Future.delayed(const Duration(milliseconds: delayMs));
          await checkProfile();
        }
      }
    }

    await checkProfile();
    return completer.future;
  }

  // Sign out
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } catch (e) {
      throw _handleAuthException(e);
    }
  }

  // Get user profile from Firestore
  Future<UserModel?> getUserProfile(String userId) async {
    try {
      print('AuthService: Getting user profile for uid: $userId');
      final doc = await _firestore.collection('users').doc(userId).get();

      if (!doc.exists) {
        print('AuthService: User profile document does not exist');
        return null;
      }

      try {
        print('AuthService: User profile document exists, creating UserModel');
        final userModel = UserModel.fromFirestore(doc);
        print('AuthService: UserModel created successfully');
        return userModel;
      } catch (e) {
        print('AuthService: Error converting document to UserModel: $e');
        print('AuthService: Raw document data: ${doc.data()}');
        // Instead of throwing, return null to allow graceful handling
        return null;
      }
    } catch (e) {
      print('AuthService: Error getting user profile: $e');
      // Instead of throwing, return null to allow graceful handling
      return null;
    }
  }

  // Update user profile
  Future<void> updateUserProfile(
      String userId, Map<String, dynamic> data) async {
    try {
      // Get current user data
      final doc = await _firestore.collection('users').doc(userId).get();
      if (!doc.exists) {
        throw Exception('User profile not found');
      }

      // Create update data
      final updateData = {
        ...data,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      await _firestore.collection('users').doc(userId).update(updateData);
    } catch (e) {
      throw Exception('Failed to update user profile: $e');
    }
  }

  // Handle Firebase Auth exceptions
  Exception _handleAuthException(dynamic e) {
    print('AuthService: Handling auth exception: $e');

    if (e is FirebaseFunctionsException) {
      switch (e.code) {
        case 'already-exists':
          return Exception('The email address is already in use.');
        case 'invalid-argument':
          return Exception(e.message ?? 'Invalid input provided.');
        default:
          return Exception(e.message ?? 'An unknown error occurred.');
      }
    }

    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'user-not-found':
          return Exception('No user found for that email.');
        case 'wrong-password':
          return Exception('Wrong password provided.');
        case 'email-already-in-use':
          return Exception('The email address is already in use.');
        case 'invalid-email':
          return Exception('Please enter a valid email address.');
        case 'weak-password':
          return Exception('The password provided is too weak.');
        case 'operation-not-allowed':
          return Exception('Email/password accounts are not enabled.');
        case 'user-disabled':
          return Exception('This account has been disabled.');
        case 'too-many-requests':
          return Exception('Too many attempts. Please try again later.');
        case 'network-request-failed':
          return Exception('Network error. Please check your connection.');
        default:
          return Exception('An unknown error occurred. Please try again.');
      }
    }

    return Exception('An unknown error occurred. Please try again.');
  }
}
