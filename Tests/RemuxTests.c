// Host fixture test for the experimental, bounded VP9/AAC segment copier.
#include "MediaBridge.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc,char **argv) {
    assert(argc==3);
    MediaInfo info; char error[512];
    MediaReader *reader=media_open(argv[1],&info,error,sizeof(error));
    if(!reader) { fprintf(stderr,"%s\n",error); return 1; }
    int count=media_keyframes(reader,NULL,0); assert(count>2);
    double *times=calloc(count+1,sizeof(double));
    assert(media_keyframes(reader,times,count)==count); times[count]=info.duration; times[0]=0;
    uint8_t *header=NULL; int header_count=0;
    // Generate distant segments first, then the complete sequence; no prior remux required.
    for(int step=-2;step<count;step++) {
        int index=step==-2?count-2:step==-1?1:step;
        uint8_t *bytes=NULL; int size=0,init=0;
        int status=media_remux_fragment(reader,&info,times[index],times[index+1],index+1,&bytes,&size,&init,error,sizeof(error));
        if(status<0) { fprintf(stderr,"segment %d: %s\n",index,error); return 2; }
        assert(init>0 && size>init && size<=32*1024*1024);
        if(!header) { header=malloc(init); memcpy(header,bytes,init); header_count=init; }
        assert(init==header_count && !memcmp(header,bytes,init));
        if(step>=0) {
            char path[4096]; snprintf(path,sizeof(path),"%s/segment%d.mp4",argv[2],index);
            FILE *out=fopen(path,"wb"); assert(out); assert(fwrite(bytes,1,size,out)==size); fclose(out);
            snprintf(path,sizeof(path),"%s/stream.mp4",argv[2]);
            out=fopen(path,index==0?"wb":"ab"); assert(out);
            if(index==0) assert(fwrite(bytes,1,init,out)==init);
            assert(fwrite(bytes+init,1,size-init,out)==size-init); fclose(out);
        }
        media_remux_free(bytes);
    }
    uint8_t *oversized=NULL; int size=0,init=0;
    assert(media_remux_fragment(reader,&info,0,info.duration,1,&oversized,&size,&init,error,sizeof(error))<0);
    assert(!oversized);
    puts("PASS: oversized fragment rejected before unbounded mux staging");
    free(header); free(times); media_close(reader);
    puts("PASS: independently sought VP9 fragments, stable init, bounded output");
}
