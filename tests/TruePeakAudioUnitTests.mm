#import "../audio/TruePeakAudioUnit.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
static void check(bool ok,const char *message) { if(!ok) {fprintf(stderr,"FAIL: %s\n",message);exit(1);} }
int main() { @autoreleasepool {
    for(double rate : {44100.,48000.,96000.,192000.}) {
        AVAudioUnitEffect *node=[OngakuTruePeakAudioUnit makeNode];
        AUAudioUnit *unit=node.AUAudioUnit;
        AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
        NSError *error=nil;
        check([unit.inputBusses[0] setFormat:format error:&error],"input format");
        check([unit.outputBusses[0] setFormat:format error:&error],"output format");
        unit.maximumFramesToRender=512;
        check([unit allocateRenderResourcesAndReturnError:&error],"allocate resources");
        const unsigned delay=unsigned(llround(unit.latency*rate));
        check(delay>=rate*.004 && unit.tailTime==unit.latency,"reported latency/tail");
        AURenderPullInputBlock pull=^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,AUAudioFrameCount count,NSInteger bus,AudioBufferList *data) {
            for(unsigned ch=0;ch<2;++ch) for(unsigned i=0;i<count;++i)
                static_cast<float *>(data->mBuffers[ch].mData)[i]=float(.1*sin((time->mSampleTime+i)*.13))*(ch?-.5f:1.f);
            return noErr;
        };
        auto render=unit.internalRenderBlock;
        for(unsigned position=0;position<8192;position+=127) {
            struct { UInt32 count; AudioBuffer buffers[2]; } raw={2,{{1,0,nullptr},{1,0,nullptr}}};
            auto *data=reinterpret_cast<AudioBufferList *>(&raw);
            AudioTimeStamp time={};time.mSampleTime=position;time.mFlags=kAudioTimeStampSampleTimeValid;
            AudioUnitRenderActionFlags flags=0;
            check(render(&flags,&time,127,0,data,nullptr,pull)==noErr,"null output buffers supported");
            for(unsigned ch=0;ch<2;++ch) for(unsigned i=0;i<127;++i) {
                float expected=position+i<delay?0:float(.1*sin((position+i-delay)*.13))*(ch?-.5f:1.f);
                check(static_cast<float *>(data->mBuffers[ch].mData)[i]==expected,"actual AU quiet PCM exact");
            }
            check(render(&flags,&time,513,0,data,nullptr,pull)==kAudioUnitErr_TooManyFramesToProcess,"reject oversized block");
            check(render(&flags,&time,1,1,data,nullptr,pull)==kAudioUnitErr_InvalidElement,"reject wrong bus");
        }
        [unit reset];
        [unit deallocateRenderResources];
        check([unit allocateRenderResourcesAndReturnError:&error],"resource reallocation");
        [unit deallocateRenderResources];
    }
    puts("PASS: real AU format/resource lifecycle, latency, null buffers, PCM, block and bus errors");
} return 0; }
