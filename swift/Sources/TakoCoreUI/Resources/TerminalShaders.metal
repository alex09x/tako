// Compiled into TakoCoreUI's SwiftPM resource bundle and into the direct
// app builds' default.metallib.
#include <metal_stdlib>

using namespace metal;

// Laid out to match TerminalMetalViewport in TerminalMetalStructs.swift:
// six floats, read here as three float2 (24 bytes, 8-byte aligned).
//   _scalePad.x  backing scale
//   _scalePad.y  color space/encoding selector
//   _offsetPad.x whole-grid vertical translation, in drawable pixels
//   _offsetPad.y whole-grid horizontal translation, in drawable pixels
struct TerminalMetalViewport {
    float2 drawablePixels;
    float2 _scalePad;
    float2 _offsetPad;
};

struct TerminalMetalBackgroundInstance {
    float4 rect;
    float4 color;
};

struct TerminalMetalSelectionInstance {
    float4 rect;
    float4 color;
};

struct TerminalMetalCursorInstance {
    float4 rect;
    uint style;
    uint blinkState;
    float2 _pad;
    float4 color;
};

struct TerminalMetalGlyphInstance {
    float4 destRect;
    float4 uvRect;
    float4 color;
    uint atlasPage;
    uint flags;
    float2 _pad;
};

struct TerminalMetalImageInstance {
    float4 destRect;
    float4 uvRect;
    float4 tint;
    uint imageId;
    uint flags;
    float2 _pad;
};

struct TerminalMetalDecorationInstance {
    float4 rect;
    float4 color;
    uint style;
    float thickness;
    float2 _pad;
};

struct TerminalMetalVertexOut {
    float4 position [[position]];
    float4 color;
};

struct TerminalMetalGlyphVertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
    uint atlasPage;
    uint flags;
    float colorTransform;
};

struct TerminalMetalDecorationVertexOut {
    float4 position [[position]];
    float4 color;
    float2 local;
    float2 size;
    uint style;
    float thickness;
};

struct TerminalMetalImageVertexOut {
    float4 position [[position]];
    float4 tint;
    float2 uv;
    float colorTransform;
};

inline float3 terminalSRGBDecode(float3 value) {
    return select(pow((value + 0.055) / 1.055, float3(2.4)), value / 12.92, value <= 0.04045);
}

inline float3 terminalSRGBEncode(float3 value) {
    value = clamp(value, 0.0, 1.0);
    return select(1.055 * pow(value, float3(1.0 / 2.4)) - 0.055, value * 12.92, value <= 0.0031308);
}

/// Converts a premultiplied sRGB texture sample into the renderer output
/// space. Unpremultiplication is guarded so transparent texels remain zero.
inline float4 terminalConvertTextureSample(float4 sample, float transform) {
    if (sample.a <= 0.0) return float4(0.0);
    if (transform < 0.5) return sample;
    float3 rgb = terminalSRGBDecode(clamp(sample.rgb / sample.a, 0.0, 1.0));
    if (transform >= 1.5) {
        rgb = float3(
            0.8225929 * rgb.r + 0.1775340 * rgb.g,
            0.0331995 * rgb.r + 0.9667835 * rgb.g,
            0.0170854 * rgb.r + 0.0723957 * rgb.g + 0.9103015 * rgb.b
        );
    }
    if (transform < 2.5 && transform >= 1.5) rgb = terminalSRGBEncode(rgb);
    return float4(rgb * sample.a, sample.a);
}

// Every vertex shader in this file reaches clip space through here, so the
// grid's vertical translation is applied in exactly one place. A pass that
// forgot to apply it would tear away from the rest of the frame; there is no
// path that can forget.
inline float4 terminalDrawableToClip(float2 pixelPos, constant TerminalMetalViewport& vp) {
    float2 ndc = float2(
        ((pixelPos.x + vp._offsetPad.y) / vp.drawablePixels.x) * 2.0 - 1.0,
        1.0 - ((pixelPos.y + vp._offsetPad.x) / vp.drawablePixels.y) * 2.0
    );
    return float4(ndc.x, ndc.y, 0.0, 1.0);
}

