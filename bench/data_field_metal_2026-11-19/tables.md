
## Gate, PG 18: counts against the regex ground truth

- x1: arm=fts term=slovakia count=10875; arm=fts term=hungary count=24097; arm=fts term=year count=734896; arm=pgts_rel term=slovakia count=10875; arm=pgts_rel term=hungary count=24097; arm=pgts_rel term=year count=734896; arm=pgts_main term=slovakia count=10875; arm=pgts_main term=hungary count=24097; arm=pgts_main term=year count=734896; arm=psearch term=slovakia count=10898; arm=psearch term=hungary count=24152; arm=psearch term=year count=735955; arm=psearch_pn term=slovakia count=10898; arm=psearch_pn term=hungary count=24152; arm=psearch_pn term=year count=735955; arm=vchord term=slovakia count=n/a; arm=vchord term=hungary count=n/a; arm=vchord term=year count=n/a; arm=gin term=slovakia count=10875; arm=gin term=hungary count=24097; arm=gin term=year count=734896; regex term=slovakia count=10898; regex term=hungary count=24148; regex term=years? count=733960
- x2: arm=fts term=slovakia count=10875; arm=fts term=hungary count=24097; arm=fts term=year count=734896; arm=pgts_rel term=slovakia count=10875; arm=pgts_rel term=hungary count=24097; arm=pgts_rel term=year count=734896; arm=pgts_main term=slovakia count=10875; arm=pgts_main term=hungary count=24097; arm=pgts_main term=year count=734896; arm=psearch term=slovakia count=10898; arm=psearch term=hungary count=24152; arm=psearch term=year count=735955; arm=psearch_pn term=slovakia count=10898; arm=psearch_pn term=hungary count=24152; arm=psearch_pn term=year count=735955; arm=vchord term=slovakia count=n/a; arm=vchord term=hungary count=n/a; arm=vchord term=year count=n/a; arm=gin term=slovakia count=10875; arm=gin term=hungary count=24097; arm=gin term=year count=734896; regex term=slovakia count=10898; regex term=hungary count=24148; regex term=years? count=733960
- a1: arm=fts term=slovakia count=10875; arm=fts term=hungary count=24097; arm=fts term=year count=734896; arm=pgts_rel term=slovakia count=10875; arm=pgts_rel term=hungary count=24097; arm=pgts_rel term=year count=734896; arm=pgts_main term=slovakia count=10875; arm=pgts_main term=hungary count=24097; arm=pgts_main term=year count=734896; arm=psearch term=slovakia count=10898; arm=psearch term=hungary count=24152; arm=psearch term=year count=735955; arm=psearch_pn term=slovakia count=10898; arm=psearch_pn term=hungary count=24152; arm=psearch_pn term=year count=735955; arm=vchord term=slovakia count=n/a; arm=vchord term=hungary count=n/a; arm=vchord term=year count=n/a; arm=gin term=slovakia count=10875; arm=gin term=hungary count=24097; arm=gin term=year count=734896; regex term=slovakia count=10898; regex term=hungary count=24148; regex term=years? count=733960
- a2: arm=fts term=slovakia count=10875; arm=fts term=hungary count=24097; arm=fts term=year count=734896; arm=pgts_rel term=slovakia count=10875; arm=pgts_rel term=hungary count=24097; arm=pgts_rel term=year count=734896; arm=pgts_main term=slovakia count=10875; arm=pgts_main term=hungary count=24097; arm=pgts_main term=year count=734896; arm=psearch term=slovakia count=10898; arm=psearch term=hungary count=24152; arm=psearch term=year count=735955; arm=psearch_pn term=slovakia count=10898; arm=psearch_pn term=hungary count=24152; arm=psearch_pn term=year count=735955; arm=vchord term=slovakia count=n/a; arm=vchord term=hungary count=n/a; arm=vchord term=year count=n/a; arm=gin term=slovakia count=10875; arm=gin term=hungary count=24097; arm=gin term=year count=734896; regex term=slovakia count=10898; regex term=hungary count=24148; regex term=years? count=733960

## Latency, PG 18 (ms; median of pass-medians [pass min-max] per host)

### x86_64

| band | pg_fts 1.18.0 | pg_textsearch 1.5.1 | pg_textsearch main | pg_search 0.27.0 | pg_search 0.27.0 pnorms | VectorChord-bm25 0.3.0 | GIN + ts_rank |
|---|---|---|---|---|---|---|---|
| rare_k10 | 0.23 [0.22-0.25] / 0.23 [0.22-0.23] | 0.91 [0.90-0.93] / 0.91 [0.91-0.91] | 0.92 [0.91-0.92] / 0.92 [0.91-0.93] | 1.18 [1.17-1.25] / 1.18 [1.16-1.21] | 1.04 [1.02-1.05] / 1.04 [1.02-1.07] | 8.79 [8.51-9.22] / 8.70 [8.63-8.91] | 55.53 [51.95-56.12] / 54.98 [46.09-55.34] |
| mid_k10 | 0.25 [0.25-0.30] / 0.25 [0.25-0.26] | 1.12 [1.11-1.13] / 1.12 [1.10-1.12] | 1.12 [1.11-1.13] / 1.11 [1.10-1.13] | 1.17 [1.15-1.17] / 1.20 [1.19-1.20] | 1.06 [1.04-1.07] / 1.02 [1.02-1.04] | 16.94 [16.40-17.19] / 16.58 [16.36-17.45] | 150 [138-153] / 138 [134-153] |
| common_k10 | 0.36 [0.35-0.37] / 0.36 [0.35-0.41] | 9.89 [9.65-10.03] / 9.88 [9.65-9.91] | 10.09 [9.97-10.34] / 10.09 [9.94-10.23] | 1.26 [1.24-1.26] / 1.22 [1.21-1.24] | 1.18 [1.18-1.22] / 1.23 [1.20-1.24] | 55.32 [54.71-55.92] / 54.69 [52.92-57.57] | 2,347 [2,315-2,692] / 2,672 [2,376-2,757] |
| common_k100 | 0.81 [0.80-0.82] / 0.81 [0.80-0.82] | 12.13 [11.97-12.25] / 12.03 [11.92-12.07] | 12.38 [12.20-12.47] / 12.26 [12.22-12.38] | 2.45 [2.44-2.47] / 2.56 [2.55-2.58] | 2.01 [1.99-2.03] / 2.08 [2.06-2.10] | 59.04 [58.23-59.29] / 58.14 [57.30-58.68] | 2,351 [2,105-3,159] / 2,734 [2,418-3,214] |
| common_k1000 | 13.40 [13.35-13.46] / 13.36 [13.32-13.47] | 14.04 [13.88-14.33] / 13.96 [13.85-14.13] | 14.22 [14.22-14.45] / 14.30 [14.13-14.31] | 7.58 [7.56-7.66] / 7.81 [7.75-7.90] | 5.85 [5.81-5.88] / 5.80 [5.79-5.88] | short / short | 2,704 [2,133-3,273] / 2,345 [2,156-2,601] |
| or2_k10 | 1.31 [1.31-1.37] / 1.31 [1.27-1.32] | 1.29 [1.28-1.29] / 1.28 [1.28-1.30] | 1.29 [1.28-1.30] / 1.30 [1.28-1.32] | 1.83 [1.80-1.85] / 1.81 [1.79-1.83] | 1.63 [1.60-1.63] / 1.62 [1.59-1.64] | 5.61 [5.57-5.70] / 5.72 [5.58-5.90] | 168 [161-204] / 167 [159-178] |
| or4_k10 | 15.70 [15.60-15.76] / 15.71 [15.58-15.74] | 15.78 [15.72-16.17] / 15.78 [15.73-15.85] | 15.77 [15.72-15.83] / 15.78 [15.72-15.80] | 10.56 [10.27-10.71] / 10.40 [10.30-10.60] | 10.09 [9.63-10.28] / 10.15 [9.57-10.30] | 31.70 [31.61-31.98] / 31.95 [31.57-32.68] | 1,719 [1,627-1,804] / 1,726 [1,575-1,866] |
| and_k10 | 0.67 [0.66-0.69] / 0.67 [0.67-0.68] | 4,966 [4,962-4,967] cte / 4,961 [4,956-4,970] cte | 4,964 [4,954-4,981] cte / 4,967 [4,955-4,986] cte | 1.61 [1.57-1.65] / 1.60 [1.58-1.61] | 1.38 [1.36-1.40] / 1.38 [1.35-1.41] | n/a / n/a | 19.14 [18.83-19.36] / 18.88 [18.33-19.60] |
| and_us_k10 | 2.16 [2.15-2.22] / 2.16 [2.15-2.17] | >300 s / >300 s | >300 s / >300 s | 9.20 [8.83-9.53] / 9.22 [8.93-9.90] | 9.15 [8.87-9.38] / 9.46 [9.03-9.86] | n/a / n/a | 2,712 [2,627-2,784] / 1,583 [1,543-1,739] |
| and_ww_k10 | 6.27 [6.26-6.29] / 6.27 [6.26-6.28] | 189,472 [188,441-191,131] cte / 189,670 [188,619-189,927] cte | 189,743 [188,597-189,870] cte / 189,868 [189,473-191,248] cte | 2.93 [2.92-2.96] / 2.85 [2.82-2.91] | 2.27 [2.25-2.30] / 2.18 [2.17-2.21] | n/a / n/a | 1,123 [1,121-1,315] / 1,231 [1,142-1,330] |
| not_k10 | 1.82 [1.82-1.86] / 1.81 [1.79-1.83] | 19,267 [19,238-19,383] cte / 19,310 [19,243-19,387] cte | 19,303 [19,248-19,474] cte / 19,332 [19,238-19,396] cte | 1.63 [1.62-1.66] / 1.67 [1.66-1.68] | 1.54 [1.52-1.58] / 1.52 [1.51-1.54] | n/a / n/a | 113 [112-133] / 121 [116-124] |
| phrase_us_k10 | 2.56 [2.52-2.65] / 2.57 [2.53-2.59] | >300 s / >300 s | >300 s / >300 s | 8.94 [8.65-9.22] / 8.99 [8.83-9.42] | 9.35 [9.26-9.71] / 9.56 [9.42-9.95] | n/a / n/a | 3,294 [3,204-3,471] / 2,090 [1,909-2,148] |
| phrase_ww_k10 | 6.59 [6.57-6.61] / 6.61 [6.55-6.62] | >300 s / >300 s | >300 s / >300 s | 8.99 [8.66-9.20] / 9.35 [9.22-9.49] | 9.26 [9.06-9.57] / 9.33 [8.86-9.47] | n/a / n/a | 1,485 [1,452-1,645] / 1,544 [1,505-1,576] |
| count_common | 0.18 [0.18-0.18] / 0.18 [0.17-0.18] | 290,744 [290,151-291,670] / 290,909 [290,115-291,378] | 291,022 [290,098-291,840] / 291,124 [290,356-291,484] | 0.96 [0.95-0.96] / 0.95 [0.95-0.97] | 0.96 [0.96-0.99] / 0.99 [0.97-1.00] | n/a / n/a | 552 [480-600] / 578 [553-597] |

