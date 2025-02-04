import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class UserAvatar extends StatelessWidget {
  final String? avatarURL;
  final double radius;
  final Color? backgroundColor;
  final bool showBorder;

  const UserAvatar({
    Key? key,
    this.avatarURL,
    this.radius = 20,
    this.backgroundColor,
    this.showBorder = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor ?? Colors.grey[300],
      child: Container(
        decoration: showBorder
            ? BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white,
                  width: 2,
                ),
              )
            : null,
        child: ClipOval(
          child: avatarURL != null && avatarURL!.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: avatarURL!,
                  width: radius * 2,
                  height: radius * 2,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Center(
                    child: SizedBox(
                      width: radius,
                      height: radius,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.grey[400],
                      ),
                    ),
                  ),
                  errorWidget: (context, url, error) {
                    print('Error loading avatar: $error');
                    return Icon(
                      Icons.person,
                      size: radius,
                      color: Colors.grey[600],
                    );
                  },
                )
              : Icon(
                  Icons.person,
                  size: radius,
                  color: Colors.grey[600],
                ),
        ),
      ),
    );
  }
}
