import Foundation

/// Immutable definition of a starter template.
///
/// The rest of the app treats templates as opaque data: one object
/// carries the editable file path, starter scaffold, system-prompt
/// preamble, preview bootstrap assets, and any bundled runtime
/// resources. Adding or removing a template should mean editing this
/// catalog, not sprinkling new `switch` cases through services,
/// screens, or tests.
struct ProjectTemplate: Identifiable, Sendable {
    struct SourceFile: Sendable {
        let path: String
        let content: String
        let language: ProjectFile.Language

        var name: String {
            URL(filePath: path).lastPathComponent
        }

        func makeProjectFile() -> ProjectFile {
            ProjectFile(
                name: name,
                path: path,
                content: content,
                language: language
            )
        }
    }

    struct RuntimeFile: Sendable {
        let path: String
        let body: String
    }

    struct BundledResource: Sendable {
        let sourceName: String
        let sourceExtension: String?
        let destinationPath: String

        var displayName: String {
            if let sourceExtension, !sourceExtension.isEmpty {
                return "\(sourceName).\(sourceExtension)"
            }
            return sourceName
        }
    }

    struct PreviewConfiguration: Sendable {
        let entryPoint: String
        let runtimeFiles: [RuntimeFile]
        let bundledResources: [BundledResource]
    }

    let id: String
    let shortLabel: String
    let menuLabel: String
    let editablePath: String
    let promptPreamble: String
    let scaffoldFiles: [SourceFile]
    let preview: PreviewConfiguration

    var editableFileName: String {
        URL(filePath: editablePath).lastPathComponent
    }

    func makeProjectFiles() -> [ProjectFile] {
        scaffoldFiles.map { $0.makeProjectFile() }
    }

