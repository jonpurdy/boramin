#include "MediaBridge.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/pixdesc.h>
#include <libavutil/mastering_display_metadata.h>
#include <libswresample/swresample.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

typedef struct { MediaIO source; AVIOContext *avio; int64_t offset, bytes_read, read_limit; } InputIO;
struct MediaReader { AVFormatContext *format; AVPacket *packet; InputIO *io; int video, prefetched; double origin; };
static int fail(int status, char *error, size_t n) { av_strerror(status, error, n); return status; }
static void be16(uint8_t *p, unsigned v) { p[0]=v>>8; p[1]=v; }
static void be32(uint8_t *p, uint32_t v) { for(int i=0;i<4;i++) p[i]=v>>(24-8*i); }
static void be64(uint8_t *p, uint64_t v) { for(int i=0;i<8;i++) p[i]=v>>(56-8*i); }

static int input_cancelled(void *context) {
    InputIO *io=context; return io->source.cancelled && io->source.cancelled(io->source.context);
}
static int input_read(void *context,uint8_t *buffer,int count) {
    InputIO *io=context;
    if(input_cancelled(io)) return AVERROR_EXIT;
    if(io->read_limit && io->bytes_read>=io->read_limit) return AVERROR(EIO);
    if(io->offset>=io->source.size) return AVERROR_EOF;
    count=(int)FFMIN(count,io->source.size-io->offset);
    if(io->read_limit)count=(int)FFMIN(count,io->read_limit-io->bytes_read);
    int result=io->source.read(io->source.context,io->offset,buffer,count);
    if(result<0) return AVERROR(EIO);
    if(result==0) return AVERROR_EOF;
    if(result>count) return AVERROR_INVALIDDATA;
    io->offset+=result; io->bytes_read+=result; return result;
}
static int64_t input_seek(void *context,int64_t offset,int whence) {
    InputIO *io=context;
    if(input_cancelled(io)) return AVERROR_EXIT;
    if(whence&AVSEEK_SIZE) return io->source.size;
    whence&=~AVSEEK_FORCE;
    int64_t base=whence==SEEK_SET?0:whence==SEEK_CUR?io->offset:whence==SEEK_END?io->source.size:-1;
    if(base<0 || offset< -base || offset>io->source.size-base) return AVERROR(EINVAL);
    io->offset=base+offset; return io->offset;
}
static void input_close(InputIO **input) {
    if(!*input) return;
    if((*input)->avio) { av_freep(&(*input)->avio->buffer); avio_context_free(&(*input)->avio); }
    av_freep(input);
}
static int input_open(const char *path,const MediaIO *source,AVFormatContext **format,InputIO **input) {
    *format=avformat_alloc_context();
    if(!*format)return AVERROR(ENOMEM);
    (*format)->probesize=1024*1024;
    (*format)->max_analyze_duration=AV_TIME_BASE;
    if(source) {
        if(!source->read || source->size<=0) return AVERROR(EINVAL);
        *input=av_mallocz(sizeof(InputIO));
        if(!*input || !*format) return AVERROR(ENOMEM);
        (*input)->source=*source;
        uint8_t *buffer=av_malloc(65536); if(!buffer) return AVERROR(ENOMEM);
        (*input)->avio=avio_alloc_context(buffer,65536,0,*input,input_read,NULL,input_seek);
        if(!(*input)->avio) { av_free(buffer); return AVERROR(ENOMEM); }
        (*format)->pb=(*input)->avio; (*format)->flags|=AVFMT_FLAG_CUSTOM_IO;
        (*format)->interrupt_callback=(AVIOInterruptCB){input_cancelled,*input};
    }
    return avformat_open_input(format,path,NULL,NULL);
}

