# FPGA Audio Effect Device — Custom DMA & Dual-Processor DSP

Mini-project for the EPFL *Embedded Systems* course (June 2023).  
Team: Albian Salihu, Andy Piantoni. Both the hardware design and firmware were developed jointly throughout.

A quasi-real-time audio effect device on the Intel DE1-SoC FPGA board. A microphone records audio, two custom hardware IP cores (a DMA controller and an interrupt-based mailbox) coordinate data movement between two independent Nios II soft-core processors, and the processed audio plays back through the speaker. All hardware IP was designed and implemented from scratch in VHDL.

---

## Result

The full pipeline ran successfully on hardware: 10 seconds of audio recorded via microphone, processed through an FFT-based low-pass filter across 480,000 samples, and played back through the speaker. The custom DMA and IRQ Sender IPs functioned correctly — interrupt-driven handoff between processors with zero polling, and proper Avalon back-pressure handling throughout.

---

## Repository Structure

```
hw/
  custom_DMA.vhd                  Custom DMA controller (Avalon Master + Slave)
  custom_interrupt_sender.vhd     Hardware IRQ mailbox (inter-CPU notification)
  DE1_SoC_top_level.vhd           Top-level VHDL entity; instantiates Audio_System Qsys component
  tb_custom_DMA.vhd               Testbench for custom_DMA
  tb_custom_interrupt_sender.vhd  Testbench for customIRQSender
  Audio_System.qsys               Platform Designer (Qsys) system definition
  Audio_System.sopcinfo           Qsys-generated component info
  MiniProjectAudio.qpf            Quartus project file
  MiniProjectAudio_time_limited.sof  Pre-compiled bitstream (time-limited)

sw/
  Audio_CPU0/main0.c   CPU0 firmware — microphone recording
  Audio_CPU1/main1.c   CPU1 firmware — FFT processing and playback
```

---

## Hardware Architecture

### System Topology

The system uses three Avalon buses:

| Bus | Domain | Components |
|-----|--------|------------|
| Bus 0 | CPU0 | Nios II Processor 0, On-chip Memory 0, customIRQSender, IP Timer 0 |
| Bus 1 | CPU1 | Nios II Processor 1, On-chip Memory 1, Custom DMA 0, Custom DMA 1, IP Audio Ctrl, IP Timer 1 |
| Bus 2 | Shared | IP Audio (WM8731 CODEC), IP PIO (8-bit switches), SDRAM Controller |

The two processors have isolated address spaces except for shared Bus 2. Inter-processor communication is handled entirely through the custom hardware IPs — no shared-memory flag polling.

The WM8731 CODEC operates at 48 kHz, clocked by a 12.288 MHz PLL.  
CPU0 records 480,256 samples (`MAX_SEND_DATA = 480,256`); CPU1 processes 479,232 (`MAX_SEND_DATA = 479,232`). The last 1,024 samples CPU0 records are never processed — a minor off-by-one in the original `#define` values.

---

### Custom DMA (`custom_DMA.vhd`)

The DMA controller is the centrepiece of the project. Two instances are used:

- **DMA 0**: transfers a 1024-sample chunk from SDRAM → on-chip memory (CPU1) for processing
- **DMA 1**: writes the processed chunk back from on-chip memory → SDRAM

Each instance is both an **Avalon Master** (drives the memory bus autonomously) and an **Avalon Slave** (exposes a register interface for CPU1 to configure and start it).

#### Register Map

| Offset | Register | Description |
|--------|----------|-------------|
| 0×00 | `RegAddStartSrc` | Source start address in memory |
| 0×04 | `RegAddStartDst` | Destination start address in memory |
| 0×08 | `RegLgtTable` | Number of elements to transfer |
| 0×0C | `RegNbByte` | Size of each element in bytes |
| 0×10 | `Start` | Write 1 to begin transfer |
| 0×14 | `Finish` | Set by FSM when transfer is complete |
| 0×18 | `StopMaster` | Emergency stop (halts mid-transfer) |
| 0×1C | `AckIRQ` | Write to acknowledge the completion IRQ |

#### FSM Design

