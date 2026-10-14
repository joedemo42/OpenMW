#ifndef OPENMW_IOS_METALFX_H
#define OPENMW_IOS_METALFX_H

namespace OMW
{
    /// MetalFX spatial upscaling of the GL texture `input` into the GL texture `output` (8 bit RGB(A), sizes as given),
    /// sharpened with `[Video] metalfx sharpening`, on the queue Mesa's zink submits to, in GL command order (mesa
    /// patch 0010). Call on the GL thread with the context current; read the output only by copy or blit (Metal tracks
    /// those, not zink's descriptor reads). false: `[Video] metalfx` is off, or MetalFX is unavailable or failed
    /// (logged once); the caller scales by itself.
    bool metalFxUpscale(
        unsigned input, int inputWidth, int inputHeight, unsigned output, int outputWidth, int outputHeight);
}

#endif