typedef struct { const uint8_t *bytes; size_t count, bit; int error; } HeaderBits;
static unsigned bits(HeaderBits *b, unsigned n) {
    if(n>32 || b->bit>b->count*8 || n>b->count*8-b->bit) { b->error=1; return 0; }
    unsigned value=0;
    while(n--) { value=(value<<1)|((b->bytes[b->bit/8]>>(7-b->bit%8))&1); b->bit++; }
    return value;
}
int media_vp9_header(const uint8_t *bytes,size_t count,MediaInfo *info) {
    if(!bytes || !info || count<1 || count>SIZE_MAX/8) return AVERROR_INVALIDDATA;
    HeaderBits b={bytes,count,0,0};
    if(bits(&b,2)!=2) return AVERROR_INVALIDDATA;
    int profile=bits(&b,1); profile|=bits(&b,1)<<1;
    if(profile==3 && bits(&b,1)) return AVERROR_INVALIDDATA;
    if(bits(&b,1)) return b.error?AVERROR_INVALIDDATA:0; // show existing frame
    int inter=bits(&b,1); bits(&b,1); bits(&b,1); // show_frame, error_resilient_mode
    if(b.error) return AVERROR_INVALIDDATA;
    if(inter) return 0;
    if(bits(&b,24)!=0x498342 || b.error) return AVERROR_INVALIDDATA;
    int depth=profile>=2?(bits(&b,1)?12:10):8;
    int color=bits(&b,3), full=1, subx=0, suby=0;
    if(color==6) return AVERROR_INVALIDDATA; // reserved color space
    if(color!=7) {
        full=bits(&b,1);
        if(profile==1 || profile==3) { subx=bits(&b,1); suby=bits(&b,1); if(bits(&b,1)) return AVERROR_INVALIDDATA; }
        else { subx=1; suby=1; }
    } else {
        if(profile!=1 && profile!=3) return AVERROR_INVALIDDATA;
        if(bits(&b,1)) return AVERROR_INVALIDDATA;
    }
    int width=bits(&b,16)+1, height=bits(&b,16)+1;
    if(b.error || (!subx && suby)) return AVERROR_INVALIDDATA;
    info->profile=profile; info->bit_depth=depth; info->width=width; info->height=height; info->full_range=full;
    // Preserve container chroma siting for 4:2:0; its default follows FFmpeg's vpcC mapping.
    info->chroma=subx?(suby?(info->chroma==0?0:1):2):3;
    if(info->matrix==AVCOL_SPC_UNSPECIFIED) {
        static const int matrices[]={2,6,1,6,7,9,2,0}; info->matrix=matrices[color];
    }
    return 1;
}
static int vp9_level(const MediaInfo *info) {
    // Same picture-size/sample-rate approximation used by FFmpeg's vpcC writer.
    static const struct { int level; double rate, size; } levels[]={
        {10,829440,36864},{11,2764800,73728},{20,4608000,122880},{21,9216000,245760},
        {30,20736000,552960},{31,36864000,983040},{40,83558400,2228224},{41,160432128,2228224},
        {50,311951360,8912896},{51,588251136,8912896},{52,1176502272,8912896},
        {60,1176502272,35651584},{61,2353004544.0,35651584},{62,4706009088.0,35651584}};
    double size=(double)info->width*info->height, rate=size*info->frame_rate;
    for(size_t i=0;i<sizeof(levels)/sizeof(levels[0]);i++) if(size<=levels[i].size && rate<=levels[i].rate) return levels[i].level;
    return 0;
}

static uint32_t native_video_type(const AVCodecParameters *p) {
    switch(p->codec_id) {
        case AV_CODEC_ID_VP9: return MKBETAG('v','p','0','9');
        case AV_CODEC_ID_H264: return MKBETAG('a','v','c','1');
        case AV_CODEC_ID_HEVC: return MKBETAG('h','v','c','1');
        case AV_CODEC_ID_AV1: return MKBETAG('a','v','0','1');
        case AV_CODEC_ID_VP8: return MKBETAG('v','p','0','8');
        case AV_CODEC_ID_MPEG4: return MKBETAG('m','p','4','v');
        case AV_CODEC_ID_MPEG2VIDEO: return MKBETAG('m','p','2','v');
        case AV_CODEC_ID_MJPEG: return MKBETAG('j','p','e','g');
        case AV_CODEC_ID_PRORES: {
            static const uint32_t types[]={MKBETAG('a','p','c','o'),MKBETAG('a','p','c','s'),MKBETAG('a','p','c','n'),MKBETAG('a','p','c','h'),MKBETAG('a','p','4','h'),MKBETAG('a','p','4','x')};
            return p->profile>=0 && p->profile<6?types[p->profile]:0;
        }
        default: {
            // Reuse the standard QuickTime codec tags for other native formats.
            // CoreMedia/VideoToolbox still validate support on the actual device.
            const struct AVCodecTag *tags[]={avformat_get_mov_video_tags(),NULL};
            uint32_t tag=av_codec_get_tag(tags,p->codec_id);
            return ((tag&255)<<24)|((tag&65280)<<8)|((tag>>8)&65280)|(tag>>24);
        }
    }
}

