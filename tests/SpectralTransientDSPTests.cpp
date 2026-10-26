#include "../audio/SpectralTransientDSP.hpp"
#include "../audio/TruePeakDSP.hpp"
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <new>
static bool track=false; static unsigned allocations=0;
void *operator new(size_t n) { if(track) ++allocations; if(auto p=std::malloc(n)) return p; throw std::bad_alloc(); }
void operator delete(void *p) noexcept { std::free(p); }
void operator delete(void *p,size_t) noexcept { std::free(p); }
static void check(bool ok,const char *s) { if(!ok) { std::fprintf(stderr,"FAIL: %s\n",s);std::exit(1); } }
static std::vector<float> render(const std::vector<float>& input,double rate,unsigned block,float amount) {
    ongaku::SpectralTransient dsp; check(dsp.prepare(1,rate),"prepare mono"); dsp.setAmount(amount);
    std::vector<float> out(input.size());
    for(unsigned i=0;i<input.size();i+=block) {
        const float *in[]={input.data()+i};float *dst[]={out.data()+i};
        dsp.process(in,dst,std::min(block,unsigned(input.size()-i)));
    }
    return out;
}
static double sinc(double x) { return std::abs(x)<1e-12?1:std::sin(3.141592653589793*x)/(3.141592653589793*x); }
// Independent 16-phase, 96-tap Blackman reconstruction (different detector).
static double reconstructedPeak(const std::vector<float>& x) {
    double peak=0;
    for(unsigned i=64;i+64<x.size();++i) for(unsigned phase=0;phase<16;++phase) {
        double sum=0,norm=0;
        for(int k=-47;k<=48;++k) {
            const double d=double(k)-double(phase)/16;
            const double window=.42+.5*std::cos(3.141592653589793*d/48)+.08*std::cos(2*3.141592653589793*d/48);
            const double weight=sinc(d)*window; sum+=weight*x[i+k];norm+=weight;
        }
        peak=std::max(peak,std::abs(sum/norm));
    }
    return peak;
}
int main() {
    ongaku::SpectralTransient invalid;
    check(!invalid.prepare(0,48000)&&!invalid.prepare(9,48000)&&!invalid.prepare(2,0),"reject bad format");
    for(double rate:{8000.,44100.,48000.,96000.,192000.,384000.}) {
        const unsigned n=unsigned(rate*.12),warm=unsigned(rate*.025);
        std::vector<float> input(n),zero(warm),scratch(warm),left(n),right(n);
        for(unsigned i=0;i<n;++i) input[i]=float(.4*std::sin(i*.37)+.15*std::sin(i*1.17));
        check(render(input,rate,127,0)==input,"default OFF is sample-exact, zero delay");
        const auto single=render(input,rate,1,1),blocks=render(input,rate,511,1);
        check(single==blocks,"partition-invariant DSP and ramp");
        bool changed=false;for(unsigned i=0;i<n;++i) {check(std::isfinite(blocks[i]),"finite");changed|=std::abs(blocks[i]-input[i])>1e-5;}
        check(changed,"actual signal processing, not a label-only effect");
        ongaku::SpectralTransient dsp;dsp.prepare(2,rate);dsp.setAmount(1);
        const float *z[]={zero.data(),zero.data()};float *zs[]={scratch.data(),scratch.data()};dsp.process(z,zs,warm);
        for(unsigned i=0;i<n;++i) right[i]=input[i]*-.5f;
        const float *src[]={input.data(),right.data()};float *dst[]={left.data(),right.data()};
        track=true;dsp.process(src,dst,n);track=false;
        check(allocations==0,"no render allocations");
        for(unsigned i=0;i<n;++i) check(std::abs(right[i]+left[i]*.5f)<1e-7,"stereo-linked gain preserves image");
        std::vector<float> steady(static_cast<size_t>(rate),0.f);
        for(unsigned i=0;i<steady.size();++i) steady[i]=float(.2*std::sin(2*3.141592653589793*std::min(2000.,rate*.2)*i/rate));
        const auto steadyWet=render(steady,rate,127,1);
        double dryEnergy=0,wetEnergy=0;
        for(unsigned i=unsigned(rate*.75);i<steady.size();++i){dryEnergy+=steady[i]*steady[i];wetEnergy+=steadyWet[i]*steadyWet[i];}
        check(std::abs(std::sqrt(wetEnergy/dryEnergy)-1)<.002,"steady tones are not mistaken for sustained attacks");
        // A warmed impulse remains on the same sample; the causal residual decays.
        std::fill(input.begin(),input.end(),0);input[n/2]=1;
        dsp.requestReset();dsp.process(z,zs,warm);
        const float *pulse[]={input.data(),input.data()};dsp.process(pulse,dst,n);
        for(unsigned i=0;i<n/2;++i) check(left[i]==0,"no pre-echo / early output");
        check(left[n/2]>1&&left[n/2]<1.16,"attack at original sample within conservative gain bound");
        check(std::abs(left.back())<1e-8,"short residual drains; no reverb added");
        // Compare switched output with fully wet reference: first control sample
        // must differ by at most the bounded 20 ms ramp step, not a bypass jump.
        ongaku::SpectralTransient reference, switched;reference.prepare(1,rate);switched.prepare(1,rate);
        reference.setAmount(1);switched.setAmount(1);
        const float *zi[]={zero.data()};float *zo[]={scratch.data()};reference.process(zi,zo,warm);switched.process(zi,zo,warm);
        for(unsigned i=0;i<n;++i) input[i]=float(.3*std::exp(-3.*i/n)*std::sin(i*.31+.67));
        std::vector<float> full(n),off(n);const float *in[]={input.data()};float *a[]={full.data()},*b[]={off.data()};
        reference.process(in,a,n);switched.setAmount(0);switched.process(in,b,n);
        check(std::abs(off[0]-full[0])<.0002,"OFF first sample does not jump");
        ongaku::SpectralTransient started;started.prepare(1,rate);started.setAmount(1);
        std::vector<float> on(n);float *onOut[]={on.data()};started.process(in,onOut,n);
        check(std::abs(on[0]-input[0])<.0002,"ON first sample does not jump");
        const unsigned ramp=unsigned(rate*.020);
        for(unsigned i=0;i<n;++i) {
            const double blend=std::min(1.,double(i+1)/ramp);
            check(std::abs(on[i]-(input[i]+blend*(full[i]-input[i])))<1e-6,"ON follows bounded rendered-sample ramp");
            check(std::abs(off[i]-(input[i]+(1-blend)*(full[i]-input[i])))<1e-6,"OFF follows bounded rendered-sample ramp");
        }

        const unsigned end=unsigned(rate*.020)+1;
        for(unsigned i=end;i<n;++i) check(off[i]==input[i],"OFF ramp returns tail to exact dry");
        // Reset while transport is quiescent, then replay equals a fresh warmed processor.
        switched.requestReset();switched.process(zi,zo,warm);switched.setAmount(1);
        ongaku::SpectralTransient fresh;fresh.prepare(1,rate);fresh.setAmount(1);
        switched.process(in,b,n);fresh.process(in,a,n);check(off==full,"stop/reset/restart removes previous history");
    }
    // High-frequency, hot alternating stereo signal through the unchanged final limiter.
    for(double rate:{44100.,48000.,96000.,192000.}) {
        constexpr unsigned n=8192;
        std::vector<float> input(n),enhanced(n),limited(n);
        for(unsigned i=0;i<n;++i) input[i]=float(2.2*std::sin(i*2.43)+.8*std::sin(i*.17));
        ongaku::SpectralTransient transient;transient.prepare(1,rate);transient.setAmount(1);
        for(unsigned offset=0;offset<n;offset+=64) {
            transient.setAmount((offset/512)%3==0?1.f:((offset/512)%3==1?0.f:.2f));
            const float *in[]={input.data()+offset};float *out[]={enhanced.data()+offset};transient.process(in,out,64);
        }
        ongaku::TruePeakLimiter limiter;check(limiter.prepare(1,rate),"limiter prepare");const float *e[]={enhanced.data()};float *l[]={limited.data()};limiter.process(e,l,n);
        double peak=reconstructedPeak(limited);
        check(peak<=std::pow(10.,-1./20),"independent reconstructed peak <= -1 dBTP");
        std::printf("PROTECTED rate=%.0f dBTP=%.4f\n",rate,20*std::log10(peak));
    }
    std::puts("PASS: 6 rates, bypass/latency, partitioning, linking, render allocations, ramp/tail/reset and protected peaks");
}
