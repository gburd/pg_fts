#include <stdint.h>
#include <stdio.h>
typedef uint8_t uint8; typedef uint32_t uint32; typedef uint64_t uint64;
#define PG_FTS_FOR_H_TEST 1
#include "for_codec_only.h"
int main(void){ uint64 bad=0, n=0; for (uint64 len=0; len <= (1u<<29); len++){ uint8 b=fts_doclen_to_byte((uint32)len); uint32 lo=fts_byte_to_doclen(b), w=fts_byte_doclen_width(b);
 if (!(lo<=len && len<=(uint64)lo+w)) { if (bad<5) printf("bad len=%lu b=%u lo=%u w=%u\n",(unsigned long)len,b,lo,w); bad++; }
 n++; }
 /* tightness: lo+w is reachable and lo+w+1 encodes to a different byte */
 uint64 loose=0; for (int b=0;b<256;b++){ uint32 lo=fts_byte_to_doclen(b), w=fts_byte_doclen_width(b); if (lo > (1u<<29)) continue; if (fts_doclen_to_byte(lo)!=b || fts_doclen_to_byte(lo+w)!=b || fts_doclen_to_byte(lo+w+1)==b) loose++; }
 printf("checked %lu lengths, %lu bad, %lu loose codes\n",(unsigned long)n,(unsigned long)bad,(unsigned long)loose); return bad||loose; }
