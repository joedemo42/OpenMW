// OSG bring-up test (temporary, replaced by the OpenMW entry point): OpenSceneGraph on the desktop GL context of
// SDL's UIKit EGL backend, set up the way OpenMW's engine.cpp does it (its SDL graphics window, osgViewer's default
// threading = draw thread per context). Checks the statically linked plugins, FreeType and what the GPU renders,
// plus the scripting and media libraries (libtest.cpp); logs one PASS/FAIL line per check and a summary.
#include <SDL2/SDL.h>

#include <osg/GLExtensions>
#include <osg/Geometry>
#include <osg/Program>
#include <osg/Texture2D>
#include <osg/Version>
#include <osgDB/Registry>
#include <osgText/Text>
#include <osgViewer/Viewer>

#include <components/sdlutil/sdlgraphicswindow.hpp>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <sstream>
#include <string>
#include <vector>

int checkLibraries(const std::string& dataDir); // libtest.cpp, returns the number of failures

namespace
{
    std::atomic<int> failures{ 0 };

    void check(const std::string& name, bool ok, const std::string& detail = {})
    {
        if (!ok)
            ++failures;
        SDL_Log("%s %s%s%s", ok ? "PASS" : "FAIL", name.c_str(), detail.empty() ? "" : ": ", detail.c_str());
    }

    std::string rgb(const osg::Vec4& color)
    {
        std::ostringstream out;
        out << "(" << int(color.r() * 255 + 0.5f) << "," << int(color.g() * 255 + 0.5f) << ","
            << int(color.b() * 255 + 0.5f) << ")";
        return out.str();
    }

    // Test pattern: top left red, top right green, bottom left blue, bottom right white.
    struct Sample
    {
        osg::Vec2 at; // 0..1 inside the image or quad
        osg::Vec4 color;
    };
    const std::vector<Sample> pattern = { { { 0.25f, 0.75f }, { 1, 0, 0, 1 } }, { { 0.75f, 0.75f }, { 0, 1, 0, 1 } },
        { { 0.25f, 0.25f }, { 0, 0, 1, 1 } }, { { 0.75f, 0.25f }, { 1, 1, 1, 1 } } };
    // DXT1 test image: left half red, right half green
    const std::vector<Sample> halves = { { { 0.25f, 0.5f }, { 1, 0, 0, 1 } }, { { 0.75f, 0.5f }, { 0, 1, 0, 1 } } };

    bool matches(const osg::Vec4& color, const osg::Vec4& expected)
    {
        const float tolerance = 24 / 255.f; // JPEG is lossy
        for (int i = 0; i < 3; ++i)
            if (std::abs(color[i] - expected[i]) > tolerance)
                return false;
        return true;
    }

    osg::ref_ptr<osg::Image> makePattern()
    {
        osg::ref_ptr<osg::Image> image = new osg::Image;
        image->allocateImage(64, 64, 1, GL_RGB, GL_UNSIGNED_BYTE);
        for (int t = 0; t < 64; ++t) // OSG images start with the bottom row
            for (int s = 0; s < 64; ++s)
            {
                const osg::Vec4& color = pattern[(t < 32 ? 2 : 0) + (s < 32 ? 0 : 1)].color;
                unsigned char* pixel = image->data(s, t);
                for (int i = 0; i < 3; ++i)
                    pixel[i] = static_cast<unsigned char>(color[i] * 255);
            }
        return image;
    }

    // 8x8 DXT1 = 2x2 blocks, each one colour: colour0 = red or green (RGB565), colour1 = black (colour0 > colour1:
    // opaque mode), all indices 0. Row order does not matter, so the DDS plugin's vertical flips cancel out.
    osg::ref_ptr<osg::Image> makeDxt1()
    {
        osg::ref_ptr<osg::Image> image = new osg::Image;
        image->allocateImage(8, 8, 1, GL_COMPRESSED_RGB_S3TC_DXT1_EXT, GL_UNSIGNED_BYTE);
        unsigned char* block = image->data();
        for (int i = 0; i < 4; ++i, block += 8)
        {
            const unsigned short color = i % 2 ? 0x07e0 : 0xf800;
            std::fill(block, block + 8, 0);
            block[0] = color & 0xff;
            block[1] = color >> 8;
        }
        return image;
    }

