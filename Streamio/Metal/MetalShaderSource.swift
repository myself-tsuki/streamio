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
    };

    fragment float4 videoFragmentShader(VertexOut in [[stage_in]],
                                       texture2d<float, access::sample> texture [[texture(0)]],
                                       sampler textureSampler [[sampler(0)]],
                                       constant ShaderParams &params [[buffer(0)]]) {
        float2 uv = in.texCoords;
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        
        float4 color = texture.sample(textureSampler, uv);
        
        // Basic adjustments
        float3 rgb = color.rgb + float3(params.brightness);
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
                    filtered = mix(float3(0.05, 0.08, 0.12), rgb, smoothstep(0.4, 0.65, d));
                }
                break;
            }
            default:
                break;
        }
        
        float3 result = mix(rgb, filtered, params.intensity);
        return float4(clamp(result, 0.0, 1.0), 1.0);
    }
    """
}
