import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class RecipeService {
  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  Future<List<String>> generateSubstitutions(
      String ingredient,
      Map<String, dynamic> recipeContext,
      Set<String> previousSubstitutions) async {
    try {
      final result = await _functions
          .httpsCallable('generateIngredientSubstitutions')
          .call({
        'ingredient': ingredient,
        'recipeContext': recipeContext,
        'previousSubstitutions': previousSubstitutions.toList(),
      });

      if (result.data == null) {
        throw Exception('No substitutions generated');
      }

      return List<String>.from(result.data['substitutions']);
    } catch (e) {
      print('Error generating substitutions: $e');
      throw Exception('Failed to generate substitutions');
    }
  }

  Future<void> saveSubstitution(String videoId, String originalIngredient,
      String substitution, bool isSelected) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return;

      final docRef = _firestore
          .collection('users')
          .doc(userId)
          .collection('recipeSubstitutions')
          .doc(videoId);

      // Get current data first
      final doc = await docRef.get();
      final data = doc.data() ?? {};

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
    } catch (e) {
      print('Error saving substitution: $e');
      rethrow; // Rethrow to handle error in UI
    }
  }

  Future<Map<String, Map<String, dynamic>>> loadSubstitutions(
      String videoId) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return {};

      final doc = await _firestore
          .collection('users')
          .doc(userId)
          .collection('recipeSubstitutions')
          .doc(videoId)
          .get();

      if (!doc.exists) return {};

      final rawData = doc.data()?['ingredients'];
      if (rawData == null) return {};

      final Map<String, Map<String, dynamic>> result = {};

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

      return result;
    } catch (e) {
      print('Error loading substitutions: $e');
      return {};
    }
  }

  Future<void> setSelectedSubstitution(String videoId,
      String originalIngredient, String selectedSubstitution) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return;

      final docRef = _firestore
          .collection('users')
          .doc(userId)
          .collection('recipeSubstitutions')
          .doc(videoId);

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

      // Ensure the selected substitution is in history
      if (!history.contains(selectedSubstitution) &&
          selectedSubstitution != originalIngredient) {
        history.add(selectedSubstitution);
      }

      await docRef.set({
        'ingredients': {
          originalIngredient: {
            'history': history,
            'selected': selectedSubstitution,
            'timestamp': FieldValue.serverTimestamp(),
          }
        }
      }, SetOptions(merge: true));
    } catch (e) {
      print('Error setting selected substitution: $e');
      rethrow;
    }
  }

  Future<void> removeSubstitution(
      String videoId, String originalIngredient) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return;

      final docRef = _firestore
          .collection('users')
          .doc(userId)
          .collection('recipeSubstitutions')
          .doc(videoId);

      // Get current data
      final doc = await docRef.get();
      if (!doc.exists) return;

      final data = doc.data() ?? {};
      final Map<String, dynamic> ingredients = {};

      if (data['ingredients'] != null) {
        (data['ingredients'] as Map).forEach((key, value) {
          if (key.toString() != originalIngredient) {
            ingredients[key.toString()] = value;
          }
        });
      }

      // Update with the removed ingredient
      await docRef.set({'ingredients': ingredients}, SetOptions(merge: true));
    } catch (e) {
      print('Error removing substitution: $e');
      rethrow;
    }
  }
}