static MediaReader *open_reader(const char *path,const MediaIO *source,MediaInfo *info,char *error,size_t n) {
    MediaReader *r=calloc(1,sizeof(*r)); int status;
    if(!r) { fail(AVERROR(ENOMEM),error,n); return NULL; }
    if((status=input_open(path,source,&r->format,&r->io))<0) goto bad;
    // Stream probing must not use a software video decoder, including in Mac control tests.
    r->format->codec_whitelist=av_strdup("opus,vorbis,aac,ac3,eac3,flac,mp3,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,alac,dca");
    if(!r->format->codec_whitelist) { status=AVERROR(ENOMEM); goto bad; }
    if((status=avformat_find_stream_info(r->format,NULL))<0) goto bad;
    r->video=av_find_best_stream(r->format,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0);
    if(r->video<0) { status=r->video; goto bad; }
    AVStream *s=r->format->streams[r->video]; AVCodecParameters *p=s->codecpar;
    memset(info,0,sizeof(*info));
    info->vp9=p->codec_id==AV_CODEC_ID_VP9; info->width=p->width; info->height=p->height;
    info->codec_type=native_video_type(p);
    const AVPixFmtDescriptor *pix=av_pix_fmt_desc_get(p->format);
    info->bit_depth=pix?pix->comp[0].depth:0; info->profile=p->profile;
    info->chroma=p->chroma_location==AVCHROMA_LOC_LEFT?0:1;
    info->primaries=p->color_primaries; info->transfer=p->color_trc; info->matrix=p->color_space;
    info->full_range=p->color_range==AVCOL_RANGE_JPEG;
    info->frame_rate=av_q2d(av_guess_frame_rate(r->format,s,NULL));
    if(!isfinite(info->frame_rate) || info->frame_rate<0) info->frame_rate=0;
    info->duration=r->format->duration==AV_NOPTS_VALUE?0:r->format->duration/(double)AV_TIME_BASE;
    r->origin=r->format->start_time==AV_NOPTS_VALUE?0:r->format->start_time/(double)AV_TIME_BASE;
    const AVPacketSideData *sd=av_packet_side_data_get(p->coded_side_data,p->nb_coded_side_data,AV_PKT_DATA_MASTERING_DISPLAY_METADATA);
    if(sd && sd->size>=sizeof(AVMasteringDisplayMetadata)) {
        const AVMasteringDisplayMetadata *m=(const void*)sd->data;
        if(m->has_primaries && m->has_luminance) {
            // CoreMedia uses G,B,R order; FFmpeg stores R,G,B.
            int order[]={1,2,0};
            for(int i=0;i<3;i++) for(int j=0;j<2;j++) be16(info->mastering+4*i+2*j,(uint32_t)lround(av_q2d(m->display_primaries[order[i]][j])*50000));
            for(int j=0;j<2;j++) be16(info->mastering+12+2*j,(uint32_t)lround(av_q2d(m->white_point[j])*50000));
            be32(info->mastering+16,(uint32_t)lround(av_q2d(m->max_luminance)*10000));
            be32(info->mastering+20,(uint32_t)lround(av_q2d(m->min_luminance)*10000)); info->has_mastering=1;
        }
    }
    sd=av_packet_side_data_get(p->coded_side_data,p->nb_coded_side_data,AV_PKT_DATA_CONTENT_LIGHT_LEVEL);
    if(sd && sd->size>=sizeof(AVContentLightMetadata)) { const AVContentLightMetadata *m=(const void*)sd->data;
        be16(info->light,m->MaxCLL); be16(info->light+2,m->MaxFALL); info->has_light=1; }
    r->packet=av_packet_alloc(); if(!r->packet) { status=AVERROR(ENOMEM); goto bad; }
    if(info->vp9) {
        // Minimal tvOS FFmpeg has no VP9 pixel decoder. Its parser reports profile,
        // but not bit depth/pixel format. Read the original keyframe header instead.
        int packets=0, found=0;
        while((status=av_read_frame(r->format,r->packet))>=0) {
            if(r->packet->stream_index==r->video) {
                int parsed=media_vp9_header(r->packet->data,r->packet->size,info);
                if(parsed<0) { status=parsed; goto bad; }
                if(parsed==1) { r->prefetched=1; found=1; break; }
                if(++packets>512) { status=AVERROR_INVALIDDATA; goto bad; }
            }
            av_packet_unref(r->packet);
        }
        if(!found) { status=AVERROR_INVALIDDATA; goto bad; }
        info->level=p->level>0?p->level:vp9_level(info);
    }
    return r;
bad: fail(status,error,n); media_close(r); return NULL;
}
MediaReader *media_open(const char *path,MediaInfo *info,char *error,size_t n) { return open_reader(path,NULL,info,error,n); }
MediaReader *media_open_io(MediaIO io,MediaInfo *info,char *error,size_t n) { return open_reader(NULL,&io,info,error,n); }
void media_close(MediaReader *r) { if(!r)return; av_packet_free(&r->packet); avformat_close_input(&r->format); input_close(&r->io); free(r); }
int media_video_configuration(MediaReader *r,const uint8_t **bytes) {
    if(!r || !bytes) return AVERROR(EINVAL);
    AVCodecParameters *p=r->format->streams[r->video]->codecpar;
    if(p->extradata_size<0 || p->extradata_size>8*1024*1024) return AVERROR_INVALIDDATA;
    *bytes=p->extradata; return p->extradata_size;
}
double media_packet_dts(MediaReader *r) {
    if(!r || r->packet->dts==AV_NOPTS_VALUE) return NAN;
    return r->packet->dts*av_q2d(r->format->streams[r->video]->time_base)-r->origin;
}
int media_seek(MediaReader *r,double seconds) {
    if(r->io && input_cancelled(r->io))return AVERROR_EXIT;
    int status=av_seek_frame(r->format,r->video,llround((seconds+r->origin)/av_q2d(r->format->streams[r->video]->time_base)),AVSEEK_FLAG_BACKWARD);
    if(status>=0) { avformat_flush(r->format); r->prefetched=0; } return status;
}
int media_keyframes(MediaReader *r,double *times,int capacity) {
    if(!r || r->video<0)return 0;
    AVStream *s=r->format->streams[r->video];
    if(!times) {
        // Matroska defers parsing Cues until the first seek. Bound discovery so
        // a file without a useful index cannot turn startup into a movie scan.
        if(r->io)r->io->read_limit=r->io->bytes_read+4*1024*1024;
        int status=media_seek(r,0);
        if(r->io)r->io->read_limit=0;
        if(status<0)return 0;
    }
    int entries=avformat_index_get_entries_count(s), count=0;
    double first=-1,last=-1,gap=0,tb=av_q2d(s->time_base);
    for(int i=0;i<entries;i++) {
        const AVIndexEntry *entry=avformat_index_get_entry(s,i);
        if(!(entry->flags&AVINDEX_KEYFRAME) || entry->timestamp==AV_NOPTS_VALUE)continue;
        double time=entry->timestamp*tb-r->origin;
        if(time<0 || time<=last)continue;
        if(first<0)first=time;
        if(last>=0)gap=fmax(gap,time-last);
        last=time;
        if(times && count<capacity)times[count]=time;
        count++;
    }
    // A partial probe index must not snap every later seek back to its beginning.
    double duration=r->format->duration/(double)AV_TIME_BASE;
    if(count<2 || first>5 || !isfinite(duration) || duration<=0 || last<duration-fmax(5,2*gap))return 0;
    return count;
}
int media_packet(MediaReader *r,const uint8_t **bytes,int *count,double *pts,double *duration,int *key) {
    if(r->io && input_cancelled(r->io))return AVERROR_EXIT;
    int status;
    if(!r->prefetched) av_packet_unref(r->packet);
    while(r->prefetched || (status=av_read_frame(r->format,r->packet))>=0) {
        r->prefetched=0;
        if(r->packet->stream_index!=r->video) { av_packet_unref(r->packet); continue; }
        if(r->packet->pts==AV_NOPTS_VALUE) return AVERROR_INVALIDDATA;
        double tb=av_q2d(r->format->streams[r->video]->time_base);
        *bytes=r->packet->data; *count=r->packet->size; *pts=r->packet->pts*tb-r->origin;
        *duration=r->packet->duration*tb; *key=!!(r->packet->flags&AV_PKT_FLAG_KEY); return 1;
    }
    return status==AVERROR_EOF?0:status;
}

