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
    bool sSharpenUnavailable = false;
    id<MTLRenderPipelineState> sSharpen = nil;
    MTLPixelFormat sSharpenFormat = MTLPixelFormatInvalid;
    // the scaler's output while sharpening
    id<MTLTexture> sScaled = nil;

    constexpr const char* sSharpenSource = R"(
        #include <metal_stdlib>
        using namespace metal;

        // one triangle covering the render target
        vertex float4 cover(uint id [[vertex_id]])
        {
            return float4(float2((id << 1) & 2, id & 2) * 2.0 - 1.0, 0.0, 1.0);
        }

        // robust contrast adaptive sharpening (RCAS) after AMD FidelityFX Super Resolution 1 (MIT): the strongest
        // negative lobe on the 4 neighbours that keeps every channel in [0, 1], limited and scaled by the sharpness
        fragment float4 sharpen(float4 position [[position]], texture2d<float, access::read> image [[texture(0)]],
            constant float& sharpness [[buffer(0)]])
        {
            const uint2 p = uint2(position.xy);
            const uint2 last = uint2(image.get_width(), image.get_height()) - 1;
            const float4 e = image.read(p);
            const float3 b = image.read(uint2(p.x, max(p.y, 1u) - 1)).rgb;
            const float3 d = image.read(uint2(max(p.x, 1u) - 1, p.y)).rgb;
            const float3 f = image.read(uint2(min(p.x + 1, last.x), p.y)).rgb;
            const float3 h = image.read(uint2(p.x, min(p.y + 1, last.y))).rgb;
            const float3 lo = min(min(b, d), min(f, h));
            const float3 hi = max(max(b, d), max(f, h));
            // result (w * (b + d + f + h) + e) / (4 * w + 1) with w <= 0: not below 0 for w >= -min / (4 * max),
            // not above 1 for w >= (1 - max) / (4 * min - 4); the divisors kept off 0 for black and white
            const float3 hitMin = min(lo, e.rgb) / max(4.0 * hi, 1.0 / 256.0);
            const float3 hitMax = (1.0 - max(hi, e.rgb)) / min(4.0 * lo - 4.0, -1.0 / 256.0);
            const float3 lobes = max(-hitMin, hitMax);
            const float lobe = clamp(max3(lobes.r, lobes.g, lobes.b), -0.1875, 0.0) * sharpness;
            return float4((lobe * (b + d + f + h) + e.rgb) / (4.0 * lobe + 1.0), e.a);
        }
    )";

    bool unavailable(const char* reason)
    {
        Log(Debug::Warning) << "MetalFX upscaling unavailable: " << reason;
        sUnavailable = true;
        return false;
    }

    // the sharpening pipeline for render targets of `format`; nil: unavailable (logged once)
    id<MTLRenderPipelineState> sharpenPipeline(id<MTLDevice> device, MTLPixelFormat format)
    {
        if (sSharpenUnavailable || (sSharpen && sSharpenFormat == format))
            return sSharpen;
        @autoreleasepool
        {
            [sSharpen release];
            sSharpen = nil;
            NSError* error = nil;
            id<MTLLibrary> library = [device newLibraryWithSource:@(sSharpenSource) options:nil error:&error];
            if (library)
            {
                MTLRenderPipelineDescriptor* descriptor = [[MTLRenderPipelineDescriptor alloc] init];
                id<MTLFunction> vertex = [library newFunctionWithName:@"cover"];
                id<MTLFunction> fragment = [library newFunctionWithName:@"sharpen"];
                descriptor.vertexFunction = vertex;
                descriptor.fragmentFunction = fragment;
                descriptor.colorAttachments[0].pixelFormat = format;
                sSharpen = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
                [vertex release];
                [fragment release];
                [descriptor release];
                [library release];
            }
            if (!sSharpen)
            {
                Log(Debug::Warning) << "MetalFX sharpening unavailable: "
                                    << (error ? error.localizedDescription.UTF8String : "no pipeline");
                sSharpenUnavailable = true;
                return nil;
            }
            sSharpenFormat = format;
            return sSharpen;
        }
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
        // nil: no sharpening; else MetalFX scales into mScaled and mSharpen writes mOutput from it
        id<MTLTexture> mScaled;
        id<MTLRenderPipelineState> mSharpen;
        float mSharpness;
    };

    // on Mesa's driver thread, after the GL commands issued before were committed to the queue
    void encode(void* data)
    {
        Job* job = static_cast<Job*>(data);
        @autoreleasepool
        {
            id<MTLCommandBuffer> commands = [job->mQueue commandBuffer];
            job->mScaler.colorTexture = job->mInput;
            job->mScaler.outputTexture = job->mScaled ? job->mScaled : job->mOutput;
            [job->mScaler encodeToCommandBuffer:commands];
            if (job->mScaled)
            {
                MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = job->mOutput;
                pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
                [encoder setRenderPipelineState:job->mSharpen];
                [encoder setFragmentTexture:job->mScaled atIndex:0];
                [encoder setFragmentBytes:&job->mSharpness length:sizeof(job->mSharpness) atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [encoder endEncoding];
            }
            [commands commit];
        }
        [job->mQueue release];
        [job->mScaler release];
        [job->mInput release];
        [job->mOutput release];
        [job->mScaled release];
        [job->mSharpen release];
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
        // OpenMW's colors are display-referred (sRGB-encoded 8 bit)
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

    // sharpening (the spatial scaler has none): MetalFX into sScaled, RCAS from it into the output
    const float sharpness = Settings::video().mMetalFxSharpening ? Settings::video().mMetalFxSharpness.get() : 0.f;
    id<MTLRenderPipelineState> sharpen = sharpness > 0 ? sharpenPipeline(device, outputTexture.pixelFormat) : nil;
    if (!sharpen || sScaled.width != static_cast<NSUInteger>(outputWidth)
        || sScaled.height != static_cast<NSUInteger>(outputHeight) || sScaled.pixelFormat != outputTexture.pixelFormat)
    {
        [sScaled release];
        sScaled = nil;
        if (sharpen)
        {
            MTLTextureDescriptor* descriptor = [[MTLTextureDescriptor alloc] init];
            descriptor.pixelFormat = outputTexture.pixelFormat;
            descriptor.width = outputWidth;
            descriptor.height = outputHeight;
            descriptor.storageMode = MTLStorageModePrivate;
            descriptor.usage = sScaler.outputTextureUsage | MTLTextureUsageShaderRead;
            sScaled = [device newTextureWithDescriptor:descriptor];
            [descriptor release];
        }
    }
    if (!sScaled)
        sharpen = nil;

    Job* job = new Job{ [(id<MTLCommandQueue>)inputObjects.mtl_command_queue retain], [sScaler retain],
        [inputTexture retain], [outputTexture retain], [sScaled retain], [sharpen retain], sharpness };
    MesaGLInteropRunAfterFlush(encode, job);
    return true;
}
#endif