    osg::ref_ptr<osg::Image> roundTrip(const std::string& extension, const osg::Image& image, const osgDB::Options* options)
    {
        osgDB::ReaderWriter* rw = osgDB::Registry::instance()->getReaderWriterForExtension(extension);
        std::stringstream stream;
        if (!rw || !rw->writeImage(image, stream, options).success())
            return nullptr;
        return rw->readImage(stream, options).getImage();
    }

    // Plugin round trips in memory. Returns the images read back (png, jpg, tga, bmp, dds).
    std::vector<osg::ref_ptr<osg::Image>> checkPlugins()
    {
        // options OpenMW's ImageManager uses
        osg::ref_ptr<osgDB::Options> options = new osgDB::Options("dds_flip dds_dxt1_detect_rgba ignoreTga2Fields");
        std::vector<osg::ref_ptr<osg::Image>> images;
        const osg::ref_ptr<osg::Image> source = makePattern();
        for (const char* extension : { "png", "jpg", "tga", "bmp" })
        {
            osg::ref_ptr<osg::Image> image = roundTrip(extension, *source, options);
            std::string detail = image ? "" : "no reader/writer or round trip failed";
            for (const Sample& sample : pattern)
                if (image && !matches(image->getColor(sample.at), sample.color))
                    detail += rgb(image->getColor(sample.at)) + " instead of " + rgb(sample.color) + " ";
            check(std::string("plugin ") + extension, detail.empty(), detail);
            images.push_back(image);
        }

        const osg::ref_ptr<osg::Image> dxt1 = makeDxt1();
        osg::ref_ptr<osg::Image> dds = roundTrip("dds", *dxt1, options);
        check("plugin dds (DXT1)",
            dds && dds->getPixelFormat() == GL_COMPRESSED_RGB_S3TC_DXT1_EXT && dds->s() == 8 && dds->t() == 8
                && dds->getTotalSizeInBytes() == 32 && std::equal(dxt1->data(), dxt1->data() + 32, dds->data()));
        images.push_back(dds);

        // serializer based .osgt, as OpenMW writes scene graphs (components/sceneutil/writescene.cpp)
        osg::ref_ptr<osg::Group> group = new osg::Group;
        group->setName("osgtest");
        group->addChild(new osg::Group);
        osg::ref_ptr<osgDB::Options> ascii = new osgDB::Options;
        ascii->setPluginStringData("fileType", "Ascii");
        osgDB::ReaderWriter* osgt = osgDB::Registry::instance()->getReaderWriterForExtension("osgt");
        std::stringstream stream;
        osg::ref_ptr<osg::Node> node;
        if (osgt && osgt->writeNode(*group, stream, ascii).success())
            node = osgt->readNode(stream, ascii).getNode();
        check("plugin osgt (serializers)",
            node && node->getName() == "osgtest" && node->asGroup() && node->asGroup()->getNumChildren() == 1);
        return images;
    }

    osg::ref_ptr<osgText::Font> checkFont(const std::string& path)
    {
        osg::ref_ptr<osgText::Font> font = osgText::readRefFontFile(path);
        osgText::Glyph* glyph = font ? font->getGlyph(osgText::FontResolution(32, 32), 'M') : nullptr;
        check("plugin freetype", glyph && glyph->s() > 0 && glyph->t() > 0, path);
        return font;
    }

    struct Quad
    {
        std::string name;
        float x, y, w, h; // in the 0..1 projection of the main camera
        std::vector<Sample> samples;
    };

    // Final draw callback: logs what OSG found out about the context in the first frame, compares the rendered
    // quads with the expected colours once the scene has settled.
    class RenderCheck : public osg::Camera::DrawCallback
    {
    public:
        std::vector<Quad> mQuads;

