{{flutter_js}}
{{flutter_build_config}}

// Keep the entrypoint in sync with Django's versioned bootstrap URL.
const bootstrapUrl = new URL(document.currentScript.src);
const buildVersion = bootstrapUrl.searchParams.get("v");
if (buildVersion) {
  for (const build of _flutter.buildConfig.builds) {
    if (build.mainJsPath) {
      const entrypointUrl = new URL(build.mainJsPath, bootstrapUrl);
      entrypointUrl.searchParams.set("v", buildVersion);
      build.mainJsPath = entrypointUrl.href;
    }
  }
}

_flutter.loader.load({
  config: {
    // Force CanvasKit assets to be loaded from local static files.
    useLocalCanvasKit: true,
    canvasKitBaseUrl: "canvaskit/",
  },
});
