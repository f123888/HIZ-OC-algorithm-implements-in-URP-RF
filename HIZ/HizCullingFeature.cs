using Unity.Collections;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class HizCullingFeature : ScriptableRendererFeature
{
    private Material _material;
    public class HizCullingPass : ScriptableRenderPass
    {
        private int _InputScaleAndMaxIndex = Shader.PropertyToID("_InputScaleAndMaxIndex");
        private int _InputDepth = Shader.PropertyToID("_InputDepth");
        public static int cullTextureSize = 64;
        public static Texture2D objectCenterTex;
        public static Texture2D objectSizeTex;
        private Material mat;
        private int[] depthMipID;
        RTHandle _GrabDepthTex;
        //private RenderTexture depthRT;
        //RTHandle _GrabDepthTex; 
        public HizCullingPass(Material hizMaterial)
        {
            mat = hizMaterial;
        }

        public static HizInfo[] hizInfos = new HizInfo[3] { new HizInfo(), new HizInfo(), new HizInfo() };
        
        // This method is called before executing the render pass.
        // It can be used to configure render targets and their clear state. Also to create temporary render target textures.
        // When empty this render pass will render to the active camera render target.
        // You should never call CommandBuffer.SetRenderTarget. Instead call <c>ConfigureTarget</c> and <c>ConfigureClear</c>.
        // The render pipeline will ensure target setup and clearing happens in a performant manner.
        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            for (int i = 0; i < HizCullingPass.hizInfos.Length; i++)
            {
                HizCullingPass.hizInfos[i].ComputePackedMipChainInfo(new Vector2Int(Camera.main.pixelWidth, Camera.main.pixelHeight));
            }
        }

        // Here you can implement the rendering logic.
        // Use <c>ScriptableRenderContext</c> to issue drawing commands or execute command buffers
        // https://docs.unity3d.com/ScriptReference/Rendering.ScriptableRenderContext.html
        // You don't have to call ScriptableRenderContext.submit, the render pipeline will call it at specific points in the pipeline.
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            GPUCulling(context, ref renderingData);
        }

        // Cleanup any allocated resources that were created during the execution of this render pass.
        public override void OnCameraCleanup(CommandBuffer cmd)
        {
        }

        public static HizInfo GetHizInfo()
        {
            return hizInfos[Time.frameCount % 3];
        }
        
        private void GPUCulling(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            var hizIndex = Time.frameCount % 3;
            if (depthMipID == null)
            {
                depthMipID = new int[32];
                for (int i = 0; i < depthMipID.Length; i++)
                {
                    depthMipID[i] = Shader.PropertyToID("_DepthMip" + i);
                }
            }

            var mipInfo = hizInfos[hizIndex];
            var hizTexture = mipInfo.hizResult;
            CommandBuffer cmd = CommandBufferPool.Get("DepthPyramid");
            //cmd.SetGlobalTexture(_InputDepth, new RenderTargetIdentifier("_CameraDepthAttachment"));
            cmd.SetViewProjectionMatrices(Matrix4x4.identity, Matrix4x4.identity);
            cmd.BeginSample("DownSampleDepth");

            // 生成每级MIPMAP
            for (int i = 0; i < mipInfo.mipLevelCount; i++)
            {
                var mipsize = mipInfo.mipLevelSizes[i];
                Vector2Int inputMipSize;
                if (i == 0)
                {
                    inputMipSize = mipInfo.mip0Size;
                    //Shader.EnableKeyword("CameraDepth_1");
                }
                else
                {
                    inputMipSize = mipInfo.mipLevelSizes[i - 1];
                    //Shader.DisableKeyword("CameraDepth_1");
                }
                int id = depthMipID[i];
                var texID = new RenderTargetIdentifier(id);
                cmd.SetGlobalVector(_InputScaleAndMaxIndex,new Vector4(inputMipSize.x/(float)mipsize.x,inputMipSize.y/(float)mipsize.y,inputMipSize.x-1,inputMipSize.y-1));
                cmd.GetTemporaryRT(id, mipsize.x,mipsize.y,0,FilterMode.Point,RenderTextureFormat.RFloat, RenderTextureReadWrite.Linear);
                cmd.SetRenderTarget(texID,RenderBufferLoadAction.DontCare,RenderBufferStoreAction.Store);
                if(i==0)
                    cmd.DrawMesh(RenderingUtils.fullscreenMesh, Matrix4x4.identity, mat, 0, 3);
                else
                {
                    cmd.DrawMesh(RenderingUtils.fullscreenMesh, Matrix4x4.identity, mat, 0, 0);
                }
                cmd.SetGlobalTexture(_InputDepth, texID);
            }
            
            
            cmd.EndSample("DownSampleDepth");
            var hizSize = mipInfo.textureSize;

            var hizID = Shader.PropertyToID("_HizID" + hizIndex);
            
            //拷贝每级mipmap到一张贴图
            cmd.BeginSample("CopyDepth");
            cmd.GetTemporaryRT(hizID, hizSize.x, hizSize.y, 0, FilterMode.Point, RenderTextureFormat.RFloat);
            cmd.SetRenderTarget(hizID, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
            for (int i = 1; i < mipInfo.mipLevelCount; i++)
            {
                int id = depthMipID[i];
                
                cmd.SetGlobalTexture(_InputDepth, new RenderTargetIdentifier(id));
                
                var mipSize = mipInfo.mipLevelSizes[i];
                var offset = mipInfo.mipLevelOffsets[i];
                cmd.SetViewport(new Rect(offset.x, offset.y, mipSize.x, mipSize.y));
                cmd.DrawMesh(RenderingUtils.fullscreenMesh, Matrix4x4.identity, mat, 0, 1);
            }
            
            cmd.SetGlobalTexture("_DepthPyramidTex",hizID);
            cmd.EndSample("CopyDepth");
            
            cmd.BeginSample("HizCulling");
            
            //   GPU剔除
            var world2Project = renderingData.cameraData.GetGPUProjectionMatrix() *
                                renderingData.cameraData.GetViewMatrix();
            cmd.SetGlobalTexture("_ObjectAABBTexture0", objectCenterTex);
            cmd.SetGlobalTexture("_ObjectAABBTexture1", objectSizeTex);
            cmd.SetGlobalMatrix("_GPUCullingVP", world2Project);
            var screen = mipInfo.mip0Size;
            cmd.SetGlobalVector("_Mip0Size", new Vector4(screen.x,screen.y));
            cmd.SetGlobalVector("_MipmapLevelMinMaxIndex",new Vector4(1,mipInfo.mipLevelCount-1));
            cmd.SetGlobalVectorArray("_MipOffsetAndSize", mipInfo.mipOffsetAndSize);
            cmd.SetRenderTarget(hizTexture, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
            cmd.DrawMesh(RenderingUtils.fullscreenMesh, Matrix4x4.identity, mat , 0, 2);
            cmd.EndSample("HizCulling");
            cmd.ReleaseTemporaryRT(hizID);
            cmd.RequestAsyncReadback(hizTexture , mipInfo.OnGPUCullingReadBack);

            mipInfo.dataReady = false;
            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }
    }
    HizCullingPass m_ScriptablePass;

    /// <inheritdoc/>
    public override void Create()
    {
        
        if (_material == null)
            _material = new Material(Shader.Find("Custom/HizShader"));
        m_ScriptablePass = new HizCullingPass(_material);

        // Configures where the render pass should be injected.
        m_ScriptablePass.renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;

        foreach (var info in HizCullingPass.hizInfos)
        {
            info.CreatResource();
        }
    }

    // Here you can inject one or multiple render passes in the renderer.
    // This method is called when setting up the renderer once per-camera.
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        renderer.EnqueuePass(m_ScriptablePass);
    }
}

