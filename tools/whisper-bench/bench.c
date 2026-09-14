// Minimal timing probe for the statically built whisper.cpp (tools/build-whisper-macos.sh).
// Usage: bench <model.bin> <16kHz-mono-f32.raw> [beam]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "whisper.h"
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
int main(int argc,char**argv){
    if(argc<3){fprintf(stderr,"bench model raw [beam]\n");return 1;}
    int beam=argc>3?atoi(argv[3]):1;
    FILE*f=fopen(argv[2],"rb"); fseek(f,0,SEEK_END); long n=ftell(f)/4; fseek(f,0,SEEK_SET);
    float*pcm=malloc(n*4); fread(pcm,4,n,f); fclose(f);
    struct whisper_context_params cp=whisper_context_default_params(); cp.use_gpu=true; cp.flash_attn=true;
    double t0=now(); struct whisper_context*ctx=whisper_init_from_file_with_params(argv[1],cp); double t1=now();
    struct whisper_full_params p=whisper_full_default_params(beam>1?WHISPER_SAMPLING_BEAM_SEARCH:WHISPER_SAMPLING_GREEDY);
    p.language="pl"; p.beam_search.beam_size=beam; p.print_progress=false; p.print_realtime=false; p.no_timestamps=true;
    whisper_full(ctx,p,pcm,(int)(n>16000?16000:n)); // warmup 1 s
    double best=1e9; for(int i=0;i<3;i++){double a=now(); whisper_full(ctx,p,pcm,(int)n); double b=now()-a; if(b<best)best=b;}
    printf("load %.2fs | audio %.2fs | best-of-3 %.2fs | beam %d | text:",t1-t0,n/16000.0,best,beam);
    for(int i=0;i<whisper_full_n_segments(ctx);i++)printf("%s",whisper_full_get_segment_text(ctx,i)); printf("\n");
    whisper_free(ctx); return 0;
}