### aarch64

| band | pg_fts 1.18.0 | pg_textsearch 1.5.1 | pg_textsearch main | pg_search 0.27.0 | pg_search 0.27.0 pnorms | VectorChord-bm25 0.3.0 | GIN + ts_rank |
|---|---|---|---|---|---|---|---|
| rare_k10 | 0.24 [0.23-0.25] / 0.24 [0.23-0.24] | 0.98 [0.97-1.87] / 0.99 [0.97-1.50] | 0.98 [0.97-1.77] / 0.99 [0.98-1.55] | 1.20 [1.16-1.21] / 1.19 [1.18-1.22] | 1.02 [1.01-1.07] / 1.06 [1.03-1.07] | 11.15 [11.00-11.34] / 11.31 [11.24-11.38] | 42.34 [41.96-42.65] / 42.85 [42.21-43.55] |
| mid_k10 | 0.25 [0.24-0.26] / 0.25 [0.25-0.26] | 1.19 [1.18-2.08] / 1.21 [1.19-1.76] | 1.20 [1.20-1.99] / 1.21 [1.19-1.78] | 1.09 [1.07-1.12] / 1.16 [1.16-1.17] | 1.03 [1.02-1.05] / 1.04 [1.02-1.05] | 21.70 [21.15-22.02] / 21.79 [21.44-21.96] | 112 [112-114] / 113 [112-114] |
| common_k10 | 0.35 [0.34-0.45] / 0.35 [0.35-0.37] | 10.74 [10.68-11.62] / 10.78 [10.69-11.23] | 10.90 [10.88-11.86] / 10.90 [10.84-11.49] | 1.24 [1.22-1.26] / 1.22 [1.20-1.24] | 1.17 [1.15-1.20] / 1.20 [1.19-1.22] | 67.74 [67.08-68.31] / 67.61 [67.30-68.20] | 1,712 [1,693-1,750] / 1,699 [1,674-1,708] |
| common_k100 | 0.81 [0.79-0.89] / 0.80 [0.79-0.81] | 13.10 [12.99-13.94] / 13.10 [13.01-13.56] | 13.28 [13.27-14.19] / 13.26 [13.18-13.85] | 2.58 [2.55-2.62] / 2.59 [2.58-2.61] | 1.97 [1.94-1.99] / 2.06 [2.02-2.07] | 69.76 [69.00-70.51] / 69.69 [69.26-70.24] | 1,710 [1,674-1,750] / 1,685 [1,664-1,703] |
| common_k1000 | 11.77 [11.72-11.83] / 11.75 [11.70-11.81] | 15.05 [15.02-15.77] / 15.20 [15.07-15.75] | 15.26 [15.23-16.26] / 15.31 [15.26-16.03] | 8.48 [8.43-8.53] / 8.42 [8.35-8.43] | 5.71 [5.64-5.76] / 5.65 [5.60-5.67] | short / short | 1,709 [1,684-1,762] / 1,708 [1,678-1,718] |
| or2_k10 | 1.30 [1.29-1.30] / 1.31 [1.28-1.33] | 1.27 [1.26-2.16] / 1.27 [1.25-1.83] | 1.28 [1.27-2.05] / 1.27 [1.27-1.84] | 1.81 [1.78-1.84] / 1.80 [1.78-1.82] | 1.55 [1.54-1.55] / 1.56 [1.55-1.59] | 6.96 [6.94-7.18] / 7.06 [7.03-7.24] | 140 [138-140] / 140 [139-141] |
| or4_k10 | 12.60 [12.59-12.63] / 12.60 [12.57-12.62] | 14.08 [13.80-14.60] / 13.87 [13.80-14.35] | 13.99 [13.99-14.07] / 14.04 [14.00-14.56] | 9.32 [9.23-11.10] / 9.16 [9.06-11.34] | 9.14 [8.77-9.18] / 9.22 [9.05-9.38] | 36.85 [36.60-37.20] / 37.16 [37.00-37.40] | 1,258 [1,238-1,291] / 1,245 [1,232-1,263] |
| and_k10 | 0.64 [0.64-0.65] / 0.65 [0.64-0.66] | 3,958 [3,941-3,989] cte / 3,957 [3,948-3,976] cte | 3,950 [3,938-3,951] cte / 3,957 [3,946-3,970] cte | 1.62 [1.60-1.63] / 1.60 [1.59-1.62] | 1.35 [1.30-1.36] / 1.34 [1.33-1.36] | n/a / n/a | 19.26 [18.86-19.68] / 19.60 [19.27-19.82] |
| and_us_k10 | 1.93 [1.89-2.00] / 1.89 [1.88-1.91] | 274,529 [273,251-279,278] cte / 274,594 [273,710-277,421] cte | 273,328 [273,212-274,138] cte / 274,603 [273,492-274,978] cte | 8.78 [8.32-8.89] / 8.61 [8.47-8.69] | 8.61 [8.40-8.73] / 8.84 [8.67-8.91] | n/a / n/a | 1,869 [1,853-1,886] / 1,875 [1,850-1,883] |
| and_ww_k10 | 5.54 [5.49-5.55] / 5.52 [5.50-5.54] | 150,250 [149,772-151,046] cte / 150,235 [150,227-150,719] cte | 149,778 [149,679-150,114] cte / 150,072 [149,854-150,266] cte | 2.85 [2.84-2.87] / 2.98 [2.96-3.00] | 2.26 [2.24-2.27] / 2.35 [2.32-2.37] | n/a / n/a | 926 [916-939] / 934 [929-942] |
| not_k10 | 1.67 [1.66-1.67] / 1.67 [1.66-1.69] | 15,286 [15,235-15,289] cte / 15,281 [15,258-15,287] cte | 15,245 [15,207-15,253] cte / 15,263 [15,223-15,284] cte | 1.53 [1.50-1.55] / 1.61 [1.58-1.63] | 1.45 [1.44-1.47] / 1.51 [1.50-1.54] | n/a / n/a | 99.11 [98.06-99.95] / 99.68 [99.32-101] |
| phrase_us_k10 | 2.44 [2.36-2.52] / 2.38 [2.33-2.44] | >300 s / >300 s | >300 s / >300 s | 8.89 [8.43-8.90] / 8.66 [8.47-8.71] | 8.63 [8.37-8.65] / 8.87 [8.65-8.93] | n/a / n/a | 2,642 [2,637-2,648] / 2,655 [2,639-2,663] |
| phrase_ww_k10 | 5.92 [5.85-6.06] / 5.88 [5.87-5.95] | 248,385 [248,223-248,564] cte / 248,692 [248,570-248,752] cte | 248,429 [248,249-248,704] cte / 248,637 [248,372-248,786] cte | 8.84 [8.36-8.88] / 8.56 [8.49-8.69] | 8.53 [8.28-8.66] / 8.72 [8.65-8.76] | n/a / n/a | 1,239 [1,235-1,250] / 1,251 [1,244-1,258] |
| count_common | 0.16 [0.16-0.17] / 0.16 [0.15-0.16] | 232,830 [232,557-233,685] / 232,885 [232,315-232,951] | 232,324 [232,203-232,603] / 232,748 [232,410-233,546] | 0.91 [0.88-0.93] / 0.90 [0.89-0.92] | 0.91 [0.90-0.94] / 0.93 [0.91-0.93] | n/a / n/a | 406 [386-417] / 400 [382-401] |


