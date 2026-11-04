#include "MediaBridge.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct { FILE *file; int cancelled; int64_t reads; } Source;
static int read_bytes(void *context,int64_t offset,uint8_t *buffer,int count) {
    Source *s=context; assert(!fseeko(s->file,offset,SEEK_SET));
    int result=(int)fread(buffer,1,count,s->file); s->reads+=result; return result;
}
static int cancelled(void *context) { return ((Source *)context)->cancelled; }
static MediaIO source(Source *s,const char *path) {
    s->file=fopen(path,"rb"); assert(s->file); fseeko(s->file,0,SEEK_END);
    return (MediaIO){s,ftello(s->file),read_bytes,cancelled};
}
int main(int argc,char **argv) {
    assert(argc==6);
    FILE *png=fopen(argv[1],"rb"); assert(png); fseek(png,0,SEEK_END); long length=ftell(png); rewind(png);
    uint8_t *expected=malloc(length); assert(fread(expected,1,length,png)==length); fclose(png);
    uint8_t *output=malloc(8*1024*1024);
    for(int i=2;i<5;i++) {
        Source s={0}; MediaIO io=source(&s,argv[i]);
        int count=media_artwork_io(io,output,8*1024*1024);
        assert(s.reads<=16*1024*1024);
        if(i<4) { assert(count==length); assert(!memcmp(output,expected,length));
            assert(media_artwork_io(io,output,4)<0); }
        else assert(count==0);
        s.cancelled=1; assert(media_artwork_io(io,output,8*1024*1024)<0); fclose(s.file);
    }
    Source huge={0}; MediaIO io=source(&huge,argv[5]);
    assert(media_artwork_io(io,output,8*1024*1024)<0);
    assert(huge.reads<=16*1024*1024); fclose(huge.file);
    free(output); free(expected);
    puts("PASS: MKV attachment and MP4 attached PNG extraction, exact bytes, absent artwork, output/read bounds and cancellation");
}
