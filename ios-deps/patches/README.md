# iOS dependency patches

`ios-deps/build-deps.sh` applies these patches to the pinned upstream sources (versions in `ios-deps/recipes/`),
in file name order, with `patch -p1`. Each patch starts with a description: what it changes, why iOS or MoltenVK
needs it, and its upstream status. A changed patch set makes the next `build-deps.sh build <dep>` extract the
source again.

| Dependency | Patch | Purpose |
|---|---|---|
| Mesa 25.1.9 | `mesa/0001-zink-static-moltenvk-on-ios.patch` | zink uses the statically linked MoltenVK on iOS instead of loading a Vulkan loader |
| | `mesa/0002-egl-surfaceless-zink-without-drm.patch` | surfaceless EGL falls back to zink when there are no DRM devices |
| | `mesa/0003-meson-dri-for-zink-on-darwin.patch` | DRI (required by EGL) with zink on darwin, backport from Mesa 26 |
| | `mesa/0004-tgsi-to-nir-sampler-name-for-msl.patch` | sampler variable name that does not hide Metal's `sampler` type in SPIRV-Cross output |
| | `mesa/0005-zink-one-io-variable-per-slot.patch` | one I/O variable per varying slot: Metal matches stage inputs and outputs by name |
| | `mesa/0006-zink-recompute-attachments-after-unordered-blit.patch` | no stale render pass loadOps after an unordered blit |
| | `mesa/0007-zink-no-push-descriptors-on-moltenvk.patch` | no push descriptors on MoltenVK (it copies the data of every push) |
| | `mesa/0008-zink-depth-clamp-without-depth-clip-enable.patch` | GL_ARB_depth_clamp with core `depthClamp`, without VK_EXT_depth_clip_enable |
| | `mesa/0009-zink-disk-cache-id-without-build-id.patch` | shader disk cache ID from the binary's timestamp where there is no ELF build-id |
| | `mesa/0010-gl-interop-metal-objects-and-ordered-callback.patch` | Metal objects through GL interop and a callback after a flush (MetalFX upscaling) |
| SDL2 2.32.10 | `sdl2/0001-uikit-uiscene-life-cycle.patch` | UIScene life cycle, required by apps built with the iOS 27 SDK |
| | `sdl2/0002-uikit-desktop-opengl-via-egl.patch` | desktop OpenGL on a static EGL (Mesa), frames presented through Metal |
| | `sdl2/0003-uikit-ios27-interface-orientation.patch` | interface orientation on iOS 27, backport from SDL3 |
| OpenSceneGraph (OpenMW fork, OSG 3.6.5) | `osg/0001-glextensions-egl-proc-address-on-ios.patch` | GL functions through `eglGetProcAddress` on iOS with desktop GL |
| | `osg/0002-cmake-find-png-jpeg-on-ios.patch` | libpng and libjpeg found on CMake's iOS platform (png plugin) |

Mesa stays on 25.1.x: from 25.2 on, zink requires robustness2 `nullDescriptor`, which MoltenVK does not provide.
