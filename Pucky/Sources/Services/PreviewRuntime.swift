import Foundation

/// Static assets for the in-app preview runtimes.
///
/// This file defines reusable runtime profiles. A `ProjectTemplate`
/// picks one by data, so services do not need template-specific
/// branches just to know how preview bootstrapping works.
enum PreviewRuntime {
    static func reactNativePreview(entryPoint: String) -> ProjectTemplate.PreviewConfiguration {
        let entryModulePath = TransformService.webviewPath(forSource: entryPoint)
        return .init(
            entryPoint: entryPoint,
            runtimeFiles: [
                .init(path: "pucky-runtime.js", body: appRuntimeJS),
                .init(path: "pucky-bootstrap.js", body: reactNativeBootstrapJS(entryModulePath: entryModulePath)),
                .init(path: "index.html", body: reactNativeIndexHTML()),
            ],
            bundledResources: []
        )
    }

    static func threeDeePreview(entryPoint: String) -> ProjectTemplate.PreviewConfiguration {
        let entryModulePath = TransformService.webviewPath(forSource: entryPoint)
        return .init(
            entryPoint: entryPoint,
            runtimeFiles: [
                .init(path: "pucky-bootstrap.js", body: threeDeeBootstrapJS(entryModulePath: entryModulePath, sourceEntryPoint: entryPoint)),
                .init(path: "index.html", body: threeDeeIndexHTML()),
            ],
            bundledResources: [
                .init(
                    sourceName: "three.module.min",
                    sourceExtension: "js",
                    destinationPath: "three.module.min.js"
                ),
            ]
        )
    }

    /// Minimal React-compatible vdom + React Native primitives. Not
    /// even close to the real implementations — just enough surface
    /// area for the kind of single-screen apps Gemma 4 emits via
    /// `replace_code` / `edit_code`: function components, hooks,
    /// View / Text / Pressable / ScrollView / Image / TextInput,
    /// StyleSheet.create, Flexbox layout, and AppRegistry.
    static let appRuntimeJS: String = #"""
    // Pucky preview runtime. Pure ES module. No build step.
    // Exported as both `react` and `react-native` via the importmap.

    // ---------- React Fast Refresh stubs ----------
    //
    // Oxc's JSX transform runs with React Fast Refresh enabled
    // and emits module footers like `$RefreshReg$(_c, "App")` at
    // the top level of every component file. Those symbols are
    // provided by real dev servers (Vite, Webpack dev server,
    // Next.js) and are undefined in our minimal runtime. Without
    // these stubs the very first call throws `ReferenceError:
    // $RefreshReg$ is not defined` while the module is evaluating,
    // which aborts the whole import chain and leaves the preview
    // blank. Wiring real HMR into this runtime is not a goal; we
    // just need the symbols to exist so the emitted footer is a
    // no-op. The upstream Rust transformer is where we'd really
    // like to disable the refresh pass, but until the XCFramework
    // is rebuilt these shims unblock everything.
    globalThis.$RefreshReg$ = globalThis.$RefreshReg$ || (() => {});
    globalThis.$RefreshSig$ = globalThis.$RefreshSig$ || (() => (type) => type);

    // ---------- vdom ----------

    let currentRoot = null;          // top-level mounted vdom
    let rootContainer = null;        // host DOM node we render into
    let currentFiber = null;         // hook ownership for the in-flight render
    const fiberStateByKey = new Map(); // persistent hook state across renders
    const visitedFiberKeys = new Set(); // populated each render so we can evict stale entries

    // Build a stable key for a vdom node. Honors the explicit React
    // `key` prop when present so reordered or conditionally-rendered
    // siblings keep their hook state. Falls back to positional index
    // when no key was given. Without explicit key handling a list
    // shuffle would silently reassign one component's `useState` to
    // a sibling's slot.
    function makeKey(parentKey, index, type, explicitKey) {
      const tag = typeof type === 'function' ? (type.name || 'fn') : String(type);
      const slot = explicitKey != null ? `k:${explicitKey}` : `i:${index}`;
      return `${parentKey}/${slot}:${tag}`;
    }

    export function createElement(type, props, ...children) {
      const flat = [];
      const push = (c) => {
        if (c == null || c === false || c === true) return;
        if (Array.isArray(c)) { c.forEach(push); return; }
        flat.push(c);
      };
      children.forEach(push);
      // Pull React's `key` prop out of props since it isn't supposed
      // to be visible to the rendered component (it's renderer
      // metadata, not a prop) but DO keep it on the vdom node so
      // `renderNode` can pass it into `makeKey`.
      const cleanProps = props ? { ...props } : {};
      const key = cleanProps.key;
      delete cleanProps.key;
      return { type, key, props: cleanProps, children: flat };
    }

