#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif
#import "../audio/SpectralTransientAudioUnit.h"
#include <mach/mach.h>
#include <time.h>
#include <vector>
#include <cmath>
#include <cstring>
#include <stdexcept>
static double clockMS(clockid_t which){timespec t{};if(clock_gettime(which,&t))throw std::runtime_error("clock");return t.tv_sec*1000.+t.tv_nsec/1e6;}
static uint64_t rss(){mach_task_basic_info_data_t info{};mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;if(task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&info,&count)!=KERN_SUCCESS)throw std::runtime_error("rss");return info.resident_size;}
static void require(bool ok,const char *message){if(!ok)throw std::runtime_error(message);}
static float amount(NSString *mode){return [mode isEqual:@"max"]?1.f:([mode isEqual:@"default"]?.2f:0.f);}
static NSDictionary *graph(NSString *mode,double rate){@autoreleasepool{
 const auto memoryBefore=rss();const double begin=clockMS(CLOCK_MONOTONIC),cpuBegin=clockMS(CLOCK_PROCESS_CPUTIME_ID);
 auto *engine=[AVAudioEngine new];auto *player=[AVAudioPlayerNode new];[engine attachNode:player];
 auto *format=[[AVAudioFormat alloc]initStandardFormatWithSampleRate:rate channels:2];
 AVAudioUnitEffect *node=nil;double factory=0;
 if(![mode isEqual:@"bare"]){const double t=clockMS(CLOCK_MONOTONIC);node=[OngakuSpectralTransientAudioUnit makeNode];factory=clockMS(CLOCK_MONOTONIC)-t;[engine attachNode:node];[(OngakuSpectralTransientAudioUnit*)node.AUAudioUnit setAmount:amount(mode)];[engine connect:player to:node format:format];[engine connect:node to:engine.mainMixerNode format:format];}
 else [engine connect:player to:engine.mainMixerNode format:format];
 NSError *error=nil;require([engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:format maximumFrameCount:512 error:&error],"manual mode");
 auto *source=[[AVAudioPCMBuffer alloc]initWithPCMFormat:format frameCapacity:512];source.frameLength=512;
 for(unsigned i=0;i<512;++i){source.floatChannelData[0][i]=float(.1*sin(i*.13+.3)+.025*sin(i*.87));source.floatChannelData[1][i]=source.floatChannelData[0][i]*-.5f;}
 [player scheduleBuffer:source atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
 require([engine startAndReturnError:&error],"start");[player play];
 const double ready=clockMS(CLOCK_MONOTONIC)-begin,readyCPU=clockMS(CLOCK_PROCESS_CPUTIME_ID)-cpuBegin;
 auto *output=[[AVAudioPCMBuffer alloc]initWithPCMFormat:format frameCapacity:512];
 auto render=[&](){const auto result=[engine renderOffline:512 toBuffer:output error:&error];require(result==AVAudioEngineManualRenderingStatusSuccess,"render success");};
 render();const double first=clockMS(CLOCK_MONOTONIC)-begin;
 require(output.frameLength==512&&std::isfinite(output.floatChannelData[0][100])&&std::abs(output.floatChannelData[0][100])>.00001,"actual first PCM");
 for(unsigned i=0;i<64;++i)render();
 const double start=clockMS(CLOCK_MONOTONIC),cpuStart=clockMS(CLOCK_PROCESS_CPUTIME_ID);
 double checksum=0;constexpr unsigned blocks=2000;
 for(unsigned i=0;i<blocks;++i){render();checksum+=output.floatChannelData[0][i%512];}
 const double elapsed=clockMS(CLOCK_MONOTONIC)-start,cpu=clockMS(CLOCK_PROCESS_CPUTIME_ID)-cpuStart;const auto memory=rss();
 [player stop];[engine stop];
 return @{ @"mode":mode,@"rate":@(rate),@"factoryMS":@(factory),@"readyMS":@(ready),@"readyCPUms":@(readyCPU),@"firstPCMms":@(first),@"renderWallMS":@(elapsed),@"renderCPUms":@(cpu),@"blocks":@(blocks),@"frames":@(blocks*512),@"virtualSeconds":@(blocks*512/rate),@"rssBefore":@(memoryBefore),@"rssReady":@(memory),@"checksum":@(checksum)};
}}
static void comparison(NSString *mode,NSString *fixtures,NSString *destination){
 auto *fm=NSFileManager.defaultManager;NSError *error=nil;require([fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:&error],"PCM directory");
 for(NSString *file in [fm contentsOfDirectoryAtPath:fixtures error:&error]){@autoreleasepool{
  if(![file.pathExtension isEqual:@"f32"])continue;
  NSArray *parts=[file.stringByDeletingPathExtension componentsSeparatedByString:@"-"];const double rate=[parts.lastObject doubleValue];
  NSData *data=[NSData dataWithContentsOfFile:[fixtures stringByAppendingPathComponent:file]];require(data.length%8==0&&data.length>0,"input PCM");
  const unsigned frames=unsigned(data.length/8);std::vector<float> input(frames*2),result(frames*2);memcpy(input.data(),data.bytes,data.length);
  if([mode isEqual:@"bare"])result=input;
  else {
   auto *node=[OngakuSpectralTransientAudioUnit makeNode];auto *unit=(OngakuSpectralTransientAudioUnit*)node.AUAudioUnit;auto *format=[[AVAudioFormat alloc]initStandardFormatWithSampleRate:rate channels:2];
   require([unit.inputBusses[0]setFormat:format error:&error]&&[unit.outputBusses[0]setFormat:format error:&error],"comparison format");unit.maximumFramesToRender=512;[unit setAmount:amount(mode)];require([unit allocateRenderResourcesAndReturnError:&error],"comparison allocate");
   const float *samples=input.data();AURenderPullInputBlock pull=^AUAudioUnitStatus(AudioUnitRenderActionFlags*f,const AudioTimeStamp*t,AUAudioFrameCount n,NSInteger b,AudioBufferList*d){const int64_t position=int64_t(t->mSampleTime);for(unsigned ch=0;ch<2;++ch)for(unsigned i=0;i<n;++i)static_cast<float*>(d->mBuffers[ch].mData)[i]=(position<0)?0:samples[(position+i)*2+ch];return noErr;};
   float l[512]{},r[512]{};struct{UInt32 count;AudioBuffer buffers[2];}raw={2,{{1,0,l},{1,0,r}}};auto *list=reinterpret_cast<AudioBufferList*>(&raw);auto render=unit.internalRenderBlock;
   for(int64_t offset=-int64_t(std::ceil(rate*.05/512)*512);offset<int64_t(frames);offset+=512){unsigned n=offset<0?512:std::min(512u,frames-unsigned(offset));raw.buffers[0].mDataByteSize=raw.buffers[1].mDataByteSize=n*4;AudioTimeStamp time{};time.mFlags=kAudioTimeStampSampleTimeValid;time.mSampleTime=offset;AudioUnitRenderActionFlags flags=0;require(render(&flags,&time,n,0,list,nullptr,pull)==noErr,"comparison render");if(offset>=0)for(unsigned i=0;i<n;++i){result[(offset+i)*2]=l[i];result[(offset+i)*2+1]=r[i];}}
   [unit deallocateRenderResources];
  }
  for(float value:result)require(std::isfinite(value),"finite comparison");
  NSString *name=[NSString stringWithFormat:@"%@-%@",mode,file];require([[NSData dataWithBytes:result.data() length:result.size()*4]writeToFile:[destination stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:&error],"PCM write");
 }}
}
static void run(NSString *mode,NSString *output,NSString *fixtures,bool pcm){
 require([@[@"bare",@"off",@"default",@"max"]containsObject:mode],"known mode");
 NSMutableArray *rows=[NSMutableArray new];for(double rate:{44100.,48000.,96000.,192000.}){[rows addObject:graph(mode,rate)];usleep(50000);}
 if(pcm)comparison(mode,fixtures,[output stringByAppendingPathComponent:@"pcm"]);
 NSError *error=nil;NSData *json=[NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:&error];
 require([json writeToFile:[output stringByAppendingPathComponent:@"result.json"] options:NSDataWritingAtomic error:&error],"result write");
 require([@"COMPLETE" writeToFile:[output stringByAppendingPathComponent:@"status.txt"] atomically:YES encoding:NSUTF8StringEncoding error:&error],"status write");
 puts("COMPLETE");fflush(stdout);
}
#if TARGET_OS_IOS
@interface AuditSceneDelegate : UIResponder<UIWindowSceneDelegate>
@property(strong,nonatomic) UIWindow *window;
@end
@implementation AuditSceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
 self.window=[[UIWindow alloc]initWithWindowScene:(UIWindowScene*)scene];self.window.rootViewController=[UIViewController new];self.window.rootViewController.view.backgroundColor=UIColor.systemBackgroundColor;[self.window makeKeyAndVisible];
 NSArray *args=NSProcessInfo.processInfo.arguments;NSString *mode=args.count>1?args[1]:@"off";bool pcm=[args containsObject:@"pcm"];
 NSString *output=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_MSEC*200),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{try{run(mode,output,[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"fixtures"],pcm);}catch(const std::exception&e){NSString *message=[NSString stringWithFormat:@"FAIL: %s",e.what()];[message writeToFile:[output stringByAppendingPathComponent:@"status.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nullptr];}}});
}
@end
@interface AuditDelegate : UIResponder<UIApplicationDelegate>
@end
@implementation AuditDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options { return YES; }
@end
int main(int argc,char**argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(AuditDelegate.class));}}
#else
int main(int argc,char**argv){@autoreleasepool{try{require(argc>=4,"mode output fixtures [pcm]");run(@(argv[1]),@(argv[2]),@(argv[3]),argc>4);}catch(const std::exception&e){fprintf(stderr,"FAIL: %s\n",e.what());return 1;}}return 0;}
#endif