## pg_fts vs each engine, PG 18: engine/pg_fts ratio of medians, bootstrap 95% CI, verdict

### x86_64 (both hosts)

| band | A/A | pg_textsearch 1.5.1 | pg_textsearch main | pg_search 0.27.0 | pg_search 0.27.0 pnorms | VectorChord-bm25 0.3.0 | GIN + ts_rank |
|---|---|---|---|---|---|---|---|
| rare_k10 | 2.6% | 3.97x [3.91-4.10] STABLE | 4.02x [3.95-4.15] STABLE | 5.15x [5.06-5.35] STABLE | 4.55x [4.48-4.71] STABLE | 38.20x [37.42-39.58] STABLE | 240.33x [226.86-248.59] STABLE |
| mid_k10 | 0.8% | 4.40x [4.33-4.47] STABLE | 4.41x [4.34-4.48] STABLE | 4.65x [4.57-4.74] STABLE | 4.10x [4.03-4.18] STABLE | 65.78x [64.58-67.91] STABLE | 574.58x [540.42-603.22] STABLE |
| common_k10 | 1.7% | 27.52x [27.00-28.08] STABLE | 28.10x [27.63-28.70] STABLE | 3.46x [3.39-3.55] STABLE | 3.36x [3.28-3.46] STABLE | 153.20x [150.83-157.37] STABLE | 6775.67x [6499.13-7579.78] STABLE |
| common_k100 | 1.7% | 14.88x [14.73-15.10] STABLE | 15.18x [15.02-15.42] STABLE | 3.10x [3.00-3.18] STABLE | 2.52x [2.47-2.59] STABLE | 72.22x [71.35-73.31] STABLE | 3040.14x [2798.20-3612.91] STABLE |
| common_k1000 | 0.3% | 1.05x [1.03-1.05] STABLE | 1.06x [1.06-1.07] STABLE | 0.58x [0.57-0.58] STABLE | 0.44x [0.43-0.44] STABLE | short | 178.92x [164.46-216.01] STABLE |
| or2_k10 | 0.8% | 0.98x [0.97-0.99] NOISY | 0.99x [0.97-1.00] NOISY | 1.38x [1.37-1.40] STABLE | 1.24x [1.22-1.26] STABLE | 4.32x [4.24-4.39] STABLE | 127.96x [125.11-137.85] STABLE |
| or4_k10 | 0.1% | 1.01x [1.00-1.01] NO CLAIM | 1.00x [1.00-1.01] NO CLAIM | 0.66x [0.66-0.67] STABLE | 0.64x [0.63-0.65] STABLE | 2.03x [2.02-2.05] STABLE | 109.67x [103.53-115.16] STABLE |
| and_k10 | 0.4% | 7431.47x [7392.86-7457.74] STABLE | 7433.58x [7404.77-7471.48] STABLE | 2.40x [2.37-2.43] STABLE | 2.06x [2.04-2.09] STABLE | n/a | 28.62x [28.02-28.91] STABLE |
| and_us_k10 | 0.6% | >300 s | >300 s | 4.27x [4.15-4.42] STABLE | 4.29x [4.17-4.39] STABLE | n/a | 1012.36x [732.94-1258.88] STABLE |
| and_ww_k10 | 0.3% | 30231.45x [30147.60-30303.59] STABLE | 30265.36x [30214.13-30286.97] STABLE | 0.46x [0.45-0.47] STABLE | 0.36x [0.35-0.36] STABLE | n/a | 185.78x [179.01-203.03] STABLE |
| not_k10 | 0.5% | 10593.78x [10533.10-10706.87] STABLE | 10599.21x [10540.88-10707.76] STABLE | 0.91x [0.89-0.92] STABLE | 0.84x [0.83-0.85] STABLE | n/a | 65.12x [62.02-69.48] STABLE |
| phrase_us_k10 | 1.3% | >300 s | >300 s | 3.49x [3.44-3.60] STABLE | 3.70x [3.64-3.76] STABLE | n/a | 1043.21x [793.36-1291.14] STABLE |
| phrase_ww_k10 | 0.7% | >300 s | >300 s | 1.40x [1.36-1.42] STABLE | 1.40x [1.37-1.42] STABLE | n/a | 228.80x [224.87-236.12] STABLE |
| count_common | 0.0% | 1642841.43x [1614341.31-1653109.97] STABLE | 1644481.56x [1616201.31-1654226.85] STABLE | 5.40x [5.30-5.45] STABLE | 5.50x [5.41-5.63] STABLE | n/a | 3189.86x [3084.89-3313.29] STABLE |

### aarch64 (both hosts)

