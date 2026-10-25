cmake_minimum_required(VERSION 3.22)
project(shortplay_crypto LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

add_library(sp_crypto_core STATIC
    crypto_core/sp_error.c
    crypto_core/sp_stream.c
    crypto_core/mp4_cenc.c
    crypto_core/sp_aes.c
    third_party/tiny_aes/aes.c
)
target_include_directories(sp_crypto_core PUBLIC crypto_core)
target_compile_definitions(sp_crypto_core PRIVATE CBC=0 CTR=0 ECB=1)
set_target_properties(sp_crypto_core PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    C_VISIBILITY_PRESET hidden
)
if(CMAKE_C_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(sp_crypto_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

# WSOLA 时伸缩（FFmpeg af_atempo.c 的移植，LGPL-2.1-or-later）。
# 听书高倍速的听感对齐官方实现，见 issue #129。
add_library(sp_audio_tempo STATIC
    audio_tempo/sp_atempo.c
    audio_tempo/sp_resample.c
    third_party/kissfft/kiss_fft.c
    third_party/kissfft/kiss_fftr.c
)
target_include_directories(sp_audio_tempo PUBLIC audio_tempo)
target_include_directories(sp_audio_tempo PRIVATE third_party/kissfft)
target_compile_definitions(sp_audio_tempo PRIVATE KISS_FFT_BUILD=1)
set_target_properties(sp_audio_tempo PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    C_VISIBILITY_PRESET hidden
)
if(CMAKE_C_COMPILER_ID MATCHES "Clang|GNU")
    # 本仓库自己的移植代码按全告警级别把控；kissfft 是原样 vendored 的第三方
    # 源码，只放宽它自带的一处有符号比较告警。
    target_compile_options(sp_audio_tempo PRIVATE -Wall -Wextra -Wpedantic -Wno-sign-compare)
endif()

if(ANDROID)
    # 时伸缩的 JNI 桥：ExoPlayer 的 AudioProcessor 直接调用这里的采样级接口。
    add_library(shortplay_tempo SHARED android/tempo_jni_bridge.c)
    target_link_libraries(shortplay_tempo PRIVATE sp_audio_tempo)
    target_compile_options(shortplay_tempo PRIVATE -Wall -Wextra -Wpedantic)
    target_link_options(shortplay_tempo PRIVATE
        "-Wl,-z,max-page-size=16384"
        "-Wl,-z,common-page-size=16384"
        "-Wl,-z,relro"
        "-Wl,-z,now"
    )

    add_library(shortplay_crypto SHARED android/jni_bridge.c)
    target_link_libraries(shortplay_crypto PRIVATE sp_crypto_core)
    target_compile_options(shortplay_crypto PRIVATE -Wall -Wextra -Wpedantic)
    set_target_properties(shortplay_crypto PROPERTIES C_VISIBILITY_PRESET hidden)
    # Both ELF LOAD alignment and offset/address congruence must support 16 KiB
    # pages. APK zip alignment alone cannot make a 4 KiB ELF compatible.
    target_link_options(shortplay_crypto PRIVATE
        "-Wl,-z,max-page-size=16384"
        "-Wl,-z,common-page-size=16384"
        "-Wl,-z,relro"
        "-Wl,-z,now"
        "-Wl,--no-undefined"
    )
endif()
