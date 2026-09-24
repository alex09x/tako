import Foundation
import Metal
import simd

// `custom-shader`: Shadertoy-style GLSL fragment shaders applied to the
// rendered terminal image before it reaches the screen.
//
// Metal does not compile GLSL, so the source is translated to Metal Shading
// Language here and compiled at runtime. The translation is textual and
// covers the subset terminal shaders use: GLSL type names, the GLSL-only
// built-ins, `out`/`inout` parameters and the Shadertoy uniforms. A shader
// outside that subset fails to compile and is reported, never trapped on.

/// `custom-shader-animation`: when a surface with custom shaders keeps
/// drawing frames without anything having changed.
@frozen public enum TerminalCustomShaderAnimation: Equatable, Sendable {
    /// `false`: a frame only when something changed.
    case disabled
    /// `true`: every frame while the surface is focused.
    case enabled
    /// `always`: every frame, focused or not.
    case always

    init?(configValue value: String) {
        switch value {
        case "true": self = .enabled
        case "false": self = .disabled
        case "always": self = .always
        default: return nil
        }
    }

    /// Whether a surface should ask for the next frame right after drawing one.
    public func keepsAnimating(isFocused: Bool) -> Bool {
        switch self {
        case .disabled: return false
        case .enabled: return isFocused
        case .always: return true
        }
    }
}

/// Why a `custom-shader` is not applied.
public enum TerminalCustomShaderError: Error, Equatable, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case compileFailed(name: String, message: String)
    case pipelineFailed(name: String, message: String)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason):
            return "custom-shader \(path): cannot read the file: \(reason)"
        case .compileFailed(let name, let message):
            return "custom-shader \(name): does not compile: \(message)"
        case .pipelineFailed(let name, let message):
            return "custom-shader \(name): no pipeline: \(message)"
        }
    }
}

/// The values every custom shader sees, laid out as the prelude's
/// `TakoShadertoyUniforms`.
struct TerminalCustomShaderUniforms: Equatable {
    var resolution: SIMD4<Float> = .zero
    var mouse: SIMD4<Float> = .zero
    var date: SIMD4<Float> = .zero
    var channelResolution: SIMD4<Float> = .zero
    /// `(x, y, width, height)` in pixels; `(x, y)` is the top-left corner
    /// with a bottom-left origin.
    var currentCursor: SIMD4<Float> = .zero
    var previousCursor: SIMD4<Float> = .zero
    var currentCursorColor: SIMD4<Float> = .zero
    var previousCursorColor: SIMD4<Float> = .zero
    var time: Float = 0
    var timeDelta: Float = 0
    var timeCursorChange: Float = 0
    var frame: Int32 = 0
}

/// One compiled custom shader, ready to run as a full-screen pass.
public struct TerminalCustomShader {
    public let name: String
    let pipeline: MTLRenderPipelineState

    /// Translate, compile and build the pass for one GLSL source.
    static func compile(
        glsl: String,
        name: String,
        device: MTLDevice,
        pixelFormat: MTLPixelFormat
    ) throws -> TerminalCustomShader {
        let source = TerminalCustomShaderTranslator.metalSource(glsl: glsl, name: name)
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw TerminalCustomShaderError.compileFailed(name: name, message: (error as NSError).localizedDescription)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "CustomShader.\(name)"
        descriptor.vertexFunction = library.makeFunction(name: TerminalCustomShaderTranslator.vertexFunction)
        descriptor.fragmentFunction = library.makeFunction(name: TerminalCustomShaderTranslator.fragmentFunction)
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        do {
            return TerminalCustomShader(name: name, pipeline: try device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            throw TerminalCustomShaderError.pipelineFailed(name: name, message: (error as NSError).localizedDescription)
        }
    }
}

/// Shadertoy GLSL in, Metal Shading Language out.
///
/// The user source is placed inside a struct whose members are the
/// uniforms and `iChannel0`, so its global constants and functions see them
/// as members. A fragment function builds that struct and calls `mainImage`.
public enum TerminalCustomShaderTranslator {
    static let vertexFunction = "tako_custom_shader_vertex"
    static let fragmentFunction = "tako_custom_shader_fragment"

