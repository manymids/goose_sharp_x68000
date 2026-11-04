# Goose Sharp X68000

*[日本語版 README](README.md)*

A Sharp X68000 emulator for Windows, implementing the CPU, memory, peripherals, and video rendering in the Goose language. It supports a Win32 GUI as well as an ARCL MCP server that can be driven from external tools over stdio. Development is based on a port from `arcl_windows_x68k`.

Compatibility work is ongoing. Boot and save/restore have been verified with Chourenjin 68K and the floppy-less X68000 version of Doom, but correct operation is not guaranteed for all software or against real hardware. The BIOS, CG-ROM, OS, games, and disk images are not included.

## Distribution layout

This folder is a source-distribution layout. It does not include a prebuilt exe, BIOS, media images, or development test/measurement tools.

```text
goose_sharp_x68000/
  README.md
  README.en.md
  THIRD_PARTY_NOTICES.md
  .gitignore
  src/
    main.goose           Entry point for startup, GUI, and ARCL
    main.build            C/C++ source and Win32 library specification
    m68k_*.goose          CPU, MMU
    mcp_server.goose      ARCL MCP
    x68k_*.goose          Devices, rendering, save state, shared services
    x68k_bridge.c/.h      Win32, file I/O, audio output
    x68k_config.c/.h      Loading/saving GUI settings
    sound/                FMGEN, ADPCM, sound source wiring
```

The startup examples below assume you build the exe at the project root and run it with that root as the current directory. `src` is where the source lives and is not normally used as the working directory for running the emulator.

## First launch

This targets Windows x64 environments. First, build `src/main.goose` using the steps described later to produce `arcl_windows_x68k_goose.exe` at the project root. If you have a separately distributed exe, you can use it with the same layout.

Place a `keropi` folder in the **current directory** at launch time. This is the reference point regardless of where the exe itself is located.

```text
goose_sharp_x68000/
  src/                         Distributed source
  arcl_windows_x68k_goose.exe   Created after building
  arcl_windows_x68k_goose.ini   Created when the GUI runs
  keropi/
    iplrom.dat     Required: 131,072 bytes (128 KiB)
    cgrom.dat      Required: 786,432 bytes (768 KiB)
    sram.dat       Optional: 16,384 bytes (16 KiB)
```

You are responsible for obtaining the ROM files and confirming you have the rights to use them. The emulator can start without `sram.dat`; it will be saved to the BIOS directory on normal exit. RAM is fixed at 12 MB, and the RAM-size field inside SRAM is set to match.

Launch from PowerShell after moving into this folder.

```powershell
Set-Location C:\work\goose_sharp_x68000
.\arcl_windows_x68k_goose.exe
```

On first launch, **FD0, FD1, and the HDD are all unset**. The emulator does not search for or auto-insert images from a particular game or a neighboring project. Select an image from the GUI's disk menu. The default settings are 10 MHz, 1x display scale, and an initial display width of 768.

You can also specify an alternate BIOS directory or a boot disk directly.

```powershell
.\arcl_windows_x68k_goose.exe --system-dir C:\MyROMs\keropi C:\Disks\boot.xdf
.\arcl_windows_x68k_goose.exe --clock 16 C:\Disks\system.hdf
```

## GUI operation

| Menu / Key | Action |
|---|---|
| File → Reset / F5 | Resets the machine; in the GUI, execution resumes |
| FD0 → Open / Eject | Insert/eject the boot floppy. A successful insert triggers a reset |
| FD1 → Open / Eject | Insert/eject the second floppy |
| HDD → Open / Eject | Insert/eject the SASI HDD. A successful insert ejects both floppies and triggers a reset |
| View → 1x / 2x Scale | Window display scale |
| View → Initial Screen | Initial display size setting, 768×512 / 512×512 |
| Clock | Change the CPU clock |
| Esc / Alt+F4 | Quit the GUI |

The actual on-screen resolution can change after boot depending on the guest's CRTC settings. Initial Screen only controls the initial display size; it does not lock the guest's video mode.

In addition to keyboard input, the arrow keys plus `Z` / `X` and Space / Enter are mapped to port 1 joypad input. Mouse and SCC are not supported.

## Saving GUI settings and priority order

By default, the GUI reads `arcl_windows_x68k_goose.ini` from the current directory. Settings are saved when you change the clock, display, or disks from the menu, and on normal exit.

The saved items are the BIOS directory, the FD0/FD1/HDD selections, the clock speed, the scale, and the initial display width. Ejecting a disk is also saved. If a disk has been moved or deleted and can no longer be loaded, the emulator warns and starts without that media.

For the regular GUI, the priority order is **explicit launch arguments → saved GUI settings → defaults**.

- Specifying a disk as an argument ignores all saved media and boots with only that disk.
- `--no-disk` ignores all saved media and boots with nothing inserted.
- `--clock` / `--system-dir` / `--scale` / `--mode` each take priority over the corresponding saved value.
- The settings last used in the regular GUI are saved for the next GUI launch.
- **ARCL (`--mcp`) and headless mode (`--no-window`) neither read nor write GUI settings.** Launch arguments and ARCL operations take priority and are not affected by whatever clock or disk was last used in the GUI.