| band | A/A | pg_textsearch 1.5.1 | pg_textsearch main | pg_search 0.27.0 | pg_search 0.27.0 pnorms | VectorChord-bm25 0.3.0 | GIN + ts_rank |
|---|---|---|---|---|---|---|---|
| rare_k10 | 4.5% | 4.11x [3.99-6.30] STABLE | 4.11x [4.00-6.20] STABLE | 4.97x [4.82-5.12] STABLE | 4.34x [4.19-4.50] STABLE | 46.96x [45.54-48.25] STABLE | 176.44x [171.99-181.99] STABLE |
| mid_k10 | 0.8% | 4.78x [4.69-7.03] STABLE | 4.79x [4.72-6.79] STABLE | 4.53x [4.34-4.67] STABLE | 4.11x [4.04-4.20] STABLE | 86.63x [85.14-88.12] STABLE | 448.19x [441.09-456.63] STABLE |
| common_k10 | 1.1% | 30.45x [29.57-31.90] STABLE | 30.84x [29.92-32.51] STABLE | 3.49x [3.37-3.53] STABLE | 3.37x [3.25-3.42] STABLE | 191.45x [185.63-193.77] STABLE | 4820.67x [4672.42-4884.29] STABLE |
| common_k100 | 1.0% | 16.29x [16.16-16.94] STABLE | 16.51x [16.39-17.23] STABLE | 3.22x [3.19-3.26] STABLE | 2.49x [2.43-2.58] STABLE | 86.72x [85.88-87.93] STABLE | 2106.57x [2081.95-2143.47] STABLE |
| common_k1000 | 0.4% | 1.29x [1.28-1.33] STABLE | 1.30x [1.30-1.35] STABLE | 0.72x [0.71-0.72] STABLE | 0.48x [0.48-0.49] STABLE | short | 145.25x [143.78-146.61] STABLE |
| or2_k10 | 0.5% | 0.98x [0.97-1.41] NO CLAIM | 0.98x [0.97-1.37] NO CLAIM | 1.39x [1.37-1.40] STABLE | 1.19x [1.18-1.21] STABLE | 5.41x [5.34-5.47] STABLE | 107.29x [106.45-108.12] STABLE |
| or4_k10 | 0.3% | 1.11x [1.10-1.14] STABLE | 1.11x [1.11-1.12] STABLE | 0.74x [0.73-0.81] STABLE | 0.73x [0.72-0.73] STABLE | 2.95x [2.92-2.95] STABLE | 99.51x [98.54-100.49] STABLE |
| and_k10 | 1.2% | 6126.01x [6064.98-6183.01] STABLE | 6115.24x [6054.32-6168.23] STABLE | 2.50x [2.46-2.52] STABLE | 2.08x [2.06-2.11] STABLE | n/a | 30.13x [29.66-30.58] STABLE |
| and_us_k10 | 0.6% | 144240.40x [141923.83-146447.53] STABLE | 143880.07x [141443.86-145125.83] STABLE | 4.55x [4.46-4.64] STABLE | 4.57x [4.48-4.66] STABLE | n/a | 984.63x [966.22-992.91] STABLE |
| and_ww_k10 | 0.5% | 27171.14x [27097.19-27321.70] STABLE | 27108.96x [27027.48-27257.64] STABLE | 0.53x [0.51-0.54] STABLE | 0.41x [0.41-0.43] STABLE | n/a | 168.48x [167.15-170.02] STABLE |
| not_k10 | 0.2% | 9173.48x [9141.33-9184.51] STABLE | 9152.98x [9119.89-9166.77] STABLE | 0.94x [0.92-0.96] STABLE | 0.89x [0.87-0.91] STABLE | n/a | 59.67x [59.36-60.11] STABLE |
| phrase_us_k10 | 1.3% | >300 s | >300 s | 3.65x [3.53-3.73] STABLE | 3.63x [3.53-3.72] STABLE | n/a | 1109.63x [1077.77-1118.21] STABLE |
| phrase_ww_k10 | 0.4% | 42044.54x [41763.15-42282.53] STABLE | 42036.37x [41746.20-42278.61] STABLE | 1.46x [1.44-1.50] STABLE | 1.46x [1.44-1.48] STABLE | n/a | 211.00x [209.08-212.60] STABLE |
| count_common | 2.5% | 1446319.77x [1436658.19-1464053.37] STABLE | 1444513.50x [1434630.73-1462187.45] STABLE | 5.61x [5.50-5.68] STABLE | 5.75x [5.62-5.80] STABLE | n/a | 2489.06x [2407.17-2544.88] STABLE |


## Settled throughput, PG 18 (tps; median of 2 passes per host; host1 / host2)

### x86_64

| arm | band | c1 | c16 | c64 | c128 | c256 | failed |
|---|---|---|---|---|---|---|---|
| pg_fts 1.18.0 | rare_k10 | 4,610 / 4,593 | 62,271 / 62,329 | 122,464 / 119,720 | 135,713 / 128,407 | 115,907 / 115,858 | 0 |
| pg_fts 1.18.0 | common_k10 | 2,969 / 2,959 | 39,749 / 39,334 | 120,878 / 120,709 | 164,361 / 164,299 | 156,034 / 156,237 | 0 |
| pg_fts 1.18.0 | and_us_k10 | 462 / 468 | 6,575 / 6,662 | 23,695 / 23,899 | 32,314 / 32,604 | 32,148 / 32,429 | 0 |
| pg_fts 1.18.0 | count_common | 5,808 / 5,820 | 79,774 / 80,113 | 246,424 / 245,777 | 341,682 / 342,639 | 354,184 / 354,040 | 0 |
| pg_textsearch 1.5.1 | rare_k10 | 1,097 / 1,102 | 12,552 / 12,554 | 20,225 / 17,776 | 15,049 / 13,863 | 15,361 / 14,028 | 0 |
| pg_textsearch 1.5.1 | common_k10 | 103 / 101 | 639 / 635 | 1,310 / 1,184 | 1,331 / 1,275 | 1,299 / 1,172 | 0 |
| pg_textsearch 1.5.1 | and_us_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch 1.5.1 | and_us_k10_cte | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch 1.5.1 | count_common | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch main | rare_k10 | 1,102 / 1,103 | 11,717 / 12,030 | 19,901 / 20,141 | 15,970 / 16,079 | 14,191 / 15,281 | 0 |
| pg_textsearch main | common_k10 | 100 / 100 | 680 / 683 | 1,403 / 1,342 | 1,281 / 1,294 | 1,292 / 1,284 | 0 |
| pg_textsearch main | and_us_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch main | and_us_k10_cte | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch main | count_common | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_search 0.27.0 | rare_k10 | 864 / 865 | 13,367 / 13,443 | 47,150 / 46,980 | 18,378 / 10,225 | 44,577 / 40,579 | 0 |
| pg_search 0.27.0 | common_k10 | 812 / 836 | 12,571 / 12,864 | 44,409 / 44,960 | 29,222 / 21,333 | 45,045 / 42,048 | 0 |
| pg_search 0.27.0 | and_us_k10 | 111 / 109 | 1,586 / 1,574 | 7,202 / 7,137 | 7,024 / 6,970 | 7,057 / 7,016 | 0 |
| pg_search 0.27.0 | count_common | 1,079 / 1,082 | 16,709 / 16,764 | 11,758 / 13,091 | 7,902 / 8,004 | 7,537 / 8,760 | 0 |
| pg_search 0.27.0 pnorms | rare_k10 | 992 / 984 | 15,191 / 15,112 | 52,643 / 52,657 | 19,833 / 10,624 | 43,794 / 34,349 | 0 |
| pg_search 0.27.0 pnorms | common_k10 | 844 / 841 | 13,106 / 12,853 | 46,574 / 45,042 | 19,552 / 10,331 | 42,032 / 41,735 | 0 |
| pg_search 0.27.0 pnorms | and_us_k10 | 110 / 108 | 1,558 / 1,544 | 7,189 / 7,124 | 7,009 / 6,963 | 7,055 / 7,001 | 0 |
| pg_search 0.27.0 pnorms | count_common | 1,052 / 1,052 | 16,451 / 16,149 | 10,769 / 11,692 | 6,035 / 6,567 | 8,647 / 7,689 | 0 |
| VectorChord-bm25 0.3.0 | rare_k10 | 114 / 112 | 1,105 / 1,110 | 2,531 / 2,551 | 2,199 / 1,979 | 1,929 / 2,021 | 0 |
| VectorChord-bm25 0.3.0 | common_k10 | 18 / 18 | 104 / 107 | 129 / 140 | 118 / 112 | 116 / 113 | 0 |
| GIN + ts_rank | rare_k10 | 20 / 20 | 238 / 233 | 446 / 459 | 360 / 361 | 357 / 324 | 0 |
| GIN + ts_rank | common_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| GIN + ts_rank | and_us_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| GIN + ts_rank | count_common | 2 / 2 | 31 / 30 | 94 / 94 | 135 / 136 | 145 / 146 | 0 |

### aarch64