    /// The complete Metal source for one shader. `name` labels compiler
    /// diagnostics, so they point at the user's own file and line.
    public static func metalSource(glsl: String, name: String = "shader.glsl") -> String {
        let fileName = name.replacingOccurrences(of: "\"", with: "'")
        return prelude
            + structHead
            + glslNames.map { "#define \($0.0) \($0.1)\n" }.joined()
            + "#line 1 \"\(fileName)\"\n"
            + translateBody(glsl)
            + "\n"
            + glslNames.map { "#undef \($0.0)\n" }.joined()
            + "};\n"
            + entryPoints
    }

    /// The user source with the GLSL-only syntax rewritten. Line numbers are
    /// kept, so a diagnostic still names the right line.
    static func translateBody(_ glsl: String) -> String {
        let lines = stripComments(glsl).components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Directives and declarations the struct already provides.
            if trimmed.hasPrefix("#version") || trimmed.hasPrefix("#extension")
                || trimmed.hasPrefix("precision ") || trimmed.hasPrefix("uniform ") {
                return ""
            }
            return line
        }
        var body = lines.joined(separator: "\n")
        body = replace(
            #"\b(?:inout|out)\s+(?:const\s+)?(?:(?:highp|mediump|lowp)\s+)?([A-Za-z_]\w*)\s+([A-Za-z_]\w*)"#,
            in: body,
            with: "thread $1& $2")
        body = replace(#"\bin\s+(?=[A-Za-z_])"#, in: body, with: "")
        return body
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        // swiftlint:disable:next force_try -- literal, always-valid patterns
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// `//` and `/* */` comments removed, newlines inside block comments kept.
    static func stripComments(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            if scalar == "/", next == "/" {
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
            } else if scalar == "/", next == "*" {
                index += 2
                while index < scalars.count, !(scalars[index] == "*" && index + 1 < scalars.count && scalars[index + 1] == "/") {
                    if scalars[index] == "\n" { out.append("\n") }
                    index += 1
                }
                index += 2
                out.append(" ")
            } else {
                out.append(scalar)
                index += 1
            }
        }
        return String(out)
    }

    /// GLSL names mapped onto the prelude, defined only around the user
    /// source so the entry points below keep Metal's own meaning.
    static let glslNames: [(String, String)] = [
        ("mod", "tako_mod"), ("atan", "tako_atan"),
        ("min", "tako_min"), ("max", "tako_max"), ("clamp", "tako_clamp"),
        ("mix", "tako_mix"), ("step", "tako_step"), ("smoothstep", "tako_smoothstep"),
        ("radians", "tako_radians"), ("degrees", "tako_degrees"),
        ("inversesqrt", "rsqrt"), ("dFdx", "dfdx"), ("dFdy", "dfdy"), ("roundEven", "rint"),
        ("lessThan", "tako_lessThan"), ("lessThanEqual", "tako_lessThanEqual"),
        ("greaterThan", "tako_greaterThan"), ("greaterThanEqual", "tako_greaterThanEqual"),
        ("equal", "tako_equal"), ("notEqual", "tako_notEqual"),
        ("texture", "tako_texture"), ("texture2D", "tako_texture"),
        ("textureLod", "tako_textureLod"), ("texture2DLod", "tako_textureLod"),
        ("texelFetch", "tako_texelFetch"), ("textureSize", "tako_textureSize"),
        ("highp", ""), ("mediump", ""), ("lowp", ""),
        // Metal keywords that are ordinary identifiers in GLSL.
        ("half", "tako_half"), ("device", "tako_device"), ("constant", "tako_constant"),
        ("kernel", "tako_kernel"), ("vertex", "tako_vertex"), ("fragment", "tako_fragment"),
    ]