public class HizInfo
{
    public Vector2Int cachedHardwareTextureSize;
    public Vector2Int mip0Size;
    public int mipLevelCount;
    public Vector2Int textureSize;
    public Vector2Int[] mipLevelOffsets = new Vector2Int[16];
    public Vector2Int[] mipLevelSizes = new Vector2Int[16];
    public Vector4[] mipOffsetAndSize = new Vector4[16];
    public bool dataReady = false;
    public bool readBackSuccess = false;
    public NativeArray<float> cullResultBackArray ;
    public RenderTexture hizResult;

    public void CreatResource()
    {
        cullResultBackArray = new NativeArray<float>(64*64, Allocator.Persistent);
        //hizResult = new Texture2D(64, 64, TextureFormat.RFloat, 0, true);
        hizResult = new RenderTexture(64, 64, 0, RenderTextureFormat.RFloat);
        hizResult.enableRandomWrite = true;
        hizResult.Create();
    }
    
    // 计算每级mipmap的信息
    public void ComputePackedMipChainInfo(Vector2Int viewportSize)
    {
        if (cachedHardwareTextureSize == viewportSize)
            return;
        cachedHardwareTextureSize = viewportSize;

        int resizeX = Mathf.IsPowerOfTwo(viewportSize.x) ? viewportSize.x : Mathf.NextPowerOfTwo(viewportSize.x); 
        int resizeY = Mathf.IsPowerOfTwo(viewportSize.y) ? viewportSize.y : Mathf.NextPowerOfTwo(viewportSize.y);
        
        if (resizeX > viewportSize.x)
            resizeX /= 2;
        if (resizeY > viewportSize.y)
            resizeY /= 2;
        mip0Size = viewportSize;
        Vector2Int hardwareTextureSize =  new Vector2Int(resizeX, resizeY);
        mipLevelOffsets[0] = Vector2Int.zero;
        mipLevelSizes[0] = Vector2Int.zero;
        int mipLevel = 0;
        Vector2Int mipSize = hardwareTextureSize;
        Vector2Int texSize = Vector2Int.zero;

        do
        {
            mipLevel++;

            // Round up.
            mipSize.x = System.Math.Max(1, (mipSize.x + 1) >> 1);
            mipSize.y = System.Math.Max(1, (mipSize.y + 1) >> 1);

            mipLevelSizes[mipLevel] = mipSize;

            Vector2Int prevMipBegin = mipLevelOffsets[mipLevel - 1];
            Vector2Int prevMipEnd = prevMipBegin +  mipLevelSizes[mipLevel - 1];
         
            Vector2Int mipBegin = new Vector2Int();

            if ((mipLevel & 1) != 0) // Odd
            {
                mipBegin.x = prevMipBegin.x;
                mipBegin.y = prevMipEnd.y;
            }
            else // Even
            {
                mipBegin.x = prevMipEnd.x;
                mipBegin.y = prevMipBegin.y;
            }

            mipLevelOffsets[mipLevel] = mipBegin;

            texSize.x = System.Math.Max(texSize.x, mipBegin.x + mipSize.x);
            texSize.y = System.Math.Max(texSize.y, mipBegin.y + mipSize.y);

        }
        while ((mipSize.x > 1) || (mipSize.y > 1));
        
        mipLevelSizes[0] = hardwareTextureSize;
        //RT实际大小
        textureSize = new Vector2Int(
            (int)Mathf.Ceil((float)texSize.x), (int)Mathf.Ceil((float)texSize.y));
        mipLevelCount = mipLevel + 1;
        for (int i = 0; i < mipLevelSizes.Length; i++)
        {
            mipOffsetAndSize[i] = new Vector4(mipLevelOffsets[i].x, mipLevelOffsets[i].y, mipLevelSizes[i].x,
                mipLevelSizes[i].y);
        }
    }

    public void OnGPUCullingReadBack(AsyncGPUReadbackRequest request)
    {
        
        if (request.done && !request.hasError)
        {
            cullResultBackArray.CopyFrom(request.GetData<float>());
            
            readBackSuccess = true;
        }
        else
        {
            Debug.LogError("ReaaBackFailed");
            readBackSuccess = false;
        }
        
        dataReady = true;
    }
    
}



