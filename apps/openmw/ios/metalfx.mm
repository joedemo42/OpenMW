#include "metalfx.hpp"

#include <components/debug/debuglog.hpp>
#include <components/settings/values.hpp>

#include <EGL/egl.h>
#include <GL/gl.h>
#include <GL/mesa_glinterop.h>

#include <TargetConditionals.h>

#import <Metal/Metal.h>
#if !TARGET_OS_SIMULATOR
#import <MetalFX/MetalFX.h>
#endif

#if TARGET_OS_SIMULATOR
// the simulator SDK has no MetalFX
bool OMW::metalFxUpscale(unsigned, int, int, unsigned, int, int)
{
    return false;
}
#else
namespace
{
    bool sUnavailable = false;
    id<MTLFXSpatialScaler> sScaler = nil;

    bool unavailable(const char* reason)
    {
        Log(Debug::Warning) << "MetalFX upscaling unavailable: " << reason;
        sUnavailable = true;
        return false;
    }

    // the Metal objects behind a GL texture of the current context (not retained)
    bool exportTexture(unsigned texture, mesa_glinterop_metal_objects& objects)
    {
        objects = {};
        mesa_glinterop_export_in in{};
        in.version = 1;
        in.target = GL_TEXTURE_2D;
        in.obj = texture;
        in.access = MESA_GLINTEROP_ACCESS_READ_WRITE;
        in.out_driver_data_size = sizeof(objects);
        in.out_driver_data = &objects;
        mesa_glinterop_export_out out{};
        out.version = 1;
        return MesaGLInteropEGLExportObject(eglGetCurrentDisplay(), eglGetCurrentContext(), &in, &out)
            == MESA_GLINTEROP_SUCCESS
            && out.out_driver_data_written >= sizeof(objects) && objects.mtl_texture && objects.mtl_command_queue;
    }

    struct Job
    {
        id<MTLCommandQueue> mQueue;
        id<MTLFXSpatialScaler> mScaler;
        id<MTLTexture> mInput;
        id<MTLTexture> mOutput;
    };

    // on Mesa's driver thread, after the GL commands issued before were committed to the queue
    void encode(void* data)
    {
        Job* job = static_cast<Job*>(data);
        @autoreleasepool
        {
            id<MTLCommandBuffer> commands = [job->mQueue commandBuffer];
            job->mScaler.colorTexture = job->mInput;
            job->mScaler.outputTexture = job->mOutput;
            [job->mScaler encodeToCommandBuffer:commands];
            [commands commit];
        }
        [job->mQueue release];
        [job->mScaler release];
        [job->mInput release];
        [job->mOutput release];
        delete job;
    }
}

bool OMW::metalFxUpscale(
    unsigned input, int inputWidth, int inputHeight, unsigned output, int outputWidth, int outputHeight)
{
    if (sUnavailable || !Settings::video().mMetalFx)
        return false;

    // every call: the textures may have been respecified since
    mesa_glinterop_metal_objects inputObjects, outputObjects;
    if (!exportTexture(input, inputObjects) || !exportTexture(output, outputObjects))
        return unavailable("no Metal objects behind the GL textures");
    id<MTLDevice> device = (id<MTLDevice>)inputObjects.mtl_device;
    id<MTLTexture> inputTexture = (id<MTLTexture>)inputObjects.mtl_texture;
    id<MTLTexture> outputTexture = (id<MTLTexture>)outputObjects.mtl_texture;

    if (!sScaler || sScaler.inputWidth != static_cast<NSUInteger>(inputWidth)
        || sScaler.inputHeight != static_cast<NSUInteger>(inputHeight)
        || sScaler.outputWidth != static_cast<NSUInteger>(outputWidth)
        || sScaler.outputHeight != static_cast<NSUInteger>(outputHeight)
        || sScaler.colorTextureFormat != inputTexture.pixelFormat
        || sScaler.outputTextureFormat != outputTexture.pixelFormat)
    {
        [sScaler release];
        sScaler = nil;
        if (![MTLFXSpatialScalerDescriptor supportsDevice:device])
            return unavailable("not supported on this device");
        MTLFXSpatialScalerDescriptor* descriptor = [[MTLFXSpatialScalerDescriptor alloc] init];
        descriptor.inputWidth = inputWidth;
        descriptor.inputHeight = inputHeight;
        descriptor.outputWidth = outputWidth;
        descriptor.outputHeight = outputHeight;
        descriptor.colorTextureFormat = inputTexture.pixelFormat;
        descriptor.outputTextureFormat = outputTexture.pixelFormat;
        // OpenMW's colors are display-referred (sRGB-encoded 8 bit). ponytail: no sharpening (the spatial scaler has
        // none); upgrade path: a sharpening pass after it, or a sharpening shader in OpenMW's post-processing chain
        descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        sScaler = [descriptor newSpatialScalerWithDevice:device];
        [descriptor release];
        if (!sScaler)
            return unavailable("no spatial scaler");

        Log(Debug::Info) << "MetalFX spatial scaler " << inputWidth << "x" << inputHeight << " -> " << outputWidth
                         << "x" << outputHeight << ", texture usage needed/present: input "
                         << sScaler.colorTextureUsage << "/" << inputTexture.usage << ", output "
                         << sScaler.outputTextureUsage << "/" << outputTexture.usage << "; storage modes "
                         << inputTexture.storageMode << "/" << outputTexture.storageMode << ", hazard tracking "
                         << inputTexture.hazardTrackingMode << "/" << outputTexture.hazardTrackingMode;
        if ((inputTexture.usage & sScaler.colorTextureUsage) != sScaler.colorTextureUsage
            || (outputTexture.usage & sScaler.outputTextureUsage) != sScaler.outputTextureUsage)
            return unavailable("texture usage");
    }

    Job* job = new Job{ [(id<MTLCommandQueue>)inputObjects.mtl_command_queue retain], [sScaler retain],
        [inputTexture retain], [outputTexture retain] };
    MesaGLInteropRunAfterFlush(encode, job);
    return true;
}
#endif
