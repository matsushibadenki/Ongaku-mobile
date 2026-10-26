#import "../audio/SpectralTransientAudioUnit.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
static void check(bool ok,const char*s){if(!ok){fprintf(stderr,"FAIL: %s\n",s);exit(1);}}
int main(){@autoreleasepool{
 for(double rate:{44100.,48000.,96000.,192000.}) for(unsigned channels:{1u,2u,6u,8u}) {
  AVAudioUnitEffect *node=[OngakuSpectralTransientAudioUnit makeNode];auto *unit=(OngakuSpectralTransientAudioUnit*)node.AUAudioUnit;
  NSError *error=nil;
  AVAudioFormat *format;
  if(channels>2) {
   auto *layout=[[AVAudioChannelLayout alloc]initWithLayoutTag:channels==6?kAudioChannelLayoutTag_MPEG_5_1_A:kAudioChannelLayoutTag_MPEG_7_1_A];
   format=[[AVAudioFormat alloc]initStandardFormatWithSampleRate:rate channelLayout:layout];
  } else format=[[AVAudioFormat alloc]initStandardFormatWithSampleRate:rate channels:channels];
  check(format!=nil,"valid test format");
  if(!([unit.inputBusses[0]setFormat:format error:&error]&&[unit.outputBusses[0]setFormat:format error:&error])) { fprintf(stderr,"format rate=%.0f channels=%u error=%s\n",rate,channels,error.description.UTF8String); fprintf(stderr,"max=%u counts=%s allocated=%d class=%s\n",unit.inputBusses[0].maximumChannelCount,unit.inputBusses[0].supportedChannelCounts.description.UTF8String,unit.renderResourcesAllocated,NSStringFromClass(unit.class).UTF8String); check(false,"formats"); }
  unit.maximumFramesToRender=512;check([unit allocateRenderResourcesAndReturnError:&error],"allocate");
  check(unit.latency==0&&unit.tailTime==.04,"honest zero fixed latency / bounded filter tail");
  AURenderPullInputBlock pull=^AUAudioUnitStatus(AudioUnitRenderActionFlags*f,const AudioTimeStamp*t,AUAudioFrameCount n,NSInteger bus,AudioBufferList*d){
   for(unsigned ch=0;ch<channels;++ch)for(unsigned i=0;i<n;++i)static_cast<float*>(d->mBuffers[ch].mData)[i]=float(.1*sin((t->mSampleTime+i)*.13))*(ch?-.5f:1.f);return noErr;
  };
  auto render=unit.internalRenderBlock;
  for(unsigned position=0;position<4096;position+=127){
   struct{UInt32 count;AudioBuffer buffers[8];} raw={channels,{}};auto *data=reinterpret_cast<AudioBufferList*>(&raw);
   AudioTimeStamp time={};time.mSampleTime=position;time.mFlags=kAudioTimeStampSampleTimeValid;AudioUnitRenderActionFlags flags=0;
   check(render(&flags,&time,127,0,data,nullptr,pull)==noErr,"render null buffers");
   for(unsigned ch=0;ch<channels;++ch)for(unsigned i=0;i<127;++i)check(static_cast<float*>(data->mBuffers[ch].mData)[i]==float(.1*sin((position+i)*.13))*(ch?-.5f:1.f),"OFF exact / no delay");
   check(render(&flags,&time,513,0,data,nullptr,pull)==kAudioUnitErr_TooManyFramesToProcess,"oversized guard");
   check(render(&flags,&time,1,1,data,nullptr,pull)==kAudioUnitErr_InvalidElement,"bus guard");
  }
  [unit setAmount:1];
  struct{UInt32 count;AudioBuffer buffers[8];} raw={channels,{}};auto *data=reinterpret_cast<AudioBufferList*>(&raw);
  AudioTimeStamp time={};time.mFlags=kAudioTimeStampSampleTimeValid;AudioUnitRenderActionFlags flags=0;
  for(unsigned block=0;block<20;++block){time.mSampleTime=4096+block*127;check(render(&flags,&time,127,0,data,nullptr,pull)==noErr,"active render");for(unsigned ch=0;ch<channels;++ch)for(unsigned i=0;i<127;++i)check(std::isfinite(static_cast<float*>(data->mBuffers[ch].mData)[i]),"active finite");}
  [unit setAmount:0];[unit reset];
  AURenderPullInputBlock silence=^AUAudioUnitStatus(AudioUnitRenderActionFlags*f,const AudioTimeStamp*t,AUAudioFrameCount n,NSInteger b,AudioBufferList*d){for(unsigned c=0;c<channels;++c)memset(d->mBuffers[c].mData,0,n*sizeof(float));*f|=kAudioUnitRenderAction_OutputIsSilence;return noErr;};
  for(unsigned block=0;block<20;++block)check(render(&flags,&time,127,0,data,nullptr,silence)==noErr,"reset/silence render");
  for(unsigned ch=0;ch<channels;++ch)for(unsigned i=0;i<127;++i)check(static_cast<float*>(data->mBuffers[ch].mData)[i]==0,"no previous-source history after reset");
  [unit deallocateRenderResources];check([unit allocateRenderResourcesAndReturnError:&error],"reallocate");[unit deallocateRenderResources];
 }
 puts("PASS: real AU mono/stereo/6/8-channel x 4 rates, metadata, OFF PCM, active render, block/bus guards, reset and reallocation");
}return 0;}