    export const Fragment = Symbol.for('pucky.fragment');

    // React 17+ "automatic" JSX runtime entry points. Oxc emits
    // imports against `react/jsx-runtime` and `react/jsx-dev-runtime`
    // by default, expecting `jsx`, `jsxs`, `jsxDEV`, and `Fragment`
    // as named exports. The importmap maps both subpath specifiers
    // back to this file, and these helpers normalise the
    // children-in-props shape into our `createElement(type, props,
    // ...children)` vdom builder. The `key` argument from the JSX
    // runtime is forwarded onto the vdom node so the renderer can
    // distinguish reordered siblings.
    function jsxImpl(type, props, key) {
      const { children, ...rest } = props || {};
      const flat = children == null
        ? []
        : (Array.isArray(children) ? children : [children]);
      const node = createElement(type, rest, ...flat);
      if (key != null) node.key = key;
      return node;
    }
    export const jsx = jsxImpl;
    export const jsxs = jsxImpl;
    // jsxDEV gets extra source/self args from Oxc dev mode that we
    // simply ignore — they're only useful for React DevTools.
    export function jsxDEV(type, props, key) { return jsxImpl(type, props, key); }

    function useHook(slot, init) {
      const key = currentFiber.key;
      let bucket = fiberStateByKey.get(key);
      if (!bucket) { bucket = []; fiberStateByKey.set(key, bucket); }
      while (bucket.length <= slot) bucket.push(undefined);
      if (bucket[slot] === undefined) bucket[slot] = init();
      return bucket[slot];
    }

    export function useState(initial) {
      const slot = currentFiber.hookCount++;
      const cell = useHook(slot, () => ({
        value: typeof initial === 'function' ? initial() : initial,
      }));
      const setter = (next) => {
        const resolved = typeof next === 'function' ? next(cell.value) : next;
        if (Object.is(resolved, cell.value)) return;
        cell.value = resolved;
        scheduleRender();
      };
      return [cell.value, setter];
    }

    export function useReducer(reducer, initial, init) {
      const [state, setState] = useState(init ? init(initial) : initial);
      const dispatch = (action) => setState((s) => reducer(s, action));
      return [state, dispatch];
    }

    export function useRef(initial) {
      const slot = currentFiber.hookCount++;
      return useHook(slot, () => ({ current: initial }));
    }

    export function useMemo(factory, deps) {
      const slot = currentFiber.hookCount++;
      const cell = useHook(slot, () => ({ deps: null, value: undefined }));
      if (!cell.deps || !depsEqual(cell.deps, deps)) {
        cell.deps = deps;
        cell.value = factory();
      }
      return cell.value;
    }

    export function useCallback(fn, deps) {
      return useMemo(() => fn, deps);
    }

    const pendingEffects = [];
    export function useEffect(fn, deps) {
      const slot = currentFiber.hookCount++;
      const cell = useHook(slot, () => ({ deps: null, cleanup: null }));
      const changed = !cell.deps || !depsEqual(cell.deps, deps);
      if (changed) {
        pendingEffects.push(() => {
          if (cell.cleanup) { try { cell.cleanup(); } catch (e) { console.error(e); } }
          const next = fn();
          cell.cleanup = typeof next === 'function' ? next : null;
        });
        cell.deps = deps;
      }
    }

    function depsEqual(a, b) {
      if (a === b) return true;
      if (!a || !b) return false;
      if (a.length !== b.length) return false;
      for (let i = 0; i < a.length; i++) if (!Object.is(a[i], b[i])) return false;
      return true;
    }

    // The default export shape mimics React enough that
    // `import React from 'react'; React.createElement(...)` works.
    const ReactDefault = {
      createElement,
      Fragment,
      useState,
      useReducer,
      useRef,
      useEffect,
      useMemo,
      useCallback,
    };
    export default ReactDefault;

    // ---------- render ----------

    function renderNode(node, parentKey, index) {
      if (node == null || node === false || node === true) return null;
      if (typeof node === 'string' || typeof node === 'number') {
        const text = document.createTextNode(String(node));
        return text;
      }
      const { type, props, children } = node;
      const key = makeKey(parentKey, index, type, node.key);

      if (type === Fragment) {
        const frag = document.createDocumentFragment();
        children.forEach((c, i) => {
          const dom = renderNode(c, key, i);
          if (dom) frag.appendChild(dom);
        });
        return frag;
      }

      if (typeof type === 'function') {
        visitedFiberKeys.add(key);
        const prevFiber = currentFiber;
        currentFiber = { key, hookCount: 0 };
        const rendered = type({ ...props, children });
        currentFiber = prevFiber;
        return renderNode(rendered, key, 0);
      }

      // Host element. `type` is one of our RN component descriptors,
      // or a string fallback.
      const host = createHostElement(type, props);
      children.forEach((c, i) => {
        const dom = renderNode(c, key, i);
        if (dom) host.appendChild(dom);
      });
      return host;
    }