    static let prelude = """
    #include <metal_stdlib>
    using namespace metal;

    typedef float2 vec2;
    typedef float3 vec3;
    typedef float4 vec4;
    typedef int2 ivec2;
    typedef int3 ivec3;
    typedef int4 ivec4;
    typedef uint2 uvec2;
    typedef uint3 uvec3;
    typedef uint4 uvec4;
    typedef bool2 bvec2;
    typedef bool3 bvec3;
    typedef bool4 bvec4;
    typedef float2x2 mat2;
    typedef float3x3 mat3;
    typedef float4x4 mat4;
    typedef float2x2 mat2x2;
    typedef float3x3 mat3x3;
    typedef float4x4 mat4x4;
    typedef texture2d<float> sampler2D;

    struct TakoShadertoyUniforms {
        float4 iResolution;
        float4 iMouse;
        float4 iDate;
        float4 iChannelResolution0;
        float4 iCurrentCursor;
        float4 iPreviousCursor;
        float4 iCurrentCursorColor;
        float4 iPreviousCursorColor;
        float iTime;
        float iTimeDelta;
        float iTimeCursorChange;
        int iFrame;
    };

    #define TAKO_VECTOR_OVERLOADS(MACRO) MACRO(float2) MACRO(float3) MACRO(float4)

    inline float tako_mod(float x, float y) { return x - y * floor(x / y); }
    #define TAKO_MOD(T) \\
        inline T tako_mod(T x, T y) { return x - y * floor(x / y); } \\
        inline T tako_mod(T x, float y) { return x - y * floor(x / y); }
    TAKO_VECTOR_OVERLOADS(TAKO_MOD)

    inline float tako_atan(float x) { return metal::atan(x); }
    inline float tako_atan(float y, float x) { return metal::atan2(y, x); }
    #define TAKO_ATAN(T) \\
        inline T tako_atan(T x) { return metal::atan(x); } \\
        inline T tako_atan(T y, T x) { return metal::atan2(y, x); }
    TAKO_VECTOR_OVERLOADS(TAKO_ATAN)

    template <typename T> inline T tako_min(T a, T b) { return metal::min(a, b); }
    template <typename T> inline T tako_max(T a, T b) { return metal::max(a, b); }
    template <typename T> inline T tako_clamp(T x, T lo, T hi) { return metal::clamp(x, lo, hi); }
    template <typename T> inline T tako_mix(T a, T b, T t) { return metal::mix(a, b, t); }
    template <typename T> inline T tako_step(T edge, T x) { return metal::step(edge, x); }
    template <typename T> inline T tako_smoothstep(T a, T b, T x) { return metal::smoothstep(a, b, x); }
    inline float tako_min(float a, float b) { return metal::min(a, b); }
    inline float tako_max(float a, float b) { return metal::max(a, b); }
    inline float tako_clamp(float x, float lo, float hi) { return metal::clamp(x, lo, hi); }
    inline float tako_mix(float a, float b, float t) { return metal::mix(a, b, t); }
    inline float tako_step(float edge, float x) { return metal::step(edge, x); }
    inline float tako_smoothstep(float a, float b, float x) { return metal::smoothstep(a, b, x); }
    #define TAKO_SCALAR_ARGUMENTS(T) \\
        inline T tako_min(T a, float b) { return metal::min(a, T(b)); } \\
        inline T tako_max(T a, float b) { return metal::max(a, T(b)); } \\
        inline T tako_clamp(T x, float lo, float hi) { return metal::clamp(x, T(lo), T(hi)); } \\
        inline T tako_mix(T a, T b, float t) { return metal::mix(a, b, T(t)); } \\
        inline T tako_step(float edge, T x) { return metal::step(T(edge), x); } \\
        inline T tako_smoothstep(float a, float b, T x) { return metal::smoothstep(T(a), T(b), x); }
    TAKO_VECTOR_OVERLOADS(TAKO_SCALAR_ARGUMENTS)

    template <typename T> inline T tako_radians(T d) { return d * 0.017453292519943295f; }
    template <typename T> inline T tako_degrees(T r) { return r * 57.29577951308232f; }

    template <typename T> inline auto tako_lessThan(T a, T b) -> decltype(a < b) { return a < b; }
    template <typename T> inline auto tako_lessThanEqual(T a, T b) -> decltype(a <= b) { return a <= b; }
    template <typename T> inline auto tako_greaterThan(T a, T b) -> decltype(a > b) { return a > b; }
    template <typename T> inline auto tako_greaterThanEqual(T a, T b) -> decltype(a >= b) { return a >= b; }
    template <typename T> inline auto tako_equal(T a, T b) -> decltype(a == b) { return a == b; }
    template <typename T> inline auto tako_notEqual(T a, T b) -> decltype(a != b) { return a != b; }

    // Texture rows run top-down; Shadertoy's v runs bottom-up.
    constexpr sampler tako_channel_sampler(coord::normalized, address::clamp_to_edge, filter::linear);
    inline float2 tako_flip(float2 uv) { return float2(uv.x, 1.0 - uv.y); }
    inline float4 tako_texture(texture2d<float> t, float2 uv) {
        return t.sample(tako_channel_sampler, tako_flip(uv));
    }
    inline float4 tako_texture(texture2d<float> t, float2 uv, float b) {
        return t.sample(tako_channel_sampler, tako_flip(uv), bias(b));
    }
    inline float4 tako_textureLod(texture2d<float> t, float2 uv, float lod) {
        return t.sample(tako_channel_sampler, tako_flip(uv), level(lod));
    }
    inline float4 tako_texelFetch(texture2d<float> t, int2 p, int lod) {
        int x = metal::clamp(p.x, 0, int(t.get_width()) - 1);
        int y = metal::clamp(int(t.get_height()) - 1 - p.y, 0, int(t.get_height()) - 1);
        return t.read(uint2(x, y));
    }
    inline int2 tako_textureSize(texture2d<float> t, int lod) {
        return int2(int(t.get_width()), int(t.get_height()));
    }

    """

