#include <stdint.h>
#include <stdio.h>
typedef uint8_t uint8; typedef uint32_t uint32; typedef uint64_t uint64;
#include "for_codec_only.h"
int main(void){ int maxe=0; for (uint64 l=0;l<=0xffffffffull;l+=(l<1000000?1:997)){ int e=(fts_doclen_to_byte((uint32)l)>>3)&31; if(e>maxe)maxe=e;} int e=(fts_doclen_to_byte(0xffffffffu)>>3)&31; if(e>maxe)maxe=e;
 int loose=0; for (int b=0;b<256;b++){ if (((b>>3)&31) > 29) continue; uint32 lo=fts_byte_to_doclen(b), w=fts_byte_doclen_width(b); uint64 hi=(uint64)lo+w;
 if (fts_doclen_to_byte(lo)!=b || fts_doclen_to_byte((uint32)hi)!=b || (hi<0xffffffffu && fts_doclen_to_byte((uint32)hi+1)==b)) loose++; }
 printf("max exponent produced by encode: %d; loose codes with e<=29: %d\n", maxe, loose); return loose; }