| arm | band | c1 | c16 | c64 | c128 | c256 | failed |
|---|---|---|---|---|---|---|---|
| pg_fts 1.18.0 | rare_k10 | 4,294 / 4,507 | 60,107 / 61,127 | 148,213 / 144,415 | 143,671 / 141,495 | 141,144 / 138,826 | 0 |
| pg_fts 1.18.0 | common_k10 | 3,223 / 3,080 | 46,307 / 46,104 | 147,683 / 138,196 | 125,838 / 118,471 | 120,612 / 114,903 | 0 |
| pg_fts 1.18.0 | and_us_k10 | 535 / 538 | 8,093 / 8,110 | 26,324 / 26,361 | 28,156 / 28,236 | 27,657 / 27,767 | 0 |
| pg_fts 1.18.0 | count_common | 6,402 / 6,573 | 96,371 / 98,211 | 306,679 / 305,238 | 289,167 / 287,042 | 269,033 / 266,618 | 0 |
| pg_textsearch 1.5.1 | rare_k10 | 1,037 / 780 | 14,635 / 10,262 | 20,211 / 12,232 | 20,098 / 12,993 | 20,125 / 13,310 | 0 |
| pg_textsearch 1.5.1 | common_k10 | 93 / 90 | 1,300 / 1,255 | 3,591 / 3,499 | 3,620 / 3,525 | 3,624 / 3,529 | 0 |
| pg_textsearch 1.5.1 | and_us_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch 1.5.1 | and_us_k10_cte | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch 1.5.1 | count_common | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch main | rare_k10 | 1,026 / 792 | 14,363 / 10,490 | 20,360 / 12,531 | 20,223 / 13,491 | 20,231 / 13,724 | 0 |
| pg_textsearch main | common_k10 | 92 / 89 | 1,288 / 1,239 | 3,564 / 3,483 | 3,597 / 3,516 | 3,606 / 3,535 | 0 |
| pg_textsearch main | and_us_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch main | and_us_k10_cte | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch main | count_common | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_search 0.27.0 | rare_k10 | 855 / 855 | 13,288 / 13,069 | 48,769 / 48,802 | 36,387 / 36,206 | 36,122 / 36,178 | 0 |
| pg_search 0.27.0 | common_k10 | 820 / 818 | 12,802 / 12,946 | 48,416 / 48,795 | 36,151 / 36,316 | 35,735 / 36,058 | 0 |
| pg_search 0.27.0 | and_us_k10 | 111 / 115 | 1,456 / 1,480 | 8,460 / 8,469 | 9,018 / 9,023 | 8,996 / 9,049 | 0 |
| pg_search 0.27.0 | count_common | 1,137 / 1,127 | 17,714 / 17,743 | 66,522 / 67,205 | 53,173 / 52,176 | 48,190 / 48,041 | 0 |
| pg_search 0.27.0 pnorms | rare_k10 | 984 / 975 | 15,305 / 15,224 | 57,407 / 56,397 | 42,589 / 41,286 | 40,965 / 40,127 | 0 |
| pg_search 0.27.0 pnorms | common_k10 | 847 / 850 | 13,386 / 13,085 | 50,574 / 49,122 | 37,593 / 36,407 | 37,062 / 36,230 | 0 |
| pg_search 0.27.0 pnorms | and_us_k10 | 113 / 113 | 1,479 / 1,467 | 8,533 / 8,443 | 9,254 / 9,015 | 9,200 / 9,006 | 0 |
| pg_search 0.27.0 pnorms | count_common | 1,098 / 1,099 | 17,176 / 17,277 | 65,635 / 65,764 | 51,723 / 50,853 | 47,494 / 47,153 | 0 |
| VectorChord-bm25 0.3.0 | rare_k10 | 87 / 87 | 819 / 633 | 1,732 / 1,609 | 2,952 / 2,900 | 2,997 / 2,960 | 0 |
| VectorChord-bm25 0.3.0 | common_k10 | 15 / 15 | 84 / 85 | 150 / 148 | 151 / 149 | 149 / 148 | 0 |
| GIN + ts_rank | rare_k10 | 24 / 23 | 242 / 242 | 468 / 458 | 477 / 469 | 476 / 468 | 0 |
| GIN + ts_rank | common_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| GIN + ts_rank | and_us_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| GIN + ts_rank | count_common | 2 / 2 | 35 / 34 | 111 / 111 | 120 / 121 | 121 / 122 | 0 |


## Cold cache, PG 18 (ms, median of 5 per host; host1 / host2)

### x86_64

- pg_fts 1.18.0 and_k10: 61.9 / 54.6
- pg_fts 1.18.0 common_k10: 54.7 / 47.3
- pg_fts 1.18.0 rare_k10: 46.0 / 40.9
- GIN + ts_rank and_k10: 1445.4 / 946.7
- GIN + ts_rank common_k10: 7217.9 / 8379.8
- GIN + ts_rank rare_k10: 2117.5 / 1990.0
- pg_textsearch main and_k10: skip / skip
- pg_textsearch main and_k10_cte: 7031.8 / 6113.2
- pg_textsearch main common_k10: 39.8 / 26.5
- pg_textsearch main rare_k10: 24.1 / 13.7
- pg_textsearch 1.5.1 and_k10: skip / skip
- pg_textsearch 1.5.1 and_k10_cte: 6972.4 / 6095.6
- pg_textsearch 1.5.1 common_k10: 42.7 / 25.8
- pg_textsearch 1.5.1 rare_k10: 24.9 / 13.7
- pg_search 0.27.0 and_k10: 67.2 / 36.0
- pg_search 0.27.0 common_k10: 70.3 / 35.7
- pg_search 0.27.0 rare_k10: 66.8 / 35.4
- pg_search 0.27.0 pnorms and_k10: 62.8 / 30.4
- pg_search 0.27.0 pnorms common_k10: 69.1 / 34.6
- pg_search 0.27.0 pnorms rare_k10: 56.4 / 30.4
- VectorChord-bm25 0.3.0 common_k10: 1239.1 / 1234.6
- VectorChord-bm25 0.3.0 rare_k10: 2352.5 / 987.0

### aarch64

- pg_fts 1.18.0 and_k10: 53.9 / 55.0
- pg_fts 1.18.0 common_k10: 47.3 / 48.4
- pg_fts 1.18.0 rare_k10: 40.8 / 40.7
- GIN + ts_rank and_k10: 1208.6 / 1232.0
- GIN + ts_rank common_k10: 6786.9 / 6865.8
- GIN + ts_rank rare_k10: 1638.3 / 1780.0
- pg_textsearch main and_k10: skip / skip
- pg_textsearch main and_k10_cte: 5208.2 / 5219.1
- pg_textsearch main common_k10: 38.0 / 37.3
- pg_textsearch main rare_k10: 21.3 / 21.5
- pg_textsearch 1.5.1 and_k10: skip / skip
- pg_textsearch 1.5.1 and_k10_cte: 5223.5 / 5175.4
- pg_textsearch 1.5.1 common_k10: 38.2 / 38.1
- pg_textsearch 1.5.1 rare_k10: 21.3 / 21.7
- pg_search 0.27.0 and_k10: 50.1 / 45.5
- pg_search 0.27.0 common_k10: 50.3 / 43.5
- pg_search 0.27.0 rare_k10: 36.0 / 35.5
- pg_search 0.27.0 pnorms and_k10: 43.7 / 37.6
- pg_search 0.27.0 pnorms common_k10: 49.1 / 44.6
- pg_search 0.27.0 pnorms rare_k10: 42.1 / 36.6
- VectorChord-bm25 0.3.0 common_k10: 915.4 / 1066.0
- VectorChord-bm25 0.3.0 rare_k10: 2022.6 / 2045.3


## Build and size, PG 18

