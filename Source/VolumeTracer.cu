
#include "VolumeTracer.cuh"
#include "Utilities.cuh"

#include "Filter.h"
#include "Scene.h"
#include "Material.h"

// ToDo: Add description
DEV bool NearestLight(CScene* pScene, CRay& R, CColorXyz& LightColor)
{
	// Whether a hit with a light was found or not 
	bool Hit = false;
	
	float T = 0.0f;

	CRay RayCopy = R;

	for (int i = 0; i < pScene->m_Lighting.m_NoLights; i++)
	{
		if (pScene->m_Lighting.m_Lights[i].Intersect(RayCopy, T, LightColor))
			Hit = true;
	}
	
	return Hit;
}

// Computes the power heuristic
DEV inline float PowerHeuristic(int nf, float fPdf, int ng, float gPdf)
{
	float f = nf * fPdf, g = ng * gPdf;
	return (f * f) / (f * f + g * g); 
}

// Find the nearest non-empty voxel in the volume
DEV inline bool NearestIntersection(CScene* pScene, CRay& R, const float& StepSize, const float& U, float* pBoxMinT = NULL, float* pBoxMaxT = NULL)
{
	float MinT;
	float MaxT;

	// Intersect the eye ray with bounding box, if it does not intersect then return the environment
	if (!pScene->m_BoundingBox.Intersect(R, &MinT, &MaxT))
		return false;

	bool Hit = false;

	if (pBoxMinT)
		*pBoxMinT = MinT;

	if (pBoxMaxT)
		*pBoxMaxT = MaxT;

	MinT += U * StepSize;

	// Step through the volume and stop as soon as we come across a non-empty voxel
	while (MinT < MaxT)
	{
		if (GetOpacity(pScene, Density(pScene, R(MinT))).r > 0.0f)
		{
			Hit = true;
			break;
		}
		else
		{
			MinT += StepSize;
		}
	}

	if (Hit)
	{
		R.m_MinT = MinT;
		R.m_MaxT = MaxT;
	}

	return Hit;
}



// Computes the attenuation through the volume
DEV inline CColorXyz Transmittance(CScene* pScene, const Vec3f& P, const Vec3f& D, const float& MaxT, const float& StepSize, CCudaRNG& Rnd)
{
	// Near and far intersections with volume axis aligned bounding box
	float NearT = 0.0f, FarT = 0.0f;

	// Intersect with volume axis aligned bounding box
	if (!pScene->m_BoundingBox.Intersect(CRay(P, D, 0.0f, FLT_MAX), &NearT, &FarT))
		return SPEC_BLACK;

	// Clamp to near plane if necessary
	if (NearT < 0.0f) 
		NearT = 0.0f;     

	CColorXyz Lt = SPEC_WHITE;

	NearT += Rnd.Get1() * StepSize;

	// Accumulate
	while (NearT < MaxT)
	{
		// Determine sample point
		const Vec3f SP = P + D * (NearT);

		// Fetch density
		const float D = Density(pScene, SP);
		
		// We ignore air density
		if (D == 0)
		{
			// Increase extent
			NearT += StepSize;
			continue;
		}

		// Get shadow opacity
		const float	Opacity = GetOpacity(pScene, D).r;

		if (Opacity > 0.0f)
		{
			// Compute eye transmittance
			Lt *= expf(-(Opacity * StepSize));

			// Exit if eye transmittance is very small
			if (Lt.y() < 0.05f)
				break;
		}

		// Increase extent
		NearT += StepSize;
	}

	return Lt;
}

