Shader "Custom/HizShader"
{
    Properties
    {
        
    }
    SubShader
    {
        ZTest Off
        Pass
        {
            Name "Generate Depth Mipmap"
            HLSLPROGRAM
			#pragma target 3.5
            #include "Common.hlsl"

            //#pragma multi_compile __ CameraDepth_1

            #pragma vertex Vertex
            #pragma fragment DownsampleDepthFrag
            
            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 texcoord     : TEXCOORD0;
            };

            struct Varyings
            {
                float2 uv                      : TEXCOORD0;
                float4 positionCS               : SV_POSITION;
            };

            Varyings Vertex(Attributes input)
            {
                Varyings output = (Varyings)0;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.texcoord;
                return output;
            }
            
            #if UNITY_REVERSED_Z
            # define MIN_DEPTH(l, r) min(l, r)
            #else
            # define MIN_DEPTH(l, r) max(l, r)
            #endif
   //          #if defined(Camera_Depth)
			// TEXTURE2D_FLOAT(_CameraDepthTexture);
			// SAMPLER(sampler_CameraDepthTexture);
			// #else
            TEXTURE2D_FLOAT(_InputDepth);
            SAMPLER(sampler_InputDepth);
			//#endif
			
            float4 _InputScaleAndMaxIndex;//xy: inputeTexsize/outputTextureSize , zw:textureSize - 1 
            half4 DownsampleDepthFrag(Varyings input) : SV_Target
            {
                int2 texCrood = int2(input.positionCS.xy) * _InputScaleAndMaxIndex.xy;
                uint2 maxIndex = _InputScaleAndMaxIndex.zw;
                int2 texCrood00 = min(texCrood + uint2(0, 0), maxIndex);
                int2 texCrood10 = min(texCrood + uint2(1, 0), maxIndex);
                int2 texCrood01 = min(texCrood + uint2(0, 1), maxIndex);
                int2 texCrood11 = min(texCrood + uint2(1, 1), maxIndex);
                // #if defined(Camera_Depth)
                // float p00 = LOAD_TEXTURE2D_LOD(_CameraDepthTexture,texCrood00,0);
                // float p01 = LOAD_TEXTURE2D_LOD(_CameraDepthTexture,texCrood10,0);
                // float p10 = LOAD_TEXTURE2D_LOD(_CameraDepthTexture,texCrood01,0);
                // float p11 = LOAD_TEXTURE2D_LOD(_CameraDepthTexture,texCrood11,0);
                // #else
                float p00 = LOAD_TEXTURE2D_LOD(_InputDepth,texCrood00,0);
                float p01 = LOAD_TEXTURE2D_LOD(_InputDepth,texCrood10,0);
                float p10 = LOAD_TEXTURE2D_LOD(_InputDepth,texCrood01,0);
                float p11 = LOAD_TEXTURE2D_LOD(_InputDepth,texCrood11,0);
                // #endif
                
                return MIN_DEPTH(MIN_DEPTH(p00 ,p01), MIN_DEPTH(p10, p11));
                //return 1-(p00+p01+p11+p10)/4;
            }
            ENDHLSL
        }

        Pass
        {
            Name "CopyDepth"
            HLSLPROGRAM
            #pragma target 3.5
            #include "Common.hlsl"

            #pragma vertex Vertex
            #pragma fragment CopyDepthFrag
            
            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 texcoord     : TEXCOORD0;
            };

            struct Varyings
            {
                float2 uv                      : TEXCOORD0;
                float4 positionCS               : SV_POSITION;
            };

            Varyings Vertex(Attributes input)
            {
                Varyings output = (Varyings)0;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.texcoord;
                return output;
            }

            TEXTURE2D_FLOAT(_InputDepth);
            SAMPLER(sampler_InputDepth);
           
            half4 CopyDepthFrag(Varyings input) : SV_Target
            {
                return  SAMPLE_TEXTURE2D(_InputDepth, sampler_InputDepth, input.uv);
            }
            ENDHLSL
        }

        Pass
        {
            Name "HIZCull"
            HLSLPROGRAM
            #pragma target 3.5
            #include "Common.hlsl"
            
            #pragma vertex Vertex
            #pragma fragment CullingFrag

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 texcoord     : TEXCOORD0;
            };
            struct Varyings
            {
                float2 uv                      : TEXCOORD0;
                float4 positionCS               : SV_POSITION;
            };

            TEXTURE2D(_ObjectAABBTexture0);
            SAMPLER(sampler_ObjectAABBTexture0);
            TEXTURE2D(_ObjectAABBTexture1);
            SAMPLER(sampler_ObjectAABBTexture1);

            TEXTURE2D(_DepthPyramidTex);
            SAMPLER(sampler_DepthPyramidTex);
            float4x4 _GPUCullingVP;
            float2 _MipmapLevelMinMaxIndex;
            float2 _Mip0Size;
            float4 _MipOffsetAndSize[16];
            float3 TransferNDC(float3 pos) 
            {
                float4 ndc = mul(_GPUCullingVP, float4(pos, 1.0));
                ndc.xyz /= ndc.w;
                ndc.xy = ndc.xy * 0.5f + 0.5f;
                ndc.y = 1 - ndc.y;
                return ndc.xyz;
            }

            Varyings Vertex(Attributes input)
            {
                Varyings output = (Varyings)0;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.texcoord;
                return output;
            }
            
            half4 CullingFrag(Varyings input) : SV_Target
            {
                float2 uv = input.uv;
                float4 aabbCenter = SAMPLE_TEXTURE2D_LOD(_ObjectAABBTexture0, sampler_ObjectAABBTexture0, uv,0.0);
                float4 aabbSize = SAMPLE_TEXTURE2D_LOD(_ObjectAABBTexture1, sampler_ObjectAABBTexture1, uv, 0.0);
                float3 aabbExtent = aabbSize.xyz * 0.5;//贴图可以直接存extent
                UNITY_BRANCH
                if (aabbCenter.a == 0.0) 
                {
                    return 1;
                }
                float3 aabbMin = aabbCenter.xyz - aabbExtent;
                float3 aabbMax = aabbCenter.xyz + aabbExtent;

                float3 pos0 = float3(aabbMin.x, aabbMin.y, aabbMin.z);
                float3 pos1 = float3(aabbMin.x, aabbMin.y, aabbMax.z);
                float3 pos2 = float3(aabbMin.x, aabbMax.y, aabbMin.z);
                float3 pos3 = float3(aabbMax.x, aabbMin.y, aabbMin.z);
                float3 pos4 = float3(aabbMax.x, aabbMax.y, aabbMin.z);
                float3 pos5 = float3(aabbMax.x, aabbMin.y, aabbMax.z);
                float3 pos6 = float3(aabbMin.x, aabbMax.y, aabbMax.z);
                float3 pos7 = float3(aabbMax.x, aabbMax.y, aabbMax.z);
              

                float3 ndc = TransferNDC(pos0);
                float3 ndcMax = ndc;
                float3 ndcMin = ndc;
                ndc = TransferNDC(pos1);
                ndcMax = max(ndc, ndcMax);
                ndcMin = min(ndc, ndcMin);
                ndc = TransferNDC(pos2);
                ndcMax = max(ndc, ndcMax);
                ndcMin = min(ndc, ndcMin);
                ndc = TransferNDC(pos3);
                ndcMax = max(ndc, ndcMax);
                ndcMin = min(ndc, ndcMin);
                ndc = TransferNDC(pos4);
                ndcMax = max(ndc, ndcMax);
                ndcMin = min(ndc, ndcMin);
                ndc = TransferNDC(pos5);
                ndcMax = max(ndc, ndcMax);
                ndcMin = min(ndc, ndcMin);
                ndc = TransferNDC(pos6);
                ndcMax = max(ndc, ndcMax);
                ndcMin = min(ndc, ndcMin);
                ndc = TransferNDC(pos7);
                ndcMax = max(ndc, ndcMax);
                ndcMin = min(ndc, ndcMin);
                
                if( ndcMax.x < 0 || ndcMax.y < 0 || ndcMin.x > 1 || ndcMin.y > 1 || ndcMax.z >1 || ndcMin.z<0)
                {
                    return half4(1, 0, 0, 1);
                }

                float2 ndcSize = floor((ndcMax.xy - ndcMin.xy) * _Mip0Size);
                float raidus = max(ndcSize.x, ndcSize.y);
                int mip = ceil(log2(raidus));
                mip = clamp(mip, _MipmapLevelMinMaxIndex.x, _MipmapLevelMinMaxIndex.y);
                float4 offsetAndSize = _MipOffsetAndSize[mip];
                int4 pxMinMax = float4(ndcMin.xy,ndcMax.xy) * offsetAndSize.zwzw + offsetAndSize.xyxy;
                
                float d0 = LOAD_TEXTURE2D_LOD(_DepthPyramidTex, pxMinMax.xy,0); // lb
                float d1 = LOAD_TEXTURE2D_LOD(_DepthPyramidTex, pxMinMax.zy,0); // rb
                float d2 = LOAD_TEXTURE2D_LOD(_DepthPyramidTex, pxMinMax.xw,0); // lt
                float d3 = LOAD_TEXTURE2D_LOD(_DepthPyramidTex, pxMinMax.zw,0); // rt
                
    #if UNITY_REVERSED_Z
                float minDepth = min(min(min(d0, d1), d2), d3);
                return  ndcMax.z < minDepth ? half4(1, 0, 0, 1) : half4(0, 0, 0, 1);
    #else
                float maxDepth = max(max(max(d0, d1), d2), d3);
                return maxDepth > ndcMax.z   ? half4(1, 0, 0, 1) : half4(0, 0, 0, 1);
    #endif

            }
            ENDHLSL
        }

        Pass
        {
            Name "CameraDepthDownSample"
            HLSLPROGRAM
			#pragma target 3.5
            #include "Common.hlsl"

            #pragma vertex Vertex
            #pragma fragment DownsampleDepthFrag
            
            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 texcoord     : TEXCOORD0;
            };

            struct Varyings
            {
                float2 uv                      : TEXCOORD0;
                float4 positionCS               : SV_POSITION;
            };

            Varyings Vertex(Attributes input)
            {
                Varyings output = (Varyings)0;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.texcoord;
                return output;
            }
            
            #if UNITY_REVERSED_Z
            # define MIN_DEPTH(l, r) min(l, r)
            #else
            # define MIN_DEPTH(l, r) max(l, r)
            #endif

			TEXTURE2D_FLOAT(_CameraDepthTexture);
			SAMPLER(sampler_CameraDepthTexture);

			
            float4 _InputScaleAndMaxIndex;//xy: inputeTexsize/outputTextureSize , zw:textureSize - 1 
            half4 DownsampleDepthFrag(Varyings input) : SV_Target
            {
                int2 texCrood = int2(input.positionCS.xy) * _InputScaleAndMaxIndex.xy;
                uint2 maxIndex = _InputScaleAndMaxIndex.zw;
                texCrood = min(texCrood,  maxIndex);
                 int2 texCrood00 = min(texCrood + uint2(0, 0), maxIndex);
                 int2 texCrood10 = min(texCrood + uint2(1, 0), maxIndex);
                 int2 texCrood01 = min(texCrood + uint2(0, 1), maxIndex);
                 int2 texCrood11 = min(texCrood + uint2(1, 1), maxIndex);
                 float p00 = LOAD_TEXTURE2D_LOD(_CameraDepthTexture,texCrood00,0);
                 float p01 = LOAD_TEXTURE2D_LOD(_CameraDepthTexture,texCrood10,0);
                 float p10 = LOAD_TEXTURE2D_LOD(_CameraDepthTexture,texCrood01,0);
                 float p11 = LOAD_TEXTURE2D_LOD(_CameraDepthTexture,texCrood11,0);
                
                return MIN_DEPTH(MIN_DEPTH(p00 ,p01), MIN_DEPTH(p10, p11));
                //return LOAD_TEXTURE2D_LOD(_CameraDepthTexture,texCrood,0);
            }
            ENDHLSL
        }

    }
    FallBack "Diffuse"
}