Example configuration. Paths that are saved automatically are absolute. Relative paths you edit by hand are resolved against the current directory at launch time. The BIOS location can be changed either through this field or via `--system-dir`.

```ini
[gui]
version=1
clock_mhz=10
scale=1
screen_width=768
bios_dir=.\keropi
fd0=
fd1=
hdd=
```

To reset to defaults, quit the application and move the INI file aside under a different name. Settings are saved by writing to a temporary file and then replacing the existing one; if the write fails, the existing settings are left intact. Use a current directory you have write permission to.

## Supported features

| Item | Implementation / Scope |
|---|---|
| CPU / RAM | Motorola 68000, RAM fixed at 12 MB |
| Clock | 10 / 16 / 25 / 50 / 75 / 100 / 150 / 200 / 250 MHz |
| Video | TVRAM/GVRAM, CRTC, palette, sprites, BG, plane compositing |
| Peripherals | MFP, FDC, DMAC, SASI, RTC (RP5C15) |
| Floppy | FD0/FD1, raw `.2HD` / `.xdf`, DIM, D88. `.img` / `.bin` can also be selected as raw images |
| HDD | SASI, `.hdf` / `.hds`, up to 40 MiB. `.img` can also be selected from the GUI's HDD menu |
| Audio | YM2151 / ADPCM mixing, Win32 waveOut output |
| Screenshots | BMP output |
| Save states | In-process regular slots, named snapshots, and rewind |

For disk arguments on the command line, `.hdf` / `.hds` are treated as an HDD, and everything else as a floppy. Writes the guest performs to a disk are kept in memory and are not written back to the original image file. GUI settings only remember the media selection; the file itself is re-read from disk the next time the emulator starts.

## ARCL MCP

Launch it from an stdio-capable MCP client as follows. It starts paused. Use `arcl_run` to execute a specified number of frames, or `arcl_resume` to continue running.

```powershell
.\arcl_windows_x68k_goose.exe --mcp --no-window --system-dir C:\work\goose_sharp_x68000\keropi
```

Example client registration. Change `command` and `--system-dir` to absolute paths for your environment. Specifying media is optional.

```json
{
  "mcpServers": {
    "x68000": {
      "command": "C:\\work\\goose_sharp_x68000\\arcl_windows_x68k_goose.exe",
      "args": ["--mcp", "--no-window", "--system-dir", "C:\\work\\goose_sharp_x68000\\keropi"]
    }
  }
}
```

Stdin/stdout use newline-delimited JSON-RPC, and diagnostics are written to stderr. If you drop `--no-window`, you can use the ARCL connection together with the on-screen display. In that case the GUI settings file is still not used.

The layers exposed by default are L0 and L1. To use debugging, device observation, snapshots, etc., pass `--mcp-layers all`, or a list such as `l0,l1,l2`. The basic execution-control and regular save tools are available regardless of the layer setting.

| Category | Main tools |
|---|---|
| Execution control | `arcl_status`, `arcl_run`, `arcl_pause`, `arcl_resume`, `arcl_reset` |
| Input / Display (L0) | `arcl_key`, `arcl_type`, `arcl_joypad`, `arcl_clear_input`, `arcl_input_state`, `arcl_input_macro`, `arcl_screenshot` |
| Console (L1) | `arcl_console_read`, `arcl_command`, `arcl_mount` |
| Debugging (L2) | `arcl_registers`, `arcl_read_mem`, `arcl_write_mem`, `arcl_step`, `arcl_breakpoint`, `arcl_disasm` |
| Device observation (L3) | `arcl_video`, `arcl_irq`, `arcl_dma`, `arcl_vram`, `x68k_opm` |
| Save state | `arcl_save_state`, `arcl_load_state`, `arcl_snapshot` / `arcl_rewind` (L4) |

Check the exact set of exposed tools and their arguments via `tools/list` on the connection. Regular save states use 10 slots numbered 0–9, named snapshots allow up to 32 entries, and rewind holds 8 entries. These are all in-memory saves and do not support resuming from a file after the process has exited.

A successful restore pauses execution and invalidates stale host input, pending audio playback, and any derived screen output. The saved MFP queue and joypad values are restored as part of the machine state. If you need a fresh screen, execute the next frame. Full mid-frame resumption from something like a PC breakpoint is not guaranteed.

## Command line

```text
arcl_windows_x68k_goose.exe [options] [disk-image]
```

| Option | Meaning |
|---|---|
| `--system-dir PATH` | BIOS directory. Default is `<current directory>\keropi` |
| `--clock MHZ` | CPU clock. Default is 10 |
| `--scale 1\|2` | Initial window scale |
| `--mode 512\|768` | Initial display width. `512x512` / `768x512` can also be specified |
| `--no-disk` | Ignore saved media and boot empty |
| `--mcp` | Enable the ARCL MCP server. GUI settings are not used |
| `--mcp-layers LIST` | Layers to expose. e.g. `all`, `l0,l1,l2` |
| `--no-window` | Don't open a window. GUI settings are not used |
| `--frames N` | End regular execution after N frames. Not used with ARCL |
| `--dump-frame PATH` | Destination for the BMP screenshot during regular execution. The `.bmp` extension is recommended |
| `--dump-after-frames N` | Frame at which the screenshot is taken. Default is 1200 |
| `--ram N` | Accepted for compatibility, but RAM is fixed at 12 MB |
| `--help` / `-h` | Show help and exit |