// Estimates direct lighting
DEV CColorXyz EstimateDirectLight(CScene* pScene, CLight& Light, CLightingSample& LS, const Vec3f& Wo, const Vec3f& Pe, const Vec3f& N, CCudaRNG& Rnd, const float& StepSize)
{
// 	if (Dot(Wo, N) < 0.0f)
// 		return SPEC_BLACK;

	// Accumulated radiance
	CColorXyz Ld = SPEC_BLACK;
	
	// Radiance from light source
	CColorXyz Li = SPEC_BLACK;

	// Attenuation
	CColorXyz Tr = SPEC_BLACK;

	const float D = Density(pScene, Pe);

	CBSDF Bsdf(N, Wo, GetDiffuse(pScene, D).ToXYZ(), GetSpecular(pScene, D).ToXYZ(), 50.0f, 0.0001 * GetRoughness(pScene, D).r);
	// Light/shadow ray
	CRay R; 

	// Light probability
	float LightPdf = 1.0f, BsdfPdf = 1.0f;
	
	// Incident light direction
	Vec3f Wi;

	CColorXyz F = SPEC_BLACK;
	
	CSurfacePoint SPe, SPl;

	SPe.m_P		= Pe;
	SPe.m_Ng	= N; 

	// Sample the light source
 	Li = Light.SampleL(Pe, R, LightPdf, LS);
	
	Wi = -R.m_D; 

	F = Bsdf.F(Wo, Wi); 

	BsdfPdf	= Bsdf.Pdf(Wo, Wi);
	
	// Sample the light with MIS
	if (!Li.IsBlack() && LightPdf > 0.0f && BsdfPdf > 0.0f)
	{
		// Compute tau
		const CColorXyz Tr = Transmittance(pScene, R.m_O, R.m_D, Length(R.m_O - Pe), StepSize, Rnd);
		
		// Attenuation due to volume
		Li *= Tr;

		// Compute MIS weight
		const float Weight = 1.0f;//PowerHeuristic(1.0f, LightPdf, 1.0f, BsdfPdf);
 
		// Add contribution
		Ld += F * Li * (AbsDot(Wi, N) * Weight / LightPdf);
	}

	return Ld;

	/*
	// Sample the BRDF with MIS
	F = Bsdf.SampleF(Wo, Wi, BsdfPdf, LS.m_BsdfSample);
	
	CLight* pNearestLight = NULL;

	Vec2f UV;
	
	if (!F.IsBlack())
	{
		float MaxT = 1000000000.0f; 

		// Compute virtual light point
		const Vec3f Pl = Pe + (MaxT * Wi);

		if (NearestLight(pScene, Pe, Wi, 0.0f, MaxT, pNearestLight, NULL, &UV, &LightPdf))
		{
			if (LightPdf > 0.0f && BsdfPdf > 0.0f) 
			{
				// Add light contribution from BSDF sampling
				const float Weight = PowerHeuristic(1.0f, BsdfPdf, 1.0f, LightPdf);
				 
				// Get exitant radiance from light source
// 				Li = pNearestLight->Le(UV, pScene->m_Materials, pScene->m_Textures, pScene->m_Bitmaps);

				if (!Li.IsBlack())
				{
					// Scale incident radiance by attenuation through volume
					Tr = Transmittance(pScene, Pe, Wi, 1.0f, StepSize, Rnd);

					// Attenuation due to volume
					Li *= Tr;

					// Contribute
					Ld += F * Li * AbsDot(Wi, N) * Weight / BsdfPdf;
				}
			}
		}
	}
	*/

	return Ld;
}

// Uniformly samples one light
DEV CColorXyz UniformSampleOneLight(CScene* pScene, const Vec3f& Wo, const Vec3f& Pe, const Vec3f& N, CCudaRNG& Rnd, const float& StepSize)
{
	// Determine no. lights
	const int NumLights = pScene->m_Lighting.m_NoLights;

	// Exit return zero radiance if no light
 	if (NumLights == 0)
 		return SPEC_BLACK;

	CLightingSample LS;

	// Create light sampler
	LS.LargeStep(Rnd);

	// Choose which light to sample
	const int WhichLight = (int)floorf(LS.m_LightNum * (float)NumLights);

	// Get the light
	CLight& Light = pScene->m_Lighting.m_Lights[WhichLight];

	// Return estimated direct light
	return (float)NumLights * EstimateDirectLight(pScene, Light, LS, Wo, Pe, N, Rnd, StepSize);
}

