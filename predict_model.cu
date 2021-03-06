/*
 *
 Copyright (C) 2014 Sarod Yatawatta <sarod@users.sf.net>  
 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.
 
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 $Id$
*/

#ifndef block_size_x
  //#define block_size_x DEFAULT_TH_PER_BK
  #define block_size_x 128
#endif

#ifndef use_kernel
  #define use_kernel 0
#endif

#ifndef use_shared_mem
  #define use_shared_mem 1
#endif

#include <cuComplex.h>
#include <stdio.h>
//#include <cublas_v2.h>
//#include "Radio.h"

//replaced header
#include "predict_model.h"


/* enable this for checking for kernel failure */
//#define CUDA_DBG

__device__ __forceinline__ void
radec2azel_gmst__(float ra, float dec, float longitude, float latitude, float thetaGMST, float *az, float *el) {
  float thetaLST=thetaGMST+longitude*180.0f/M_PI;

  float LHA=fmodf(thetaLST-ra*180.0f/M_PI,360.0f);

  float sinlat,coslat,sindec,cosdec,sinLHA,cosLHA;
  sincosf(latitude,&sinlat,&coslat);
  sincosf(dec,&sindec,&cosdec);
  sincosf(LHA*M_PI/180.0f,&sinLHA,&cosLHA);

  float tmp=sinlat*sindec+coslat*cosdec*cosLHA;
  float eld=asinf(tmp);

  float sinel,cosel;
  sincosf(eld,&sinel,&cosel);

  float azd=fmodf(atan2f(-sinLHA*cosdec/cosel,(sindec-sinel*sinlat)/(cosel*coslat)),2.0f*M_PI);
  if (azd<0.0f) {
   azd+=2.0f*M_PI;
  }
  *el=eld;
  *az=azd;
}

/* slave kernel to calculate phase of manifold vector for given station */
/* x,y,z: Nx1 arrays of element coords */
/* sum: scalar to store result */
/* NOTE: only 1 block should be used here */
__global__ void 
kernel_array_beam_slave_sin(int N, float r1, float r2, float r3, float *x, float *y, float *z, float *sum, int blockDim_2) {
  unsigned int n=threadIdx.x+blockDim.x*blockIdx.x;
  extern __shared__ float tmpsum[]; /* assumed to be size Nx1 */
  if (n<N) {
    tmpsum[n]=sinf((r1*__ldg(&x[n])+r2*__ldg(&y[n])+r3*__ldg(&z[n])));
  }
  __syncthreads();

 // Build summation tree over elements, handling case where total threads is not a power of two.
  int nTotalThreads = blockDim_2; // Total number of threads (==N), rounded up to the next power of two
  while(nTotalThreads > 1) {
    int halfPoint = (nTotalThreads >> 1); // divide by two
    if (n < halfPoint) {
     int thread2 = n + halfPoint;
     if (thread2 < blockDim.x) { // Skipping the fictitious threads >N ( blockDim.x ... blockDim_2-1 )
      tmpsum[n] = tmpsum[n]+tmpsum[thread2];
     }
    }
    __syncthreads();
    nTotalThreads = halfPoint; // Reducing the binary tree size by two
  }

  /* now thread 0 will add up results */
  if (threadIdx.x==0) {
   *sum=tmpsum[0];
  }
}

__global__ void 
kernel_array_beam_slave_cos(int N, float r1, float r2, float r3, float *x, float *y, float *z, float *sum, int blockDim_2) {
  unsigned int n=threadIdx.x+blockDim.x*blockIdx.x;
  extern __shared__ float tmpsum[]; /* assumed to be size Nx1 */
  if (n<N) {
    tmpsum[n]=cosf((r1*__ldg(&x[n])+r2*__ldg(&y[n])+r3*__ldg(&z[n])));
  }
  __syncthreads();
  // Build summation tree over elements, handling case where total threads is not a power of two.
  int nTotalThreads = blockDim_2; // Total number of threads (==N), rounded up to the next power of two
  while(nTotalThreads > 1) {
    int halfPoint = (nTotalThreads >> 1); // divide by two
    if (n < halfPoint) {
     int thread2 = n + halfPoint;
     if (thread2 < blockDim.x) { // Skipping the fictitious threads >N ( blockDim.x ... blockDim_2-1 )
      tmpsum[n] = tmpsum[n]+tmpsum[thread2];
     }
    }
    __syncthreads();
    nTotalThreads = halfPoint; // Reducing the binary tree size by two
  }

  /* now thread 0 will add up results */
  if (threadIdx.x==0) {
   *sum=tmpsum[0];
  }
}

/* sum: 2x1 array */
__global__ void 
kernel_array_beam_slave_sincos(int N, float r1, float r2, float r3, const float *x, const float *y, const float *z, float *sum, int blockDim_2) {
  unsigned int n=threadIdx.x+blockDim.x*blockIdx.x;
  extern __shared__ float tmpsum[]; /* assumed to be size 2*Nx1 */
  if (n<N) {
    float ss,cc;
    sincosf((r1*__ldg(&x[n])+r2*__ldg(&y[n])+r3*__ldg(&z[n])),&ss,&cc);
    tmpsum[2*n]=ss;
    tmpsum[2*n+1]=cc;
  }
  __syncthreads();

 // Build summation tree over elements, handling case where total threads is not a power of two.
  int nTotalThreads = blockDim_2; // Total number of threads (==N), rounded up to the next power of two
  while(nTotalThreads > 1) {
    int halfPoint = (nTotalThreads >> 1); // divide by two
    if (n < halfPoint) {
     int thread2 = n + halfPoint;
     if (thread2 < blockDim.x) { // Skipping the fictitious threads >N ( blockDim.x ... blockDim_2-1 )
      tmpsum[2*n] = tmpsum[2*n]+tmpsum[2*thread2];
      tmpsum[2*n+1] = tmpsum[2*n+1]+tmpsum[2*thread2+1];
     }
    }
    __syncthreads();
    nTotalThreads = halfPoint; // Reducing the binary tree size by two
  }

  /* now thread 0 will add up results */
  if (threadIdx.x==0) {
   sum[0]=tmpsum[0];
   sum[1]=tmpsum[1];
  }
}


