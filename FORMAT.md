# PackFS format

PackFS stores game data in an index and a set of headerless archives. This
description covers the examined GFDM V4-V8, XG1, and jubeat data sets. All
integers are little-endian.

```text
data/
├── finfolist.bin
└── pack/
    ├── packinfo.bin
    ├── d000/pack0000.pak
    ├── d000/pack0001.pak
    └── d001/pack0030.pak
```

`packinfo.bin` maps hashed paths to payload ranges. The `.pak` files contain
aligned payload bytes. `finfolist.bin` provides whole-file integrity records.

## `packinfo.bin`

The 16-byte header is:

| Offset | Type | Description |
|---:|---|---|
| `0x00` | `u32` | Magic |
| `0x04` | `u32` | File-table offset |
| `0x08` | `u32` | Archive-MD5-table offset |
| `0x0c` | `u16` | File-record count |
| `0x0e` | `u16` | Archive count |

Known magic values are `0x20041207` for GFDM V4-V7, XG1, and jubeat, and
`0x20110201` for GFDM V8. The magic does not determine whether payloads use the
cipher.

Each file record is 32 bytes:

| Offset | Type | Description |
|---:|---|---|
| `0x00` | 16 bytes | Plaintext payload MD5 |
| `0x10` | `u32` | Path CRC-32 |
| `0x14` | `u16` | Path CRC-16 |
| `0x16` | `u16` | Archive ID |
| `0x18` | `u32` | Payload offset in the archive |
| `0x1c` | `u32` | Payload size |

Records are sorted by `(CRC-32, CRC-16)` for binary lookup. The archive table
contains one 16-byte MD5 per archive. Entry `N` hashes the complete archive,
including inter-payload padding.

## Archives

Archive `N` is stored under the data root as:

```text
pack/dDDD/packNNNN.pak
```

where `DDD` is `N / 30` using integer division.

The first payload begins at offset zero. Every later payload begins at:

```text
align_up(previous_offset + previous_size, 512)
```

Gaps are filled with `0x20`. There is no required trailing padding. Payloads
are not compressed and are stored either raw or with the XOR transform below.

## Path keys

Path strings are not stored. To derive an index key, canonicalize a candidate
path as follows. V7, XG1, V8, and jubeat also do this during lookup. V4-V6 hash
the supplied path directly, so it must already use the canonical spelling.

1. If it starts with `data/`, ignoring case, prepend `/`.
2. If the result starts with `/data/aep`, ignoring case, lowercase its ASCII
   letters.

All other bytes and case remain unchanged.

Both hashes are required for lookup. The primary key is reflected
CRC-32/ISO-HDLC with initial value `0xffffffff`, polynomial `0xedb88320`, and
final XOR `0xffffffff`. The secondary key is CRC-16/X-25 with initial value
`0xffff`, reflected polynomial `0x8408`, and final XOR `0xffff`.

For example, `/data/product/font/font16x16x8/0_0.img` hashes to CRC-32
`6cdf6a53` and CRC-16 `90dd`.

Names can only be recovered by testing candidates. The jubeat data also contains
70 unreachable historical records produced with CRC-32 initial value
`0xd9ad63cb` and CRC-16 initial value `0x059a`. These alternate initials describe
that stale bank, not a second runtime lookup mode.

## Payload cipher

Raw payloads occur in the examined GFDM V4-V6 and jubeat data. XOR payloads
occur in GFDM V7, XG1, and V8. Because V6 and V7 share a magic value, detect the
mode against plaintext MD5s or supply it externally.

For CRC-32 `H` and CRC-16 `S`, calculate unsigned 32-bit states:

```text
K[0]   = ROL32(H + S, 3)
K[n+1] = ROL32(K[n] + S, 3)
```

XOR each complete four-byte payload word with `LE32(K[n])`. For a final tail
of `r = size mod 4` bytes, the retail algorithm XORs all `r` corresponding key
bytes into only the first tail byte. The remaining tail bytes are unchanged.

```text
output[4n] = input[4n] XOR key_byte[0] XOR ... XOR key_byte[r - 1]
```

The transform is symmetric and restarts at state `K[0]` for every payload. It
does not depend on archive ID or archive offset.

## `finfolist.bin`

`finfolist.bin` starts with a `u32` record count followed by 88-byte records:

| Offset | Type | Description |
|---:|---|---|
| `0x00` | 64 bytes | NUL-terminated path |
| `0x40` | `u32` | Whole-file size |
| `0x44` | 16 bytes | Whole-file MD5 |
| `0x54` | `u32` | Result/group index |

For an archive, this MD5 duplicates the corresponding `packinfo.bin` archive
MD5. Rebuilding an archive therefore requires updating its payload records,
archive-table MD5, and matching `finfolist.bin` size and MD5.
