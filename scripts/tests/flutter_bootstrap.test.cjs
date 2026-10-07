const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(
  path.join(__dirname, '../../flutter_app/web/flutter_bootstrap.js'), 'utf8',
).replace('{{flutter_js}}', '').replace('{{flutter_build_config}}', '');

function bootstrap(scriptUrl, mainJsPath = 'main.dart.js') {
  const build = { mainJsPath };
  let options;
  vm.runInNewContext(source, {
    URL,
    document: { currentScript: { src: scriptUrl } },
    _flutter: {
      buildConfig: { builds: [build] },
      loader: { load(value) { options = value; } },
    },
  });
  return { build, options };
}

test('main script follows the Django bootstrap version after rebuilding', () => {
  const { build, options } = bootstrap('https://localhost:8443/static/flutter_app/flutter_bootstrap.js?v=123');
  assert.equal(build.mainJsPath, 'https://localhost:8443/static/flutter_app/main.dart.js?v=123');
  assert.equal(options.config.useLocalCanvasKit, true);
});

test('standalone Flutter build works without a Django version', () => {
  assert.equal(bootstrap('https://localhost/flutter_bootstrap.js').build.mainJsPath, 'main.dart.js');
});

test('entrypoint version preserves other query parameters', () => {
  const { build } = bootstrap('https://localhost/flutter_bootstrap.js?v=456', 'main.dart.js?mode=release');
  const url = new URL(build.mainJsPath);
  assert.equal(url.searchParams.get('v'), '456');
  assert.equal(url.searchParams.get('mode'), 'release');
});