// CAF, 48 kHz stereo signed packed little-endian PCM. 64-bit lengths avoid WAV's 4 GiB limit.
static void caf_bytes(uint8_t *h,int64_t frames) {
    memset(h,0,68); memcpy(h,"caff",4); h[5]=1; memcpy(h+8,"desc",4); be64(h+12,32);
    double rate=48000; uint64_t bits; memcpy(&bits,&rate,8); be64(h+20,bits); memcpy(h+28,"lpcm",4);
    be32(h+32,2); be32(h+36,4); be32(h+40,1); be32(h+44,2); be32(h+48,16);
    memcpy(h+52,"data",4); be64(h+56,(uint64_t)frames*4+4);
}
int64_t media_caf_header(double duration,uint8_t *header) {
    if(!isfinite(duration) || duration<=0 || duration>(INT64_MAX-68)/192000.0) return -1;
    int64_t frames=(int64_t)ceil(duration*48000);
    caf_bytes(header,frames); return 68+frames*4;
}
static int caf_header(FILE *f,int64_t frames) {
    uint8_t h[68]; caf_bytes(h,frames);
    return fwrite(h,1,68,f)==68?0:AVERROR(EIO);
}
int media_audio(const char *input,const char *output,int (*cancel)(void*),void *context,char *error,size_t n) {
    AVFormatContext *f=NULL; AVCodecContext *decoder=NULL; SwrContext *swr=NULL;
    AVFrame *frame=av_frame_alloc(); AVPacket *packet=av_packet_alloc(); FILE *out=NULL;
    int status=0, index; int64_t written=0; uint8_t *pcm=NULL; unsigned pcm_capacity=0;
    const AVCodec *codec=NULL;
    if(!frame || !packet) { status=AVERROR(ENOMEM); goto end; }
    if((status=avformat_open_input(&f,input,NULL,NULL))<0 || (status=avformat_find_stream_info(f,NULL))<0) goto end;
    out=fopen(output,"wb+"); if(!out) { status=AVERROR(errno); goto end; }
    if((status=caf_header(out,0))<0) goto end;
    index=av_find_best_stream(f,AVMEDIA_TYPE_AUDIO,-1,-1,&codec,0);
    if(index==AVERROR_STREAM_NOT_FOUND) {
        if(f->duration<=0 || f->duration==AV_NOPTS_VALUE) { status=AVERROR_INVALIDDATA; goto end; }
        written=(int64_t)ceil(f->duration/(double)AV_TIME_BASE*48000);
        if(fseeko(out,68+written*4-1,SEEK_SET) || fputc(0,out)==EOF) { status=AVERROR(EIO); goto end; }
    } else {
        if(index<0) { status=index; goto end; }
        AVStream *s=f->streams[index];
        if(!codec) { status=AVERROR_DECODER_NOT_FOUND; goto end; }
        decoder=avcodec_alloc_context3(codec); if(!decoder) { status=AVERROR(ENOMEM); goto end; }
        if((status=avcodec_parameters_to_context(decoder,s->codecpar))<0 || (status=avcodec_open2(decoder,codec,NULL))<0) goto end;
        decoder->pkt_timebase=s->time_base;
        AVChannelLayout stereo=AV_CHANNEL_LAYOUT_STEREO;
        if((status=swr_alloc_set_opts2(&swr,&stereo,AV_SAMPLE_FMT_S16,48000,&decoder->ch_layout,decoder->sample_fmt,decoder->sample_rate,0,NULL))<0 || (status=swr_init(swr))<0) goto end;
        double origin=f->start_time==AV_NOPTS_VALUE?0:f->start_time/(double)AV_TIME_BASE;
        int eof=0, have_audio=0;
        while(!eof) {
            if(cancel && cancel(context)) { status=AVERROR_EXIT; goto end; }
            status=av_read_frame(f,packet); eof=status==AVERROR_EOF;
            if(status<0 && !eof) goto end;
            if(!eof && packet->stream_index!=index) { av_packet_unref(packet); continue; }
            status=avcodec_send_packet(decoder,eof?NULL:packet); av_packet_unref(packet); if(status<0) goto end;
            while((status=avcodec_receive_frame(decoder,frame))>=0) {
                int capacity=swr_get_out_samples(swr,frame->nb_samples);
                av_fast_malloc(&pcm,&pcm_capacity,(size_t)capacity*4); if(!pcm) {status=AVERROR(ENOMEM);goto end;}
                int samples=swr_convert(swr,&pcm,capacity,(const uint8_t**)frame->extended_data,frame->nb_samples);
                if(samples<0) {status=samples;goto end;}
                // Align audio to the video/container timeline, including initial offsets and gaps.
                int64_t target=frame->best_effort_timestamp==AV_NOPTS_VALUE?written:llround((frame->best_effort_timestamp*av_q2d(s->time_base)-origin)*48000);
                // Container timestamps may be rounded to milliseconds. Do not insert gaps or
                // trim samples every frame for quantization or the resampler's small delay.
                if(have_audio && llabs(target-written)<=2400) target=written;
                have_audio=1;
                if(target>written) { if(fseeko(out,68+target*4,SEEK_SET)) {status=AVERROR(EIO);goto end;} written=target; }
                int skip=(int)FFMIN(samples,FFMAX(0,written-target));
                if(fwrite(pcm+skip*4,4,samples-skip,out)!=(size_t)(samples-skip)) {status=AVERROR(EIO);goto end;}
                written+=samples-skip; av_frame_unref(frame);
            }
            if(status!=AVERROR(EAGAIN) && status!=AVERROR_EOF) goto end;
        }
        // Drain resampler delay.
        int samples;
        while((samples=swr_convert(swr,&pcm,(int)(pcm_capacity/4),NULL,0))>0) {
            if(fwrite(pcm,4,samples,out)!=(size_t)samples) {status=AVERROR(EIO);goto end;} written+=samples;
        }
        if(samples<0) {status=samples;goto end;}
        int64_t full=f->duration>0?llround(f->duration/(double)AV_TIME_BASE*48000):written;
        if(full>written) { if(fseeko(out,68+full*4-1,SEEK_SET)||fputc(0,out)==EOF) {status=AVERROR(EIO);goto end;} written=full; }
    }
    if(fseeko(out,0,SEEK_SET)) {status=AVERROR(EIO);goto end;}
    status=caf_header(out,written);
end:
    if(out && fclose(out)!=0 && status>=0) status=AVERROR(EIO);
    if(status<0) { remove(output); fail(status,error,n); }
    av_free(pcm); swr_free(&swr); avcodec_free_context(&decoder); av_frame_free(&frame); av_packet_free(&packet); avformat_close_input(&f);
    return status<0?status:0;
}

