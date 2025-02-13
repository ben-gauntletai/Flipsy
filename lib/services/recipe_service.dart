import 'package:cloud_functions/cloud_functions.dart';

class RecipeService {
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  Future<List<String>> generateSubstitutions(
      String ingredient, Map<String, dynamic> recipeContext) async {
    try {
      final result = await _functions
          .httpsCallable('generateIngredientSubstitutions')
          .call({
        'ingredient': ingredient,
        'recipeContext': recipeContext,
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
}
