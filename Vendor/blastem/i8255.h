#ifndef I8255_H_
#define I8255_H_

#include <stdint.h>

typedef struct i8255 i8255;
typedef void (*i8255_out_update)(i8255 *ppi, uint32_t cycle, uint32_t port, uint8_t data);
typedef uint8_t (*i8255_in_sample)(i8255 *ppi, uint32_t cycle, uint32_t port);

struct i8255 {
	uint8_t          latches[4];
	uint8_t          control;
	uint8_t          portc_write_mask;
	uint8_t          portc_out_mask;
	i8255_out_update out_handler;
	i8255_in_sample  in_handler;
	void             *system;
};

void i8255_init(i8255 *ppi, i8255_out_update out, i8255_in_sample in);
void i8255_write(uint32_t address, i8255 *ppi, uint8_t value, uint32_t cycle);
uint8_t i8255_read(uint32_t address, i8255 *ppi, uint32_t cycle);
void i8255_input_strobe_a(i8255 *ppi, uint8_t value, uint32_t cycle);
void i8255_input_strobe_b(i8255 *ppi, uint8_t value, uint32_t cycle);
uint8_t i8255_output_ack_a(i8255 *ppi, uint32_t cycle);
uint8_t i8255_output_ack_b(i8255 *ppi, uint32_t cycle);

#endif //I8255_H_