__device__ int
NearestPowerOf2 (int n){
  if (!n) return n;  //(0 == 2^0)

  int x = 1;
  while(x < n) {
      x <<= 1;
  }
  return x;
}


/* master kernel to calculate beam */
/* tarr: size NTKFx2 buffer to store sin() cos() sums */
__global__ void 
kernel_array_beam(int N, int T, int K, int F,
        const float *__restrict__ freqs, const float *__restrict__ longitude, const float *__restrict__ latitude,
        const double *__restrict__ time_utc, const int *__restrict__ Nelem,
        const float * const *__restrict__ xx, const float * const *__restrict__ yy, const float * const *__restrict__ zz,
        const float *__restrict__ ra, const float *__restrict__ dec,
        float ph_ra0, float ph_dec0, float ph_freq0, float *beam, float *tarr) {

    // global thread index, in x-dimension
    int x=threadIdx.x+blockDim.x*blockIdx.x;
    int istat = blockIdx.y;

    #if use_kernel == 1
    int n = istat*(K*T*F)+x;
    #endif

    // find respective source,freq,time for this thread
    int n1 = x;
    int isrc=n1/(T*F);
    n1=n1-isrc*(T*F);
    int ifrq=n1/(T);
    n1=n1-ifrq*(T);
    int itm=n1;

    //number of elements for this station
    int Nelems = __ldg(&Nelem[istat]);

    //if not using slave kernel, and using shared memory
    //preload all x,y,z positions of elements for this station
    //it's important that all threads participate in this loop
    #if (use_kernel == 0) && (use_shared_mem == 1)
    #define MAX_ELEM 512
    __shared__ float sh_x[MAX_ELEM];
    __shared__ float sh_y[MAX_ELEM];
    __shared__ float sh_z[MAX_ELEM];
    for (int i=threadIdx.x; i<Nelems; i+=block_size_x) {
        sh_x[i] = __ldg(&xx[istat][i]);
        sh_y[i] = __ldg(&yy[istat][i]);
        sh_z[i] = __ldg(&zz[istat][i]);
    }
    __syncthreads();
    #endif

    float r1,r2,r3;
    if (x < (K*T*F)) {

        // time is already converted to thetaGMST
        float thetaGMST=(float) __ldg(&time_utc[itm]);
        // find az,el
        float az,el,az0,el0,theta,phi,theta0,phi0;
        radec2azel_gmst__(__ldg(&ra[isrc]),__ldg(&dec[isrc]), __ldg(&longitude[istat]), __ldg(&latitude[istat]), thetaGMST, &az, &el);
        radec2azel_gmst__(ph_ra0,ph_dec0, __ldg(&longitude[istat]), __ldg(&latitude[istat]), thetaGMST, &az0, &el0);
        // transform : theta = 90-el, phi=-az? 45 only needed for element beam
        theta=M_PI_2-el;
        phi=-az;
        theta0=M_PI_2-el0;
        phi0=-az0;

        // 2*PI/C
        const float tpc=2.0f * M_PI/CONST_C;
        float sint,cost,sinph,cosph,sint0,cost0,sinph0,cosph0;
        sincosf(theta,&sint,&cost);
        sincosf(phi,&sinph,&cosph);
        sincosf(theta0,&sint0,&cost0);
        sincosf(phi0,&sinph0,&cosph0);

        /*r1=(float)-tpc*(ph_freq0*sint0*cosph0-freqs[ifrq]*sint*cosph);
        r2=(float)-tpc*(ph_freq0*sint0*sinph0-freqs[ifrq]*sint*sinph);
        r3=(float)-tpc*(ph_freq0*cost0-freqs[ifrq]*cost);
        */
        float f=__ldg(&freqs[ifrq]);
        float rat1=ph_freq0*sint0;
        float rat2=f*sint;
        r1=-tpc*(rat1*cosph0-rat2*cosph);
        r2=-tpc*(rat1*sinph0-rat2*sinph);
        r3=-tpc*(ph_freq0*cost0-f*cost);

        #if use_kernel == 1 // use the slave kernel

        //int boffset=istat*K*T*F + isrc*T*F + ifrq*T + itm;
        // always use 1 block, assuming total elements<512 
        kernel_array_beam_slave_sincos<<<1,Nelems,sizeof(float)*Nelems*2>>>(Nelems,r1,r2,r3,xx[istat],yy[istat],zz[istat],&tarr[2*n],NearestPowerOf2(Nelems));
        cudaDeviceSynchronize();
        #ifdef CUDA_DBG
            cudaError_t error = cudaGetLastError();
            if(error != cudaSuccess) {
                // print the CUDA error message and exit
                printf("CUDA error: %s :%s: %d\n", cudaGetErrorString(error),__FILE__,__LINE__);
            }
        #endif
        float ssum=__ldg(&tarr[2*n]);
        float csum=__ldg(&tarr[2*n+1]);

        #else  // instead just use a for-loop

        float ssum = 0.0f;
        float csum = 0.0f;
        for (int i=0; i<Nelems; i++) {
            float ss,cc;
            #if use_shared_mem == 0
            sincosf((r1*__ldg(&xx[istat][i])+r2*__ldg(&yy[istat][i])+r3*__ldg(&zz[istat][i])),&ss,&cc);
            #else
            sincosf(r1*sh_x[i]+r2*sh_y[i]+r3*sh_z[i],&ss,&cc);
            #endif
            ssum += ss;
            csum += cc;
        }

        #endif // use_kernel
   
        float Nnor=1.0f/(float)Nelems;
        ssum*=Nnor;
        csum*=Nnor;
        // store output (amplitude of beam)
        int boffset=itm*N*K*F+isrc*N*F+ifrq*N+istat;
        beam[boffset]=sqrtf(ssum*ssum+csum*csum);
        //printf("thread %d stat %d src %d freq %d time %d : %lf longitude=%lf latitude=%lf time=%lf freq=%lf elem=%d ra=%lf dec=%lf beam=%lf\n",n,istat,isrc,ifrq,itm,time_utc[itm],longitude[istat],latitude[istat],time_utc[itm],freqs[ifrq],Nelem[istat],ra[isrc],dec[isrc],beam[boffset]);
  
    } // x < ktf
 
}

