#define SM_EXPOSE_STRUCT 1
#include "sm.h"
#include <stdio.h>
int main(void){ sm_cursor_t c = SM_CURSOR_INIT; printf("sizeof(sm_cursor_t)=%zu init={%zu,%llu,%zu} version=%s\n", sizeof c, c.offset, (unsigned long long)c.start_idx, c.prev_offset, SM_VERSION_STRING); return 0; }