- x1: build fts expr s=255.439295478 size=1435435008
- x1: fts_vacuum s=.046258946 size=1435435008
- x1: build fts positions s=314.209785155 size=2703384576
- x1: build pgts_rel s=299.438282785 size=1978302464 all_rels_bytes=1978302464
- x1: build pgts_main s=300.736793267 size=1978302464 all_rels_bytes=1978302464
- x1: build psearch ('stemmer=english') s=130.431007831 size=2420252672 all_rels_bytes=2420293632 def=CREATE INDEX docs_idx ON public.docs USING paradedb (id, ((content)::pdb.simple('stemmer=english')))
- x1: build psearch_pn ('stemmer=english', 'pnorms=true') s=133.710029515 size=2835374080 all_rels_bytes=2835415040 def=CREATE INDEX docs_idx ON public.docs USING paradedb (id, ((content)::pdb.simple('stemmer=english', 'pnorms=true')))
- x1: build vchord model_s=891.276695780 tokenize_s=2335.460285592 index_s=150.359291205 size=44495831040 all_rels_bytes=44915154944
- x1: build gin column_s=985.624096586 index_s=71.351690257 size=1645436928 heap_growth_bytes=6657007616
- x2: build fts expr s=256.501291983 size=1435435008
- x2: fts_vacuum s=.045736824 size=1435435008
- x2: build fts positions s=313.244857165 size=2703425536
- x2: build pgts_rel s=298.009572464 size=1978302464 all_rels_bytes=1978302464
- x2: build pgts_main s=300.777662296 size=1978302464 all_rels_bytes=1978302464
- x2: build psearch ('stemmer=english') s=118.261554373 size=2420580352 all_rels_bytes=2420621312 def=CREATE INDEX docs_idx ON public.docs USING paradedb (id, ((content)::pdb.simple('stemmer=english')))
- x2: build psearch_pn ('stemmer=english', 'pnorms=true') s=134.136199468 size=2835456000 all_rels_bytes=2835496960 def=CREATE INDEX docs_idx ON public.docs USING paradedb (id, ((content)::pdb.simple('stemmer=english', 'pnorms=true')))
- x2: build vchord model_s=893.633676747 tokenize_s=2334.252877351 index_s=150.184971462 size=44495831040 all_rels_bytes=44915154944
- x2: build gin column_s=983.738554392 index_s=69.593549907 size=1645436928 heap_growth_bytes=6657007616
- a1: build fts expr s=240.534486894 size=1435435008
- a1: fts_vacuum s=.043797465 size=1435435008
- a1: build fts positions s=284.487174700 size=2703417344
- a1: build pgts_rel s=266.442330313 size=1978302464 all_rels_bytes=1978302464
- a1: build pgts_main s=265.482401657 size=1978302464 all_rels_bytes=1978302464
- a1: build psearch ('stemmer=english') s=122.779180818 size=2420441088 all_rels_bytes=2420482048 def=CREATE INDEX docs_idx ON public.docs USING paradedb (id, ((content)::pdb.simple('stemmer=english')))
- a1: build psearch_pn ('stemmer=english', 'pnorms=true') s=128.257254825 size=2835767296 all_rels_bytes=2835808256 def=CREATE INDEX docs_idx ON public.docs USING paradedb (id, ((content)::pdb.simple('stemmer=english', 'pnorms=true')))
- a1: build vchord model_s=813.091878016 tokenize_s=2227.848961372 index_s=161.154520002 size=44495831040 all_rels_bytes=44915154944
- a1: build gin column_s=786.058595132 index_s=72.923645622 size=1645436928 heap_growth_bytes=6657007616
- a2: build fts expr s=239.494475244 size=1435435008
- a2: fts_vacuum s=.043691683 size=1435435008
- a2: build fts positions s=283.422745384 size=2703368192
- a2: build pgts_rel s=266.188513800 size=1978302464 all_rels_bytes=1978302464
- a2: build pgts_main s=266.037976285 size=1978302464 all_rels_bytes=1978302464
- a2: build psearch ('stemmer=english') s=124.147094621 size=2420482048 all_rels_bytes=2420523008 def=CREATE INDEX docs_idx ON public.docs USING paradedb (id, ((content)::pdb.simple('stemmer=english')))
- a2: build psearch_pn ('stemmer=english', 'pnorms=true') s=111.693113628 size=2835423232 all_rels_bytes=2835464192 def=CREATE INDEX docs_idx ON public.docs USING paradedb (id, ((content)::pdb.simple('stemmer=english', 'pnorms=true')))
- a2: build vchord model_s=812.240945994 tokenize_s=2207.638262255 index_s=162.298666267 size=44495831040 all_rels_bytes=44915154944
- a2: build gin column_s=781.821972530 index_s=72.890911468 size=1645436928 heap_growth_bytes=6657007616

## Gate, PG 19: counts against the regex ground truth

- x1: arm=fts term=slovakia count=10875; arm=fts term=hungary count=24097; arm=fts term=year count=734896; arm=pgts_main term=slovakia count=10875; arm=pgts_main term=hungary count=24097; arm=pgts_main term=year count=734896; arm=gin term=slovakia count=10875; arm=gin term=hungary count=24097; arm=gin term=year count=734896; regex term=slovakia count=10898; regex term=hungary count=24148; regex term=years? count=733960
- x2: arm=fts term=slovakia count=10875; arm=fts term=hungary count=24097; arm=fts term=year count=734896; arm=pgts_main term=slovakia count=10875; arm=pgts_main term=hungary count=24097; arm=pgts_main term=year count=734896; arm=gin term=slovakia count=10875; arm=gin term=hungary count=24097; arm=gin term=year count=734896; regex term=slovakia count=10898; regex term=hungary count=24148; regex term=years? count=733960
- a1: arm=fts term=slovakia count=10875; arm=fts term=hungary count=24097; arm=fts term=year count=734896; arm=pgts_main term=slovakia count=10875; arm=pgts_main term=hungary count=24097; arm=pgts_main term=year count=734896; arm=gin term=slovakia count=10875; arm=gin term=hungary count=24097; arm=gin term=year count=734896; regex term=slovakia count=10898; regex term=hungary count=24148; regex term=years? count=733960
- a2: arm=fts term=slovakia count=10875; arm=fts term=hungary count=24097; arm=fts term=year count=734896; arm=pgts_main term=slovakia count=10875; arm=pgts_main term=hungary count=24097; arm=pgts_main term=year count=734896; arm=gin term=slovakia count=10875; arm=gin term=hungary count=24097; arm=gin term=year count=734896; regex term=slovakia count=10898; regex term=hungary count=24148; regex term=years? count=733960

## Latency, PG 19 (ms; median of pass-medians [pass min-max] per host)

### x86_64

