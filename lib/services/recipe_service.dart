import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'logging_service.dart';
import 'dart:developer' as developer;

class RecipeService {
  static const String _logName = 'RecipeService';
  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

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

  Future<void> setSelectedSubstitution(String videoId,
      String originalIngredient, String selectedSubstitution) async {
    LoggingService.logInfo(
      '📝 Setting substitution for videoId: $videoId',
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
        LoggingService.logWarning(
          'Cannot set substitution - no user authenticated',
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
        'Fetching current document state',
        name: _logName,
        data: {'path': docRef.path},
      );

      // Get current data to ensure we don't lose history
      final doc = await docRef.get();
      final data = doc.data() ?? {};

      // Safely cast the ingredients map
      final Map<String, dynamic> ingredientData = {};
      if (data['ingredients'] != null) {
        (data['ingredients'] as Map).forEach((key, value) {
          ingredientData[key.toString()] = value as Map<String, dynamic>;
        });
      }

      // Get current history and ensure it's a List<String>
      final List<String> history = [];
      if (ingredientData[originalIngredient]?['history'] != null) {
        for (var item
            in (ingredientData[originalIngredient]!['history'] as List)) {
          history.add(item.toString());
        }
      }

      // Add new substitution to history if not already present
      if (!history.contains(selectedSubstitution) &&
          selectedSubstitution != originalIngredient) {
        history.add(selectedSubstitution);
        LoggingService.logDebug(
          'Added new substitution to history',
          name: _logName,
          data: {'newSubstitution': selectedSubstitution},
        );
      }

      final updateData = {
        'ingredients': {
          originalIngredient: {
            'history': history,
            'selected': selectedSubstitution,
            'timestamp': FieldValue.serverTimestamp(),
          }
        }
      };

      LoggingService.logDebug(
        'Updating document',
        name: _logName,
        data: updateData,
      );

      await docRef.set(updateData, SetOptions(merge: true));

      LoggingService.logSuccess(
        'Successfully updated substitution',
        name: _logName,
      );
    } catch (e, stackTrace) {
      LoggingService.logError(
        'Error setting substitution',
        name: _logName,
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
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
}