Example of running headlessly for a fixed number of frames and saving a screenshot. When using `--no-window` outside of ARCL, you need either `--frames` or `--dump-frame`.

```powershell
.\arcl_windows_x68k_goose.exe --no-window --system-dir .\keropi `
  --frames 1200 --dump-frame screen.bmp .\Disks\boot.xdf
```

## Building from source

You need the Goose compiler and standard library, plus an MSVC C/C++ build environment and the Windows SDK. The Goose compiler itself is not included in this source distribution. Run the build from a development PowerShell (or similar) where MSVC commands are available, from the **project root**.

```powershell
Set-Location C:\work\goose_sharp_x68000
goose build .\src\main.goose -o .\arcl_windows_x68k_goose.exe
```

Use a different output name for debug builds.

```powershell
goose build .\src\main.goose --debug -o .\arcl_windows_x68k_goose_debug.exe
```

Goose uses [src/main.build](src/main.build), located in the same folder as the source. The relative paths in `c_sources` and `c_include` assume this layout, so keep the files under `src` and the `sound` folder together. The C/C++ parts are `src/x68k_bridge.c`, `src/x68k_config.c`, and `src/sound/`.

Using `-o` to output the exe at the project root also keeps the locations of `keropi` and the INI file clear at runtime. Even if you place the exe inside `src`, the reference point for the BIOS and INI files is the current directory at launch time, not the exe's own location.

This public-distribution layout does not include `tools/architecture/build.ps1` from the original development tree. Use the Goose commands above instead.

## Implementation and verification scope

| Location | Responsibility |
|---|---|
| [src/main.goose](src/main.goose) | Launch arguments, GUI/ARCL event loop |
| `src/m68k_*` | CPU instructions, MMU |
| `src/x68k_mfp/fdc/dmac/sasi/rtc.goose` | Peripherals |
| [src/x68k_ppu.goose](src/x68k_ppu.goose) | Scanline processing and rendering composition |
| [src/x68k_emu.goose](src/x68k_emu.goose) | Frame progression and shared reset logic |
| [src/x68k_state.goose](src/x68k_state.goose) | Shared save logic for regular saves, snapshots, and rewind |
| [src/x68k_session.goose](src/x68k_session.goose) / [src/x68k_input.goose](src/x68k_input.goose) | Shared execution control and input handling across frontends |
| [src/mcp_server.goose](src/mcp_server.goose) | JSON-RPC parsing, exposed tools, responses |
| [src/x68k_config.c](src/x68k_config.c) | GUI INI handling. Independent of machine save states |
| `src/x68k_bridge.c` / `src/sound/` | Win32, file I/O, audio device and mixing |

In the original development tree, release/debug CPU, device, save, lifecycle-management, and configuration tests have been run, along with confirming boot and save/restore for Chourenjin 68K and Doom. For configuration, separation from ARCL, CLI priority, the initial empty boot, and retaining the existing INI on a failed write have also been verified.

**This public-distribution layout does not include `test_*.goose`, the corresponding test `.build` files, `tools/architecture/`, or the development `ARCHITECTURE_*.md` files.** The verification described above was performed in the original development tree; it does not mean the same automated tests can be re-run from this folder alone.

## Troubleshooting and known limitations

- If the BIOS can't be found, check the current directory, the location of `keropi`, and the file names/sizes. Specifying an absolute path with `--system-dir` can also help narrow down the issue. There is no automatic fallback to ROMs from another project or next to the exe.
- If the GUI starts with an unintended disk, either launch with `--no-disk` or move the INI file aside after quitting. ARCL does not read the INI.
- If no audio device is available, the emulator warns and runs silently.
- The current file dialog and path handling have Win32 character-encoding and `MAX_PATH` constraints. If you run into path issues, try testing with a short, alphanumeric folder name.
- The emulator assumes a single registered machine instance. Core sharing across multiple instances, persistent save-state storage, a mouse, and full compatibility with every VRAM mode/piece of software are unsupported or unverified.

When reporting a bug, please include the build type, Windows environment, launch arguments, image format, reproduction steps, and logs or screenshots. There's no need to attach the BIOS or the game itself.

## Provenance and rights information

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the provenance of the original port and the sound code, and [src/sound/fmgen-readme.txt](src/sound/fmgen-readme.txt) for the original text of the bundled FMGEN notes and terms. Note the distinction between the Goose compiler's own license and the terms of the ported/third-party code included in the emulator.

Rights to the BIOS, CG-ROM, OS, games, and disk images belong to their respective rights holders. The source distribution does not include this actual data, nor any personal SRAM or configuration files.
