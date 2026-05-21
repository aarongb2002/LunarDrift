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
        ..style.width = '100%'
        ..style.height = '100%'
        ..allowFullscreen = true
        ..src = url
        ..allow = 'autoplay; fullscreen; picture-in-picture; encrypted-media; accelerometer; gyroscope';
    });
  } catch (e) {
    // Ignore if already registered
  }
}

Widget buildWebIframe(String url) {
  return HtmlElementView(viewType: 'iframe-$url');
}