struct MediaPCMReader {
    AVFormatContext *format; InputIO *io; AVCodecContext *decoder; SwrContext *swr;
    AVPacket *packet; AVFrame *frame;
    uint8_t *pcm; unsigned capacity;
    int audio, seek_stream, draining, ended, have_time, samples;
    int64_t start, next, position, total;
    double origin;
};
void media_pcm_close(MediaPCMReader *r) {
    if(!r) return;
    av_free(r->pcm); swr_free(&r->swr); avcodec_free_context(&r->decoder);
    av_packet_free(&r->packet); av_frame_free(&r->frame);
    avformat_close_input(&r->format); input_close(&r->io); free(r);
}
MediaPCMReader *media_pcm_open(MediaIO io,double duration,char *error,size_t n) {
    int status=0; MediaPCMReader *r=calloc(1,sizeof(*r));
    const AVCodec *codec=NULL;
    if(!r) {fail(AVERROR(ENOMEM),error,n);return NULL;}
    uint8_t header[68]; int64_t length=media_caf_header(duration,header);
    if(length<0) {status=AVERROR(EINVAL);goto bad;} r->total=(length-68)/4;
    if((status=input_open(NULL,&io,&r->format,&r->io))<0) goto bad;
    r->format->codec_whitelist=av_strdup("opus,vorbis,aac,ac3,eac3,flac,mp3,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,alac,dca");
    if(!r->format->codec_whitelist) {status=AVERROR(ENOMEM);goto bad;}
    if((status=avformat_find_stream_info(r->format,NULL))<0) goto bad;
    r->origin=r->format->start_time==AV_NOPTS_VALUE?0:r->format->start_time/(double)AV_TIME_BASE;
    r->audio=av_find_best_stream(r->format,AVMEDIA_TYPE_AUDIO,-1,-1,&codec,0);
    if(r->audio==AVERROR_STREAM_NOT_FOUND) return r;
    if(r->audio<0) {status=r->audio;goto bad;}
    // Matroska commonly has Cues only for video. Seeking its audio stream can
    // otherwise make FFmpeg scan the movie to build an audio index.
    r->seek_stream=av_find_best_stream(r->format,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0);
    if(r->seek_stream<0)r->seek_stream=r->audio;
    AVStream *s=r->format->streams[r->audio];
    if(!codec) {status=AVERROR_DECODER_NOT_FOUND;goto bad;}
    r->decoder=avcodec_alloc_context3(codec); r->packet=av_packet_alloc();r->frame=av_frame_alloc();
    if(!r->decoder || !r->packet || !r->frame) {status=AVERROR(ENOMEM);goto bad;}
    if((status=avcodec_parameters_to_context(r->decoder,s->codecpar))<0) goto bad;
    r->decoder->pkt_timebase=s->time_base;
    if((status=avcodec_open2(r->decoder,codec,NULL))<0) goto bad;
    AVChannelLayout stereo=AV_CHANNEL_LAYOUT_STEREO;
    if((status=swr_alloc_set_opts2(&r->swr,&stereo,AV_SAMPLE_FMT_S16,48000,&r->decoder->ch_layout,r->decoder->sample_fmt,r->decoder->sample_rate,0,NULL))<0 || (status=swr_init(r->swr))<0) goto bad;
    return r;
bad: fail(status,error,n);media_pcm_close(r);return NULL;
}
static int pcm_seek(MediaPCMReader *r,int64_t target) {
    double seconds=fmax(0,target/48000.0-0.25)+r->origin;
    int status=av_seek_frame(r->format,r->seek_stream,(int64_t)(seconds/av_q2d(r->format->streams[r->seek_stream]->time_base)),AVSEEK_FLAG_BACKWARD);
    if(status<0)return status;
    avformat_flush(r->format);avcodec_flush_buffers(r->decoder);swr_close(r->swr);
    if((status=swr_init(r->swr))<0)return status;
    av_packet_unref(r->packet);av_frame_unref(r->frame);
    r->draining=r->ended=r->have_time=r->samples=0;
    return 0;
}
static int pcm_next(MediaPCMReader *r) {
    r->samples=0;
    while(!r->ended) {
        if(input_cancelled(r->io)) return AVERROR_EXIT;
        int status=avcodec_receive_frame(r->decoder,r->frame);
        if(status>=0) {
            int capacity=swr_get_out_samples(r->swr,r->frame->nb_samples);
            if(capacity<=0) {av_frame_unref(r->frame);continue;}
            av_fast_malloc(&r->pcm,&r->capacity,(size_t)capacity*4);
            if(!r->pcm)return AVERROR(ENOMEM);
            int samples=swr_convert(r->swr,&r->pcm,capacity,(const uint8_t**)r->frame->extended_data,r->frame->nb_samples);
            if(samples<0)return samples;
            int64_t timestamp=r->frame->best_effort_timestamp;
            int64_t start=timestamp==AV_NOPTS_VALUE?r->next:llround((timestamp*av_q2d(r->format->streams[r->audio]->time_base)-r->origin)*48000);
            if(r->have_time && llabs(start-r->next)<=2400)start=r->next;
            r->start=start;r->samples=samples;r->next=start+samples;r->have_time=1;
            av_frame_unref(r->frame);
            if(samples)return 1;
            continue;
        }
        if(status==AVERROR_EOF) {
            // Retain the resampler's final few samples instead of truncating audio.
            r->samples=swr_convert(r->swr,&r->pcm,(int)(r->capacity/4),NULL,0);
            if(r->samples<0)return r->samples;
            r->start=r->next;r->next+=r->samples;
            if(!r->samples)r->ended=1;
            return r->samples?1:0;
        }
        if(status!=AVERROR(EAGAIN))return status;
        if(r->draining)return AVERROR_INVALIDDATA;
        while((status=av_read_frame(r->format,r->packet))>=0 && r->packet->stream_index!=r->audio)av_packet_unref(r->packet);
        if(status<0 && status!=AVERROR_EOF)return status;
        r->draining=status==AVERROR_EOF;
        status=avcodec_send_packet(r->decoder,r->draining?NULL:r->packet);
        av_packet_unref(r->packet);if(status<0)return status;
    }
    return 0;
}
int media_pcm_read(MediaPCMReader *r,int64_t first,int frames,uint8_t *output) {
    if(!r || !output || first<0 || frames<=0 || frames>INT_MAX/4)return AVERROR(EINVAL);
    if(input_cancelled(r->io))return AVERROR_EXIT;
    if(first>=r->total)return 0;
    frames=(int)FFMIN(frames,r->total-first);
    if(r->audio==AVERROR_STREAM_NOT_FOUND) {memset(output,0,(size_t)frames*4);return frames*4;}
    if(first!=r->position) {int status=pcm_seek(r,first);if(status<0)return status;}
    int filled=0;
    while(filled<frames) {
        int64_t target=first+filled;
        if(r->samples && target<r->start+r->samples) {
            if(target<r->start) {
                int silence=(int)FFMIN(frames-filled,r->start-target);
                memset(output+filled*4,0,(size_t)silence*4);filled+=silence;
            } else {
                int skip=(int)(target-r->start), count=FFMIN(frames-filled,r->samples-skip);
                memcpy(output+filled*4,r->pcm+skip*4,(size_t)count*4);filled+=count;
            }
        } else {
            int status=pcm_next(r);
            if(status<0)return status;
            if(!status) {memset(output+filled*4,0,(size_t)(frames-filled)*4);filled=frames;}
        }
    }
    r->position=first+frames;
    return frames*4;
}

