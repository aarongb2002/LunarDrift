import 'package:flutter/material.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:google_sign_in_web/google_sign_in_web.dart' as web;

Widget buildWebSignInButton() {
  return SizedBox(
    height: 50,
    child: (GoogleSignInPlatform.instance as web.GoogleSignInPlugin).renderButton(
      configuration: web.GSIButtonConfiguration(
        theme: web.GSIButtonTheme.filledBlack,
        size: web.GSIButtonSize.large,
        minimumWidth: 400.0,
      ),
    ),
  );
}