// Trace volume with single scattering
KERNEL void KrnlSS(CScene* pScene, curandStateXORWOW_t* pDevRandomStates, CColorXyz* pDevEstFrameXyz)
{
	const int X = (blockIdx.x * blockDim.x) + threadIdx.x;		// Get global y
	const int Y	= (blockIdx.y * blockDim.y) + threadIdx.y;		// Get global x
	
	// Compute sample ID
	const int SID = (Y * (gridDim.x * blockDim.x)) + X;

	float StepSize = 0.03;

	// Exit if beyond kernel boundaries
	if (X >= pScene->m_Camera.m_Film.m_Resolution.GetResX() || Y >= pScene->m_Camera.m_Film.m_Resolution.GetResY())
		return;
	
	// Init random number generator
	CCudaRNG RNG(&pDevRandomStates[SID]);

	// Transmittance
	CColorXyz 	EyeTr	= SPEC_WHITE;		// Eye transmittance
	CColorXyz	L		= SPEC_BLACK;		// Measured volume radiance

	// Continue
	bool Continue = true;

	CRay EyeRay, RayCopy;

	float BoxMinT = 0.0f, BoxMaxT = 0.0f;

 	// Generate the camera ray
 	pScene->m_Camera.GenerateRay(Vec2f(X, Y), RNG.Get2(), EyeRay.m_O, EyeRay.m_D);

	EyeRay.m_MinT = 0.0f; 
	EyeRay.m_MaxT = FLT_MAX;

	// Check if ray passes through volume, if it doesn't, evaluate scene lights and stop tracing 
 	if (!NearestIntersection(pScene, EyeRay, StepSize, RNG.Get1(), &BoxMinT, &BoxMaxT))
 		Continue = false;

	CColorXyz Li = SPEC_BLACK;
	RayCopy = CRay(EyeRay.m_O, EyeRay.m_D, 0.0f, Continue ? EyeRay.m_MinT : EyeRay.m_MaxT);

	if (NearestLight(pScene, RayCopy, Li))
	{
		pDevEstFrameXyz[Y * (int)pScene->m_Camera.m_Film.m_Resolution.GetResX() + X] = Li;
		return;
	}

	if (EyeRay.m_MaxT == INF_MAX)
 		Continue = false;
	
	float EyeT	= EyeRay.m_MinT;

	Vec3f EyeP, Normal;
	
	// Walk along the eye ray with ray marching
	while (Continue && EyeT < EyeRay.m_MaxT)
	{
		// Determine new point on eye ray
		EyeP = EyeRay(EyeT);

		// Increase parametric range
		EyeT += StepSize;

		// Fetch density
		const float D = Density(pScene, EyeP);

		// We ignore air density
		if (Density == 0) 
			continue;
		 
		// Get opacity at eye point
		const float		Tr = GetOpacity(pScene, D).r;
		const CColorXyz	Ke = GetEmission(pScene, D).ToXYZ();
		
		// Add emission
		EyeTr += Ke; 
		
		// Compute outgoing direction
		const Vec3f Wo = Normalize(-EyeRay.m_D);

		// Obtain normal
		Normal = NormalizedGradient(pScene, EyeP, &gTexDensity);//ComputeGradient(pScene, EyeP, Wo);

		// Exit if air, or not within hemisphere
		if (Tr < 0.05f)// || Dot(Wo, Normal[TID]) < 0.0f)
			continue;

		// Estimate direct light at eye point
	 	L += EyeTr * UniformSampleOneLight(pScene, Wo, EyeP, Normal, RNG, StepSize);

		// Compute eye transmittance
		EyeTr *= expf(-(Tr * StepSize));

		/*
		// Russian roulette
		if (EyeTr.y() < 0.5f)
		{
			const float DieP = 1.0f - (EyeTr.y() / Threshold);

			if (DieP > RNG.Get1())
			{
				break;
			}
			else
			{
				EyeTr *= 1.0f / (1.0f - DieP);
			}
		}
		*/

		if (EyeTr.y() < 0.05f)
			break;
	}

	RayCopy.m_O		= EyeP;
	RayCopy.m_D		= EyeRay.m_D;
	RayCopy.m_MinT	= EyeT;
	RayCopy.m_MaxT	= 10000000.0f;

	if (NearestLight(pScene, RayCopy, Li))
		Li += EyeTr * Li;

	// Contribute
	pDevEstFrameXyz[Y * (int)pScene->m_Camera.m_Film.m_Resolution.GetResX() + X] = L;
}

// Traces the volume
void RenderVolume(CScene* pScene, CScene* pDevScene, curandStateXORWOW_t* pDevRandomStates, CColorXyz* pDevEstFrameXyz)
{
	// Copy the scene from host memory to device memory
//	cudaMemcpyToSymbol("gScene", pScene, sizeof(CScene));

	const dim3 KernelBlock(32, 8);
	const dim3 KernelGrid((int)ceilf((float)pScene->m_Camera.m_Film.m_Resolution.GetResX() / (float)KernelBlock.x), (int)ceilf((float)pScene->m_Camera.m_Film.m_Resolution.GetResY() / (float)KernelBlock.y));
	
	// Execute kernel
	KrnlSS<<<KernelGrid, KernelBlock>>>(pDevScene, pDevRandomStates, pDevEstFrameXyz);
}
