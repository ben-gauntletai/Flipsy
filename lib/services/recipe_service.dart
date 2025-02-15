import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'logging_service.dart';
import 'dart:developer' as developer;
import 'package:rxdart/rxdart.dart';

class RecipeService {
  static const String _logName = 'RecipeService';
  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final BehaviorSubject<Map<String, dynamic>> _substitutionController =
      BehaviorSubject<Map<String, dynamic>>();

  // Add this getter to expose the stream
  Stream<Map<String, dynamic>> get substitutionStream =>
      _substitutionController.stream;

  // Add this to track the current state
  final Map<String, Map<String, dynamic>> _currentState = {};

  RecipeService() {
    _testLogging();
    LoggingService.logInfo('🔄 RecipeService constructor called',
        name: _logName);
    LoggingService.logDebug(
      'Initializing with instances',
      name: _logName,
      data: {
        'functions': _functions != null,
        'firestore': _firestore != null,
        'auth': _auth != null,
      },
    );
  }

  void _testLogging() {
    print('\n🧪 TESTING LOGGING SYSTEM 🧪');
    developer.log('TEST: Direct developer log');
    print('TEST: Direct print statement');

    LoggingService.logInfo('Test info message', name: _logName);
    LoggingService.logError(
      'Test error message',
      name: _logName,
      error: Exception('Test error'),
      stackTrace: StackTrace.current,
    );
    LoggingService.logWarning('Test warning message', name: _logName);
    LoggingService.logSuccess('Test success message', name: _logName);
    LoggingService.logDebug(
      'Test debug message',
      name: _logName,
      data: {'test': 'data'},
    );
    print('🧪 LOGGING TEST COMPLETE 🧪\n');
  }