    // Walk every fiber the renderer touched in the most recent pass
    // and evict the entries that weren't visited. For each evicted
    // entry, run any `useEffect` cleanup so subscriptions tear down
    // when their owning component unmounts. Without this sweep
    // `fiberStateByKey` only ever grows, and unmounted components
    // leak hook state and live effect subscriptions forever.
    function sweepUnmountedFibers() {
      for (const [key, bucket] of fiberStateByKey) {
        if (visitedFiberKeys.has(key)) continue;
        for (const cell of bucket) {
          if (cell && typeof cell === 'object' && typeof cell.cleanup === 'function') {
            try { cell.cleanup(); } catch (e) { console.error(e); }
          }
        }
        fiberStateByKey.delete(key);
      }
    }

    function scheduleRender() {
      // Coalesce multiple state changes in the same tick into one
      // render so onPress handlers that bump several pieces of state
      // don't repaint repeatedly.
      if (scheduleRender.scheduled) return;
      scheduleRender.scheduled = true;
      queueMicrotask(() => {
        scheduleRender.scheduled = false;
        if (!rootContainer || !currentRoot) return;
        visitedFiberKeys.clear();
        rootContainer.replaceChildren();
        const dom = renderNode(currentRoot, 'root', 0);
        if (dom) rootContainer.appendChild(dom);
        // Anything in `fiberStateByKey` that wasn't visited this
        // render is unmounted. Tear it down so subscriptions stop
        // and the map doesn't grow forever.
        sweepUnmountedFibers();
        const effects = pendingEffects.splice(0);
        effects.forEach((fn) => { try { fn(); } catch (e) { console.error(e); } });
      });
    }

    // ---------- React Native shim ----------

    function styleToCss(styleSource) {
      if (!styleSource) return {};
      const flat = Array.isArray(styleSource)
        ? Object.assign({}, ...styleSource.flat(Infinity).filter(Boolean))
        : styleSource;
      const css = {};
      const numericPx = new Set([
        'width','height','minWidth','minHeight','maxWidth','maxHeight',
        'top','left','right','bottom',
        'padding','paddingTop','paddingBottom','paddingLeft','paddingRight','paddingHorizontal','paddingVertical',
        'margin','marginTop','marginBottom','marginLeft','marginRight','marginHorizontal','marginVertical',
        'borderRadius','borderTopLeftRadius','borderTopRightRadius','borderBottomLeftRadius','borderBottomRightRadius',
        'borderWidth','borderTopWidth','borderBottomWidth','borderLeftWidth','borderRightWidth',
        'fontSize','lineHeight','letterSpacing','gap','rowGap','columnGap',
      ]);
      for (const key in flat) {
        const v = flat[key];
        if (v == null) continue;
        if (key === 'paddingHorizontal') { css.paddingLeft = px(v); css.paddingRight = px(v); continue; }
        if (key === 'paddingVertical') { css.paddingTop = px(v); css.paddingBottom = px(v); continue; }
        if (key === 'marginHorizontal') { css.marginLeft = px(v); css.marginRight = px(v); continue; }
        if (key === 'marginVertical') { css.marginTop = px(v); css.marginBottom = px(v); continue; }
        if (key === 'tintColor') { css.color = v; continue; }
        if (key === 'shadowColor' || key === 'shadowOffset' || key === 'shadowOpacity' || key === 'shadowRadius' || key === 'elevation') continue;
        const cssKey = camelToDash(key);
        css[cssKey] = numericPx.has(key) && typeof v === 'number' ? px(v) : v;
      }
      return css;
    }

