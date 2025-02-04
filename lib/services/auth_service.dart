import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flipsy/features/auth/models/user_model.dart';

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

  // Sign up with email and password using Cloud Function
  Future<UserModel> signUpWithEmailAndPassword({
    required String email,
    required String password,
    required String displayName,
  }) async {
    print('AuthService: Starting user creation via Cloud Function');
    try {
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

      // Wait for Firestore to complete writing
      await Future.delayed(const Duration(milliseconds: 2000));

      // Get the user profile directly
      final userProfile = await getUserProfile(uid);
      if (userProfile == null) {
        throw Exception('Failed to create user profile');
      }

      // Now attempt to sign in
      try {
        print('AuthService: Attempting to sign in after profile verification');
        await _auth.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
        print('AuthService: Sign in successful');
        return userProfile;
      } catch (signInError) {
        print('AuthService: Error signing in after creation: $signInError');
        // Even if sign in fails, return the profile since we know it exists
        return userProfile;
      }
    } catch (e) {
      print('AuthService: Error in signUpWithEmailAndPassword: $e');
      if (e is FirebaseFunctionsException) {
        print(
            'AuthService: Firebase Functions error details - Code: ${e.code}, Message: ${e.message}, Details: ${e.details}');
      }
      throw _handleAuthException(e);
    }
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

      print('AuthService: User profile document exists, creating UserModel');
      final userModel = UserModel.fromFirestore(doc);
      print('AuthService: UserModel created successfully');
      return userModel;
    } catch (e) {
      print('AuthService: Error getting user profile: $e');
      throw Exception('Failed to get user profile: $e');
    }
  }

  // Update user profile
  Future<void> updateUserProfile(
      String userId, Map<String, dynamic> data) async {
    try {
      await _firestore.collection('users').doc(userId).update({
        ...data,
        'updatedAt': FieldValue.serverTimestamp(),
      });
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
          return Exception('The email address is invalid.');
        case 'operation-not-allowed':
          return Exception('Email/password accounts are not enabled.');
        case 'weak-password':
          return Exception('The password is too weak.');
        case 'invalid-credential':
          return Exception('The email or password is incorrect.');
        default:
          return Exception(e.message ?? 'An unknown error occurred.');
      }
    }

    return Exception('An unknown error occurred. Please try again.');
  }
}