// Opt-in streaming-remux experiment. No decoder or encoder is opened here.
typedef struct { uint8_t *bytes; int count, capacity; } FragmentBuffer;
static int fragment_write(void *opaque,const uint8_t *bytes,int count) {
    FragmentBuffer *b=opaque;
    const int limit=32*1024*1024;
    if(count<0 || count>limit-b->count)return AVERROR(ENOSPC);
    int needed=b->count+count;
    if(needed>b->capacity) {
        int capacity=FFMIN(limit,FFMAX(needed,FFMAX(65536,b->capacity*2)));
        uint8_t *grown=av_realloc(b->bytes,capacity);
        if(!grown)return AVERROR(ENOMEM);
        b->bytes=grown; b->capacity=capacity;
    }
    memcpy(b->bytes+b->count,bytes,count); b->count+=count; return count;
}
void media_remux_free(uint8_t *bytes) { av_free(bytes); }
int media_remux_fragment(MediaReader *r,const MediaInfo *info,double start,double end,
                         int sequence,uint8_t **bytes,int *count,int *init_count,char *error,size_t n) {
    AVFormatContext *out=NULL; AVIOContext *io=NULL; AVPacket *packet=NULL;
    AVDictionary *options=NULL; FragmentBuffer buffer={0};
    int status=AVERROR(EINVAL), audio=-1, init=0, wrote_video=0, video_end=0, audio_end=0;
    int64_t old_limit=r && r->io?r->io->read_limit:0, payload=0; int packet_count=0;
    double last_video_end=0;
    if(!r || !info || !bytes || !count || !init_count || !isfinite(start) || !isfinite(end) || start<0 || end<=start || sequence<1)goto done;
    *bytes=NULL; *count=0; *init_count=0;
    AVStream *video=r->format->streams[r->video];
    if(video->codecpar->codec_id!=AV_CODEC_ID_VP9) { status=AVERROR(ENOSYS); goto done; }
    for(unsigned i=0;i<r->format->nb_streams;i++) if(r->format->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_AUDIO) {
        if(r->format->streams[i]->codecpar->codec_id!=AV_CODEC_ID_AAC) { status=AVERROR(ENOSYS); goto done; }
        audio=i; break;
    }
    if(r->io)r->io->read_limit=r->io->bytes_read+64*1024*1024;
    if((status=media_seek(r,start))<0)goto done;
    if((status=avformat_alloc_output_context2(&out,NULL,"mp4",NULL))<0)goto done;
    out->avoid_negative_ts=AVFMT_AVOID_NEG_TS_DISABLED;
    for(int i=0;i<(audio<0?1:2);i++) {
        AVStream *input=r->format->streams[i==0?r->video:audio];
        AVStream *stream=avformat_new_stream(out,NULL);
        if(!stream) { status=AVERROR(ENOMEM); goto done; }
        if((status=avcodec_parameters_copy(stream->codecpar,input->codecpar))<0)goto done;
        stream->codecpar->codec_tag=0; stream->time_base=input->time_base;
        stream->avg_frame_rate=input->avg_frame_rate;
        if(i==0) {
            // The minimal VP9 parser does not expose pixel format. Use the proven
            // uncompressed keyframe-header metadata rather than opening a decoder.
            if(info->chroma>1 || (info->bit_depth!=8 && info->bit_depth!=10 && info->bit_depth!=12)) { status=AVERROR(ENOSYS); goto done; }
            stream->codecpar->format=info->bit_depth==10?AV_PIX_FMT_YUV420P10LE:info->bit_depth==12?AV_PIX_FMT_YUV420P12LE:AV_PIX_FMT_YUV420P;
            stream->codecpar->profile=info->profile; stream->codecpar->level=info->level;
        }
    }
    uint8_t *scratch=av_malloc(65536);
    if(!scratch) { status=AVERROR(ENOMEM); goto done; }
    io=avio_alloc_context(scratch,65536,1,&buffer,NULL,fragment_write,NULL);
    if(!io) { av_free(scratch); status=AVERROR(ENOMEM); goto done; }
    io->seekable=0; out->pb=io; out->flags|=AVFMT_FLAG_CUSTOM_IO;
    av_dict_set(&options,"movflags","frag_custom+frag_discont+empty_moov+default_base_moof+omit_tfhd_offset+skip_trailer",0);
    av_dict_set_int(&options,"fragment_index",sequence,0);
    av_dict_set(&options,"use_editlist","0",0);
    if((status=avformat_write_header(out,&options))<0)goto done;
    avio_flush(io); init=buffer.count;
    packet=av_packet_alloc(); if(!packet) { status=AVERROR(ENOMEM); goto done; }
    audio_end=audio<0;
    while((status=av_read_frame(r->format,packet))>=0) {
        int input_index=packet->stream_index;
        if(input_index!=r->video && input_index!=audio) { av_packet_unref(packet); continue; }
        AVStream *input=r->format->streams[input_index];
        if(packet->pts==AV_NOPTS_VALUE || packet->dts==AV_NOPTS_VALUE) { status=AVERROR_INVALIDDATA; goto done; }
        double seconds=packet->pts*av_q2d(input->time_base)-r->origin;
        int is_video=input_index==r->video;
        if(seconds>=end-0.000001) { if(is_video)video_end=1; else audio_end=1; }
        if(video_end && audio_end) { av_packet_unref(packet); break; }
        if(seconds<start-0.000001 || seconds>=end-0.000001) { av_packet_unref(packet); continue; }
        if(is_video && !wrote_video && !(packet->flags&AV_PKT_FLAG_KEY)) { status=AVERROR_INVALIDDATA; goto done; }
        if(is_video) { wrote_video=1; last_video_end=seconds+packet->duration*av_q2d(input->time_base); }
        // Bound the muxer's own mdat staging, not only our output AVIO buffer.
        payload+=packet->size;
        if(payload>24*1024*1024 || ++packet_count>65536) { status=AVERROR(ENOSPC); goto done; }
        int output_index=is_video?0:1;
        int64_t origin=llround(r->origin/av_q2d(input->time_base));
        packet->pts-=origin; packet->dts-=origin;
        av_packet_rescale_ts(packet,input->time_base,out->streams[output_index]->time_base);
        packet->stream_index=output_index; packet->pos=-1;
        if((status=av_interleaved_write_frame(out,packet))<0)goto done;
        av_packet_unref(packet);
    }
    if(status<0 && status!=AVERROR_EOF)goto done;
    if(!wrote_video || (!video_end && last_video_end<end-0.1)) { status=AVERROR_INVALIDDATA; goto done; }
    if((status=av_interleaved_write_frame(out,NULL))<0 || (status=av_write_frame(out,NULL))<0)goto done;
    avio_flush(io);
    if(io->error<0) { status=io->error; goto done; }
    *bytes=buffer.bytes; *count=buffer.count; *init_count=init; buffer.bytes=NULL; status=0;
done:
    if(r && r->io)r->io->read_limit=old_limit;
    av_dict_free(&options); av_packet_free(&packet);
    if(out)out->pb=NULL;
    avformat_free_context(out);
    if(io) { av_freep(&io->buffer); avio_context_free(&io); }
    av_free(buffer.bytes);
    return status<0?fail(status,error,n):0;
}

#ifdef __APPLE__
#include <mach/mach.h>
uint64_t media_process_resident_bytes(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
    return task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&info,&count)==KERN_SUCCESS?info.resident_size:0;
}
#else
uint64_t media_process_resident_bytes(void) { return 0; }
#endif

#ifdef __APPLE__
#include <sys/resource.h>
double media_process_cpu_seconds(void) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
           usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}
#else
double media_process_cpu_seconds(void) { return -1; }
#endif