    function px(v) { return typeof v === 'number' ? `${v}px` : v; }
    function camelToDash(s) { return s.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase()); }

    function applyStyle(el, style) {
      const css = styleToCss(style);
      for (const k in css) el.style.setProperty(k, css[k]);
    }

    function createHostElement(type, props) {
      let tag = 'div';
      let extraStyle = null;
      switch (type) {
        case 'Text': tag = 'span'; extraStyle = { display: 'inline-block', color: 'inherit' }; break;
        case 'TextInput': tag = 'input'; break;
        case 'Image': tag = 'img'; break;
        case 'ScrollView': tag = 'div'; extraStyle = { overflow: 'auto', display: 'flex', flexDirection: 'column' }; break;
        case 'View':
        case 'Pressable':
        case 'TouchableOpacity':
        case 'TouchableHighlight':
        case 'SafeAreaView':
        default:
          tag = 'div'; extraStyle = { display: 'flex', flexDirection: 'column' };
      }
      const el = document.createElement(tag);
      if (extraStyle) applyStyle(el, extraStyle);
      if (props.style) applyStyle(el, props.style);
      // Pressable / Touchable opacity feedback
      if (type === 'Pressable' || type === 'TouchableOpacity' || type === 'TouchableHighlight') {
        el.style.cursor = 'pointer';
        el.addEventListener('pointerdown', () => { el.style.opacity = '0.6'; });
        el.addEventListener('pointerup', () => { el.style.opacity = '1'; });
        el.addEventListener('pointerleave', () => { el.style.opacity = '1'; });
      }
      // Event handlers
      if (props.onPress) el.addEventListener('click', (e) => props.onPress(e));
      if (props.onChangeText && tag === 'input') {
        el.addEventListener('input', (e) => props.onChangeText(e.target.value));
      }
      if (props.onChange && tag === 'input') {
        el.addEventListener('input', (e) => props.onChange(e));
      }
      // Image src
      if (type === 'Image' && props.source) {
        const src = typeof props.source === 'string' ? props.source : props.source.uri;
        if (src) el.setAttribute('src', src);
      }
      // TextInput value + placeholder
      if (type === 'TextInput') {
        if (props.value != null) el.value = props.value;
        if (props.placeholder) el.placeholder = props.placeholder;
        el.style.background = 'transparent';
        el.style.border = '0';
        el.style.outline = '0';
      }
      // Accessibility
      if (props.accessibilityLabel) el.setAttribute('aria-label', props.accessibilityLabel);
      // testID is harmless metadata in the preview
      if (props.testID) el.setAttribute('data-testid', props.testID);
      return el;
    }

    export const View = 'View';
    export const Text = 'Text';
    export const Pressable = 'Pressable';
    export const TouchableOpacity = 'TouchableOpacity';
    export const TouchableHighlight = 'TouchableHighlight';
    export const ScrollView = 'ScrollView';
    export const Image = 'Image';
    export const TextInput = 'TextInput';
    export const SafeAreaView = 'SafeAreaView';

    export const StyleSheet = {
      create(s) { return s; },
      flatten(s) { return Array.isArray(s) ? Object.assign({}, ...s.flat(Infinity).filter(Boolean)) : s; },
      hairlineWidth: 1,
      absoluteFill: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
      absoluteFillObject: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
    };

    export const Platform = { OS: 'ios', select: (m) => m.ios ?? m.default };
    export const Dimensions = {
      get(_kind) {
        return { width: window.innerWidth, height: window.innerHeight };
      },
      addEventListener() { return { remove() {} }; },
    };
    export const Alert = {
      alert(title, message) { window.alert(message ? `${title}\n\n${message}` : title); },
    };

    let registered = null;
    export const AppRegistry = {
      registerComponent(name, getComponent) {
        registered = { name, component: getComponent() };
      },
      runApplication() { /* no-op, mounted by bootstrap */ },
    };

    export function __puckyMount(container) {
      rootContainer = container;
      if (!registered) {
        // Fallback: try to find a default-exported function on the window.
        container.textContent = 'No component registered via AppRegistry.';
        return;
      }
      currentRoot = createElement(registered.component, {});
      scheduleRender();
    }
    """#

    /// Bootstrap module that imports the user's entry point (which
    /// will call `AppRegistry.registerComponent`) and then mounts
    /// whatever was registered. Loaded as a module from index.html.
    static func reactNativeBootstrapJS(entryModulePath: String) -> String {
        """
        import './\(entryModulePath)';
        import { __puckyMount } from 'react-native';
        __puckyMount(document.getElementById('root'));
        """
    }

    /// HTML host page for the React Native template. Sets up the
    /// import map so the user's `import 'react'` /
    /// `import 'react-native'` resolve to the same runtime shim,
    /// then loads the bootstrap module which kicks off the rest.
    /// The dark theme matches the rest of the app.
    static func reactNativeIndexHTML() -> String {
        htmlHostPage(
            title: "Pucky preview",
            bodyStyles: "#root { display: flex; flex-direction: column; min-height: 100%; }",
            bodyMarkup: "<div id=\"root\"></div>",
            importMapJSON: """
            {
              "imports": {
                "react": "./pucky-runtime.js",
                "react-native": "./pucky-runtime.js",
                "react/jsx-runtime": "./pucky-runtime.js",
                "react/jsx-dev-runtime": "./pucky-runtime.js"
              }
            }
            """,
            bootstrapPath: "./pucky-bootstrap.js"
        )
    }

    // MARK: — Three.js template runtime

    /// Bootstrap module for the Three.js template. Imports the
    /// user's compiled entry module (`src/App.js`), grabs the
    /// default export, and calls it with the mounted canvas. The
    /// user's `setup(canvas)` is expected to return a teardown
    /// callback — we keep it on `window.__puckyCleanup` so the
    /// next hot reload can run it before booting the new scene.
    static func threeDeeBootstrapJS(entryModulePath: String, sourceEntryPoint: String) -> String {
        """
        const canvas = document.getElementById('pucky-canvas');
        // Match the canvas's internal resolution to its CSS size so
        // Three.js doesn't end up rendering to a 300×150 default.
        function fitCanvas() {
          const dpr = window.devicePixelRatio || 1;
          canvas.width  = Math.floor(canvas.clientWidth  * dpr);
          canvas.height = Math.floor(canvas.clientHeight * dpr);
        }
        fitCanvas();
        window.addEventListener('resize', fitCanvas);

        // Unwind any previous scene the last bundle may have left behind.
        if (typeof window.__puckyCleanup === 'function') {
          try { window.__puckyCleanup(); } catch (e) { console.error(e); }
          window.__puckyCleanup = null;
        }

        const mod = await import('./\(entryModulePath)');
        const setup = mod.default;
        if (typeof setup !== 'function') {
          throw new Error("\(sourceEntryPoint) must default-export a setup(canvas) function.");
        }
        const cleanup = setup(canvas);
        if (typeof cleanup === 'function') {
          window.__puckyCleanup = cleanup;
        }
        """
    }

    /// HTML host page for the Three.js template. Provides a
    /// full-screen canvas and an importmap that aliases `"three"`
    /// to the locally-served build. The error overlay + console
    /// bridge are identical to the app runtime so build + runtime
    /// errors flow back to the agent the same way.
    static func threeDeeIndexHTML() -> String {
        htmlHostPage(
            title: "Pucky 3D preview",
            backgroundColor: "#0b0a0f",
            bodyStyles: """
            #pucky-canvas {
              position: fixed;
              inset: 0;
              width: 100%;
              height: 100%;
              display: block;
              touch-action: none;
            }
            """,
            bodyMarkup: "<canvas id=\"pucky-canvas\"></canvas>",
            importMapJSON: """
            {
              "imports": {
                "three": "./three.module.min.js"
              }
            }
            """,
            bootstrapPath: "./pucky-bootstrap.js"
        )
    }

    private static func htmlHostPage(
        title: String,
        backgroundColor: String = "#0b0c10",
        bodyStyles: String = "",
        bodyMarkup: String,
        importMapJSON: String? = nil,
        bootstrapPath: String
    ) -> String {
        let importMapSection: String
        if let importMapJSON, !importMapJSON.isEmpty {
            importMapSection = """
              <script type="importmap">
              \(importMapJSON)
              </script>
            """
        } else {
            importMapSection = ""
        }

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
          <title>\(title)</title>
          <style>
            :root { color-scheme: dark; }
            html, body { margin: 0; padding: 0; height: 100%; background: \(backgroundColor); color: #f4f4f5; -webkit-font-smoothing: antialiased; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif; }
            body { overflow: hidden; }
            \(bodyStyles)
            #pucky-error { position: fixed; left: 0; right: 0; bottom: 0; padding: 12px 16px; background: #2a0d12; color: #ff6b81; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; line-height: 1.4; max-height: 50vh; overflow: auto; white-space: pre-wrap; display: none; }
            #pucky-error.visible { display: block; }
          </style>
        \(importMapSection)
        </head>
        <body>
          \(bodyMarkup)
          <pre id="pucky-error"></pre>
          <script type="module">
            const errBox = document.getElementById('pucky-error');
            function showError(e) {
              const text = (e && (e.stack || e.message)) || String(e);
              errBox.textContent = text;
              errBox.classList.add('visible');
              try { console.error(text); } catch (_) {}
            }
            window.addEventListener('error', (ev) => showError(ev.error || ev.message));
            window.addEventListener('unhandledrejection', (ev) => showError(ev.reason));
            try {
              await import('\(bootstrapPath)');
            } catch (e) {
              showError(e);
            }
          </script>
        </body>
        </html>
        """
    }
}
