import 'package:flutter/material.dart';

class SpicinessSelector extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  final bool enabled;

  const SpicinessSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  // Using hollow chili pepper emoji 🌶️
  static const pepperEmoji = '🌶️';

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (index) {
        final isSelected = index < value;
        return GestureDetector(
          onTap: enabled
              ? () {
                  // If tapping the same pepper that's already selected as the max,
                  // reset to 0, otherwise set to index + 1
                  if (value == index + 1) {
                    onChanged(0);
                  } else {
                    onChanged(index + 1);
                  }
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            child: Text(
              pepperEmoji,
              style: TextStyle(
                fontSize: 24,
                color: isSelected ? null : Colors.grey.withOpacity(0.5),
              ),
            ),
          ),
        );
      }),
    );
  }
}
