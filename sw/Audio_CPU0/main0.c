#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <stdlib.h>

#include "../Audio_CPU0_bsp/drivers/inc/altera_up_avalon_audio.h"
#include "../Audio_CPU0_bsp/drivers/inc/altera_up_avalon_audio_and_video_config.h"
#include "../Audio_CPU0_bsp/drivers/inc/altera_avalon_mutex.h"

#include "../Audio_CPU0_bsp/system.h"
#include "../Audio_CPU0_bsp/HAL/inc/io.h"
#include "../Audio_CPU0_bsp/HAL/inc/sys/alt_irq.h"

// Configuration -------------------------------------------------------------------
#define SECONDS        10
#define MAX_SEND_DATA  (((SECONDS * 48000) / 1024) * 1024 + 1024)  // ~480k samples
#define SIZE_FFT       1024
#define SIZE_DATA_BYTE 2

#define DMA_OFFSET_LENGTH      (4 * 2)
#define DMA_OFFSET_LENGTH_BYTE (4 * 3)

#define PIO_OFFSET_EDGECAPTURE   (3 * 4)
#define PIO_OFFSET_DIRECTION     (1 * 4)
#define PIO_OFFSET_INTERRUPTMASK (2 * 4)

#define INTERRUPT_SENDER_OFFSET_DATA (0 * 4)
// ---------------------------------------------------------------------------------

// Prototypes ----------------------------------------------------------------------
static void my_isr(void* context);
// ---------------------------------------------------------------------------------

// Global state --------------------------------------------------------------------
int start_sending   = 0;
int start_recording = 0;
// ---------------------------------------------------------------------------------

int main()
{
    printf("CPU0: starting\n");

    void *ptr = (void*) NULL;
    alt_ic_isr_register(PIO_0_IRQ_INTERRUPT_CONTROLLER_ID, PIO_0_IRQ, my_isr, ptr, ptr);

    IOWR_16DIRECT(PIO_0_BASE, PIO_OFFSET_DIRECTION,     0x00); // configure as input
    IOWR_16DIRECT(PIO_0_BASE, PIO_OFFSET_EDGECAPTURE,   0x0f);
    IOWR_16DIRECT(PIO_0_BASE, PIO_OFFSET_INTERRUPTMASK, 0x0f); // enable IRQ on first bit

    IOWR_32DIRECT(CUSTOM_DMA_RECIEVE_BASE, DMA_OFFSET_LENGTH,      SIZE_FFT);       // transfer length
    IOWR_32DIRECT(CUSTOM_DMA_RECIEVE_BASE, DMA_OFFSET_LENGTH_BYTE, SIZE_DATA_BYTE); // bytes per element

    alt_up_av_config_dev* config_dev = alt_up_av_config_open_dev("/dev/audio_and_video_config_0");
    alt_up_av_config_reset(config_dev);

    alt_u16 *sdramData;
    sdramData = (int *)SDRAM_CONTROLLER_0_BASE;
    printf("CPU0: SDRAM base address: 0x%p\n", (void*)sdramData);

    int count  = 0;
    alt_up_audio_dev *audio_dev;

    // Open audio device
    audio_dev = alt_up_audio_open_dev("/dev/audio_0");
    if (audio_dev == NULL)
        printf("Error: could not open audio device\n");
    else
        printf("Audio device opened\n");

    // Record loop: poll right-channel FIFO and write samples directly to SDRAM
    while (1)
    {
        int fifospace = alt_up_audio_read_fifo_avail(audio_dev, ALT_UP_AUDIO_RIGHT);
        if (start_recording && fifospace > 0 && count < MAX_SEND_DATA)
        {
            alt_up_audio_read_fifo(audio_dev, &(sdramData[count]), 1, ALT_UP_AUDIO_RIGHT);
            count += 1;
        }

        if (count >= MAX_SEND_DATA)
        {
            if (start_sending == 0)
            {
                printf("CPU0: recording complete (%d samples). Notifying CPU1.\n", count);
                // Send SDRAM base address to CPU1 via hardware IRQ mailbox
                IOWR_32DIRECT(CUSTOM_INTERRUPT_SENDER_0_BASE, INTERRUPT_SENDER_OFFSET_DATA, sdramData);
                start_sending = 1;
                break;
            }
        }
    }

    return 0;
}

// ISR: fired by PIO switch — starts the recording loop
void my_isr(void* context)
{
    start_recording = 1;
    IOWR_16DIRECT(PIO_0_BASE, PIO_OFFSET_EDGECAPTURE, 0x0f);
}