/***************************************************************************/
__device__ cuFloatComplex
gaussian_contrib(int *dd, float u, float v, float w) {
  exinfo_gaussian *dp=(exinfo_gaussian*)dd;
  float up,vp,a,b,ut,vt,cosph,sinph;

  /* first the rotation due to projection */
  if (dp->use_projection) {
   up=u*(dp->cxi)-v*(dp->cphi)*(dp->sxi)+w*(dp->sphi)*(dp->sxi);
   vp=u*(dp->sxi)+v*(dp->cphi)*(dp->cxi)-w*(dp->sphi)*(dp->cxi);
  } else {
   up=u;
   vp=v;
  }

  /* linear transformations, if any */
  a=dp->eX;
  b=dp->eY;
  sincosf(dp->eP,&sinph,&cosph);
  ut=a*(cosph*up-sinph*vp);
  vt=b*(sinph*up+cosph*vp);

  return make_cuFloatComplex(0.5f*M_PI*expf(-(ut*ut+vt*vt)),0.0f);
}



__device__ cuFloatComplex
ring_contrib(int *dd, float u, float v, float w) {
  exinfo_ring *dp=(exinfo_ring*)dd;
  float up,vp,a,b;

  /* first the rotation due to projection */
  up=u*(dp->cxi)-v*(dp->cphi)*(dp->sxi)+w*(dp->sphi)*(dp->sxi);
  vp=u*(dp->sxi)+v*(dp->cphi)*(dp->cxi)-w*(dp->sphi)*(dp->cxi);

  a=dp->eX; /* diameter */
  b=sqrtf(up*up+vp*vp)*a*2.0f*M_PI;

  return make_cuFloatComplex(j0f(b),0.0f);
}

__device__ cuFloatComplex
disk_contrib(int *dd, float u, float v, float w) {
  exinfo_disk *dp=(exinfo_disk*)dd;
  float up,vp,a,b;

  /* first the rotation due to projection */
  up=u*(dp->cxi)-v*(dp->cphi)*(dp->sxi)+w*(dp->sphi)*(dp->sxi);
  vp=u*(dp->sxi)+v*(dp->cphi)*(dp->cxi)-w*(dp->sphi)*(dp->cxi);

  a=dp->eX; /* diameter */
  b=sqrtf(up*up+vp*vp)*a*2.0f*M_PI;

  return make_cuFloatComplex(j1f(b),0.0f);
}


/* Hermite polynomial, non recursive version */
__device__ float 
H_e(float x, int n) {
  if(n==0) return 1.0f;
  if(n==1) return 2.0f*x;
  /* else iterate */
  float Hn_1,Hn,Hnp1;
  Hn_1=1.0f;
  Hn=2.0f*x;
  int ci;
  for (ci=1; ci<n; ci++) {
    Hnp1=2.0f*x*Hn-2.0f*((float)ci)*Hn_1;
    Hn_1=Hn;
    Hn=Hnp1;
  }

  return Hn;
}

__device__ void
calculate_uv_mode_vectors_scalar(float u, float v, float beta, int n0, float *Av, int *cplx) {

  int xci,zci,Ntot;

  float **shpvl, *fact;
  int n1,n2,start;
  float xval;
  int signval;

  Ntot=2; /* u,v seperately */
  /* set up factorial array */
  fact=(float *)malloc((size_t)(n0)*sizeof(float));
  fact[0]=1.0f;
  for (xci=1; xci<(n0); xci++) {
    fact[xci]=(xci+1.0f)*fact[xci-1];
  }

  /* setup array to store calculated shapelet value */
  /* need max storage Ntot x n0 */
  shpvl=(float**)malloc((size_t)(Ntot)*sizeof(float*));
  for (xci=0; xci<Ntot; xci++) {
   shpvl[xci]=(float*)malloc((size_t)(n0)*sizeof(float));
  }


  /* start filling in the array from the positive values */
  zci=0;
  xval=u*beta;
  float expval=__expf(-0.5f*(float)xval*xval);
  for (xci=0; xci<n0; xci++) {
    shpvl[zci][xci]=H_e(xval,xci)*expval/__fsqrt_rn((float)(2<<xci)*fact[xci]);
  }
  zci=1;
  xval=v*beta;
  expval=exp(-0.5f*xval*xval);
  for (xci=0; xci<n0; xci++) {
    shpvl[zci][xci]=H_e(xval,xci)*expval/__fsqrt_rn((float)(2<<xci)*fact[xci]);
  }

  /* now calculate the mode vectors */
  /* each vector is 1 x 1 length and there are n0*n0 of them */

  for (n2=0; n2<(n0); n2++) {
   for (n1=0; n1<(n0); n1++) {
    cplx[n2*n0+n1]=((n1+n2)%2==0?0:1) /* even (real) or odd (imaginary)*/;
    /* sign */
    if (cplx[n2*n0+n1]==0) {
      signval=(((n1+n2)/2)%2==0?1:-1);
    } else {
      signval=(((n1+n2-1)/2)%2==0?1:-1);
    }

    /* fill in 1*1*(zci) to 1*1*(zci+1)-1 */
    start=(n2*(n0)+n1);
    if (signval==-1) {
        Av[start]=-shpvl[0][n1]*shpvl[1][n2];
    } else {
        Av[start]=shpvl[0][n1]*shpvl[1][n2];
    }
   }
  }

  free(fact);
  for (xci=0; xci<Ntot; xci++) {
   free(shpvl[xci]);
  }
  free(shpvl);
}

