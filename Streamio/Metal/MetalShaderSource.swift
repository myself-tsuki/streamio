//
//  MetalShaderSource.swift
//  Streamio
//

import Foundation

public struct MetalShaderSource {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoords;
    };

    vertex VertexOut videoVertexShader(uint vertexID [[vertex_id]]) {
        float2 positions[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };
        
        float2 texCoords[3] = {
            float2(0.0, 1.0),
            float2(2.0, 1.0),
            float2(0.0, -1.0)
        };
        
        VertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.texCoords = texCoords[vertexID];
        return out;
    }

    struct ShaderParams {
        float brightness;
        float contrast;
        float saturation;
        float intensity;
        uint filterType;
        float uvX;
        float uvY;
        float uvWidth;
        float uvHeight;
        uint mirror;
        float opacity;
        // Shape mask: 0 box, 1 rounded box, 2 ellipse, 3 hexagon, 4 diamond.
        uint shape;
        // Size of the layer's viewport in pixels, for round corners and crisp edges.
        float viewWidth;
        float viewHeight;
        // Border thickness as a fraction of the shorter side, and its colour.
        float borderWidth;
        float borderRed;
        float borderGreen;
        float borderBlue;
    };

    // Signed distance to the shape, in units of the viewport's shorter side (negative inside).
    float shapeDistance(float2 uv, constant ShaderParams &params) {
        float minSide = max(min(params.viewWidth, params.viewHeight), 1.0);
        float2 halfSize = float2(params.viewWidth, params.viewHeight) / minSide * 0.5;
        float2 p = (uv - 0.5) * float2(params.viewWidth, params.viewHeight) / minSide;
        switch (params.shape) {
            case 1: { // rounded box
                float r = 0.18;
                float2 q = abs(p) - (halfSize - float2(r));
                return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
            }
            case 2: { // circle / ellipse
                return (length(p / halfSize) - 1.0) * min(halfSize.x, halfSize.y);
            }
            case 3: { // hexagon, point sideways
                float2 n = p / halfSize * 0.5;
                const float3 k = float3(-0.866025404, 0.5, 0.577350269);
                float2 a = abs(n);
                a -= 2.0 * min(dot(k.xy, a), 0.0) * k.xy;
                a -= float2(clamp(a.x, -k.z * 0.46, k.z * 0.46), 0.46);
                return length(a) * sign(a.y) * min(halfSize.x, halfSize.y) * 2.0;
            }
            case 4: { // diamond
                float2 n = p / halfSize * 0.5;
                return (abs(n.x) + abs(n.y) - 0.5) * 0.70710678 * min(halfSize.x, halfSize.y) * 2.0;
            }
            default: { // box
                float2 q = abs(p) - halfSize;
                return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0);
            }
        }
    }

    fragment float4 videoFragmentShader(VertexOut in [[stage_in]],
                                       texture2d<float, access::sample> texture [[texture(0)]],
                                       sampler textureSampler [[sampler(0)]],
                                       constant ShaderParams &params [[buffer(0)]]) {
        float2 uv = in.texCoords;
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 0.0);
        }

        // Layer transform: optional horizontal mirror, then the crop rectangle.
        float2 sourceUV = float2(params.mirror != 0 ? 1.0 - uv.x : uv.x, uv.y);
        sourceUV = float2(params.uvX, params.uvY) + sourceUV * float2(params.uvWidth, params.uvHeight);
        float4 color = texture.sample(textureSampler, sourceUV);
        float alpha = color.a;
        float3 straight = alpha > 0.0 ? color.rgb / alpha : float3(0.0);

        // Basic adjustments
        float3 rgb = straight + float3(params.brightness);
        rgb = (rgb - 0.5) * params.contrast + 0.5;
        
        float luma = dot(rgb, float3(0.299, 0.587, 0.114));
        rgb = mix(float3(luma), rgb, params.saturation);
        rgb = clamp(rgb, 0.0, 1.0);
        
        float3 filtered = rgb;
        
        switch (params.filterType) {
            case 1: { // Monochrome / Noir
                float gray = dot(rgb, float3(0.299, 0.587, 0.114));
                filtered = float3(gray);
                break;
            }
            case 2: { // Warm Sepia
                float r = dot(rgb, float3(0.393, 0.769, 0.189));
                float g = dot(rgb, float3(0.349, 0.686, 0.168));
                float b = dot(rgb, float3(0.272, 0.534, 0.131));
                filtered = clamp(float3(r, g, b), 0.0, 1.0);
                break;
            }
            case 3: { // Cyberpunk Neon
                float3 cyan = float3(0.0, rgb.g * 1.2, rgb.b * 1.4);
                float3 magenta = float3(rgb.r * 1.4, 0.0, rgb.b * 1.2);
                filtered = mix(cyan, magenta, uv.x);
                filtered = clamp(filtered * 1.15, 0.0, 1.0);
                break;
            }
            case 4: { // Studio Vignette
                float dist = distance(uv, float2(0.5, 0.5));
                float vig = smoothstep(0.75, 0.35, dist);
                filtered = rgb * vig;
                break;
            }
            case 5: { // Comic / Posterize
                float levels = 4.0;
                filtered = floor(rgb * levels) / levels;
                float edge = abs(rgb.r - rgb.g) + abs(rgb.g - rgb.b);
                if (edge > 0.25) {
                    filtered *= 1.25;
                }
                break;
            }
            case 6: { // Invert
                filtered = float3(1.0) - rgb;
                break;
            }
            case 7: { // Chroma Key (Green Screen)
                float3 greenRef = float3(0.0, 1.0, 0.0);
                float d = distance(rgb, greenRef);
                if (d < 0.65) {
                    // Keyed pixels become transparent so lower layers show through.
                    alpha *= mix(1.0, smoothstep(0.4, 0.65, d), params.intensity);
                }
                break;
            }
            default:
                break;
        }
        
        float3 result = clamp(mix(rgb, filtered, params.intensity), 0.0, 1.0);
        float outAlpha = clamp(alpha * params.opacity, 0.0, 1.0);

        // Cut to the shape with an anti-aliased edge, and paint the border band inside it.
        if (params.shape != 0 || params.borderWidth > 0.0) {
            float edge = 1.0 / max(min(params.viewWidth, params.viewHeight), 1.0);
            float d = shapeDistance(uv, params);
            float inside = clamp(0.5 - d / edge, 0.0, 1.0);
            if (params.borderWidth > 0.0) {
                float band = clamp(0.5 + (d + params.borderWidth) / edge, 0.0, 1.0);
                result = mix(result, float3(params.borderRed, params.borderGreen, params.borderBlue), band);
                outAlpha = mix(outAlpha, 1.0, band);
            }
            outAlpha *= inside;
        }
        // Premultiplied output; the pipeline blends with (one, oneMinusSourceAlpha).
        return float4(result * outAlpha, outAlpha);
    }
    """
}
