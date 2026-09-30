// GL bring-up test (temporary, replaced by the OpenMW entry point): desktop OpenGL through SDL's
// UIKit EGL backend (Mesa zink on MoltenVK), window and context set up the way OpenMW does it.
#include <EGL/egl.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_opengl.h>

static void logExtension(const char* name)
{
    SDL_Log("  %-36s %s", name, SDL_GL_ExtensionSupported(name) ? "yes" : "NO");
}

static void logProc(const char* name)
{
    SDL_Log("  %-36s %s", name, SDL_GL_GetProcAddress(name) ? "found" : "MISSING");
}

static void logGlErrors(const char* where)
{
    static int reported = 0;
    GLenum error;
    while ((error = glGetError()) != GL_NO_ERROR && reported < 20)
    {
        SDL_Log("GL error 0x%04x %s", error, where);
        ++reported;
    }
}

int main(int argc, char* argv[])
{
    if (SDL_Init(SDL_INIT_VIDEO) != 0)
    {
        SDL_Log("SDL_Init failed: %s", SDL_GetError());
        return 1;
    }

    SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 0);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);

    SDL_Window* window = SDL_CreateWindow("Morrowind", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, 1024, 768,
        SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI
            | SDL_WINDOW_FULLSCREEN);
    if (!window)
    {
        SDL_Log("SDL_CreateWindow failed: %s", SDL_GetError());
        return 1;
    }
    SDL_GLContext context = SDL_GL_CreateContext(window);
    if (!context)
    {
        SDL_Log("SDL_GL_CreateContext failed: %s", SDL_GetError());
        return 1;
    }

    int width, height, windowWidth, windowHeight, value;
    SDL_GL_GetDrawableSize(window, &width, &height);
    SDL_GetWindowSize(window, &windowWidth, &windowHeight);
    SDL_Log("EGL %s / %s", eglQueryString(eglGetCurrentDisplay(), EGL_VENDOR),
        eglQueryString(eglGetCurrentDisplay(), EGL_VERSION));
    SDL_Log("GL_VENDOR   %s", glGetString(GL_VENDOR));
    SDL_Log("GL_RENDERER %s", glGetString(GL_RENDERER));
    SDL_Log("GL_VERSION  %s", glGetString(GL_VERSION));
    SDL_Log("GLSL        %s", glGetString(GL_SHADING_LANGUAGE_VERSION));
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &value);
    SDL_Log("max texture %d, drawable %dx%d, window %dx%d", value, width, height, windowWidth, windowHeight);
    SDL_GL_GetAttribute(SDL_GL_DEPTH_SIZE, &value);
    SDL_Log("depth bits %d, swap interval 1: %s", value, SDL_GL_SetSwapInterval(1) == 0 ? "ok" : SDL_GetError());

    SDL_Log("extensions:");
    const char* extensions[] = { "GL_ARB_framebuffer_object", "GL_EXT_framebuffer_object",
        "GL_EXT_texture_compression_s3tc", "GL_ARB_texture_compression_rgtc", "GL_EXT_texture_filter_anisotropic",
        "GL_ARB_texture_float", "GL_ARB_depth_buffer_float", "GL_ARB_depth_clamp", "GL_ARB_clip_control",
        "GL_ARB_vertex_buffer_object", "GL_ARB_shader_objects", "GL_ARB_draw_instanced",
        "GL_ARB_uniform_buffer_object", "GL_EXT_gpu_shader4", "GL_ARB_texture_rg", "GL_ARB_multisample",
        "GL_ARB_compute_shader", "GL_ARB_shader_image_load_store", "GL_OVR_multiview", "GL_MESA_pack_invert" };
    for (size_t i = 0; i < SDL_arraysize(extensions); ++i)
        logExtension(extensions[i]);
    SDL_Log("functions:");
    logProc("glGenFramebuffers");
    logProc("glCompressedTexImage2D");
    logProc("glUseProgram");
    logGlErrors("after setup");

    int paused = 0, running = 1, frames = 0;
    Uint32 last = SDL_GetTicks();
    while (running)
    {
        SDL_Event event;
        while (SDL_PollEvent(&event))
        {
            switch (event.type)
            {
                case SDL_QUIT:
                    running = 0;
                    break;
                case SDL_APP_WILLENTERBACKGROUND:
                    SDL_Log("event: will enter background");
                    paused = 1;
                    break;
                case SDL_APP_DIDENTERBACKGROUND:
                    SDL_Log("event: did enter background");
                    break;
                case SDL_APP_WILLENTERFOREGROUND:
                    SDL_Log("event: will enter foreground");
                    break;
                case SDL_APP_DIDENTERFOREGROUND:
                    SDL_Log("event: did enter foreground");
                    paused = 0;
                    break;
                case SDL_WINDOWEVENT:
                    if (event.window.event == SDL_WINDOWEVENT_SIZE_CHANGED)
                        SDL_Log("event: window size %dx%d", event.window.data1, event.window.data2);
                    break;
            }
        }
        if (paused)
        {
            SDL_Delay(100);
            continue;
        }

        SDL_GL_GetDrawableSize(window, &width, &height);
        glViewport(0, 0, width, height);
        const float t = (SDL_GetTicks() % 4000) / 4000.f;
        glClearColor(0.1f, 0.2f + 0.3f * t, 0.5f, 1.f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        // fixed function: white bar in the upper half, red square in the top left corner
        glMatrixMode(GL_PROJECTION);
        glLoadIdentity();
        glOrtho(0, 1, 0, 1, -1, 1);
        glMatrixMode(GL_MODELVIEW);
        glLoadIdentity();
        glBegin(GL_QUADS);
        glColor3f(1, 1, 1);
        glVertex2f(0.2f, 0.6f);
        glVertex2f(0.8f, 0.6f);
        glVertex2f(0.8f, 0.9f);
        glVertex2f(0.2f, 0.9f);
        glColor3f(1, 0, 0);
        glVertex2f(0.f, 0.9f);
        glVertex2f(0.1f, 0.9f);
        glVertex2f(0.1f, 1.f);
        glVertex2f(0.f, 1.f);
        glEnd();
        logGlErrors("in frame");

        SDL_GL_SwapWindow(window);
        logGlErrors("after swap");

        ++frames;
        const Uint32 now = SDL_GetTicks();
        if (now - last >= 2000)
        {
            SDL_Log("%.1f fps (%dx%d)", frames * 1000.f / (now - last), width, height);
            frames = 0;
            last = now;
        }
    }

    SDL_GL_DeleteContext(context);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
