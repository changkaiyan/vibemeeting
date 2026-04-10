{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    // Force CanvasKit assets to be loaded from local static files.
    useLocalCanvasKit: true,
    canvasKitBaseUrl: "canvaskit/",
  },
});
