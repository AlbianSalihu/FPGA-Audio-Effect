#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <stdlib.h>
#include <math.h>
#include <complex.h>

#include "../Audio_CPU1_bsp/drivers/inc/altera_up_avalon_audio.h"
#include "../Audio_CPU1_bsp/system.h"
#include "../Audio_CPU1_bsp/HAL/inc/io.h"
#include "../Audio_CPU1_bsp/HAL/inc/sys/alt_irq.h"
#include "../Audio_CPU1_bsp/HAL/inc/sys/alt_cache.h"

// KissFFT must be present on the compiler include path (add the library sources
// to the Nios II EDS BSP project and configure the include directory accordingly).
#include "kiss_fft.h"

// Configuration -------------------------------------------------------------------
#define SECONDS        10
#define MAX_SEND_DATA  (((SECONDS * 48000) / 1024) * 1024)  // 480,000 samples

#define DMA_OFFSET_SOURCE      (4 * 0)
#define DMA_OFFSET_DESTINATION (4 * 1)
#define DMA_OFFSET_START       (4 * 4)
#define DMA_OFFSET_LENGTH      (4 * 2)
#define DMA_OFFSET_LENGTH_BYTE (4 * 3)
#define DMA_OFFSET_ACKIRQ      (4 * 7)

#define PIO_OFFSET_EDGECAPTURE   (3 * 4)
#define PIO_OFFSET_DIRECTION     (1 * 4)
#define PIO_OFFSET_INTERRUPTMASK (2 * 4)

#define START       1
#define RESET_START 0
#define SIZE_FFT    1024
#define SIZE_DATA_BYTE 2
#define ACK_IRQ     1
#define FORWARD     0
#define INVERSE     1
// ---------------------------------------------------------------------------------

// Prototypes ----------------------------------------------------------------------
static void isr_irqSender(void* context);
static void isr_DMA_send(void* context);
static void isr_DMA_recieve(void* context);
static void pio_isr(void* context);

void fft(complex double *x, int N);
void ifft(complex double *x, int N);
// ---------------------------------------------------------------------------------

// Global state (written by ISRs, read in main loop) --------------------------------
uint32_t flag           = 0;  // set by isr_irqSender when CPU0 sends SDRAM address
uint32_t address        = 0;  // SDRAM base address received from CPU0
uint32_t start_transform = 0;
uint32_t start_listening = 0;
uint32_t start_recieve  = 0;  // triggers DMA 0 (SDRAM → on-chip)
uint32_t start_send     = 0;  // triggers FFT+filter+IFFT and DMA 1 (on-chip → SDRAM)
// ---------------------------------------------------------------------------------