__device__ cuFloatComplex
shapelet_contrib(int *dd, float u, float v, float w) {
  exinfo_shapelet *dp=(exinfo_shapelet*)dd;
  int *cplx;
  float *Av;
  int ci,M;
  float a,b,ut,vt,up,vp;
  float sinph,cosph;
  float realsum,imagsum;

  /* first the rotation due to projection */
  if (dp->use_projection) {
   up=-u*(dp->cxi)+v*(dp->cphi)*(dp->sxi)-w*(dp->sphi)*(dp->sxi);
   vp=-u*(dp->sxi)-v*(dp->cphi)*(dp->cxi)+w*(dp->sphi)*(dp->cxi);
  } else {
   up=u;
   vp=v;
  }

  /* linear transformations, if any */
  a=1.0f/dp->eX;
  b=1.0f/dp->eY;
  __sincosf((float)dp->eP,&sinph,&cosph);
  ut=a*(cosph*up-sinph*vp);
  vt=b*(sinph*up+cosph*vp);
  /* note: we decompose f(-l,m) so the Fourier transform is F(-u,v)
   so negate the u grid */
  Av=(float*)malloc((size_t)((dp->n0)*(dp->n0))*sizeof(float));
  cplx=(int*)malloc((size_t)((dp->n0)*(dp->n0))*sizeof(int));

  calculate_uv_mode_vectors_scalar(-ut, vt, dp->beta, dp->n0, Av, cplx);
  realsum=imagsum=0.0f;
  M=(dp->n0)*(dp->n0);
  for (ci=0; ci<M; ci++) {
    if (cplx[ci]) {
     imagsum+=dp->modes[ci]*Av[ci];
    } else {
     realsum+=dp->modes[ci]*Av[ci];
    }
  }

  free(Av);
  free(cplx);
  //return 2.0*M_PI*(realsum+_Complex_I*imagsum);
  realsum*=2.0f*M_PI*a*b;
  imagsum*=2.0f*M_PI*a*b;
  return make_cuFloatComplex(realsum,imagsum);
}


__device__ cuFloatComplex compute_prodterm(int sta1, int sta2, int N, int K, int T, int F,
float phterm0, float sIf, float sI0f, float spec_idxf, float spec_idx1f, float spec_idx2f, float myf0,
const float *__restrict__ freqs, float deltaf, int dobeam, int itm, int k1, int cf, float *beam, int **exs, unsigned char stypeT,
float u, float v, float w, int k) {

     float sinph,cosph;
     float myfreq=__ldg(&freqs[cf]);
     sincosf(phterm0*myfreq,&sinph,&cosph);
     cuFloatComplex prodterm=make_cuFloatComplex(cosph,sinph);
     float If;
     if (F==1) {
      /* flux: do not use spectra here, because F=1*/
      If=sIf;
     } else {
      /* evaluate spectra */
      float fratio=__logf(myfreq/myf0);
      float fratio1=fratio*fratio;
      float fratio2=fratio1*fratio;
      /* catch -ve flux */
      if (sI0f>0.0f) {
        If=__expf(__logf(sI0f)+spec_idxf*fratio+spec_idx1f*fratio1+spec_idx2f*fratio2);
      } else if (sI0f<0.0f) {
        If=-__expf(__logf(-sI0f)+spec_idxf*fratio+spec_idx1f*fratio1+spec_idx2f*fratio2);
      } else {
        If=0.0f;
      }
     }
     /* smearing */
     float phterm =phterm0*0.5f*deltaf;
     if (phterm!=0.0f) {
      sinph=__sinf(phterm)/phterm;
      If *=fabsf(sinph); /* catch -ve values due to rounding off */
     }

     if (dobeam) {
      /* get beam info */
      //int boffset1=sta1*K*T*F + k1*T*F + cf*T + itm;

      int boffset1=itm*N*K*F+k1*N*F+cf*N+sta1;
      //  printf("itm=%d, k1=%d, sta1=%d, sta2=%d, boffset1=%d, boffset2=%d\n", itm, k1, sta1, sta2, boffset1, boffset2);
      float beam1=__ldg(&beam[boffset1]);
      //int boffset2=sta2*K*T*F + k1*T*F + cf*T + itm;
      int boffset2=itm*N*K*F+k1*N*F+cf*N+sta2;
      float beam2=__ldg(&beam[boffset2]);
      If *=beam1*beam2;
     }

     /* form complex value */
     prodterm.x *=If;
     prodterm.y *=If;

     /* check for type of source */
     if (stypeT!=STYPE_POINT) {
      float uscaled=u*myfreq;
      float vscaled=v*myfreq;
      float wscaled=w*myfreq;
      if (stypeT==STYPE_SHAPELET) {
       prodterm=cuCmulf(shapelet_contrib(exs[k],uscaled,vscaled,wscaled),prodterm);
      } else if (stypeT==STYPE_GAUSSIAN) {
       prodterm=cuCmulf(gaussian_contrib(exs[k],uscaled,vscaled,wscaled),prodterm);
      } else if (stypeT==STYPE_DISK) {
       prodterm=cuCmulf(disk_contrib(exs[k],uscaled,vscaled,wscaled),prodterm);
      } else if (stypeT==STYPE_RING) {
       prodterm=cuCmulf(ring_contrib(exs[k],uscaled,vscaled,wscaled),prodterm);
      }
     }
     

    return prodterm;

}


/* slave thread to calculate coherencies, for 1 source */
/* baseline (sta1,sta2) at time itm */
/* K: total sources, uset to find right offset 
   Kused: actual sources calculated in this thread block
   Koff: offset in source array to start calculation
   NOTE: only 1 block is used
 */