    static func == (lhs: ProjectTemplate, rhs: ProjectTemplate) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension ProjectTemplate: Hashable {
    static let defaultTemplate: ProjectTemplate = allCases.first!

    static let allCases: [ProjectTemplate] = [
        reactNativeApp,
        threeDeeScene,
    ]

    static func template(id: String) -> ProjectTemplate? {
        allCases.first { $0.id == id }
    }

    private static let reactNativeApp: ProjectTemplate = {
        let editablePath = "src/App.tsx"
        return ProjectTemplate(
            id: "app",
            shortLabel: "App",
            menuLabel: "App (React Native)",
            editablePath: editablePath,
            promptPreamble: """
            You are Pucky, a senior React Native engineer building iPhone apps. You are working on a single piece of code that is the entire app. You cannot create or delete anything — the only thing you can do is modify that one piece of code, and you have exactly two tools to do it:

            - edit_code replaces exactly one occurrence of find with replace inside the code. Prefer this for localised changes because the find/replace payload is tiny compared to rewriting the whole thing. The find string must occur exactly once: include enough surrounding context to make it unique.
            - replace_code rewrites the entire code. Use it when the change touches many parts of the code.

            The current code is shown at the bottom of this prompt inside a <code> block with line numbers prefixed for reference. The line number prefix is not part of the code, so do not include it in find or text.

            Build on the user's first message. Pick a reasonable default for anything they did not specify and ship it, then offer to adjust afterwards. A one sentence acknowledgement is enough because the tool calls are visible to the user. Keep code inside the tool calls so it does not get duplicated in the chat transcript.

            Code constraints:
            - Import only from react and react-native because those are the only packages the runtime bundles.
            - Every component, hook, style, and helper must live inside the single piece of code you are editing. There is nothing else.
            - The code must default-export the root React component.
            - Write TSX function components with hooks. Style with StyleSheet.create using flexbox and a dark theme so the whole app reads as one design.
            """,
            scaffoldFiles: [
                SourceFile(
                    path: editablePath,
                    content: appSeed,
                    language: .typescriptReact
                ),
                SourceFile(
                    path: "src/index.ts",
                    content: """
                    import { AppRegistry } from 'react-native';
                    import App from './App';

                    AppRegistry.registerComponent('PuckyPreview', () => App);
                    """,
                    language: .typescript
                ),
                SourceFile(
                    path: "package.json",
                    content: """
                    {
                      "name": "pucky-preview",
                      "version": "1.0.0",
                      "private": true,
                      "dependencies": {
                        "react": "^19.0.0",
                        "react-native": "^0.84.0"
                      }
                    }
                    """,
                    language: .json
                ),
            ],
            preview: PreviewRuntime.reactNativePreview(entryPoint: "src/index.ts")
        )
    }()

    private static let threeDeeScene: ProjectTemplate = {
        let editablePath = "src/App.ts"
        return ProjectTemplate(
            id: "threeDee",
            shortLabel: "3D",
            menuLabel: "3D (Three.js)",
            editablePath: editablePath,
            promptPreamble: """
            You are Pucky, a senior graphics engineer writing Three.js scenes that run inside a WKWebView on an iPhone. You are working on a single piece of code that is the entire scene. You cannot create or delete anything — the only thing you can do is modify that one piece of code, and you have exactly two tools to do it:

            - edit_code replaces exactly one occurrence of find with replace inside the code. Prefer this for localised changes because the find/replace payload is tiny compared to rewriting the whole thing. The find string must occur exactly once: include enough surrounding context to make it unique.
            - replace_code rewrites the entire code. Use it when the change touches many parts of the code.

            The current code is shown at the bottom of this prompt inside a <code> block with line numbers prefixed for reference. The line number prefix is not part of the code, so do not include it in find or text.

            Build on the user's first message. Pick a reasonable default for anything they did not specify and ship it, then offer to adjust afterwards. A one sentence acknowledgement is enough because the tool calls are visible to the user. Keep code inside the tool calls so it does not get duplicated in the chat transcript.

            Code constraints:
            - Import THREE from 'three'. That's the only package the runtime bundles.
            - The code must default-export a function `setup(canvas: HTMLCanvasElement)`. The runtime calls it with a full-screen canvas after the page mounts.
            - Your setup function should return a teardown callback that disposes the renderer, cancels the animation frame, and removes any event listeners. The runtime runs it before your new code on every edit_code or replace_code reload.
            - Use PointerEvents (pointerdown / pointermove / pointerup) for touch input because that's what WKWebView forwards for finger gestures.
            - Write a requestAnimationFrame loop for animation. Call renderer.setPixelRatio(window.devicePixelRatio) once at startup. Resize the renderer + camera inside the loop whenever canvas.clientWidth / clientHeight change so rotation and orientation work.
            """,
            scaffoldFiles: [
                SourceFile(
                    path: editablePath,
                    content: threeDeeSeed,
                    language: .typescript
                ),
            ],
            preview: PreviewRuntime.threeDeePreview(entryPoint: editablePath)
        )
    }()

    /// Self-contained React Native starter with a working counter,
    /// Pucky palette, and a few styled sub-components. Gives the
    /// model something real to riff on instead of a one-line hello
    /// world.
    private static let appSeed = """
    import React, { useState } from 'react';
    import { View, Text, Pressable, StyleSheet, SafeAreaView } from 'react-native';

    export default function App() {
      const [count, setCount] = useState(0);

      return (
        <SafeAreaView style={styles.root}>
          <View style={styles.container}>
            <Text style={styles.eyebrow}>PUCKY</Text>
            <Text style={styles.title}>Hello.</Text>
            <Text style={styles.subtitle}>
              Describe what you want to build in the chat tab and this screen
              will change.
            </Text>

            <View style={styles.counterCard}>
              <Text style={styles.counterLabel}>Counter</Text>
              <Text style={styles.counterValue}>{count}</Text>
              <View style={styles.buttonRow}>
                <Pressable
                  style={({ pressed }) => [styles.button, pressed && styles.buttonPressed]}
                  onPress={() => setCount((c) => c - 1)}
                >
                  <Text style={styles.buttonLabel}>−</Text>
                </Pressable>
                <Pressable
                  style={({ pressed }) => [styles.button, pressed && styles.buttonPressed]}
                  onPress={() => setCount((c) => c + 1)}
                >
                  <Text style={styles.buttonLabel}>+</Text>
                </Pressable>
              </View>
            </View>
          </View>
        </SafeAreaView>
      );
    }

    const styles = StyleSheet.create({
      root: { flex: 1, backgroundColor: '#0b0a0f' },
      container: {
        flex: 1,
        paddingHorizontal: 28,
        justifyContent: 'center',
      },
      eyebrow: {
        fontSize: 11,
        letterSpacing: 3,
        color: '#ff2099',
        fontWeight: '600',
        marginBottom: 12,
      },
      title: {
        fontSize: 48,
        color: '#f2e8e6',
        fontWeight: '300',
        marginBottom: 12,
      },
      subtitle: {
        fontSize: 15,
        color: '#7d7380',
        lineHeight: 22,
        marginBottom: 36,
      },
      counterCard: {
        borderRadius: 20,
        padding: 20,
        backgroundColor: '#17121f',
        borderWidth: 1,
        borderColor: '#2a2234',
      },
      counterLabel: {
        fontSize: 11,
        letterSpacing: 2,
        color: '#7d7380',
        fontWeight: '600',
        marginBottom: 6,
      },
      counterValue: {
        fontSize: 56,
        color: '#f2e8e6',
        fontWeight: '200',
        marginBottom: 16,
      },
      buttonRow: {
        flexDirection: 'row',
        gap: 12,
      },
      button: {
        flex: 1,
        paddingVertical: 14,
        borderRadius: 14,
        backgroundColor: '#251c31',
        alignItems: 'center',
      },
      buttonPressed: {
        backgroundColor: '#ff2099',
      },
      buttonLabel: {
        fontSize: 22,
        color: '#f2e8e6',
        fontWeight: '500',
      },
    });
    """

    /// Three.js starter: a well-lit WebGL cube with touch-to-rotate.
    /// The editable file default-exports `setup(canvas)` which the
    /// runtime calls with the mounted canvas. The function returns
    /// a teardown callback so a replace_code call can unwind the
    /// previous scene cleanly.
    private static let threeDeeSeed = #"""
    import * as THREE from 'three';

    /// Called by the Pucky preview runtime with a full-screen
    /// canvas once the page has mounted. Return a function that
    /// tears down the scene so the runtime can reload cleanly on
    /// the next edit.
    export default function setup(canvas: HTMLCanvasElement) {
      const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
      renderer.setPixelRatio(window.devicePixelRatio);
      renderer.toneMapping = THREE.ACESFilmicToneMapping;
      renderer.toneMappingExposure = 1.15;

      const scene = new THREE.Scene();
      scene.background = new THREE.Color(0x0b0a0f);

      const camera = new THREE.PerspectiveCamera(
        45,
        canvas.clientWidth / canvas.clientHeight,
        0.1,
        100
      );
      camera.position.set(2.2, 1.6, 3.2);
      camera.lookAt(0, 0, 0);

      // Lighting: warm key light above + cool fill from the side +
      // a hot-pink rim light behind the cube for Pucky's accent
      // color. Ambient keeps the shadow side from going black.
      const ambient = new THREE.AmbientLight(0xffffff, 0.35);
      scene.add(ambient);

      const key = new THREE.DirectionalLight(0xfff1cf, 2.4);
      key.position.set(3.2, 4.4, 2.5);
      scene.add(key);

      const fill = new THREE.DirectionalLight(0x7ab6ff, 0.9);
      fill.position.set(-4, 1.8, 3.5);
      scene.add(fill);

      const rim = new THREE.PointLight(0xff2099, 18, 20, 2.2);
      rim.position.set(-2.6, 1.2, -2.4);
      scene.add(rim);

      const geometry = new THREE.BoxGeometry(1.2, 1.2, 1.2, 4, 4, 4);
      const material = new THREE.MeshStandardMaterial({
        color: 0xf5efe8,
        metalness: 0.22,
        roughness: 0.28,
      });
      const cube = new THREE.Mesh(geometry, material);
      scene.add(cube);

      const floor = new THREE.Mesh(
        new THREE.CircleGeometry(5, 48),
        new THREE.MeshBasicMaterial({ color: 0x140f19 })
      );
      floor.rotation.x = -Math.PI / 2;
      floor.position.y = -1.2;
      scene.add(floor);

      let spin = 0.8;
      let tilt = 0.38;
      let pointerId: number | null = null;
      let raf = 0;
      let lastWidth = 0;
      let lastHeight = 0;

      function handlePointerDown(event: PointerEvent) {
        pointerId = event.pointerId;
      }

      function handlePointerMove(event: PointerEvent) {
        if (pointerId !== event.pointerId) return;
        spin += event.movementX * 0.014;
        tilt += event.movementY * 0.01;
        tilt = Math.max(-1.0, Math.min(1.0, tilt));
      }

      function handlePointerUp(event: PointerEvent) {
        if (pointerId === event.pointerId) pointerId = null;
      }

      canvas.addEventListener('pointerdown', handlePointerDown);
      window.addEventListener('pointermove', handlePointerMove);
      window.addEventListener('pointerup', handlePointerUp);
      window.addEventListener('pointercancel', handlePointerUp);

      function frame(time: number) {
        raf = requestAnimationFrame(frame);

        const width = canvas.clientWidth;
        const height = canvas.clientHeight;
        if (width !== lastWidth || height !== lastHeight) {
          lastWidth = width;
          lastHeight = height;
          renderer.setSize(width, height, false);
          camera.aspect = width / Math.max(height, 1);
          camera.updateProjectionMatrix();
        }

        cube.rotation.x = tilt + Math.sin(time * 0.0012) * 0.08;
        cube.rotation.y = spin + time * 0.0008;

        renderer.render(scene, camera);
      }

      raf = requestAnimationFrame(frame);

      return () => {
        cancelAnimationFrame(raf);
        canvas.removeEventListener('pointerdown', handlePointerDown);
        window.removeEventListener('pointermove', handlePointerMove);
        window.removeEventListener('pointerup', handlePointerUp);
        window.removeEventListener('pointercancel', handlePointerUp);
        geometry.dispose();
        material.dispose();
        renderer.dispose();
      };
    }
    """#
}