The transfer is orchestrated by a 7-state FSM:

```
Idle → LdParam → RdAcc → WaitRd → WriteValue → WrEnd → EndTable
                   ↑___________________________|
```

- **Idle**: waits for `Start = 1`
- **LdParam**: latches source address, destination address, length, and byte-width from registers
- **RdAcc**: asserts `avm_Rd` to request the next word from the source address
- **WaitRd**: stalls until `avm_WaitRequest` deasserts (Avalon back-pressure from SDRAM controller)
- **WriteValue**: asserts `avm_Wr` with the buffered data to write to the destination address
- **WrEnd**: waits for the write to be acknowledged
- **EndTable**: if more elements remain, loops to `RdAcc` with incremented addresses; otherwise sets `Finish`, raises `IRQ`, and returns to `Idle`

Avalon back-pressure is handled natively — the DMA stalls mid-transfer when the SDRAM controller is busy, with no CPU intervention required.

---

### Custom IRQ Sender (`custom_interrupt_sender.vhd`)

A lightweight hardware mailbox. CPU0 needs to tell CPU1 the SDRAM address where recorded audio is stored, via a hardware interrupt rather than a shared-memory flag.

#### Register Map

| Offset | Register | Description |
|--------|----------|-------------|
| 0×00 | `RegMessage` | 32-bit payload (SDRAM base address from CPU0) |
| 0×04 | `RegAckIRQ` | Write to deassert the IRQ and clear the message |

**Flow**: CPU0 writes the SDRAM address to `RegMessage`. The component immediately raises `IRQ`. CPU1's ISR reads the address, then writes to `RegAckIRQ` to acknowledge and lower the line. CPU0 never needs to poll; CPU1 is interrupt-driven.

---

### Top-Level (`DE1_SoC_top_level.vhd`)

Connects the DE1-SoC board pins to the Qsys-generated `Audio_System` component:

- `CLOCK_50` → Qsys system clock
- `KEY_N(0)` → active-low system reset
- `SW(7:0)` → PIO input (switch 0 triggers recording, switch 1 triggers playback)
- `AUD_*` → WM8731 CODEC I²S signals
- `FPGA_I2C_*` → CODEC configuration over I²C
- `DRAM_*` → SDRAM (32 MB, 16-bit bus)

---

## Software Architecture

### CPU0 — Recording (`sw/Audio_CPU0/main0.c`)

CPU0's role is simple and single-shot:

1. Register an ISR on the PIO interrupt (hardware switch 0)
2. When the switch is flipped, set `start_recording = 1`
3. Poll the Audio IP right-channel FIFO; for each available sample write it to `sdramData[count]`
4. Once `count` reaches `MAX_SEND_DATA` (480,000 samples ≈ 10 s at 48 kHz), write the SDRAM base address into the `customIRQSender` register, triggering CPU1

CPU0 only does sequential writes to SDRAM — no cache coherency issues on the record path.

### CPU1 — Processing (`sw/Audio_CPU1/main1.c`)

CPU1 is fully interrupt-driven. It registers three ISRs at startup:

| ISR | Trigger | Action |
|-----|---------|--------|
| `isr_irqSender` | customIRQSender IRQ | Latch SDRAM address; set `flag = 1` |
| `isr_DMA_recieve` | DMA 0 complete | Acknowledge IRQ; set `start_send = 1` |
| `isr_DMA_send` | DMA 1 complete | Acknowledge IRQ; advance `count`; set `start_recieve = 1` |

Main loop flow per 1024-sample chunk:

```
flag detected
  └─ start_recieve=1 → DMA 0: SDRAM[count..count+1024] → data1[]
                         └─ isr_DMA_recieve → start_send=1
                              └─ FFT(data1) → low-pass filter → IFFT(data1) → normalise
                                   └─ count+=1024; DMA 1: data1[] → SDRAM[count-1024..count]
                                        └─ isr_DMA_send → start_recieve=1
                                             └─ (next chunk)
```

After all chunks are processed, a second switch press (`start_listening == 2`) triggers playback: CPU1 streams the full SDRAM buffer sample-by-sample into the Audio IP left and right FIFOs.