int main()
{
    printf("CPU1: starting\n");

    // Register interrupt service routines
    void *ptr = (void*) NULL;
    alt_ic_isr_register(CUSTOM_INTERRUPT_SENDER_0_IRQ_INTERRUPT_CONTROLLER_ID,
            CUSTOM_INTERRUPT_SENDER_0_IRQ, isr_irqSender, ptr, ptr);

    alt_ic_isr_register(CUSTOM_DMA_RECIEVE_IRQ_INTERRUPT_CONTROLLER_ID,
            CUSTOM_DMA_RECIEVE_IRQ, isr_DMA_recieve, ptr, ptr);

    alt_ic_isr_register(CUSTOM_DMA_SEND_IRQ_INTERRUPT_CONTROLLER_ID,
            CUSTOM_DMA_SEND_IRQ, isr_DMA_send, ptr, ptr);

    alt_ic_isr_register(PIO_0_IRQ_INTERRUPT_CONTROLLER_ID, PIO_0_IRQ, pio_isr, ptr, ptr);

    alt_irq_cpu_enable_interrupts();

    // Configure PIO switch
    IOWR_16DIRECT(PIO_0_BASE, PIO_OFFSET_DIRECTION,     0x00); // input
    IOWR_16DIRECT(PIO_0_BASE, PIO_OFFSET_EDGECAPTURE,   0x0f);
    IOWR_16DIRECT(PIO_0_BASE, PIO_OFFSET_INTERRUPTMASK, 0x0f);

    // Initialise DMA 0 (SDRAM → on-chip memory)
    IOWR_32DIRECT(CUSTOM_DMA_RECIEVE_BASE, DMA_OFFSET_LENGTH,      SIZE_FFT);
    IOWR_32DIRECT(CUSTOM_DMA_RECIEVE_BASE, DMA_OFFSET_LENGTH_BYTE, SIZE_DATA_BYTE);
    IOWR_32DIRECT(CUSTOM_DMA_RECIEVE_BASE, DMA_OFFSET_START,       RESET_START);
    IOWR_32DIRECT(CUSTOM_DMA_RECIEVE_BASE, DMA_OFFSET_ACKIRQ,      ACK_IRQ);

    // Initialise DMA 1 (on-chip memory → SDRAM)
    IOWR_32DIRECT(CUSTOM_DMA_SEND_BASE, DMA_OFFSET_LENGTH,      SIZE_FFT);
    IOWR_32DIRECT(CUSTOM_DMA_SEND_BASE, DMA_OFFSET_LENGTH_BYTE, SIZE_DATA_BYTE);
    IOWR_32DIRECT(CUSTOM_DMA_SEND_BASE, DMA_OFFSET_START,       RESET_START);
    IOWR_32DIRECT(CUSTOM_DMA_SEND_BASE, DMA_OFFSET_ACKIRQ,      ACK_IRQ);

    // Local variables
    alt_u16 *sdramData;

    // KissFFT configuration objects (allocated once, reused for every chunk)
    kiss_fft_cfg cfgForward = kiss_fftr_alloc(SIZE_FFT, FORWARD, NULL, NULL);
    kiss_fft_cfg cfgInverse = kiss_fftr_alloc(SIZE_FFT, INVERSE, NULL, NULL);

    // On-chip working buffer (DMA target / FFT source)
    alt_u16       data1[SIZE_FFT];
    kiss_fft_cpx  tableIFFT[SIZE_FFT / 2 + 1];
    kiss_fft_scalar tableFFT[SIZE_FFT];

    int count       = 0;
    int countListen = 0;
    int freq        = 0;

    alt_up_audio_dev *audio_dev;

    audio_dev = alt_up_audio_open_dev("/dev/audio_0");
    if (audio_dev == NULL)
        printf("Error: could not open audio device\n");
    else
        printf("Audio device opened\n");

    while (1)
    {
        // Step 1: CPU0 has finished recording — latch the SDRAM address and begin pipeline
        if (flag && !start_transform)
        {
            sdramData = (int*)address;
            printf("CPU1: starting FFT pipeline at SDRAM address 0x%x\n", &sdramData[0]);
            flag = 0;
            start_transform = 1;
            start_recieve = 1;
        }

        // Step 2: DMA 0 — read one 1024-sample chunk from SDRAM into on-chip buffer
        if (start_transform && (count < MAX_SEND_DATA) && start_recieve)
        {
            IOWR_32DIRECT(CUSTOM_DMA_RECIEVE_BASE, DMA_OFFSET_SOURCE,      &sdramData[count]);
            IOWR_32DIRECT(CUSTOM_DMA_RECIEVE_BASE, DMA_OFFSET_DESTINATION, data1);
            IOWR_32DIRECT(CUSTOM_DMA_RECIEVE_BASE, DMA_OFFSET_START,       START);
            start_recieve = 0;
        }

        // Step 3: FFT → low-pass filter → IFFT, then DMA 1 writes result back to SDRAM
        if (start_send && (count < MAX_SEND_DATA) && start_transform)
        {
            // Copy on-chip buffer into KissFFT scalar input
            for (int i = 0; i < SIZE_FFT; i++)
                tableFFT[i] = data1[i];

            // Forward FFT
            kiss_fftr(cfgForward, tableFFT, tableIFFT);

            // Low-pass filter: zero all bins at or above 20 kHz
            // Bin frequency: freq = (i * Fs/2) / N  where Fs = 48000, N = 1024
            for (int i = 0; i < SIZE_FFT; i++)
            {
                freq = (i * 48000 / 2) / SIZE_FFT;
                if (freq >= 20000)
                {
                    tableIFFT[i].r = 0;
                    tableIFFT[i].i = 0;
                }
            }

            // Inverse FFT
            kiss_fftri(cfgInverse, tableIFFT, tableFFT);

            // Normalise and write back to on-chip buffer
            for (int i = 0; i < SIZE_FFT; i++)
                data1[i] = tableFFT[i] / SIZE_FFT;

            // DMA 1 — write processed chunk from on-chip buffer back to SDRAM
            IOWR_32DIRECT(CUSTOM_DMA_SEND_BASE, DMA_OFFSET_SOURCE,      data1);
            IOWR_32DIRECT(CUSTOM_DMA_SEND_BASE, DMA_OFFSET_DESTINATION, &sdramData[count]);
            IOWR_32DIRECT(CUSTOM_DMA_SEND_BASE, DMA_OFFSET_START,       START);

            start_send = 0;
            count += SIZE_FFT;
            printf("Processing: %d%%\r", (count * 100 / MAX_SEND_DATA));
        }

        // Step 4: Playback — stream processed SDRAM buffer to audio FIFO
        // Requires a second switch press (start_listening == 2) after processing is complete
        int fifospace = alt_up_audio_write_fifo_space(audio_dev, ALT_UP_AUDIO_RIGHT);
        if (count >= MAX_SEND_DATA && countListen < MAX_SEND_DATA
                && fifospace > 0 && start_listening == 2)
        {
            alt_up_audio_write_fifo(audio_dev, &(sdramData[countListen]), 1, ALT_UP_AUDIO_RIGHT);
            alt_up_audio_write_fifo(audio_dev, &(sdramData[countListen]), 1, ALT_UP_AUDIO_LEFT);
            countListen += 1;
        }

        if (countListen >= MAX_SEND_DATA)
            break;
    }

    free(cfgInverse);
    free(cfgForward);
    return 0;
}