        void operator()(osg::RenderInfo& renderInfo) const override
        {
            ++mFrame;
            if (mFrame == 1)
                logContext(renderInfo);
            if (mFrame != 60)
                return;
            const osg::Viewport* viewport = renderInfo.getCurrentCamera()->getViewport();
            for (const Quad& quad : mQuads)
            {
                std::string detail;
                for (const Sample& sample : quad.samples)
                {
                    unsigned char pixel[4];
                    glReadPixels(GLint(viewport->x() + (quad.x + sample.at.x() * quad.w) * viewport->width()),
                        GLint(viewport->y() + (quad.y + sample.at.y() * quad.h) * viewport->height()), 1, 1, GL_RGBA,
                        GL_UNSIGNED_BYTE, pixel);
                    const osg::Vec4 color(pixel[0] / 255.f, pixel[1] / 255.f, pixel[2] / 255.f, 1);
                    if (!matches(color, sample.color))
                        detail += rgb(color) + " instead of " + rgb(sample.color) + " ";
                }
                check("render " + quad.name, detail.empty(), detail);
            }
            const GLenum error = glGetError();
            check("no GL error", error == GL_NO_ERROR, std::to_string(error));
            SDL_Log("osgtest: %s (%d failed)", failures ? "FAILED" : "all checks passed", failures.load());
        }

    private:
        mutable int mFrame = 0;

        static void logContext(osg::RenderInfo& renderInfo)
        {
            const osg::GLExtensions* ext = renderInfo.getState()->get<osg::GLExtensions>();
            SDL_Log("GL_RENDERER %s", reinterpret_cast<const char*>(glGetString(GL_RENDERER)));
            SDL_Log("GL_VERSION  %s", reinterpret_cast<const char*>(glGetString(GL_VERSION)));
            SDL_Log("OSG: GL %.1f, GLSL %.2f, glsl %d, vbo %d, fbo %d, s3tc %d, npot %d", ext->glVersion,
                ext->glslLanguageVersion, ext->isGlslSupported, ext->isVBOSupported, ext->isFrameBufferObjectSupported,
                ext->isTextureCompressionS3TCSupported, ext->isNonPowerOfTwoTextureSupported(GL_LINEAR));
            // OSG loads everything past GL 1.1 through osg::getGLExtensionFuncPtr (EGL on iOS, osg patch 0001)
            check("OSG GL function lookup",
                ext->glUseProgram && ext->glGenBuffers && ext->glGenFramebuffers && ext->glCompressedTexImage2D);
        }
    };

    osg::ref_ptr<osg::Geometry> quadGeometry(const Quad& quad)
    {
        return osg::createTexturedQuadGeometry(
            osg::Vec3(quad.x, quad.y, 0), osg::Vec3(quad.w, 0, 0), osg::Vec3(0, quad.h, 0));
    }

