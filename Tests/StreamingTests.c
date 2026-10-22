#include "MediaBridge.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <math.h>
typedef struct { FILE *file; int cancelled; int64_t bytes; } TestSource;
static int read_at(void *context,int64_t offset,uint8_t *output,int count) {
    TestSource *s=context; int result=(int)pread(fileno(s->file),output,count,offset);
    if(result>0)s->bytes+=result;return result;
}
static int cancelled(void *context) {return ((TestSource*)context)->cancelled;}
static MediaIO input(TestSource *source,const char *path) {
    source->file=fopen(path,"rb");assert(source->file);struct stat st;assert(fstat(fileno(source->file),&st)==0);
    return (MediaIO){source,st.st_size,read_at,cancelled};
}
int main(int argc,char **argv) {
    assert(argc==4);char error[512];MediaInfo info;
    TestSource video={0};MediaIO io=input(&video,argv[1]);
    MediaReader *r=media_open_io(io,&info,error,sizeof(error));assert(r && info.bit_depth==10 && info.profile==2);
    assert(video.bytes<io.size); // Startup must not require reading the whole fixture.
    const uint8_t *bytes;int size,key;double pts,duration;
    assert(media_packet(r,&bytes,&size,&pts,&duration,&key)==1 && key);
    assert(media_seek(r,5)>=0);assert(media_packet(r,&bytes,&size,&pts,&duration,&key)==1 && key && pts<=5.01);
    video.cancelled=1;assert(media_seek(r,0)<0);media_close(r);fclose(video.file);
    TestSource audio={0};io=input(&audio,argv[2]);
    r=media_open_io(io,&info,error,sizeof(error));assert(r);double audioDuration=info.duration;media_close(r);
    MediaPCMReader *pcm=media_pcm_open(io,audioDuration,error,sizeof(error));
    if(!pcm){fprintf(stderr,"PCM open: %s\n",error);return 1;}
    uint8_t header[68];int64_t length=media_caf_header(audioDuration,header);assert(length>68);
    FILE *reference=fopen(argv[3],"rb");assert(reference);uint8_t actual[8192],expected[8192];
    assert(fread(expected,1,68,reference)==68 && !memcmp(header,expected,68));
    int64_t frame=0;
    while(frame<(length-68)/4) {
        int count=media_pcm_read(pcm,frame,2048,actual);assert(count>0);
        assert(fread(expected,1,count,reference)==(size_t)count);
        assert(!memcmp(actual,expected,count));frame+=count/4;
    }
    // Backward/forward random reads must produce the requested timeline, not the previous cursor.
    for(int i=0;i<3;i++) {
        int64_t target=(int64_t[]){48000,12000,72000}[i];
        int count=media_pcm_read(pcm,target,1024,actual);assert(count==4096);
        assert(fseeko(reference,68+(target-48)*4,SEEK_SET)==0);assert(fread(expected,1,count+96*4,reference)==(size_t)(count+96*4));
        // Matroska timestamps are quantized to milliseconds. Allow that precision after
        // a seek, while checking sample content and Opus convergence against the full reference.
        double best=1e30;int alignment=0;
        for(int shift=-48;shift<=48;shift++) {
            double errorSum=0;
            for(int j=0;j<count/2;j++){int16_t a,b;memcpy(&a,actual+j*2,2);memcpy(&b,expected+(shift+48)*4+j*2,2);errorSum+=(a-b)*(double)(a-b);}
            double rms=sqrt(errorSum/(count/2));if(rms<best){best=rms;alignment=shift;}
        }
        printf("Audio seek %.3fs: RMS %.3f, alignment %d samples (<=1ms)\n",target/48000.0,best,alignment);assert(best<20);
    }
    audio.cancelled=1;assert(media_pcm_read(pcm,0,100,actual)<0);
    media_pcm_close(pcm);fclose(reference);fclose(audio.file);
    puts("PASS: custom range IO, partial-file startup, video seek, exact sequential PCM, random audio seek and cancellation");
}
