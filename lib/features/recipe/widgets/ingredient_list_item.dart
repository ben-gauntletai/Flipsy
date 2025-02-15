import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class IngredientListItem extends StatefulWidget {
  final String videoId;
  final String ingredient;
  final String? substitution;
  final Function()? onRefresh;
  final Function()? onGenerateSubstitution;
  final Function(String)? onSubstitutionSelected;
  final Set<String>? substitutionHistory;
  final Function(bool)? onHiddenStateChanged;

  const IngredientListItem({
    Key? key,
    required this.videoId,
    required this.ingredient,
    this.substitution,
    this.onRefresh,
    this.onGenerateSubstitution,
    this.onSubstitutionSelected,
    this.substitutionHistory,
    this.onHiddenStateChanged,
  }) : super(key: key);

  @override
  State<IngredientListItem> createState() => _IngredientListItemState();
}

class _IngredientListItemState extends State<IngredientListItem> {
  bool _isHidden = false;
  late SharedPreferences _prefs;

  @override
  void initState() {
    super.initState();
    _loadHiddenState();
  }

  Future<void> _loadHiddenState() async {
    _prefs = await SharedPreferences.getInstance();
    final hiddenIngredients =
        _prefs.getStringList('hidden_ingredients_${widget.videoId}') ?? [];
    if (mounted) {
      setState(() {
        _isHidden = hiddenIngredients.contains(widget.ingredient);
      });
      widget.onHiddenStateChanged?.call(_isHidden);
    }
  }

  void _toggleHidden() {
    setState(() {
      _isHidden = !_isHidden;
      final hiddenIngredients =
          _prefs.getStringList('hidden_ingredients_${widget.videoId}') ?? [];

      if (_isHidden) {
        hiddenIngredients.add(widget.ingredient);
      } else {
        hiddenIngredients.remove(widget.ingredient);
      }

      _prefs.setStringList(
          'hidden_ingredients_${widget.videoId}', hiddenIngredients);
      widget.onHiddenStateChanged?.call(_isHidden);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isHidden) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.add, size: 20),
              onPressed: _toggleHidden,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              splashRadius: 20,
            ),
            const Icon(Icons.check_circle_outline, color: Colors.grey),
          ],
        ),
        title: Text(
          widget.ingredient,
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove, size: 20),
            onPressed: _toggleHidden,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            splashRadius: 20,
          ),
          const Icon(Icons.check_circle_outline),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: PopupMenuButton<String>(
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.substitution ?? widget.ingredient),
                  ),
                  if (widget.substitution != null &&
                      widget.substitution != widget.ingredient)
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: const Icon(Icons.restore,
                          color: Colors.blue, size: 20),
                      onPressed: () => widget.onSubstitutionSelected
                          ?.call(widget.ingredient),
                      tooltip: 'Reset to Original',
                    ),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
              itemBuilder: (context) {
                final List<PopupMenuEntry<String>> items = [
                  if (widget.substitutionHistory?.isNotEmpty ?? false) ...[
                    const PopupMenuItem<String>(
                      enabled: false,
                      height: 24,
                      child: Text(
                        'Previous Substitutions',
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    ...widget.substitutionHistory!.map(
                      (sub) => PopupMenuItem<String>(
                        value: sub,
                        child: Text(sub),
                      ),
                    ),
                    const PopupMenuDivider(),
                  ],
                  PopupMenuItem<String>(
                    value: 'generate_new',
                    child: Row(
                      children: const [
                        Icon(Icons.add, color: Colors.blue),
                        SizedBox(width: 8),
                        Text(
                          'Generate New Substitution',
                          style: TextStyle(color: Colors.blue),
                        ),
                      ],
                    ),
                  ),
                ];
                return items;
              },
              onSelected: (value) {
                if (value == 'generate_new') {
                  widget.onGenerateSubstitution?.call();
                } else {
                  widget.onSubstitutionSelected?.call(value);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