inline float2 terminalCornerPosition(uint vertexId) {
    return float2(
        (vertexId == 1 || vertexId == 2) ? 1.0 : 0.0,
        (vertexId == 2 || vertexId == 3) ? 1.0 : 0.0
    );
}

vertex TerminalMetalVertexOut
terminalBackgroundVertex(
    uint vertex_id [[vertex_id]],
    constant TerminalMetalViewport &vp [[buffer(0)]],
    constant TerminalMetalBackgroundInstance* instances [[buffer(1)]],
    uint instance_id [[instance_id]]
) {
    TerminalMetalBackgroundInstance instance = instances[instance_id];
    float2 corner = terminalCornerPosition(vertex_id);
    float2 position = instance.rect.xy + corner * instance.rect.zw;

    TerminalMetalVertexOut out {
        .position = terminalDrawableToClip(position, vp),
        .color = instance.color,
    };
    return out;
}

fragment float4
terminalBackgroundFragment(TerminalMetalVertexOut in [[stage_in]]) {
    return in.color;
}

vertex TerminalMetalVertexOut
terminalSelectionVertex(
    uint vertex_id [[vertex_id]],
    constant TerminalMetalViewport &vp [[buffer(0)]],
    constant TerminalMetalSelectionInstance* instances [[buffer(1)]],
    uint instance_id [[instance_id]]
) {
    TerminalMetalSelectionInstance instance = instances[instance_id];
    float2 corner = terminalCornerPosition(vertex_id);
    float2 position = instance.rect.xy + corner * instance.rect.zw;

    TerminalMetalVertexOut out {
        .position = terminalDrawableToClip(position, vp),
        .color = instance.color,
    };
    return out;
}

fragment float4
terminalSelectionFragment(TerminalMetalVertexOut in [[stage_in]]) {
    return in.color;
}

vertex TerminalMetalVertexOut
terminalCursorVertex(
    uint vertex_id [[vertex_id]],
    constant TerminalMetalViewport &vp [[buffer(0)]],
    constant TerminalMetalCursorInstance* instances [[buffer(1)]],
    uint instance_id [[instance_id]]
) {
    TerminalMetalCursorInstance instance = instances[instance_id];
    float2 corner = terminalCornerPosition(vertex_id);
    float2 position = instance.rect.xy + corner * instance.rect.zw;

    TerminalMetalVertexOut out {
        .position = terminalDrawableToClip(position, vp),
        .color = instance.color,
    };
    return out;
}

fragment float4
terminalCursorFragment(TerminalMetalVertexOut in [[stage_in]]) {
    // The host omits the cursor instance while blink is off. Fragment stages
    // have no per-instance index, so consulting an instance buffer here would
    // incorrectly apply one cursor's state to the entire instanced draw.
    return in.color;
}

vertex TerminalMetalGlyphVertexOut
terminalGrayscaleGlyphVertex(
    uint vertex_id [[vertex_id]],
    constant TerminalMetalViewport &vp [[buffer(0)]],
    constant TerminalMetalGlyphInstance* instances [[buffer(1)]],
    uint instance_id [[instance_id]]
) {
    TerminalMetalGlyphInstance instance = instances[instance_id];
    float2 corner = terminalCornerPosition(vertex_id);
    float2 position = instance.destRect.xy + corner * instance.destRect.zw;
    float2 uv = float2(
        mix(instance.uvRect.x, instance.uvRect.z, corner.x),
        mix(instance.uvRect.y, instance.uvRect.w, corner.y)
    );

    TerminalMetalGlyphVertexOut out {
        .position = terminalDrawableToClip(position, vp),
        .color = instance.color,
        .uv = uv,
        .atlasPage = instance.atlasPage,
        .flags = instance.flags,
        .colorTransform = vp._scalePad.y,
    };
    return out;
}