| band | pg_fts 1.18.0 | pg_textsearch main | GIN + ts_rank |
|---|---|---|---|
| rare_k10 | 0.23 [0.22-0.24] / 0.22 [0.22-0.23] | 0.91 [0.91-0.92] / 0.92 [0.91-0.92] | 52.56 [49.45-56.25] / 54.85 [50.95-55.33] |
| mid_k10 | 0.25 [0.25-0.26] / 0.25 [0.25-0.27] | 1.11 [1.11-1.13] / 1.11 [1.11-1.12] | 146 [135-152] / 140 [123-153] |
| common_k10 | 0.36 [0.34-0.37] / 0.34 [0.34-0.35] | 9.90 [9.83-9.97] / 10.01 [9.91-10.17] | 3,715 [3,446-4,186] / 3,999 [3,672-4,192] |
| common_k100 | 0.81 [0.79-0.82] / 0.80 [0.80-0.82] | 12.14 [12.10-12.20] / 12.12 [12.05-12.28] | 3,611 [3,327-4,078] / 3,648 [3,454-3,707] |
| common_k1000 | 13.39 [13.31-13.47] / 13.39 [13.32-13.43] | 14.12 [14.07-14.17] / 14.15 [14.07-14.25] | 3,441 [3,291-3,611] / 3,729 [3,410-4,326] |
| or2_k10 | 1.32 [1.24-1.36] / 1.28 [1.27-1.33] | 1.30 [1.28-1.30] / 1.27 [1.27-1.31] | 155 [153-190] / 164 [154-178] |
| or4_k10 | 15.78 [15.57-15.89] / 15.61 [15.60-16.05] | 15.73 [15.68-15.81] / 15.73 [15.72-15.79] | 1,515 [1,450-1,754] / 1,515 [1,486-1,624] |
| and_k10 | 0.66 [0.66-0.67] / 0.66 [0.66-0.67] | 5,210 [5,209-5,243] cte / 5,214 [5,207-5,238] cte | 19.12 [18.15-19.70] / 18.51 [17.75-18.77] |
| and_us_k10 | 2.15 [2.13-2.18] / 2.13 [2.12-2.14] | >300 s / >300 s | 2,504 [2,334-3,006] / 2,641 [2,338-2,710] |
| and_ww_k10 | 6.26 [6.25-6.28] / 6.25 [6.24-6.29] | 199,297 [198,616-199,892] cte / 199,461 [198,396-200,267] cte | 1,084 [1,070-1,175] / 1,237 [1,118-1,325] |
| not_k10 | 1.82 [1.76-1.85] / 1.80 [1.75-1.86] | 20,278 [20,232-20,493] cte / 20,270 [20,246-20,618] cte | 113 [109-133] / 114 [110-130] |
| phrase_us_k10 | 2.54 [2.52-2.63] / 2.54 [2.52-2.59] | >300 s / >300 s | 3,236 [3,162-3,339] / 3,440 [3,145-3,508] |
| phrase_ww_k10 | 6.61 [6.55-6.70] / 6.59 [6.54-6.73] | >300 s / >300 s | 1,452 [1,431-1,657] / 1,459 [1,433-1,484] |
| count_common | 0.17 [0.17-0.18] / 0.17 [0.17-0.17] | >300 s / >300 s | 536 [445-553] / 535 [454-614] |

### aarch64

| band | pg_fts 1.18.0 | pg_textsearch main | GIN + ts_rank |
|---|---|---|---|
| rare_k10 | 0.23 [0.23-0.24] / 0.24 [0.23-0.25] | 0.97 [0.97-1.39] / 0.99 [0.96-1.34] | 41.97 [41.87-42.11] / 43.11 [41.64-43.23] |
| mid_k10 | 0.26 [0.25-0.26] / 0.26 [0.25-0.26] | 1.20 [1.19-1.63] / 1.19 [1.19-1.55] | 111 [110-111] / 111 [110-112] |
| common_k10 | 0.35 [0.35-0.36] / 0.35 [0.34-0.35] | 10.89 [10.87-11.32] / 10.88 [10.83-11.19] | 2,701 [2,656-2,705] / 2,661 [2,637-2,672] |
| common_k100 | 0.79 [0.78-0.80] / 0.79 [0.77-0.80] | 13.31 [13.26-13.71] / 13.28 [13.23-13.64] | 2,706 [2,663-2,714] / 2,658 [2,617-2,692] |
| common_k1000 | 11.76 [11.70-11.80] / 11.63 [11.59-11.74] | 15.27 [15.22-15.77] / 15.23 [15.19-15.70] | 2,710 [2,661-2,714] / 2,675 [2,644-2,703] |
| or2_k10 | 1.29 [1.28-1.31] / 1.29 [1.29-1.31] | 1.28 [1.26-1.70] / 1.26 [1.25-1.61] | 138 [137-139] / 138 [137-139] |
| or4_k10 | 12.59 [12.57-12.62] / 12.58 [12.57-12.63] | 14.09 [14.03-14.14] / 14.09 [14.03-14.14] | 1,161 [1,159-1,162] / 1,140 [1,136-1,157] |
| and_k10 | 0.63 [0.62-0.64] / 0.63 [0.62-0.64] | 4,008 [4,001-4,036] cte / 4,012 [4,004-4,015] cte | 19.38 [19.20-19.53] / 19.24 [19.19-19.74] |
| and_us_k10 | 1.88 [1.87-1.89] / 1.87 [1.86-1.89] | 277,778 [277,720-278,293] cte / 278,051 [277,612-278,328] cte | 1,125 [1,121-1,134] / 1,888 [1,875-1,909] |
| and_ww_k10 | 5.48 [5.47-5.52] / 5.49 [5.46-5.49] | 152,316 [152,052-152,367] cte / 152,319 [152,232-152,545] cte | 923 [919-927] / 926 [922-939] |
| not_k10 | 1.67 [1.66-1.69] / 1.66 [1.65-1.67] | 15,465 [15,454-15,501] cte / 15,487 [15,481-15,496] cte | 97.88 [97.59-99.48] / 98.23 [97.49-99.11] |
| phrase_us_k10 | 2.31 [2.30-2.32] / 2.32 [2.30-2.33] | >300 s / >300 s | 1,440 [1,438-1,458] / 2,657 [2,640-2,671] |
| phrase_ww_k10 | 5.82 [5.80-5.83] / 5.84 [5.82-5.89] | 252,024 [251,986-252,242] cte / 252,341 [252,264-252,423] cte | 1,241 [1,238-1,249] / 1,245 [1,234-1,255] |
| count_common | 0.16 [0.15-0.16] / 0.16 [0.15-0.16] | 235,931 [235,805-236,433] / 235,853 [235,536-236,124] | 2,041 [2,017-2,048] / 2,015 [2,005-2,026] |


## pg_fts vs each engine, PG 19: engine/pg_fts ratio of medians, bootstrap 95% CI, verdict

### x86_64 (both hosts)

| band | A/A | pg_textsearch main | GIN + ts_rank |
|---|---|---|---|
| rare_k10 | 1.3% | 4.10x [3.95-4.14] STABLE | 239.78x [223.76-247.38] STABLE |
| mid_k10 | 2.8% | 4.44x [4.39-4.51] STABLE | 575.68x [549.63-606.75] STABLE |
| common_k10 | 4.3% | 28.53x [27.69-28.94] STABLE | 10957.31x [10259.01-11995.28] STABLE |
| common_k100 | 2.9% | 14.99x [14.82-15.24] STABLE | 4459.58x [4307.99-4579.17] STABLE |
| common_k1000 | 0.2% | 1.05x [1.05-1.06] STABLE | 265.18x [256.53-280.76] STABLE |
| or2_k10 | 0.8% | 1.01x [0.97-1.02] NO CLAIM | 124.21x [116.73-131.98] STABLE |
| or4_k10 | 1.1% | 1.00x [0.99-1.01] NO CLAIM | 96.49x [95.00-103.29] STABLE |
| and_k10 | 0.6% | 7878.77x [7822.58-7915.97] STABLE | 28.25x [27.65-28.95] STABLE |
| and_us_k10 | 0.9% | >300 s | 1203.58x [1127.92-1318.53] STABLE |
| and_ww_k10 | 0.2% | 31885.40x [31750.42-31978.44] STABLE | 183.59x [173.10-197.90] STABLE |
| not_k10 | 0.4% | 11198.10x [11021.94-11416.13] STABLE | 62.91x [61.29-72.45] STABLE |
| phrase_us_k10 | 0.3% | >300 s | 1288.96x [1246.31-1353.62] STABLE |
| phrase_ww_k10 | 0.2% | >300 s | 220.48x [217.54-224.18] STABLE |
| count_common | 1.2% | >300 s | 3105.06x [2639.10-3205.99] STABLE |

### aarch64 (both hosts)

