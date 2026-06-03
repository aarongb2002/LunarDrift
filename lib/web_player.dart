import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:web/web.dart' as web;
import 'dart:ui_web' as ui_web;

String _iframeViewId(String url, int reloadKey) {
  // Incorporate reloadKey to force fresh registration when user clicks reload
  final int id = url.hashCode.abs();
  return 'vid-$id-$reloadKey';
}

void registerWebIframe(String url, {int reloadKey = 0}) {
  final String viewId = _iframeViewId(url, reloadKey);
  try {
    ui_web.platformViewRegistry.registerViewFactory(viewId, (int id) {
      // Wrapping in a Div element resolves sizing and injection issues in many WASM environments
      final web.HTMLElement wrapper = web.document.createElement('div') as web.HTMLElement;
      wrapper.style.width = '100%';
      wrapper.style.height = '100%';
      wrapper.style.backgroundColor = 'black';
      wrapper.style.overflow = 'hidden';

      final web.HTMLElement iframe = web.document.createElement('iframe') as web.HTMLElement;
      (iframe as web.HTMLIFrameElement).src = url;
      iframe.id = 'lunar-player-frame'; // Explicit ID for easier dev-tools inspection
      iframe.style.width = '100%';
      iframe.style.height = '100%';
      iframe.style.border = 'none';
      iframe.allowFullscreen = true;
      // Sends the origin (e.g., localhost) which mirrors often require to allow the embed
      iframe.setAttribute('referrerpolicy', 'origin');
      // Use setAttribute for complex attributes to ensure correct DOM mapping in Skwasm
      iframe.setAttribute('allow', 'autoplay; fullscreen; encrypted-media; picture-in-picture');
      
      wrapper.appendChild(iframe);
      return wrapper;
    });
  } catch (e) {
    // Ignore if already registered
  }
}

Widget buildWebIframe(String url, {int reloadKey = 0}) {
  return HtmlElementView(
    key: ValueKey('view-${url.hashCode.abs()}-$reloadKey'),
    viewType: _iframeViewId(url, reloadKey),
  );
}