fragment float4
terminalColorGlyphFragment(
    TerminalMetalGlyphVertexOut in [[stage_in]],
    texture2d<float> glyphAtlas [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float4 pixel = terminalConvertTextureSample(glyphAtlas.sample(glyphSampler, in.uv), in.colorTransform);
    // BGRA storage is swizzled by Metal into logical RGBA. Both the atlas
    // sample and tint are premultiplied, including dim/unfocused alpha.
    return pixel * in.color;
}

vertex TerminalMetalDecorationVertexOut
terminalDecorationVertex(
    uint vertex_id [[vertex_id]],
    constant TerminalMetalViewport &vp [[buffer(0)]],
    constant TerminalMetalDecorationInstance* instances [[buffer(1)]],
    uint instance_id [[instance_id]]
) {
    TerminalMetalDecorationInstance instance = instances[instance_id];
    float2 corner = terminalCornerPosition(vertex_id);
    float2 position = instance.rect.xy + corner * instance.rect.zw;
    return TerminalMetalDecorationVertexOut {
        .position = terminalDrawableToClip(position, vp),
        .color = instance.color,
        .local = corner * instance.rect.zw,
        .size = instance.rect.zw,
        .style = instance.style,
        .thickness = instance.thickness,
    };
}

fragment float4
terminalDecorationFragment(TerminalMetalDecorationVertexOut in [[stage_in]]) {
    float t = max(in.thickness, 1.0);
    float coverage = 1.0;
    if (in.style == 2) {
        coverage = (in.local.y < t || in.local.y >= in.size.y - t) ? 1.0 : 0.0;
    } else if (in.style == 3) {
        float center = in.size.y * 0.5 + sin(in.local.x * 3.14159265 / max(2.0 * t, 1.0)) * t;
        coverage = 1.0 - smoothstep(t * 0.45, t, abs(in.local.y - center));
    } else if (in.style == 4) {
        coverage = fmod(floor(in.local.x / t), 2.0) < 1.0 ? 1.0 : 0.0;
    } else if (in.style == 5) {
        coverage = fmod(in.local.x, 7.0 * t) < 4.0 * t ? 1.0 : 0.0;
    }
    return in.color * coverage;
}

fragment float4
terminalGrayscaleGlyphFragment(
    TerminalMetalGlyphVertexOut in [[stage_in]],
    texture2d<float> glyphAtlas [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float alpha = glyphAtlas.sample(glyphSampler, in.uv).r;
    return float4(in.color.rgb * alpha, in.color.a * alpha);
}

vertex TerminalMetalImageVertexOut
terminalImageVertex(
    uint vertex_id [[vertex_id]],
    constant TerminalMetalViewport &vp [[buffer(0)]],
    constant TerminalMetalImageInstance* instances [[buffer(1)]],
    uint instance_id [[instance_id]]
) {
    TerminalMetalImageInstance instance = instances[instance_id];
    float2 corner = terminalCornerPosition(vertex_id);
    float2 position = instance.destRect.xy + corner * instance.destRect.zw;
    float2 uv = float2(
        mix(instance.uvRect.x, instance.uvRect.z, corner.x),
        mix(instance.uvRect.y, instance.uvRect.w, corner.y)
    );

    TerminalMetalImageVertexOut out {
        .position = terminalDrawableToClip(position, vp),
        .tint = instance.tint,
        .uv = uv,
        .colorTransform = vp._scalePad.y,
    };
    return out;
}

fragment float4
terminalImageFragment(
    TerminalMetalImageVertexOut in [[stage_in]],
    texture2d<float> image [[texture(0)]],
    sampler imageSampler [[sampler(0)]]
) {
    // The host uploads Kitty images as premultiplied BGRA8 (see
    // MetalImageCache), and the tint is premultiplied too, so a plain
    // multiply keeps the result premultiplied for the blend state.
    return terminalConvertTextureSample(image.sample(imageSampler, in.uv), in.colorTransform) * in.tint;
}
