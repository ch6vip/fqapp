# tiny-AES-c

`aes.c`, `aes.h`, and `unlicense.txt` are unmodified copies of
[kokke/tiny-AES-c](https://github.com/kokke/tiny-AES-c) at commit
[`23856752fbd139da0b8ca6e471a13d5bcc99a08d`](https://github.com/kokke/tiny-AES-c/tree/23856752fbd139da0b8ca6e471a13d5bcc99a08d).
The upstream Unlicense is preserved in [unlicense.txt](unlicense.txt).

Source integrity (SHA-256):

| File | SHA-256 |
| --- | --- |
| `aes.c` | `f7f78b44654efd3542b6886923dd05194286807ebcfeb078ea05d21fe901ee9e` |
| `aes.h` | `9f74a4de3bd11621ff6e8fb9b352b060f699e6c1c67f81a22d104aacad61a23b` |
| `unlicense.txt` | `7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c` |

Build `aes.c` together with `../../crypto_core/sp_aes.c` using the definitions
`CBC=0`, `CTR=0`, and `ECB=1`. AES-128 is the upstream default; AES-192 and
AES-256 must remain disabled. The wrapper uses the AES block-encryption
primitive to implement CENC counter-mode reads at arbitrary encrypted-byte
offsets. An 8-byte CENC IV occupies the first eight counter bytes, followed by
eight zeros. A 16-byte IV is used unchanged. Counter addition and increment
operate on the full 128-bit big-endian value, modulo 2^128.

The wrapper stores a 176-byte expanded key, keeps all mutable state per call,
and clears expanded-key copies and temporary keystream with volatile stores.
The compiled AES ECB interface is an implementation detail; the stream API
only exposes CENC AES-CTR decryption.