    static let structHead = """
    struct TakoShadertoy {
        float3 iResolution;
        float iTime;
        float iTimeDelta;
        int iFrame;
        float4 iMouse;
        float4 iDate;
        float3 iChannelResolution[4];
        float iChannelTime[4];
        float4 iCurrentCursor;
        float4 iPreviousCursor;
        float4 iCurrentCursorColor;
        float4 iPreviousCursorColor;
        float iTimeCursorChange;
        texture2d<float> iChannel0;

        TakoShadertoy(TakoShadertoyUniforms tako_u, texture2d<float> tako_channel0)
            : iResolution(tako_u.iResolution.xyz), iTime(tako_u.iTime), iTimeDelta(tako_u.iTimeDelta),
              iFrame(tako_u.iFrame), iMouse(tako_u.iMouse), iDate(tako_u.iDate),
              iCurrentCursor(tako_u.iCurrentCursor), iPreviousCursor(tako_u.iPreviousCursor),
              iCurrentCursorColor(tako_u.iCurrentCursorColor), iPreviousCursorColor(tako_u.iPreviousCursorColor),
              iTimeCursorChange(tako_u.iTimeCursorChange), iChannel0(tako_channel0) {
            for (int i = 0; i < 4; i++) {
                iChannelResolution[i] = float3(0.0);
                iChannelTime[i] = tako_u.iTime;
            }
            iChannelResolution[0] = tako_u.iChannelResolution0.xyz;
        }

    """

    static let entryPoints = """

    struct TakoCustomShaderVertexOut {
        float4 position [[position]];
    };

    vertex TakoCustomShaderVertexOut tako_custom_shader_vertex(uint vid [[vertex_id]]) {
        // One triangle covering the whole target.
        float2 corner = float2(float((vid << 1) & 2), float(vid & 2));
        TakoCustomShaderVertexOut out;
        out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    fragment float4 tako_custom_shader_fragment(
        TakoCustomShaderVertexOut v [[stage_in]],
        constant TakoShadertoyUniforms& tako_u [[buffer(0)]],
        texture2d<float> tako_channel0 [[texture(0)]]
    ) {
        TakoShadertoy shader(tako_u, tako_channel0);
        float4 color = float4(0.0);
        shader.mainImage(color, float2(v.position.x, tako_u.iResolution.y - v.position.y));
        return color;
    }

    """
}