  Future<List<String>> generateSubstitutions(
      String ingredient,
      Map<String, dynamic> recipeContext,
      Set<String> previousSubstitutions) async {
    LoggingService.logInfo(
      '📝 Starting generateSubstitutions',
      name: _logName,
    );
    LoggingService.logDebug(
      'Input parameters',
      name: _logName,
      data: {
        'ingredient': ingredient,
        'recipeContext': recipeContext,
        'previousSubstitutions': previousSubstitutions.toList(),
      },
    );

    try {
      LoggingService.logInfo(
        '🔄 Calling Cloud Function: generateIngredientSubstitutions',
        name: _logName,
      );

      final result = await _functions
          .httpsCallable('generateIngredientSubstitutions')
          .call({
        'ingredient': ingredient,
        'recipeContext': recipeContext,
        'previousSubstitutions': previousSubstitutions.toList(),
      });

      LoggingService.logDebug(
        'Raw Cloud Function response',
        name: _logName,
        data: result.data,
      );

      if (result.data == null) {
        LoggingService.logError(
          '❌ Null response from Cloud Function',
          name: _logName,
        );
        throw Exception('No substitutions generated - null response');
      }

      final substitutions = List<String>.from(result.data['substitutions']);
      LoggingService.logSuccess(
        '✅ Generated ${substitutions.length} substitutions',
        name: _logName,
      );
      LoggingService.logDebug(
        'Generated substitutions',
        name: _logName,
        data: substitutions,
      );

      return substitutions;
    } catch (e, stackTrace) {
      LoggingService.logError(
        '❌ Error in generateSubstitutions',
        name: _logName,
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> saveSubstitution(String videoId, String originalIngredient,
      String substitution, bool isSelected) async {
    LoggingService.logInfo(
      '📝 Starting saveSubstitution',
      name: _logName,
    );
    LoggingService.logDebug(
      'Input parameters',
      name: _logName,
      data: {
        'videoId': videoId,
        'originalIngredient': originalIngredient,
        'substitution': substitution,
        'isSelected': isSelected,
      },
    );

    try {
      final userId = _auth.currentUser?.uid;
      LoggingService.logDebug(
        'Current user state',
        name: _logName,
        data: {'userId': userId},
      );

      if (userId == null) {
        LoggingService.logError(
          '❌ Authentication required - No user ID',
          name: _logName,
        );
        throw Exception('User must be authenticated to save substitutions');
      }

      final docRef = _firestore
          .collection('users')
          .doc(userId)
          .collection('recipeSubstitutions')
          .doc(videoId);

      LoggingService.logInfo(
        '🔄 Fetching existing document',
        name: _logName,
      );

      final doc = await docRef.get();
      final data = doc.data() ?? {};

      LoggingService.logDebug(
        'Existing document data',
        name: _logName,
        data: data,
      );

      // Safely cast the ingredients map
      final Map<String, dynamic> ingredientData = {};
      if (data['ingredients'] != null) {
        (data['ingredients'] as Map).forEach((key, value) {
          ingredientData[key.toString()] = value as Map<String, dynamic>;
        });
      }

      // Get or initialize the ingredient's data
      final Map<String, dynamic> currentIngredientData =
          (ingredientData[originalIngredient] as Map<String, dynamic>?) ??
              {
                'history': <String>[],
                'selected': originalIngredient,
              };

      // Get current history and ensure it's a List<String>
      final List<String> history = [];
      if (currentIngredientData['history'] != null) {
        for (var item in (currentIngredientData['history'] as List)) {
          history.add(item.toString());
        }
      }

      // Add new substitution to history if not already present
      if (!history.contains(substitution)) {
        history.add(substitution);
      }

      // Update the document with merged data
      await docRef.set({
        'ingredients': {
          originalIngredient: {
            'history': history,
            'selected':
                isSelected ? substitution : currentIngredientData['selected'],
            'timestamp': FieldValue.serverTimestamp(),
          }
        }
      }, SetOptions(merge: true));

      LoggingService.logSuccess(
        '✅ Successfully saved substitution',
        name: _logName,
      );
    } catch (e, stackTrace) {
      LoggingService.logError(
        '❌ Error in saveSubstitution',
        name: _logName,
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<Map<String, Map<String, dynamic>>> loadSubstitutions(
      String videoId) async {
    LoggingService.logInfo(
      '📝 Starting loadSubstitutions for videoId: $videoId',
      name: _logName,
    );

    try {
      final userId = _auth.currentUser?.uid;
      LoggingService.logDebug(
        'Auth state check',
        name: _logName,
        data: {'userId': userId != null},
      );

      if (userId == null) {
        LoggingService.logInfo(
          'No user authenticated, returning empty substitutions',
          name: _logName,
        );
        return {};
      }

      final docRef = _firestore
          .collection('users')
          .doc(userId)
          .collection('recipeSubstitutions')
          .doc(videoId);

      LoggingService.logDebug(
        'Attempting to fetch document',
        name: _logName,
        data: {'path': docRef.path},
      );

      final doc = await docRef.get();

      if (!doc.exists) {
        LoggingService.logInfo(
          'No substitutions document exists for this video',
          name: _logName,
        );
        return {};
      }

      final rawData = doc.data()?['ingredients'];
      if (rawData == null) {
        LoggingService.logInfo(
          'No ingredients data in document',
          name: _logName,
        );
        return {};
      }

      final Map<String, Map<String, dynamic>> result = {};

      try {
        (rawData as Map).forEach((key, value) {
          if (value is Map) {
            final Map<String, dynamic> ingredientData = {};

            // Safely convert history to List<String>
            final List<String> history = [];
            if (value['history'] != null) {
              for (var item in (value['history'] as List)) {
                history.add(item.toString());
              }
            }

            ingredientData['history'] = history;
            ingredientData['selected'] =
                value['selected']?.toString() ?? key.toString();
            ingredientData['timestamp'] = value['timestamp'];

            result[key.toString()] = ingredientData;
          }
        });

        LoggingService.logSuccess(
          'Successfully processed substitutions',
          name: _logName,
        );

        // Update local state and notify listeners
        _currentState[videoId] = rawData as Map<String, dynamic>;
        _notifySubstitutionChange(videoId, rawData);

        return result;
      } catch (e, stackTrace) {
        LoggingService.logError(
          'Error processing ingredients data',
          name: _logName,
          error: e,
          stackTrace: stackTrace,
        );
        return {};
      }
    } catch (e, stackTrace) {
      LoggingService.logError(
        'Error loading substitutions',
        name: _logName,
        error: e,
        stackTrace: stackTrace,
      );
      return {};
    }
  }

  Future<void> setSelectedSubstitution(
    String videoId,
    String originalIngredient,
    String substitution,
  ) async {
    LoggingService.logInfo(
      '📝 Setting substitution for videoId: $videoId',
      name: _logName,
    );

    try {
      // Check if user is authenticated
      final userId = _auth.currentUser?.uid;
      LoggingService.logDebug(
        'Auth state check',
        name: _logName,
        data: {'userId': userId != null},
      );

      if (userId == null) {
        throw Exception('User must be authenticated');
      }

      // Get the document reference
      final docRef = _firestore
          .collection('users')
          .doc(userId)
          .collection('recipeSubstitutions')
          .doc(videoId);

      LoggingService.logDebug(
        'Fetching current document state',
        name: _logName,
        data: {'path': docRef.path},
      );

      // Get current document state
      final docSnapshot = await docRef.get();
      final currentData = docSnapshot.data() ?? {};
      final currentIngredients =
          currentData['ingredients'] as Map<String, dynamic>? ?? {};

      // Prepare the update data
      final ingredientData = {
        'ingredients': {
          originalIngredient: {
            'history': [substitution],
            'selected': substitution,
            'timestamp': FieldValue.serverTimestamp(),
          }
        }
      };

      LoggingService.logDebug(
        'Updating document',
        name: _logName,
        data: ingredientData,
      );

      // Update the document
      await docRef.set(ingredientData, SetOptions(merge: true));

      // Notify listeners of the change
      _notifySubstitutionChange(videoId, ingredientData);

      LoggingService.logSuccess(
        'Successfully updated substitution',
        name: _logName,
      );
    } catch (e, stackTrace) {
      LoggingService.logError(
        '❌ Error in setSelectedSubstitution',
        name: _logName,
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  void _notifySubstitutionChange(
      String videoId, Map<String, dynamic> ingredients) {
    try {
      // Ensure we're always sending ingredients in the same format
      final Map<String, dynamic> state =
          Map<String, dynamic>.from(_currentState[videoId] ?? {});

      // Merge new ingredients with existing state
      if (ingredients is Map) {
        ingredients.forEach((key, value) {
          if (value is Map<String, dynamic>) {
            // Get existing ingredient data
            final Map<String, dynamic> existingData =
                Map<String, dynamic>.from(state[key] ?? {});

            // Get current history
            final List<String> history =
                List<String>.from(existingData['history'] ?? []);

            // Add new substitution to history if not present
            if (value['selected'] != null &&
                !history.contains(value['selected'])) {
              history.add(value['selected'].toString());
            }

            // Update state with merged data
            state[key] = {
              'history': history,
              'selected': value['selected'] ?? existingData['selected'],
              'timestamp': value['timestamp'] ?? existingData['timestamp'],
            };
          }
        });
      }

      // Update local state
      _currentState[videoId] = state;

      // Notify listeners with complete state
      _substitutionController.add({
        'videoId': videoId,
        'state': state,
      });

      LoggingService.logDebug(
        'Notifying state change',
        name: _logName,
        data: {'videoId': videoId, 'state': state},
      );
    } catch (e, stackTrace) {
      LoggingService.logError(
        'Error notifying substitution change',
        name: _logName,
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> removeSubstitution(
      String videoId, String originalIngredient) async {
    LoggingService.logInfo(
      '📝 Starting removal of substitution',
      name: _logName,
    );
    LoggingService.logDebug(
      'Input parameters',
      name: _logName,
      data: {
        'videoId': videoId,
        'originalIngredient': originalIngredient,
      },
    );

    try {
      final userId = _auth.currentUser?.uid;
      LoggingService.logDebug(
        'Auth state check',
        name: _logName,
        data: {'userId': userId != null},
      );

      if (userId == null) {
        LoggingService.logWarning(
          'Cannot remove substitution - no user authenticated',
          name: _logName,
        );
        return;
      }

      final docRef = _firestore
          .collection('users')
          .doc(userId)
          .collection('recipeSubstitutions')
          .doc(videoId);

      LoggingService.logDebug(
        'Fetching document for removal',
        name: _logName,
        data: {'path': docRef.path},
      );

      // Get current data
      final doc = await docRef.get();
      if (!doc.exists) {
        LoggingService.logInfo(
          'No document exists to remove substitution from',
          name: _logName,
        );
        return;
      }

      final data = doc.data() ?? {};
      final Map<String, dynamic> ingredients = {};

      if (data['ingredients'] != null) {
        (data['ingredients'] as Map).forEach((key, value) {
          if (key.toString() != originalIngredient) {
            ingredients[key.toString()] = value;
          }
        });
      }

      LoggingService.logDebug(
        'Removing ingredient from document',
        name: _logName,
        data: {
          'removedIngredient': originalIngredient,
          'remainingIngredientsCount': ingredients.length,
        },
      );

      // Update with the removed ingredient
      await docRef.set({'ingredients': ingredients}, SetOptions(merge: true));

      LoggingService.logSuccess(
        'Successfully removed substitution',
        name: _logName,
      );
    } catch (e, stackTrace) {
      LoggingService.logError(
        'Error removing substitution',
        name: _logName,
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<List<String>> getUserDietaryPreferences() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return [];
      }

      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (!userDoc.exists) {
        return [];
      }

      final userData = userDoc.data();
      if (userData == null) {
        return [];
      }

      return List<String>.from(userData['dietaryTags'] ?? []);
    } catch (e, stackTrace) {
      LoggingService.logError(
        '❌ Error fetching user dietary preferences',
        name: _logName,
        error: e,
        stackTrace: stackTrace,
      );
      return [];
    }
  }

  Future<Map<String, String>> getIngredientSubstitutions(
    List<String> ingredients,
    List<String> dietaryTags,
    String videoId, {
    String? recipeDescription,
  }) async {
    LoggingService.logInfo(
      '📝 Starting getIngredientSubstitutions',
      name: _logName,
    );

    try {
      // Validate inputs
      if (ingredients.isEmpty) {
        throw Exception('No ingredients provided');
      }

      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        throw Exception('User must be authenticated');
      }

      // Get user's dietary preferences and merge with provided tags
      final userPreferences = await getUserDietaryPreferences();
      final mergedTags = {...dietaryTags, ...userPreferences}.toList();

      LoggingService.logDebug(
        'Merged dietary tags',
        name: _logName,
        data: {
          'providedTags': dietaryTags,
          'userPreferences': userPreferences,
          'mergedTags': mergedTags,
        },
      );

      // Load existing substitutions first
      final existingSubstitutions = await loadSubstitutions(videoId);
      final Map<String, String> currentSubstitutions = {};

      // Convert existing substitutions to the expected format
      for (final entry in existingSubstitutions.entries) {
        if (entry.value['selected'] != null &&
            entry.value['selected'] != entry.key) {
          currentSubstitutions[entry.key] = entry.value['selected'] as String;
        }
      }

      // Call cloud function with merged tags
      final result =
          await _functions.httpsCallable('getIngredientSubstitutions').call({
        'ingredients': ingredients,
        'dietaryTags': mergedTags,
        'existingSubstitutions': currentSubstitutions,
        if (recipeDescription != null && recipeDescription.trim().isNotEmpty)
          'recipeDescription': recipeDescription.trim(),
        'userId': userId,
        'videoId': videoId,
      });

      if (result.data == null) {
        return {};
      }

      final Map<String, dynamic> responseData =
          Map<String, dynamic>.from(result.data);
      final Map<String, dynamic> rawSubstitutions =
          Map<String, dynamic>.from(responseData['substitutions'] ?? {});
      final Map<String, String> substitutions = {};

      // Convert raw substitutions to string map
      rawSubstitutions.forEach((key, value) {
        substitutions[key.toString()] = value.toString();
      });

      // Get current document state
      final docRef = _firestore
          .collection('users')
          .doc(userId)
          .collection('recipeSubstitutions')
          .doc(videoId);

      final docSnapshot = await docRef.get();
      final currentData = docSnapshot.data() ?? {};
      final currentIngredients =
          currentData['ingredients'] as Map<String, dynamic>? ?? {};

      // Prepare the update data
      final Map<String, dynamic> updatedIngredients =
          Map<String, dynamic>.from(currentIngredients);

      // Update ingredients data
      for (final entry in substitutions.entries) {
        final ingredient = entry.key.trim();
        final substitution = entry.value.trim();

        // Get current history
        final List<String> history =
            (updatedIngredients[ingredient]?['history'] as List<dynamic>?)
                    ?.map((e) => e.toString())
                    .toList() ??
                [];

        // Add new substitution to history if not present
        if (!history.contains(substitution)) {
          history.add(substitution);
        }

        updatedIngredients[ingredient] = {
          'history': history,
          'selected': substitution,
          'timestamp': FieldValue.serverTimestamp(),
        };
      }

      // Single write to Firestore
      await docRef.set({
        'ingredients': updatedIngredients,
        'appliedPreferences': dietaryTags,
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // Notify listeners with the updated state
      _notifySubstitutionChange(videoId, updatedIngredients);

      return substitutions;
    } catch (e, stackTrace) {
      LoggingService.logError(
        '❌ Error in getIngredientSubstitutions',
        name: _logName,
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  void dispose() {
    _substitutionController.close();
  }
}
