import 'package:flutter/material.dart';
import 'dart:async';
import '../../../services/recipe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class RecipeSubstitutionsPanel extends StatefulWidget {
  final String videoId;
  final List<String> ingredients;
  final List<String> dietaryTags;
  final String? recipeDescription;

  const RecipeSubstitutionsPanel({
    Key? key,
    required this.videoId,
    required this.ingredients,
    required this.dietaryTags,
    this.recipeDescription,
  }) : super(key: key);

  @override
  State<RecipeSubstitutionsPanel> createState() =>
      _RecipeSubstitutionsPanelState();
}

class _RecipeSubstitutionsPanelState extends State<RecipeSubstitutionsPanel> {
  final RecipeService _recipeService = RecipeService();
  final Map<String, String> _substitutions = {};
  final Set<String> _hiddenIngredients = {};
  bool _isLoading = false;
  String? _error;
  StreamSubscription? _substitutionSubscription;
  bool _initialized = false;
  late SharedPreferences _prefs;

  @override
  void initState() {
    super.initState();
    _setupPreferences();
    _setupSubscription();
    _loadSubstitutions();
  }

  Future<void> _setupPreferences() async {
    _prefs = await SharedPreferences.getInstance();
    final hiddenIngredients =
        _prefs.getStringList('hidden_ingredients_${widget.videoId}') ?? [];
    if (mounted) {
      setState(() {
        _hiddenIngredients.addAll(hiddenIngredients);
      });
    }
  }

  void _saveHiddenIngredients() {
    _prefs.setStringList(
      'hidden_ingredients_${widget.videoId}',
      _hiddenIngredients.toList(),
    );
  }

  void _setupSubscription() {
    _substitutionSubscription = _recipeService.substitutionStream.listen(
      (change) {
        if (mounted && change['videoId'] == widget.videoId) {
          setState(() {
            final state = change['state'] as Map<String, dynamic>;

            // Update substitutions without clearing
            state.forEach((key, value) {
              if (value is Map && value['selected'] != null) {
                _substitutions[key.toString()] = value['selected'].toString();
              }
            });

            _isLoading = false;
            _error = null;
          });
        }
      },
      onError: (error) {
        if (mounted) {
          setState(() {
            _error = error.toString();
            _isLoading = false;
          });
        }
      },
    );
  }

  Future<void> _loadSubstitutions() async {
    if (!mounted) return;

    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      // Load existing substitutions first
      final existingSubstitutions =
          await _recipeService.loadSubstitutions(widget.videoId);

      if (!mounted) return;

      // Update state with existing substitutions
      setState(() {
        // Clear only if we have new data
        if (existingSubstitutions.isNotEmpty) {
          _substitutions.clear();
          for (final entry in existingSubstitutions.entries) {
            if (entry.value['selected'] != null) {
              _substitutions[entry.key] = entry.value['selected'] as String;
            }
          }
        }
        _initialized = true;
      });

      // Only generate new substitutions if we haven't initialized yet
      if (!_initialized || _substitutions.isEmpty) {
        final substitutions = await _recipeService.getIngredientSubstitutions(
          widget.ingredients,
          widget.dietaryTags,
          widget.videoId,
          recipeDescription: widget.recipeDescription,
        );

        if (!mounted) return;

        setState(() {
          _substitutions.addAll(substitutions);
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _refreshSubstitution(String ingredient) async {
    if (!mounted) return;

    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      final newSubstitutions = await _recipeService.getIngredientSubstitutions(
        [ingredient],
        widget.dietaryTags,
        widget.videoId,
        recipeDescription: widget.recipeDescription,
      );

      if (!mounted) return;

      setState(() {
        _substitutions.addAll(newSubstitutions);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && !_initialized) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Error: $_error',
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadSubstitutions,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        ListView.builder(
          itemCount: widget.ingredients.length,
          itemBuilder: (context, index) {
            final ingredient = widget.ingredients[index];
            final substitution = _substitutions[ingredient];
            final isHidden = _hiddenIngredients.contains(ingredient);

            if (isHidden) {
              return ListTile(
                leading: IconButton(
                  icon: const Icon(Icons.add, size: 20),
                  onPressed: () {
                    setState(() {
                      _hiddenIngredients.remove(ingredient);
                      _saveHiddenIngredients();
                    });
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  splashRadius: 20,
                ),
                title: Text(
                  ingredient,
                  style: const TextStyle(color: Colors.grey),
                ),
              );
            }

            return ListTile(
              leading: IconButton(
                icon: const Icon(Icons.remove, size: 20),
                onPressed: () {
                  setState(() {
                    _hiddenIngredients.add(ingredient);
                    _saveHiddenIngredients();
                  });
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                splashRadius: 20,
              ),
              title: Text(ingredient),
              subtitle: substitution != null
                  ? Text('Substituted with: $substitution')
                  : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (substitution != null)
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: _isLoading
                          ? null
                          : () => _refreshSubstitution(ingredient),
                    ),
                  IconButton(
                    icon: Icon(
                      substitution != null
                          ? Icons.check_circle
                          : Icons.add_circle,
                      color: substitution != null ? Colors.green : null,
                    ),
                    onPressed: _isLoading
                        ? null
                        : () async {
                            if (substitution == null) {
                              await _refreshSubstitution(ingredient);
                            }
                          },
                  ),
                ],
              ),
            );
          },
        ),
        if (_isLoading)
          const Positioned.fill(
            child: Center(
              child: CircularProgressIndicator(),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _substitutionSubscription?.cancel();
    super.dispose();
  }
}
