Shader "Unlit/Genshin_body_Complete"
{
    Properties
    {
        [Header(Textures)]
        _BaseMap("Base Map", 2D) = "white"{}
        // R=材质ID, G=阴影阈值/AO
        _LightMap("Light Map (G=AO, A=ID)", 2D) = "white"{} 
        _RampTex("Ramp Tex", 2D) = "white"{} 

        [Header(Settings)]
        [Toggle(_USE_LIGHTMAP_AO)] _UseLightMapAO("Use LightMap AO", Float) = 1
        [Toggle(_USE_RAMP_SHADOW)] _UseRampShadow("Use Ramp Shadow", Float) = 1
        
        _ShadowRampWidth("Shadow Ramp width", Range(0, 1)) = 0.5 
        _ShadowPosition("Shadow Position", Range(0, 1)) = 0.5
        _ShadowSoftness("Shadow Softness", Range(0.01, 1)) = 0.5
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalRenderPipeline"
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
        }

        HLSLINCLUDE
            // ---------------------------------------------------------
            // 核心引用库
            // ---------------------------------------------------------
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            // 引用 Shadows.hlsl 以获取 ApplyShadowBias 等底层函数
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            // ---------------------------------------------------------
            // 变量定义 (纹理放 CBUFFER 外，数值放 CBUFFER 内)
            // ---------------------------------------------------------
            TEXTURE2D(_BaseMap);    SAMPLER(sampler_BaseMap);
            TEXTURE2D(_LightMap);   
            TEXTURE2D(_RampTex);    SAMPLER(sampler_RampTex);

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                half _ShadowRampWidth;
                half _ShadowPosition;
                half _ShadowSoftness;
            CBUFFER_END

            // ID计算辅助函数
            half RampShadowID(half inputID)
            {
                half rowCount = 5.0;
                half row = floor(saturate(inputID) * rowCount) / rowCount; 
                return row + (1.0 / (rowCount * 2.0)); 
            }
        ENDHLSL

        // =====================================================================
        // Pass 1: 主渲染通道 (Forward)
        // =====================================================================
        Pass
        {
            Name "UniversalForward"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex MainVS
            #pragma fragment MainFS

            #pragma shader_feature_local _USE_LIGHTMAP_AO
            #pragma shader_feature_local _USE_RAMP_SHADOW
            
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile _ _SHADOWS_SOFT

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv0 : TEXCOORD0;
                float3 normalOS : NORMAL;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv0 : TEXCOORD0;
                float3 normalWS : TEXCOORD1;
            };

            Varyings MainVS(Attributes input)
            {
                Varyings output;
                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
                VertexNormalInputs vertexNormalInputs = GetVertexNormalInputs(input.normalOS);

                output.positionCS = vertexInput.positionCS;
                output.normalWS = vertexNormalInputs.normalWS;
                output.uv0 = TRANSFORM_TEX(input.uv0, _BaseMap);
                return output;
            }

            half4 MainFS(Varyings input) : SV_TARGET
            {
                half3 N = normalize(input.normalWS);
                Light light = GetMainLight(); 
                half3 L = normalize(light.direction);
                half NdotL = dot(N, L);

                half4 baseMap = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv0);
                half4 lightMap = SAMPLE_TEXTURE2D(_LightMap, sampler_BaseMap, input.uv0);

                half halfLambert = NdotL * 0.5 + 0.5;
                half ao = lightMap.g; 

                #if _USE_LIGHTMAP_AO
                    half lightingVal = halfLambert * ao; 
                #else
                    half lightingVal = halfLambert;
                #endif

                half shadowSmooth = _ShadowSoftness * 0.5;
                half rampU = smoothstep(_ShadowPosition - shadowSmooth, _ShadowPosition + shadowSmooth, lightingVal);
                half rampV = RampShadowID(lightMap.a); 
                
                half3 rampColor = SAMPLE_TEXTURE2D(_RampTex, sampler_RampTex, float2(rampU, rampV)).rgb;
                rampColor *= light.shadowAttenuation;

                half3 finalColor; 
                
                #if _USE_RAMP_SHADOW
                    finalColor = baseMap.rgb * rampColor * light.color; 
                #else
                    finalColor = baseMap.rgb * lightingVal; 
                #endif

                return half4(finalColor, 1);
            }
            ENDHLSL
        }

        // =====================================================================
        // Pass 2: 阴影投射通道 (ShadowCaster - 手动修复版)
        // =====================================================================
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }

            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull Off 

            HLSLPROGRAM
            #pragma vertex ShadowVS
            #pragma fragment ShadowFS
            
            #pragma multi_compile_instancing
            // 这一句必须加，否则点光源阴影计算会报错
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW

            // 手动声明 URP 全局变量，防止 include 顺序问题导致的未定义
            float3 _LightDirection;
            float3 _LightPosition;

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            Varyings ShadowVS(Attributes input)
            {
                Varyings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);

                float3 positionWS = TransformObjectToWorld(input.positionOS.xyz);
                float3 normalWS = TransformObjectToWorldNormal(input.normalOS);

                // 手动计算光照方向，不依赖 GetShadowPositionHClip
                #if _CASTING_PUNCTUAL_LIGHT_SHADOW
                    float3 lightDirectionWS = normalize(_LightPosition - positionWS);
                #else
                    float3 lightDirectionWS = _LightDirection;
                #endif

                // ApplyShadowBias 通常在 Shadows.hlsl 中
                float4 positionCS = TransformWorldToHClip(ApplyShadowBias(positionWS, normalWS, lightDirectionWS));

                // 处理反转 Z 缓冲
                #if UNITY_REVERSED_Z
                    positionCS.z = min(positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #else
                    positionCS.z = max(positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #endif

                output.positionCS = positionCS;
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                return output;
            }

            half4 ShadowFS(Varyings input) : SV_TARGET
            {
                UNITY_SETUP_INSTANCE_ID(input);
                return 0;
            }
            ENDHLSL
        }
    }
}