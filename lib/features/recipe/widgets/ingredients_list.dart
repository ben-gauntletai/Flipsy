import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ingredient_list_item.dart';
import '../../../services/recipe_service.dart';

class IngredientsList extends StatefulWidget {
  final String videoId;
  final List<String> ingredients;
  final Map<String, String> substitutions;
  final Map<String, Set<String>> substitutionHistoryMap;
  final Map<String, dynamic> recipeContext;
  final Function(String, String) onSubstitutionUpdated;

  const IngredientsList({
    Key? key,
    required this.videoId,
    required this.ingredients,
    required this.substitutions,
    required this.substitutionHistoryMap,
    required this.recipeContext,
    required this.onSubstitutionUpdated,
  }) : super(key: key);

  @override
  State<IngredientsList> createState() => _IngredientsListState();
}

class _IngredientsListState extends State<IngredientsList> {
  late SharedPreferences _prefs;
  Map<String, bool> _hiddenStates = {};
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializePreferences();
  }

  Future<void> _initializePreferences() async {
    _prefs = await SharedPreferences.getInstance();
    final hiddenIngredients =
        _prefs.getStringList('hidden_ingredients_${widget.videoId}') ?? [];

    if (mounted) {
      setState(() {
        _hiddenStates = {
          for (var ingredient in widget.ingredients)
            ingredient: hiddenIngredients.contains(ingredient)
        };
        _isInitialized = true;
      });
    }
  }

  List<String> _getSortedIngredients() {
    return List<String>.from(widget.ingredients)
      ..sort((a, b) {
        final isAHidden = _hiddenStates[a] ?? false;
        final isBHidden = _hiddenStates[b] ?? false;
        if (isAHidden == isBHidden) return 0;
        return isAHidden ? 1 : -1;
      });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    final sortedIngredients = _getSortedIngredients();
    final hiddenCount =
        _hiddenStates.values.where((isHidden) => isHidden).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Show count of hidden ingredients if any are hidden
        if (hiddenCount > 0) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '$hiddenCount ingredient${hiddenCount == 1 ? '' : 's'} hidden',
              style: const TextStyle(
                color: Colors.grey,
                fontSize: 12,
              ),
            ),
          ),
        ],

        // Visible ingredients
        ...sortedIngredients.map((ingredient) {
          final currentSubstitution = widget.substitutions[ingredient];
          final history = widget.substitutionHistoryMap[ingredient] ?? {};

          return IngredientListItem(
            key: ValueKey(ingredient),
            videoId: widget.videoId,
            ingredient: ingredient,
            substitution: currentSubstitution,
            substitutionHistory: history,
            onHiddenStateChanged: (isHidden) {
              setState(() {
                _hiddenStates[ingredient] = isHidden;
              });
            },
            onGenerateSubstitution: () async {
              // Show loading indicator
              if (!context.mounted) return;
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) => const Center(
                  child: CircularProgressIndicator(),
                ),
              );

              try {
                final recipeService = RecipeService();
                final newSubstitutions =
                    await recipeService.generateSubstitutions(
                  ingredient,
                  widget.recipeContext,
                  widget.substitutionHistoryMap[ingredient] ?? {},
                  [], // Empty list - will be merged with user preferences
                );

                if (!context.mounted) return;
                Navigator.pop(context); // Dismiss loading dialog

                if (newSubstitutions.isNotEmpty) {
                  final newSubstitution = newSubstitutions.first;

                  // Save to Firestore without selecting
                  try {
                    await recipeService.saveSubstitution(
                      widget.videoId,
                      ingredient,
                      newSubstitution,
                      false, // Don't make it selected
                    );
                  } catch (e) {
                    print('Error saving substitution: $e');
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Error saving substitution'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                }
              } catch (e) {
                if (!context.mounted) return;
                Navigator.pop(context); // Dismiss loading dialog
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                        'Failed to generate substitution. Please try again.'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
            onSubstitutionSelected: (value) async {
              try {
                final recipeService = RecipeService();
                await recipeService.setSelectedSubstitution(
                  widget.videoId,
                  ingredient,
                  value,
                );
                widget.onSubstitutionUpdated(ingredient, value);
              } catch (e) {
                print('Error selecting substitution: $e');
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Error selecting substitution'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
          );
        }).toList(),

        // Add a visual separator between visible and hidden ingredients
        if (hiddenCount > 0) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 1),
          ),
        ],
      ],
    );
  }
}
