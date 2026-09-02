# PackFS

PackFS is a command-line tool for Konami PackFS data roots. It can inspect and
verify packed data, unpack files into a manifest workspace, and rebuild
selected archives after files have been added, removed, replaced, or resized.

See [PackFS format](FORMAT.md) for the binary layouts, path hashes, and
payload cipher.

## Download

Download the latest standalone executable from the
[GitHub Releases page](https://github.com/haste/packfs/releases/latest):

- [Linux x86-64](https://github.com/haste/packfs/releases/latest/download/packfs_linux_x86_64)
- [Windows x86-64](https://github.com/haste/packfs/releases/latest/download/packfs_windows_x86_64.exe)

## Commands

```text
packfs inspect TARGET [--records] [--json]
packfs verify TARGET [--archives] [--files] [--json]
packfs unpack SOURCE OUTPUT [options]
packfs add WORKSPACE SOURCE --path VIRTUAL_PATH [options]
packfs status WORKSPACE [--json]
packfs repack WORKSPACE OUTPUT [--force] [--quiet]
```

`TARGET` may be either a packed data root containing `pack/packinfo.bin` or an
extraction workspace containing `packfs-manifest.json`.

Inspect a single archive and include its records:

```sh
packfs inspect /games/gfdm/v8/data --pack 42 --records
```

Run structural checks plus complete archive and plaintext payload digests:

```sh
packfs verify /games/gfdm/v8/data --archives --files
```

Without `--archives` or `--files`, verification performs structural checks
only. For workspaces, `--files` checks extracted-file MD5s. `--archives` applies
only to packed data.

Extract all archives with the V8 name table:

```sh
packfs unpack /games/gfdm/v8/data ./gfdm/v8-workspace \
  --name-set gfdm-v8
```

Archive selections are repeatable and accept IDs, comma lists, and inclusive
ranges:

```sh
packfs unpack /games/gfdm/v8/data ./packs-10-20 \
  --pack 10-20 --pack 25,27 \
  --name-set gfdm-v8
```

Rebuild the archives represented by a workspace:

```sh
packfs repack ./gfdm/v8-workspace ./rebuilt-data
```

When a workspace contains only selected archives, the repacked output is an
overlay: it contains those `.pak` files plus updated complete index files. The
untouched index records still refer to archives from the original data root.

Use `--json` with `inspect` or `verify` for stable machine-readable output. Use
`packfs help COMMAND` for every option.

## Extraction workspaces

An extraction uses this layout:

```text
workspace/
├── packfs-manifest.json
├── files/
│   ├── data/...
│   └── __unknown__/<crc32>-<crc16>-<record>.bin
├── updates/
│   └── <name>/data/...
└── original/
    ├── packinfo.bin
    └── finfolist.bin
```

Runtime files retain their paths under `files/`. Alternate-CRC records go under
`updates/<name>/`, and unknown records use stable names under
`files/__unknown__/`. Edit or delete tracked files in place. Use `packfs add` for
new files and `packfs status` to review `M`, `D`, and `A` changes. Additions use
the sole selected archive or require `--pack ID`. Retained-update additions
require `--update NAME:CRC32:CRC16`.

## Path name sets

The executable bundles self-contained path lists for these games:

| Name set | Resolved | Missing | Notes |
|---|---:|---:|---|
| `gfdm-v4` | 5,780 / 5,780 | 0 | Complete |
| `gfdm-v5` | 6,447 / 6,447 | 0 | Complete |
| `gfdm-v6` | 6,821 / 6,821 | 0 | Complete |
| `gfdm-v7` | 7,431 / 7,541 | 110 | 110 unresolved path hashes |
| `gfdm-v8` | 7,803 / 8,023 | 220 | 220 unresolved path hashes |
| `gfdm-xg1` | 8,447 / 8,638 | 191 | 191 unresolved path hashes |
| `jubeat` | 575 / 575 | 0 | 505 current + 70 pre-update |
| `jubeat-ripples` | 800 / 800 | 0 | Complete |
| `jubeat-ripples-append` | 903 / 903 | 0 | Complete |

`all` is the default. A release-specific set is faster and avoids treating a
cross-release double-hash alias as a valid name. `--name-set` is repeatable,
and `--names FILE` adds exact newline-delimited candidates. User-supplied files
take precedence over bundled candidates. Equal-priority collisions remain
unresolved and produce a warning.

Missing names do not prevent unpacking or repacking. Those records appear under
`files/__unknown__`.

The `jubeat` set puts its 70 retained records under `updates/pre-update/`.
Additional update CRCs use:

```sh
packfs unpack DATA_ROOT WORKSPACE \
  --names paths.txt \
  --update pre-update:d9ad63cb:059a
```

CRC initials are hexadecimal. Repacking preserves the indexed keys.

## Development

The repository uses [mise](https://mise.jdx.dev/) to install the pinned
development toolchain and run project tasks. After cloning the repository:

```sh
mise install
mise run check
```

The full check runs the formatter in check mode, compiles with warnings treated
as errors, runs the test suite, and applies the strict lint configuration.
Individual tasks are also available while iterating:

```sh
mise run format
mise run compile
mise run test
mise run credo
```

Run the CLI directly through Mix while developing:

```sh
mix packfs --help
mix packfs inspect /path/to/data
```

To test the escript entry point used outside Mix:

```sh
mix escript.build
./packfs --help
```

Build the Linux x86-64 standalone executable with:

```sh
mise run release
```

The executable is written to `burrito_out/packfs_linux_x86_64`.

Build the Windows x86-64 standalone executable with:

```sh
mise run release-windows
```

The executable is written to `burrito_out/packfs_windows_x86_64.exe`.