__global__ void 
kernel_coherencies_slave(int sta1, int sta2, int itm, int B, int N, int T, int K, int Kused, int Koff, int F,
    float u, float v, float w, const float *freqs, float *beam, const float *ll, const float *mm, const float *nn, const float *sI,
    const unsigned char *stype, const float *sI0, const float *f0, const float *spec_idx, const float *spec_idx1, const float *spec_idx2,
    int **exs, float deltaf, float deltat, float dec0, float *__restrict__ coh, int dobeam, int blockDim_2) {
  /* which source we work on */
  unsigned int k=threadIdx.x+blockDim.x*blockIdx.x;

  extern __shared__ float tmpcoh[]; /* assumed to be size 8*F*Kusedx1 */

  if (k<Kused) {

   int k1=k+Koff; /* actual source id */

   /* preload all freq independent variables */
   /* Fourier phase */
   float phterm0=2.0f*M_PI*(u*__ldg(&ll[k])+v*__ldg(&mm[k])+w*__ldg(&nn[k]));
   float sIf,sI0f,spec_idxf,spec_idx1f,spec_idx2f,myf0;
   sIf=__ldg(&sI[k]);
   if (F>1) {
     sI0f=__ldg(&sI0[k]);
     spec_idxf=__ldg(&spec_idx[k]);
     spec_idx1f=__ldg(&spec_idx1[k]);
     spec_idx2f=__ldg(&spec_idx2[k]);
     myf0=__ldg(&f0[k]);
   }
   unsigned char stypeT=__ldg(&stype[k]);
   for(int cf=0; cf<F; cf++) {


    cuFloatComplex prodterm = compute_prodterm(sta1, sta2, N, K, T, F,
phterm0, sIf, sI0f, spec_idxf, spec_idx1f, spec_idx2f, myf0, freqs, deltaf, dobeam, itm, k1, cf, beam, exs, stypeT, u, v, w, k);


//printf("k=%d cf=%d freq=%f uvw %f,%f,%f lmn %f,%f,%f phterm %f If %f\n",k,cf,freqs[cf],u,v,w,ll[k],mm[k],nn[k],phterm,If);

     /* write output to shared array */
     tmpcoh[k*8*F+8*cf]=prodterm.x;
     tmpcoh[k*8*F+8*cf+1]=prodterm.y;
     tmpcoh[k*8*F+8*cf+2]=0.0f;
     tmpcoh[k*8*F+8*cf+3]=0.0f;
     tmpcoh[k*8*F+8*cf+4]=0.0f;
     tmpcoh[k*8*F+8*cf+5]=0.0f;
     tmpcoh[k*8*F+8*cf+6]=prodterm.x;
     tmpcoh[k*8*F+8*cf+7]=prodterm.y;
   }
  }
  __syncthreads();

  // Build summation tree over elements, handling case where total threads is not a power of two.
  int nTotalThreads = blockDim_2; // Total number of threads (==Kused), rounded up to the next power of two
  while(nTotalThreads > 1) {
    int halfPoint = (nTotalThreads >> 1); // divide by two
    if (k < halfPoint) {
     int thread2 = k + halfPoint;
     if (thread2 < blockDim.x) { // Skipping the fictitious threads >Kused ( blockDim.x ... blockDim_2-1 )
      for(int cf=0; cf<F; cf++) {
       tmpcoh[k*8*F+8*cf]=tmpcoh[k*8*F+8*cf]+tmpcoh[thread2*8*F+8*cf];
       tmpcoh[k*8*F+8*cf+1]=tmpcoh[k*8*F+8*cf+1]+tmpcoh[thread2*8*F+8*cf+1];
       tmpcoh[k*8*F+8*cf+2]=tmpcoh[k*8*F+8*cf+2]+tmpcoh[thread2*8*F+8*cf+2];
       tmpcoh[k*8*F+8*cf+3]=tmpcoh[k*8*F+8*cf+3]+tmpcoh[thread2*8*F+8*cf+3];
       tmpcoh[k*8*F+8*cf+4]=tmpcoh[k*8*F+8*cf+4]+tmpcoh[thread2*8*F+8*cf+4];
       tmpcoh[k*8*F+8*cf+5]=tmpcoh[k*8*F+8*cf+5]+tmpcoh[thread2*8*F+8*cf+5];
       tmpcoh[k*8*F+8*cf+6]=tmpcoh[k*8*F+8*cf+6]+tmpcoh[thread2*8*F+8*cf+6];
       tmpcoh[k*8*F+8*cf+7]=tmpcoh[k*8*F+8*cf+7]+tmpcoh[thread2*8*F+8*cf+7];
      }

     }
    }
    __syncthreads();
    nTotalThreads = halfPoint; // Reducing the binary tree size by two
  }

  /* add up to form final result */
  if (threadIdx.x==0) {
    for(int cf=0; cf<F; cf++) {
     coh[cf*8*B]+=tmpcoh[8*cf];
     coh[cf*8*B+1]+=tmpcoh[8*cf+1];
     coh[cf*8*B+2]+=tmpcoh[8*cf+2];
     coh[cf*8*B+3]+=tmpcoh[8*cf+3];
     coh[cf*8*B+4]+=tmpcoh[8*cf+4];
     coh[cf*8*B+5]+=tmpcoh[8*cf+5];
     coh[cf*8*B+6]+=tmpcoh[8*cf+6];
     coh[cf*8*B+7]+=tmpcoh[8*cf+7];
    }
  }
}