// ISR: customIRQSender — CPU0 has finished recording; read the SDRAM address
static void isr_irqSender(void* context)
{
    address = IORD_32DIRECT(CUSTOM_INTERRUPT_SENDER_0_BASE, 4 * 0);
    IOWR_32DIRECT(CUSTOM_INTERRUPT_SENDER_0_BASE, 1 * 4, 1); // acknowledge IRQ
    flag = 1;
    printf("CPU1: IRQ sender fired — SDRAM address: 0x%x\n", address);
}

// ISR: DMA 0 complete (SDRAM → on-chip) — signal main loop to run FFT
static void isr_DMA_recieve(void* context)
{
    IOWR_32DIRECT(CUSTOM_DMA_RECIEVE_BASE, DMA_OFFSET_ACKIRQ, ACK_IRQ);
    start_transform = 1;
    start_send = 1;
}

// ISR: DMA 1 complete (on-chip → SDRAM) — advance chunk pointer, trigger next DMA 0
static void isr_DMA_send(void* context)
{
    IOWR_32DIRECT(CUSTOM_DMA_SEND_BASE, DMA_OFFSET_ACKIRQ, ACK_IRQ);
    start_transform = 1;
    start_recieve = 1;
}

// ISR: PIO switch — second press enables playback
static void pio_isr(void* context)
{
    start_listening++;
    if (start_listening == 2)
        printf("CPU1: playback ready.\n");
    IOWR_16DIRECT(PIO_0_BASE, PIO_OFFSET_EDGECAPTURE, 0x0f);
}

// Custom Cooley-Tukey FFT (recursive, validated against KissFFT output).
// Not used in the final pipeline (KissFFT selected for lower memory footprint on Nios II),
// but included as a reference implementation.
void fft(complex double *x, int N)
{
    if (N <= 1)
        return;

    complex double *xeven = malloc((N / 2) * sizeof(complex double));
    complex double *xodd  = malloc((N / 2) * sizeof(complex double));

    for (int i = 0; i < N / 2; i++)
    {
        xeven[i] = x[2 * i];
        xodd[i]  = x[2 * i + 1];
    }

    fft(xeven, N / 2);
    fft(xodd,  N / 2);

    for (int k = 0; k < N / 2; k++)
    {
        complex double t = cexp(-I * 2 * M_PI * k / N) * xodd[k];
        x[k]       = xeven[k] + t;
        x[k + N/2] = xeven[k] - t;
    }

    free(xeven);
    free(xodd);
}

// Conjugate-symmetry IFFT: conjugate → FFT → conjugate and scale by 1/N
void ifft(complex double *x, int N)
{
    if (N <= 1)
        return;

    for (int i = 0; i < N; i++)
        x[i] = conj(x[i]);

    fft(x, N);

    for (int i = 0; i < N; i++)
        x[i] = conj(x[i]) / N;
}
