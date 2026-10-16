#include "../audio/TruePeakDSP.hpp"
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <new>
static bool countAllocations = false;
static unsigned allocations = 0;
void *operator new(size_t n) { if (countAllocations) ++allocations; if (auto p = std::malloc(n)) return p; throw std::bad_alloc(); }
void operator delete(void *p) noexcept { std::free(p); }
void operator delete(void *p, size_t) noexcept { std::free(p); }
static void check(bool ok, const char *message) { if (!ok) { std::fprintf(stderr,"FAIL: %s\n",message); std::exit(1); } }
static std::vector<std::vector<float>> run(const std::vector<std::vector<float>> &in, double rate, unsigned block) {
    ongaku::TruePeakLimiter dsp;
    check(dsp.prepare(unsigned(in.size()),rate),"prepare");
    std::vector<std::vector<float>> out(in.size(),std::vector<float>(in[0].size()));
    std::array<const float *,8> src{}; std::array<float *,8> dst{};
    for (unsigned offset=0; offset<in[0].size(); offset+=block) {
        const unsigned n=std::min(block,unsigned(in[0].size())-offset);
        for (unsigned ch=0;ch<in.size();++ch) { src[ch]=in[ch].data()+offset;dst[ch]=out[ch].data()+offset; }
        countAllocations=true; dsp.process(src.data(),dst.data(),n); countAllocations=false;
    }
    check(allocations==0,"no allocations during processing");
    return out;
}
int main() {
    ongaku::TruePeakLimiter invalid;
    check(!invalid.prepare(0,48000) && !invalid.prepare(9,48000) && !invalid.prepare(2,0) &&
          !invalid.prepare(2,std::numeric_limits<double>::infinity()),"reject invalid format");
    for (double rate : {44100.,48000.,96000.,192000.}) {
        const unsigned count=unsigned(rate/4);
        std::vector<std::vector<float>> quiet(2,std::vector<float>(count));
        for(unsigned i=0;i<count;++i) { quiet[0][i]=float(.1*std::sin(i*.13));quiet[1][i]=quiet[0][i]*-.5f; }
        auto output=run(quiet,rate,127);
        ongaku::TruePeakLimiter dsp; dsp.prepare(2,rate); const unsigned delay=dsp.latencyFrames();
        for(unsigned ch=0;ch<2;++ch) for(unsigned i=0;i<count;++i)
            check(output[ch][i]==(i<delay?0:quiet[ch][i-delay]),"quiet PCM exact after declared latency");
        auto hot=quiet;
        for(unsigned i=0;i<count;++i) { hot[0][i]*=40;hot[1][i]*=40; }
        const auto singles=run(hot,rate,1), blocks=run(hot,rate,4096);
        check(singles==blocks,"block-size-independent waveform");
        for(unsigned i=0;i<count;++i) {
            check(std::isfinite(blocks[0][i]) && std::abs(blocks[0][i])<1,"finite bounded hot signal");
            check(blocks[1][i]==blocks[0][i]*-.5f,"linked gain preserves stereo ratio");
        }
        std::array<float,512> source{},dest{}; source.fill(4);
        const float *src[]={source.data(),source.data()};float *dst[]={dest.data(),dest.data()};
        dsp.process(src,dst,512); dsp.reset();source.fill(0);dsp.process(src,dst,512);
        for(float x:dest) check(x==0,"reset clears delayed samples and gain");
        source.fill(std::numeric_limits<float>::quiet_NaN());dsp.process(src,dst,512);
        for(float x:dest)check(std::isfinite(x),"nonfinite input sanitized");
    }
    std::puts("PASS: latency-exact quiet PCM, stereo linking, chunk invariance, reset, invalid/nonfinite inputs and zero render allocations");
}