/* master kernel to calculate coherencies */
extern "C"
__global__ void 
kernel_coherencies(int B, int N, int T, int K, int F, float *u, float *v, float *w, baseline_t *barr, float *freqs, float *beam,
    const float *__restrict__ ll, const float *__restrict__ mm, const float *__restrict__ nn,
    const float *__restrict__ sI, const unsigned char *__restrict__ stype,
    const float *__restrict__ sI0, const float *__restrict__ f0,
    const float *__restrict__ spec_idx, const float *__restrict__ spec_idx1, const float *__restrict__ spec_idx2, int **exs, float deltaf, float deltat, float dec0, float *coh, int dobeam) {

  /* global thread index */
  unsigned int n=threadIdx.x+blockDim.x*blockIdx.x;

  /* each thread will calculate for one baseline, over all sources */
  if (n<B) {
   int sta1=barr[n].sta1;
   int sta2=barr[n].sta2;
   /* find out which time slot this baseline is from */
   int tslot=n/((N*(N-1)/2));


    #if use_kernel == 1

#ifdef CUDA_DBG
   cudaError_t error;
#endif

   int ThreadsPerBlock= block_size_x; //DEFAULT_TH_PER_BK;
   /* each slave thread will calculate one source, 8xF values for all freq */
   /* also give right offset for coherencies */
   if (K<ThreadsPerBlock) {
    /* one kernel is enough, offset is 0 */
    kernel_coherencies_slave<<<1,K,sizeof(float)*(8*F*K)>>>(sta1,sta2,tslot,B,N,T,K,K,0,F,__ldg(&u[n]),__ldg(&v[n]),__ldg(&w[n]),freqs,beam,ll,mm,nn,sI,stype,sI0,f0,spec_idx,spec_idx1,spec_idx2,exs,deltaf,deltat,dec0,&coh[8*n],dobeam,NearestPowerOf2(K));
    cudaDeviceSynchronize();
#ifdef CUDA_DBG
  error = cudaGetLastError();
  if(error != cudaSuccess) {
    // print the CUDA error message and exit
    printf("CUDA error: %s :%s: %d\n", cudaGetErrorString(error),__FILE__,__LINE__);
  }
#endif
   } else {
    /* more than 1 kernel */
    int L=(K+ThreadsPerBlock-1)/ThreadsPerBlock;
    int ct=0;
    int myT;
    for (int ci=0; ci<L; ci++) {
     if (ct+ThreadsPerBlock<K) {
       myT=ThreadsPerBlock;
     } else {
       myT=K-ct;
     }
     /* launch kernel with myT threads, starting at ct offset */
     kernel_coherencies_slave<<<1,myT,sizeof(float)*(8*F*myT)>>>(sta1,sta2,tslot,B,N,T,K,myT,ct,F,__ldg(&u[n]),__ldg(&v[n]),__ldg(&w[n]),freqs,beam,&ll[ct],&mm[ct],&nn[ct],&sI[ct],&stype[ct],&sI0[ct],&f0[ct],&spec_idx[ct],&spec_idx1[ct],&spec_idx2[ct],&exs[ct],deltaf,deltat,dec0,&coh[8*n],dobeam,NearestPowerOf2(myT));
     cudaDeviceSynchronize();
#ifdef CUDA_DBG
  error = cudaGetLastError();
  if(error != cudaSuccess) {
    // print the CUDA error message and exit
    printf("CUDA error: %s :%s: %d\n", cudaGetErrorString(error),__FILE__,__LINE__);
  }
#endif
     ct=ct+ThreadsPerBlock;
    }
   }

    #else //use_kernel == 0

    float u_n = u[n];
    float v_n = v[n];
    float w_n = w[n];

    //TODO: figure out if this max_f makes any sense
    #define MAX_F 20
    cuFloatComplex l_coh[MAX_F];
    for(int cf=0; cf<F; cf++) {
        l_coh[cf] = make_cuFloatComplex(0.0f, 0.0f);
    }

    //use simply for-loop, if K is very large this may be slow and may need further parallelization
    for (int k=0; k<K; k++) {

        //source specific params
        float phterm0 = 0.0f;
        float sIf,sI0f,spec_idxf,spec_idx1f,spec_idx2f,myf0;

        phterm0 = 2.0f*M_PI*(u_n*__ldg(&ll[k])+v_n*__ldg(&mm[k])+w_n*__ldg(&nn[k]));
        sIf=__ldg(&sI[k]);
        if (F>1) {
            sI0f=__ldg(&sI0[k]);
            spec_idxf=__ldg(&spec_idx[k]);
            spec_idx1f=__ldg(&spec_idx1[k]);
            spec_idx2f=__ldg(&spec_idx2[k]);
            myf0=__ldg(&f0[k]);
        }

        unsigned char stypeT=__ldg(&stype[k]);

        for(int cf=0; cf<F; cf++) {
            l_coh[cf] = cuCaddf(l_coh[cf], compute_prodterm(sta1, sta2, N, K, T, F, phterm0, sIf, sI0f, spec_idxf, spec_idx1f, spec_idx2f,
                                myf0, freqs, deltaf, dobeam, tslot, k, cf, beam, exs, stypeT, u_n, v_n, w_n, k));
        }

    }

    //write output
    coh = &coh[8*n];
    for(int cf=0; cf<F; cf++) {

        coh[cf*8*B+0] = l_coh[cf].x;
        coh[cf*8*B+1] = l_coh[cf].y;
        coh[cf*8*B+2] = 0.0f;
        coh[cf*8*B+3] = 0.0f;
        coh[cf*8*B+4] = 0.0f;
        coh[cf*8*B+5] = 0.0f;
        coh[cf*8*B+6] = l_coh[cf].x;
        coh[cf*8*B+7] = l_coh[cf].y;

    }


    #endif

  }
}


/* kernel to convert time (JD) to GMST angle*/
__global__ void 
kernel_convert_time(int T, double *time_utc) {

  /* global thread index */
  unsigned int n=threadIdx.x+blockDim.x*blockIdx.x;
  if (n<T) {
   /* convert time */
   double t_ut1=(__ldg(&time_utc[n])-2451545.0)/36525.0;
   /* use Horners rule */
   double theta=67310.54841 + t_ut1*((876600.0*3600.0 + 8640184.812866) + t_ut1*(0.093104-(6.2*10e-6)*(t_ut1)));
   double thetaGMST=fmod((fmod(theta,86400.0*(theta/fabs(theta)))/240.0),360.0);
   time_utc[n]=thetaGMST;
  }

}