| band | A/A | pg_textsearch main | GIN + ts_rank |
|---|---|---|---|
| rare_k10 | 1.3% | 4.08x [4.00-5.12] STABLE | 175.23x [172.84-183.26] STABLE |
| mid_k10 | 2.7% | 4.65x [4.61-5.66] STABLE | 430.07x [426.74-442.99] STABLE |
| common_k10 | 2.6% | 31.06x [30.90-31.87] STABLE | 7617.02x [7560.16-7767.89] STABLE |
| common_k100 | 1.4% | 16.83x [16.63-17.19] STABLE | 3400.99x [3341.08-3457.90] STABLE |
| common_k1000 | 0.5% | 1.30x [1.30-1.33] STABLE | 229.46x [226.82-232.49] STABLE |
| or2_k10 | 0.5% | 0.99x [0.97-1.17] NO CLAIM | 106.75x [105.27-107.67] STABLE |
| or4_k10 | 0.1% | 1.12x [1.12-1.12] STABLE | 92.00x [90.52-92.31] STABLE |
| and_k10 | 1.6% | 6381.37x [6256.93-6417.85] STABLE | 30.83x [30.21-31.11] STABLE |
| and_us_k10 | 0.5% | 148428.08x [147832.19-148788.63] STABLE | 804.01x [599.76-1009.62] STABLE |
| and_ww_k10 | 0.4% | 27779.95x [27731.81-27828.17] STABLE | 168.57x [168.03-169.19] STABLE |
| not_k10 | 0.5% | 9312.30x [9277.65-9343.48] STABLE | 58.98x [58.63-59.47] STABLE |
| phrase_us_k10 | 1.1% | >300 s | 887.11x [622.54-1151.32] STABLE |
| phrase_ww_k10 | 0.9% | 43323.79x [43068.60-43381.07] STABLE | 213.15x [212.07-214.48] STABLE |
| count_common | 1.3% | 1488430.04x [1464926.95-1523135.62] STABLE | 12766.72x [12547.49-13111.31] STABLE |


## Settled throughput, PG 19 (tps; median of 2 passes per host; host1 / host2)

### x86_64

| arm | band | c1 | c16 | c64 | c128 | c256 | failed |
|---|---|---|---|---|---|---|---|
| pg_fts 1.18.0 | rare_k10 | 4,598 / 4,610 | 61,787 / 61,753 | 129,820 / 129,431 | 144,115 / 148,555 | 128,612 / 125,480 | 0 |
| pg_fts 1.18.0 | common_k10 | 2,958 / 3,034 | 40,141 / 40,484 | 127,629 / 128,261 | 179,266 / 180,566 | 168,059 / 168,865 | 0 |
| pg_fts 1.18.0 | and_us_k10 | 466 / 470 | 6,675 / 6,677 | 23,971 / 24,086 | 33,886 / 33,975 | 33,730 / 33,644 | 0 |
| pg_fts 1.18.0 | count_common | 5,914 / 5,903 | 84,179 / 83,240 | 259,744 / 260,081 | 394,917 / 396,881 | 404,296 / 406,500 | 0 |
| pg_textsearch main | rare_k10 | 1,110 / 1,109 | 12,218 / 11,974 | 19,685 / 20,942 | 15,486 / 12,961 | 14,306 / 14,220 | 0 |
| pg_textsearch main | common_k10 | 99 / 100 | 705 / 672 | 1,383 / 1,313 | 1,216 / 1,132 | 1,240 / 1,244 | 0 |
| pg_textsearch main | and_us_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch main | and_us_k10_cte | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch main | count_common | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| GIN + ts_rank | rare_k10 | 20 / 20 | 239 / 241 | 534 / 549 | 431 / 403 | 406 / 388 | 0 |
| GIN + ts_rank | common_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| GIN + ts_rank | and_us_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| GIN + ts_rank | count_common | 2 / 2 | 29 / 29 | 105 / 101 | 143 / 139 | 160 / 163 | 0 |

### aarch64

| arm | band | c1 | c16 | c64 | c128 | c256 | failed |
|---|---|---|---|---|---|---|---|
| pg_fts 1.18.0 | rare_k10 | 4,371 / 4,518 | 60,743 / 60,292 | 151,473 / 147,969 | 146,630 / 143,830 | 141,358 / 139,374 | 0 |
| pg_fts 1.18.0 | common_k10 | 3,050 / 3,288 | 46,910 / 47,547 | 145,624 / 145,588 | 121,252 / 122,293 | 116,221 / 120,580 | 0 |
| pg_fts 1.18.0 | and_us_k10 | 535 / 543 | 8,123 / 8,207 | 26,856 / 26,901 | 28,490 / 28,869 | 28,055 / 28,365 | 0 |
| pg_fts 1.18.0 | count_common | 6,578 / 6,553 | 96,858 / 98,965 | 311,344 / 310,642 | 292,284 / 292,500 | 270,038 / 269,900 | 0 |
| pg_textsearch main | rare_k10 | 1,034 / 1,039 | 14,613 / 14,873 | 19,717 / 20,247 | 19,626 / 20,155 | 19,641 / 20,175 | 0 |
| pg_textsearch main | common_k10 | 93 / 93 | 1,295 / 1,301 | 3,529 / 3,518 | 3,548 / 3,596 | 3,582 / 3,610 | 0 |
| pg_textsearch main | and_us_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch main | and_us_k10_cte | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| pg_textsearch main | count_common | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| GIN + ts_rank | rare_k10 | 24 / 24 | 243 / 239 | 523 / 516 | 552 / 552 | 549 / 552 | 0 |
| GIN + ts_rank | common_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| GIN + ts_rank | and_us_k10 | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |
| GIN + ts_rank | count_common | skip / skip | skip / skip | skip / skip | skip / skip | skip / skip | 0 |


## Cold cache, PG 19 (ms, median of 5 per host; host1 / host2)

### x86_64

- pg_fts 1.18.0 and_k10: 63.9 / 56.2
- pg_fts 1.18.0 common_k10: 54.6 / 47.9
- pg_fts 1.18.0 rare_k10: 45.6 / 41.1
- GIN + ts_rank and_k10: 1374.7 / 945.4
- GIN + ts_rank common_k10: 6194.9 / 8039.6
- GIN + ts_rank rare_k10: 1733.5 / 1980.0
- pg_textsearch main and_k10: skip / skip
- pg_textsearch main and_k10_cte: 7356.6 / 6349.2
- pg_textsearch main common_k10: 42.1 / 26.5
- pg_textsearch main rare_k10: 29.8 / 14.0

### aarch64

- pg_fts 1.18.0 and_k10: 54.9 / 55.1
- pg_fts 1.18.0 common_k10: 48.4 / 48.5
- pg_fts 1.18.0 rare_k10: 41.1 / 41.0
- GIN + ts_rank and_k10: 1327.0 / 1267.4
- GIN + ts_rank common_k10: 5517.0 / 5382.8
- GIN + ts_rank rare_k10: 1717.1 / 1672.8
- pg_textsearch main and_k10: skip / skip
- pg_textsearch main and_k10_cte: 5240.4 / 5237.9
- pg_textsearch main common_k10: 37.6 / 38.1
- pg_textsearch main rare_k10: 24.6 / 25.1


## Build and size, PG 19

- x1: build fts expr s=264.077905350 size=1435525120
- x1: fts_vacuum s=.047216088 size=1435525120
- x1: build fts positions s=321.130064405 size=2703556608
- x1: build pgts_main s=312.436534446 size=1978351616 all_rels_bytes=1978351616
- x1: build gin column_s=1035.650610391 index_s=71.352648216 size=1645469696 heap_growth_bytes=6659473408
- x2: build fts expr s=262.625008361 size=1435525120
- x2: fts_vacuum s=.046834325 size=1435525120
- x2: build fts positions s=318.741903464 size=2703523840
- x2: build pgts_main s=312.015149227 size=1978351616 all_rels_bytes=1978351616
- x2: build gin column_s=1035.250453716 index_s=70.528087835 size=1645387776 heap_growth_bytes=6659473408
- a1: build fts expr s=240.659980809 size=1435525120
- a1: fts_vacuum s=.046164756 size=1435525120
- a1: build fts positions s=284.634925801 size=2703491072
- a1: build pgts_main s=267.388247507 size=1978351616 all_rels_bytes=1978351616
- a1: build gin column_s=791.744946202 index_s=75.863280965 size=1645445120 heap_growth_bytes=6659473408
- a2: build fts expr s=242.346442396 size=1435525120
- a2: fts_vacuum s=.047554673 size=1435525120
- a2: build fts positions s=285.424306459 size=2703540224
- a2: build pgts_main s=268.648712426 size=1978351616 all_rels_bytes=1978351616
- a2: build gin column_s=791.173636771 index_s=73.985460035 size=1645387776 heap_growth_bytes=6659473408
