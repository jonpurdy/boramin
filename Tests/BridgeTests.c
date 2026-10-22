#include "MediaBridge.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
static int cancel(void *context) { return 1; }
int main(int argc,char **argv) {
    assert(argc==5);
    char error[512]; MediaInfo info;
    assert(!media_open("/missing/not-a-movie",&info,error,sizeof(error)));
    MediaReader *r=media_open(argv[1],&info,error,sizeof(error));
    if(!r) {fprintf(stderr,"%s\n",error);return 1;}
    assert(info.vp9 && info.width==3840 && info.height==2160 && info.bit_depth==10 && info.profile==2);
    assert(info.primaries==9 && info.transfer==16 && info.matrix==9);
    assert(info.level==51 && info.chroma<=1);
    const uint8_t *bytes; int size,key; double pts,duration,last=-1; int count=0;
    FILE *packets=fopen(argv[4],"wb"); assert(packets);
    while(media_packet(r,&bytes,&size,&pts,&duration,&key)==1) {
        assert(size>0 && pts>=last); last=pts; count++;
        if(count==1) {
            MediaInfo parsed={0}; parsed.chroma=1;
            assert(media_vp9_header(bytes,size,&parsed)==1 && parsed.profile==2 && parsed.bit_depth==10);
            assert(parsed.width==3840 && parsed.height==2160);
            for(size_t shortSize=0;shortSize<9;shortSize++) assert(media_vp9_header(bytes,shortSize,&parsed)<0);
            uint8_t bad[16]={0}; assert(media_vp9_header(bad,sizeof(bad),&parsed)<0);
        }
        assert(fwrite(bytes,1,size,packets)==(size_t)size);
    }
    fclose(packets); assert(count==600);
    assert(media_seek(r,5)>=0);
    assert(media_packet(r,&bytes,&size,&pts,&duration,&key)==1 && key && pts<=5.01);
    media_close(r);
    r=media_open(argv[2],&info,error,sizeof(error));
    assert(r && info.vp9 && info.profile==0 && info.bit_depth==8 && info.width==64 && info.height==64);
    assert(media_seek(r,0)>=0);
    assert(media_packet(r,&bytes,&size,&pts,&duration,&key)==1 && key);
    media_close(r);
    assert(media_audio(argv[1],argv[3],NULL,NULL,error,sizeof(error))==0);
    assert(media_audio(argv[2],argv[3],cancel,NULL,error,sizeof(error))<0);
    assert(media_audio(argv[2],argv[3],NULL,NULL,error,sizeof(error))==0);
    FILE *audio=fopen(argv[3],"rb"); assert(audio); char magic[4]; assert(fread(magic,1,4,audio)==4 && !memcmp(magic,"caff",4)); fclose(audio);
    puts("PASS: VP9 metadata, 600 packets, keyframe seek, missing input, CAF silence/audio and cancellation");
}