    osg::ref_ptr<osg::Texture2D> texture(osg::Image* image, bool mipmaps = true)
    {
        osg::ref_ptr<osg::Texture2D> result = new osg::Texture2D(image);
        if (!mipmaps)
            result->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);
        return result;
    }

    osg::ref_ptr<osg::Program> patternProgram()
    {
        osg::ref_ptr<osg::Program> program = new osg::Program;
        program->addShader(new osg::Shader(osg::Shader::VERTEX,
            "#version 120\n"
            "void main()\n"
            "{\n"
            "    gl_TexCoord[0] = gl_MultiTexCoord0;\n"
            "    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;\n"
            "}\n"));
        program->addShader(new osg::Shader(osg::Shader::FRAGMENT,
            "#version 120\n"
            "void main()\n"
            "{\n"
            "    vec2 t = gl_TexCoord[0].xy;\n"
            "    vec3 top = t.x < 0.5 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);\n"
            "    vec3 bottom = t.x < 0.5 ? vec3(0.0, 0.0, 1.0) : vec3(1.0);\n"
            "    gl_FragColor = vec4(t.y < 0.5 ? bottom : top, 1.0);\n"
            "}\n"));
        return program;
    }

    // Row of quads: images read back by the plugins (png, jpg, tga, bmp, DXT1 dds), GLSL 1.20 program,
    // render-to-texture (FBO) of the png image; a text line above them.
    osg::ref_ptr<osg::Group> createScene(const std::vector<osg::ref_ptr<osg::Image>>& images, osgText::Font* font,
        RenderCheck& renderCheck, float aspect)
    {
        osg::ref_ptr<osg::Group> root = new osg::Group;
        root->getOrCreateStateSet()->setMode(GL_LIGHTING, osg::StateAttribute::OFF);
        const char* names[] = { "png", "jpg", "tga", "bmp", "dds (DXT1, S3TC on the GPU)", "GLSL 1.20", "FBO" };
        for (int i = 0; i < 7; ++i)
        {
            Quad quad{ names[i], 0.02f + i * 0.14f, 0.35f, 0.12f, 0.3f, i == 4 ? halves : pattern };
            osg::ref_ptr<osg::Geometry> geometry = quadGeometry(quad);
            osg::StateSet* stateSet = geometry->getOrCreateStateSet();
            if (i < 5 && images[i])
                stateSet->setTextureAttributeAndModes(0, texture(images[i], i != 4));
            else if (i == 5)
                stateSet->setAttributeAndModes(patternProgram());
            else if (i == 6)
            {
                osg::ref_ptr<osg::Texture2D> target = new osg::Texture2D;
                target->setTextureSize(64, 64);
                target->setInternalFormat(GL_RGBA);
                target->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);
                osg::ref_ptr<osg::Camera> rtt = new osg::Camera;
                rtt->setRenderOrder(osg::Camera::PRE_RENDER);
                rtt->setRenderTargetImplementation(osg::Camera::FRAME_BUFFER_OBJECT);
                rtt->attach(osg::Camera::COLOR_BUFFER, target.get());
                rtt->setReferenceFrame(osg::Transform::ABSOLUTE_RF);
                rtt->setViewport(0, 0, 64, 64);
                rtt->setProjectionMatrixAsOrtho2D(0, 1, 0, 1);
                rtt->setViewMatrix(osg::Matrix::identity());
                rtt->setComputeNearFarMode(osg::CullSettings::DO_NOT_COMPUTE_NEAR_FAR);
                osg::ref_ptr<osg::Geometry> source = quadGeometry({ "", 0, 0, 1, 1, {} });
                if (images[0])
                    source->getOrCreateStateSet()->setTextureAttributeAndModes(0, texture(images[0]));
                rtt->addChild(source);
                root->addChild(rtt);
                stateSet->setTextureAttributeAndModes(0, target);
            }
            root->addChild(geometry);
            renderCheck.mQuads.push_back(quad);
        }

        osg::ref_ptr<osgText::Text> text = new osgText::Text;
        if (font)
            text->setFont(font);
        text->setCharacterSize(0.04f, aspect); // glyph width = height / aspect: undoes the 0..1 projection's stretch
        text->setPosition(osg::Vec3(0.02f, 0.8f, 0));
        text->setText(std::string("OpenSceneGraph ") + osgGetVersion() + " (static) on the SDL EGL context");
        root->addChild(text);
        return root;
    }

    const char* threadingModelName(osgViewer::ViewerBase::ThreadingModel model)
    {
        switch (model)
        {
            case osgViewer::ViewerBase::SingleThreaded:
                return "SingleThreaded";
            case osgViewer::ViewerBase::CullDrawThreadPerContext:
                return "CullDrawThreadPerContext";
            case osgViewer::ViewerBase::DrawThreadPerContext:
                return "DrawThreadPerContext";
            case osgViewer::ViewerBase::CullThreadPerCameraDrawThreadPerContext:
                return "CullThreadPerCameraDrawThreadPerContext";
            default:
                return "AutomaticSelection";
        }
    }
}