/* only use extern if calling code is C */
extern "C"
{

#ifdef CUDA_DBG
static void
checkCudaError(cudaError_t err, const char *file, int line)
{
    if(!err)
        return;
    fprintf(stderr,"GPU (CUDA): %s %s %d\n", cudaGetErrorString(err),file,line);
    exit(EXIT_FAILURE);
}
#endif


/* 
  precalculate station beam:
  N: no of stations
  T: no of time slots
  K: no of sources
  F: no of frequencies
  freqs: frequencies Fx1
  longitude, latitude: Nx1 station locations
  time_utc: Tx1 time
  Nelem: Nx1 array of no. of elements
  xx,yy,zz: Nx1 arrays of Nelem[] station locations
  ra,dec: Kx1 source positions
  beam: output beam values NxTxKxF values
  ph_ra0,ph_dec0: beam pointing direction
  ph_freq0: beam referene freq
*/

void
cudakernel_array_beam(int N, int T, int K, int F, float *freqs, float *longitude, float *latitude,
 double *time_utc, int *Nelem, float **xx, float **yy, float **zz, float *ra, float *dec, float ph_ra0, float ph_dec0, float ph_freq0, float *beam) {
#ifdef CUDA_DBG
  cudaError_t error;
  error = cudaGetLastError();
#endif
  // Set a heap size of 128 megabytes. Note that this must
  // be done before any kernel is launched. 
  //cudaDeviceSetLimit(cudaLimitMallocHeapSize, 128*1024*1024);
  // for an array of max 24*16 x 2  double, the default 8MB is ok

  /* total number of threads needed */
  int Ntotal=N*T*K*F;
  float *buffer;
  /* allocate buffer to store intermerdiate sin() cos() values per thread */
#ifdef CUDA_DBG
  error=cudaMalloc((void**)&buffer, 2*Ntotal*sizeof(float));
  checkCudaError(error,__FILE__,__LINE__);
#endif
#ifndef CUDA_DBG
  cudaMalloc((void**)&buffer, 2*Ntotal*sizeof(float));
#endif
  cudaMemset(buffer,0,sizeof(float)*2*Ntotal);


  int ThreadsPerBlock=DEFAULT_TH_PER_BK;
  /* note: make sure we do not exceed max no of blocks available, otherwise (too many sources, loop over source id) */
  //int BlocksPerGrid= 2*(Ntotal+ThreadsPerBlock-1)/ThreadsPerBlock;
  dim3 grid(1, 1, 1);
  grid.x = (int)ceilf((K*T*F) / (float)ThreadsPerBlock);
  grid.y = N;

  kernel_array_beam<<<grid,ThreadsPerBlock>>>(N,T,K,F,freqs,longitude,latitude,time_utc,Nelem,xx,yy,zz,ra,dec,ph_ra0,ph_dec0,ph_freq0,beam,buffer);
  cudaDeviceSynchronize();

  cudaFree(buffer);
#ifdef CUDA_DBG
  error = cudaGetLastError();
  if(error != cudaSuccess) {
    // print the CUDA error message and exit
    fprintf(stderr,"CUDA error: %s :%s: %d\n", cudaGetErrorString(error),__FILE__,__LINE__);
    exit(-1);
  }
#endif
}


/* 
  calculate coherencies:
  B: total baselines
  N: no of stations
  T: no of time slots
  K: no of sources
  F: no of frequencies
  u,v,w: Bx1 uvw coords
  barr: Bx1 array of baseline/flag info
  freqs: Fx1 frequencies
  beam: NxTxKxF beam gain
  ll,mm,nn : Kx1 source coordinates
  sI: Kx1 source flux at reference freq
  stype: Kx1 source type info
  sI0: Kx1 original source referene flux
  f0: Kx1 source reference freq for calculating flux 
  spec_idx,spec_idx1,spec_idx2: Kx1 spectra info 
  exs: Kx1 array of pointers to extended source info
  deltaf,deltat: freq/time smearing integration interval
  dec0: phace reference dec
  coh: coherency Bx8 values, all K sources are added together

  dobeam: enable beam if >0
*/
void
cudakernel_coherencies(int B, int N, int T, int K, int F, float *u, float *v, float *w,baseline_t *barr, float *freqs, float *beam, float *ll, float *mm, float *nn, float *sI,
  unsigned char *stype, float *sI0, float *f0, float *spec_idx, float *spec_idx1, float *spec_idx2, int **exs, float deltaf, float deltat, float dec0, float *coh,int dobeam) {
#ifdef CUDA_DBG
  cudaError_t error;
  error = cudaGetLastError();
  error=cudaMemset(coh,0,sizeof(float)*8*B*F);
  checkCudaError(error,__FILE__,__LINE__);
#endif
#ifndef CUDA_DBG
  cudaMemset(coh,0,sizeof(float)*8*B*F);
#endif

  /* spawn threads to handle baselines, these threads will spawn threads for sources */
  int ThreadsPerBlock=DEFAULT_TH_PER_BK;
  /* note: make sure we do not exceed max no of blocks available, 
   otherwise (too many baselines, loop over source id) */
  int BlocksPerGrid= 2*(B+ThreadsPerBlock-1)/ThreadsPerBlock;
  kernel_coherencies<<<BlocksPerGrid,ThreadsPerBlock>>>(B, N, T, K, F,u,v,w,barr,freqs, beam, ll, mm, nn, sI,
    stype, sI0, f0, spec_idx, spec_idx1, spec_idx2, exs, deltaf, deltat, dec0, coh, dobeam);
  cudaDeviceSynchronize();
#ifdef CUDA_DBG
  error = cudaGetLastError();
  if(error != cudaSuccess) {
    // print the CUDA error message and exit
    fprintf(stderr,"CUDA error: %s :%s: %d\n", cudaGetErrorString(error),__FILE__,__LINE__);
    exit(-1);
  }
#endif
}


/* convert time JD to GMST angle
  store result at the same location */
void
cudakernel_convert_time(int T, double *time_utc) {
#ifdef CUDA_DBG
  cudaError_t error;
  error = cudaGetLastError();
#endif

  int ThreadsPerBlock=DEFAULT_TH_PER_BK;
  /* note: make sure we do not exceed max no of blocks available, 
   otherwise (too many baselines, loop over source id) */
  int BlocksPerGrid= 2*(T+ThreadsPerBlock-1)/ThreadsPerBlock;
  kernel_convert_time<<<BlocksPerGrid,ThreadsPerBlock>>>(T,time_utc);
  cudaDeviceSynchronize();
 #ifdef CUDA_DBG
  error = cudaGetLastError();
  if(error != cudaSuccess) {
    // print the CUDA error message and exit
    fprintf(stderr,"CUDA error: %s :%s: %d\n", cudaGetErrorString(error),__FILE__,__LINE__);
    exit(-1);
  }
#endif
}









/* 
  This kernel is there so we can call the kernel_array_beam using the Kernel Tuner
  for testing and performance tuning purposes

  precalculate station beam:
  N: no of stations
  T: no of time slots
  K: no of sources
  F: no of frequencies
  freqs: frequencies Fx1
  longitude, latitude: Nx1 station locations
  time_utc: Tx1 time
  Nelem: Nx1 array of no. of elements
  x,y,z: N*Nelemsx1 array of station locations
  ra,dec: Kx1 source positions
  beam: output beam values NxTxKxF values
  ph_ra0,ph_dec0: beam pointing direction
  ph_freq0: beam referene freq
*/
float
kernel_tuner_host_array_beam(int N, int T, int K, int F, float *freqs, float *longitude, float *latitude,
 double *time_utc, int *Nelem, float *x, float *y, float *z, float *ra, float *dec, float ph_ra0, float ph_dec0, float ph_freq0, float *beam, int TotalElems) {

    cudaError_t err;

    //move x,y,z to the GPU
    float *d_x, *d_y, *d_z;
    cudaMalloc((void**)&d_x, TotalElems*sizeof(float));
    cudaMalloc((void**)&d_y, TotalElems*sizeof(float));
    cudaMalloc((void**)&d_z, TotalElems*sizeof(float));
    cudaMemcpy(d_x, x, TotalElems*sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(d_y, y, TotalElems*sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(d_z, z, TotalElems*sizeof(float), cudaMemcpyHostToDevice);

    //construct the pointer arrays from float arrays x, y, z
    float **xx = (float **)malloc(N * sizeof(float*));
    float **yy = (float **)malloc(N * sizeof(float*));
    float **zz = (float **)malloc(N * sizeof(float*));
    int sumElems = 0;
    for (int i=0; i<N; i++) {
        xx[i] = d_x+sumElems;
        yy[i] = d_y+sumElems;
        zz[i] = d_z+sumElems;
        sumElems += Nelem[i];
    }

    //move xx,yy,zz to GPU memory
    float **d_xx, **d_yy, **d_zz;
    cudaMalloc((void**)&d_xx, N*sizeof(float*));
    cudaMalloc((void**)&d_yy, N*sizeof(float*));
    cudaMalloc((void**)&d_zz, N*sizeof(float*));
    cudaMemcpy(d_xx, xx, N*sizeof(float*), cudaMemcpyHostToDevice);
    cudaMemcpy(d_yy, yy, N*sizeof(float*), cudaMemcpyHostToDevice);
    cudaMemcpy(d_zz, zz, N*sizeof(float*), cudaMemcpyHostToDevice);
    free(xx);
    free(yy);
    free(zz);

    //allocate GPU memory for the rest of the stuff
    float *d_freqs, *d_longitude, *d_latitude, *d_ra, *d_dec, *d_beam;
    double *d_time_utc;
    int *d_Nelem;
    cudaMalloc((void**)&d_freqs, F*sizeof(float));
    cudaMalloc((void**)&d_longitude, N*sizeof(float));
    cudaMalloc((void**)&d_latitude, N*sizeof(float));
    cudaMalloc((void**)&d_ra, K*sizeof(float));
    cudaMalloc((void**)&d_dec, K*sizeof(float));
    cudaMalloc((void**)&d_beam, N*T*K*F*sizeof(float));
    cudaMalloc((void**)&d_time_utc, T*sizeof(double));
    cudaMalloc((void**)&d_Nelem, N*sizeof(int));

    cudaMemcpy(d_freqs, freqs, F*sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(d_longitude, longitude, N*sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(d_latitude, latitude, N*sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(d_ra, ra, K*sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(d_dec, dec, K*sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(d_time_utc, time_utc, T*sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(d_Nelem, Nelem, N*sizeof(int), cudaMemcpyHostToDevice);

    cudaMemset(d_beam,0,N*T*K*F*sizeof(float));

    // create events for measuring time
    cudaEvent_t start;
    err = cudaEventCreate(&start);
    if (err != cudaSuccess) {
        fprintf(stderr, "Error in cudaEventCreate: %s\n", cudaGetErrorString(err));
    }

    cudaEvent_t stop;
    err = cudaEventCreate(&stop);
    if (err != cudaSuccess) {
        fprintf(stderr, "Error in cudaEventCreate: %s\n", cudaGetErrorString(err));
    }

    /* total number of threads needed */

    #if use_kernel == 1
    int Ntotal=N*T*K*F;
    float *buffer;
    cudaMalloc((void**)&buffer, 2*Ntotal*sizeof(float));
    cudaMemset(buffer,0,sizeof(float)*2*Ntotal);
    #endif

    //int ThreadsPerBlock=DEFAULT_TH_PER_BK;
    int ThreadsPerBlock= block_size_x;
    //int BlocksPerGrid= 2*(Ntotal+ThreadsPerBlock-1)/ThreadsPerBlock;  
    //int BlocksPerGrid = (int)ceilf(Ntotal / (float)ThreadsPerBlock);
    dim3 grid(1, 1, 1);
    grid.x = (int)ceilf((K*T*F) / (float)ThreadsPerBlock);
    grid.y = N;

    //start timing
    cudaDeviceSynchronize();
    cudaEventRecord(start, 0);

    #if use_kernel == 1
    kernel_array_beam<<<grid,ThreadsPerBlock>>>(N,T,K,F,d_freqs,d_longitude,d_latitude,d_time_utc,d_Nelem,d_xx,d_yy,d_zz,d_ra,d_dec,ph_ra0,ph_dec0,ph_freq0,d_beam,buffer);
    #else
    kernel_array_beam<<<grid,ThreadsPerBlock>>>(N,T,K,F,d_freqs,d_longitude,d_latitude,d_time_utc,d_Nelem,d_xx,d_yy,d_zz,d_ra,d_dec,ph_ra0,ph_dec0,ph_freq0,d_beam, (float *)0);
    #endif

    //mark the end of the computation
    cudaEventRecord(stop, 0);

    //wait for all to finish and get time
    cudaDeviceSynchronize();
    float time = 0.0f;
    cudaEventElapsedTime(&time, start, stop);

    cudaMemcpy(beam, d_beam, N*T*K*F*sizeof(float), cudaMemcpyDeviceToHost);

    cudaFree(d_x);
    cudaFree(d_y);
    cudaFree(d_z);
    cudaFree(d_xx);
    cudaFree(d_yy);
    cudaFree(d_zz);

    cudaFree(d_freqs);
    cudaFree(d_longitude);
    cudaFree(d_latitude);
    cudaFree(d_ra);
    cudaFree(d_dec);
    cudaFree(d_beam);
    cudaFree(d_time_utc);
    cudaFree(d_Nelem);

    cudaEventDestroy(start);
    cudaEventDestroy(stop);

    //make sure there have been no errors
    cudaDeviceSynchronize();
    err = cudaGetLastError();
    if (err != cudaSuccess) {
        //this bit is necessary because the Kernel Tuner currently can't decide whether
        //it's OK to silently skip an error or break execution when calling C functions
        const char *error_string = cudaGetErrorString(err);
        if (strncmp("too many resources requested for launch", error_string, 10) == 0) {
            time = -1.0;
        } else {
            fprintf(stderr, "Error at the end of kernel_tuner_host_array_beam: %s\n", error_string);
            exit(1);
        }
    }

    return time;
}








} /* extern "C" */
