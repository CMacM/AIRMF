fp32

ELEM="f32", ACCUM="f32"

GEMM: A=f32, B=f32, C=f32

Conv: Activation=f32, Filter=f32, Output=f32

fp16

ELEM="f16", ACCUM="f32"

GEMM: A=f16, B=f16, C=f16

Conv: Activation=f16, Filter=f16, Output=f16

bf16

ELEM="bf16", ACCUM="f32"

GEMM: A=bf16, B=bf16, C=bf16

Conv: Activation=bf16, Filter=bf16, Output=bf16

tf32

ELEM="tf32", ACCUM="f32"

GEMM: A=tf32, B=tf32, C=f32 (special-cased)

Conv: Activation=tf32, Filter=tf32, Output=f32 (special-cased)

int8

ELEM="s8", ACCUM="s32"

GEMM: A=s8, B=s8, C=s8

Conv: Activation=s8, Filter=s8, Output=s8