int main(int argc, char* argv[])
{
    if (SDL_Init(SDL_INIT_VIDEO) != 0)
    {
        SDL_Log("SDL_Init failed: %s", SDL_GetError());
        return 1;
    }

    // window and GL attributes as in OpenMW's engine.cpp
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

    SDL_Log("OpenSceneGraph %s", osgGetVersion());
    const std::vector<osg::ref_ptr<osg::Image>> images = checkPlugins();
    char* basePath = SDL_GetBasePath();
    const osg::ref_ptr<osgText::Font> font = checkFont(std::string(basePath ? basePath : "") + "DejaVuLGCSansMono.ttf");
    SDL_free(basePath);
    failures += checkLibraries(argc > 1 ? argv[1] : ""); // argument: game data directory (optional)

    osg::ref_ptr<osg::GraphicsContext::Traits> traits = new osg::GraphicsContext::Traits;
    SDL_GetWindowPosition(window, &traits->x, &traits->y);
    SDL_GL_GetDrawableSize(window, &traits->width, &traits->height);
    traits->windowName = SDL_GetWindowTitle(window);
    traits->windowDecoration = !(SDL_GetWindowFlags(window) & SDL_WINDOW_BORDERLESS);
    traits->screenNum = SDL_GetWindowDisplayIndex(window);
    traits->vsync = 0;
    traits->inheritedWindowData = new SDLUtil::GraphicsWindowSDL2::WindowData(window);
    osg::ref_ptr<SDLUtil::GraphicsWindowSDL2> graphicsWindow
        = new SDLUtil::GraphicsWindowSDL2(traits, SDLUtil::VSyncMode::Enabled);
    if (!graphicsWindow->valid())
    {
        SDL_Log("GraphicsWindowSDL2 failed");
        return 1;
    }

    osg::ref_ptr<RenderCheck> renderCheck = new RenderCheck;
    osgViewer::Viewer viewer;
    viewer.setReleaseContextAtEndOfFrameHint(false);
    viewer.setUseConfigureAffinity(false);
    viewer.setLightingMode(osg::View::NO_LIGHT);
    viewer.setKeyEventSetsDone(0);
    osg::Camera* camera = viewer.getCamera();
    camera->setGraphicsContext(graphicsWindow);
    camera->setViewport(0, 0, traits->width, traits->height);
    camera->setProjectionResizePolicy(osg::Camera::FIXED);
    camera->setProjectionMatrixAsOrtho2D(0, 1, 0, 1);
    camera->setViewMatrix(osg::Matrix::identity());
    camera->setComputeNearFarMode(osg::CullSettings::DO_NOT_COMPUTE_NEAR_FAR);
    camera->setClearColor(osg::Vec4(0.1f, 0.1f, 0.15f, 1));
    camera->setFinalDrawCallback(renderCheck);
    viewer.setSceneData(createScene(images, font, *renderCheck, float(traits->width) / traits->height));
    viewer.realize();
    SDL_Log("viewer threading model %s, drawable %dx%d", threadingModelName(viewer.getThreadingModel()),
        traits->width, traits->height);

    bool paused = false;
    int frames = 0;
    Uint32 last = SDL_GetTicks();
    while (!viewer.done())
    {
        SDL_Event event;
        while (SDL_PollEvent(&event))
        {
            switch (event.type)
            {
                case SDL_QUIT:
                    viewer.setDone(true);
                    break;
                case SDL_APP_WILLENTERBACKGROUND:
                    SDL_Log("event: will enter background");
                    paused = true;
                    break;
                case SDL_APP_DIDENTERFOREGROUND:
                    SDL_Log("event: did enter foreground");
                    paused = false;
                    break;
                case SDL_WINDOWEVENT:
                    if (event.window.event == SDL_WINDOWEVENT_SIZE_CHANGED)
                    {
                        int width, height;
                        SDL_GL_GetDrawableSize(window, &width, &height);
                        graphicsWindow->resized(0, 0, width, height);
                        SDL_Log("event: drawable size %dx%d", width, height);
                    }
                    break;
            }
        }
        if (paused)
        {
            SDL_Delay(100);
            continue;
        }

        viewer.frame();

        ++frames;
        const Uint32 now = SDL_GetTicks();
        if (now - last >= 2000)
        {
            SDL_Log("%.1f fps", frames * 1000.f / (now - last));
            frames = 0;
            last = now;
        }
    }
    return 0;
}