### Signal Processing

The filter operates in the frequency domain on 1024-sample blocks:

1. **Forward FFT** — `kiss_fftr` (KissFFT, real-valued 1024-point)
2. **Low-pass filter** — zero all bins where `freq = (i × 24000) / 1024 ≥ 20000 Hz`
3. **Inverse FFT** — `kiss_fftri`
4. **Normalise** — divide each output sample by `SIZE_FFT` (1024)

With 48 kHz sampling and Nyquist at 24 kHz, the filter removes the top ~4 kHz band. A custom recursive Cooley-Tukey FFT/IFFT (conjugate-based IFFT) was also implemented in C and validated against KissFFT output; KissFFT was selected for the final pipeline due to its lower memory footprint on the Nios II.

---

## Build & Run

### Prerequisites

| Tool | Version |
|------|---------|
| Intel Quartus Prime | 18.1 or later (for `.qpf` / `.qsys`) |
| Nios II EDS (Eclipse) | matching Quartus version |
| KissFFT | [github.com/mborgerding/kissfft](https://github.com/mborgerding/kissfft) |

### Hardware (Quartus)

```
1. Open hw/MiniProjectAudio.qpf in Quartus Prime.
2. Run Platform Designer (Qsys) on hw/Audio_System.qsys to regenerate HDL if needed.
3. Compile the project (Processing → Start Compilation).
4. Program the FPGA: Tools → Programmer → add the .sof file and click Start.
   (A pre-compiled bitstream is provided at hw/MiniProjectAudio_time_limited.sof —
    it is time-limited and will stop functioning after ~1 hour of operation.)
```

### Software (Nios II EDS)

```
1. In Nios II EDS (Eclipse), import the two BSP projects:
     sw/Audio_CPU0_bsp  (linked to Audio_CPU0/main0.c)
     sw/Audio_CPU1_bsp  (linked to Audio_CPU1/main1.c)
2. Add KissFFT to the CPU1 project:
   - Copy the KissFFT source files into the project (or add the include path).
   - The include directive in main1.c is: #include "kiss_fft.h"
3. Generate the BSPs (right-click each BSP → Nios II → Generate BSP).
4. Build both projects.
5. Use the Nios II flasher to download both ELFs to the corresponding processor
   on-chip memories.
```

### Usage

```
1. Power on the DE1-SoC with the FPGA programmed and both CPUs running.
2. Connect a microphone to the Line-In / Mic jack and headphones to Line-Out.
3. Flip SW0 (switch 0) → CPU0 begins recording for 10 seconds.
4. Wait for CPU0 to signal CPU1 (UART log: "CPU0: recording complete").
5. CPU1 runs FFT/filter/IFFT on all 480,000 samples (watch the "Processing: N%" log).
6. Flip SW0 again → CPU1 begins playback of the processed audio.
```

---

## Known Limitations

- **Not real-time**: the pipeline is record-all → process → playback. True real-time streaming would require double-buffering and pipelined DMA chaining.
- **Trivial filter effect**: the 20 kHz cutoff is just below Nyquist; the perceptual difference is minimal. A lower cutoff (e.g. 1–2 kHz for a telephone effect) would be more audible.
- **Blank spots in playback**: some 1024-sample windows came back corrupted, likely due to Nios II data cache coherency — the cache was not flushed (`alt_dcache_flush`) before DMA reads.
- **Off-by-1024 sample count**: CPU0's `MAX_SEND_DATA` is 480,256 while CPU1's is 479,232. The last 1,024 samples CPU0 records are therefore never processed.
- **Sequential pipeline**: one chunk is fully processed before the next begins, rather than overlapping DMA 0, computation, and DMA 1.

---

## Portfolio Note

This repository is a cleaned-up version of the original EPFL Embedded Systems submission. All hardware logic and firmware algorithms are **untouched**. Changes were limited to: fixing a compile error in `tb_custom_DMA.vhd` (stateTest port reference), fixing a hardcoded absolute Windows path for KissFFT in `main1.c`, removing unused debug signals and variables across both firmware files, and translating French comments to English.
