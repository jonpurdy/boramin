#include "MediaBridge.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char **argv) { assert(argc==2); MediaInfo info; char error[512];
 MediaReader *r=media_open(argv[1],&info,error,sizeof(error)); assert(r);
 int count=media_keyframes(r,NULL,0); printf("Index entries: %d\n",count); assert(count>2);
 double *times=calloc(count,sizeof(double)); assert(media_keyframes(r,times,count)==count);
 for(int i=0;i<count;i++) { const unsigned char *bytes; int size,key; double pts,duration;
 assert(i==0 || times[i]>times[i-1]); assert(media_seek(r,times[i])>=0);
 assert(media_packet(r,&bytes,&size,&pts,&duration,&key)==1 && key);
 if(fabs(pts-times[i])>0.0001) { printf("Wrong keyframe %d: index %.6f, packet %.6f\n",i,times[i],pts); return 1; }
 }
 for(int j=0;j<3;j++) { double requested=(double[]){90,20,60}[j],best=times[0];
 for(int i=1;i<count;i++) if(fabs(times[i]-requested)<fabs(best-requested))best=times[i];
 printf("Requested %.3f -> nearest indexed keyframe %.6f\n",requested,best); }
 puts("PASS: every indexed keyframe lands on its original compressed key packet"); media_close(r);free(times);}
