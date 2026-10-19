#ifndef SH7095_H_
#define SH7095_H_
#include "sh2.h"

enum {
	SH_SMR,
	SH_BRR,
	SH_SCR,
	SH_TDR,
	SH_SSR,
	SH_RDR,
	SH_TIER = 0x10,
	SH_FTCSR,
	SH_FRCH,
	SH_FRCL,
	SH_OCRH,
	SH_OCRL,
	SH_TCR,
	SH_TOCR,
	SH_ICRH,
	SH_ICRL,
	SH_IPRB = 0x60,
	SH_VCRA = 0x62,
	SH_VCRB = 0x64,
	SH_VCRC = 0x66,
	SH_VCRD = 0x68,
	SH_DRCR0 = 0x71,
	SH_DRCR1,
	SH_WTCSR = 0x80,
	SH_WTCNT,
	SH_RSTCSR = 0x83,
	SH_SBYCR = 0x91,
	SH_CCR,
	SH_ICR = 0xE0,
	SH_IPRA = 0xE2,
	SH_VCRWDT = 0xE4,
	SH_DVSR = 0x100,
	SH_DVDNT = 0x104,
	SH_DVCR = 0x108,
	SH_VCRDIV = 0x10C,
	SH_DVDNTH = 0x110,//does this have a mirror at 0x118?
	SH_DVDNTL = 0x114,
	SH_DVDNTH_ALT = 0x118,
	SH_DVDNTL_ALT = 0x11C,
	//TODO: user break controller
	SH_SAR0 = 0x180,
	SH_DAR0 = 0x184,
	SH_TCR0 = 0x188,
	SH_CHCR0 = 0x18C,
	SH_SAR1 = 0x190,
	SH_DAR1 = 0x194,
	SH_TCR1 = 0x198,
	SH_CHCR1 = 0x19C,
	SH_VCRDMA0 = 0x1A0,
	SH_VCRDMA1 = 0x1A8,
	SH_DMAOR = 0x1B0,
	SH_BCR1 = 0x1E0,
	SH_BCR2 = 0x1E4,
	SH_WCR = 0x1E8,
	SH_MCR = 0x1EC,
	SH_RTCSR = 0x1F0,
	SH_RTCNT = 0x1F4,
	SH_RTCOR = 0x1F8
};

#define BIT_SMR_CA   0x80
#define BIT_SMR_CHR  0x40
#define BIT_SMR_PE   0x20
#define BIT_SMR_STOP 0x08
#define MASK_SMR_CKS 0x03

#define BIT_SCR_TIE  0x80
#define BIT_SCR_RIE  0x40
#define BIT_SCR_TE   0x20
#define BIT_SCR_RE   0x10
#define BIT_SCR_TEIE 0x04
#define MASK_SCR_CKE 0x03

#define BIT_SSR_TDRE 0x80
#define BIT_SSR_RDRF 0x40
#define BIT_SSR_ORER 0x20
#define BIT_SSR_TEND 0x04

#define BIT_TOCR_OCRS 0x10

#define BIT_FTCSR_OCFA  0x08
#define BIT_FTCSR_OCFB  0x04
#define BIT_FTCSR_OVF   0x02
#define BIT_FTCSR_CCLRA 0x01

#define BIT_WTCSR_OVF  0x80
#define BIT_WTCSR_WTIT 0x40
#define BIT_WTCSR_TME  0x20

#define BIT_RSTCSR_WOVF 0x80
#define BIT_RSTCSR_RSTE 0x40
#define BIT_RSTCSR_RSTS 0x20

#define BIT_CCR_CP 0x10
#define BIT_CCR_TW 0x08
#define BIT_CCR_OD 0x04
#define BIT_CCR_ID 0x02
#define BIT_CCR_CE 0x01

#define BIT_CHCR_IE 0x04
#define BIT_CHCR_TE 0x02
#define BIT_CHCR_DE 0x01

#define BIT_DMAOR_PR   0x08
#define BIT_DMAOR_DMIE 0x01

typedef void (*sci_handler)(void *data, uint32_t cycle, uint8_t byte);
typedef struct {
	void        *sci_handler_data;
	sci_handler transmit_handler;
	uint32_t    cycle;
	uint32_t    divide_counter;
	uint32_t    transmit_counter;
	uint32_t    frc_counter;
	uint32_t    wdt_counter;
	int32_t     quotient;
	int32_t     remainder;
	uint16_t    ocra;
	uint16_t    ocrb;
	uint8_t     div_overflow;
	uint8_t     frc_temp;
	uint8_t     tsr;
	uint8_t     ti_pending;
	uint8_t     ri_pending;
	uint8_t     tei_pending;
	uint8_t     eri_pending;
	uint8_t     dmac_which;
	uint8_t     dmac0_run;
	uint8_t     dmac1_run;
	uint8_t     dreq0;
	uint8_t     dreq1;
	uint8_t     dmac0_pending;
	uint8_t     dmac1_pending;
	uint8_t     iti_pending;
	uint8_t     divu_loaded;
} sh7095_periph;

void sh7095_setup(sh2_context *sh2);
void sh7095_free(sh2_context *sh2);
void sh7095_adjust_cycles(sh2_context *sh2, uint32_t deduction);
void sh7095_sci_to_sh7095_sci(void *data, uint32_t cycle, uint8_t byte);
void sh7095_next_int(sh2_context *sh2, uint32_t priority_mask);
void sh7095_assert_dreq0(sh2_context *sh2);
void sh7095_assert_dreq1(sh2_context *sh2);
void sh7095_clear_dreq0(sh2_context *sh2);
void sh7095_clear_dreq1(sh2_context *sh2);

#endif //SH7095_H_
