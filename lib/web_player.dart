import 'package:flutter/material.dart';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

void registerWebIframe(String url) {
  final String viewId = 'iframe-$url';
  try {
    ui_web.platformViewRegistry.registerViewFactory(viewId, (int id) {
      return html.IFrameElement()
        ..style.border = 'none'
        ..allowFullscreen = true
        ..src = url;
    });
  } catch (e) {
    // Ignore if already registered
  }
}

Widget buildWebIframe(String url) {
  return HtmlElementView(viewType: 'iframe-$url');
}