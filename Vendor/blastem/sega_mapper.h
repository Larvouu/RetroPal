#ifndef SEGA_MAPPER_H_
#define SEGA_MAPPER_H_
#include "serialize.h"

uint16_t read_sram_w(uint32_t address, m68k_context * context);
uint16_t s32x_read_sram_w(uint32_t address, void * vcontext);
uint16_t s32x_read_bankable_w(uint32_t address, void * vcontext);
uint8_t read_sram_b(uint32_t address, m68k_context * context);
uint8_t s32x_read_sram_b(uint32_t address, void * vcontext);
uint8_t s32x_read_bankable_b(uint32_t address, void * vcontext);
m68k_context * write_sram_area_w(uint32_t address, m68k_context * context, uint16_t value);
void *s32x_write_sram_area_w(uint32_t address, void *vcontext, uint16_t value);
void *s32x_write_bankable_w(uint32_t address, void *vcontext, uint16_t value);
m68k_context * write_sram_area_b(uint32_t address, m68k_context * context, uint8_t value);
void *s32x_write_sram_area_b(uint32_t address, void *vcontext, uint8_t value);
void *s32x_write_bankable_b(uint32_t address, void *vcontext, uint8_t value);
m68k_context * write_bank_reg_w(uint32_t address, m68k_context * context, uint16_t value);
m68k_context * write_bank_reg_b(uint32_t address, m68k_context * context, uint8_t value);
void *s32x_write_bank_reg_w(uint32_t address, void *vcontext, uint16_t value);
void *s32x_write_bank_reg_b(uint32_t address, void *vcontext, uint8_t value);
uint16_t med_reg_read_w(uint32_t address, void *vcontext);
uint8_t med_reg_read_b(uint32_t address, void *vcontext);
void* write_med_ram0_w(uint32_t address, void *vcontext, uint16_t value);
void* write_med_ram1_w(uint32_t address, void *vcontext, uint16_t value);
void* write_med_ram2_w(uint32_t address, void *vcontext, uint16_t value);
void* write_med_ram3_w(uint32_t address, void *vcontext, uint16_t value);
void* write_med_ram4_w(uint32_t address, void *vcontext, uint16_t value);
void* write_med_ram5_w(uint32_t address, void *vcontext, uint16_t value);
void* write_med_ram6_w(uint32_t address, void *vcontext, uint16_t value);
void* write_med_ram7_w(uint32_t address, void *vcontext, uint16_t value);
void* write_med_ram0_b(uint32_t address, void *vcontext, uint8_t value);
void* write_med_ram1_b(uint32_t address, void *vcontext, uint8_t value);
void* write_med_ram2_b(uint32_t address, void *vcontext, uint8_t value);
void* write_med_ram3_b(uint32_t address, void *vcontext, uint8_t value);
void* write_med_ram4_b(uint32_t address, void *vcontext, uint8_t value);
void* write_med_ram5_b(uint32_t address, void *vcontext, uint8_t value);
void* write_med_ram6_b(uint32_t address, void *vcontext, uint8_t value);
void* write_med_ram7_b(uint32_t address, void *vcontext, uint8_t value);
void sega_mapper_serialize(genesis_context *gen, serialize_buffer *buf);
void sega_mapper_deserialize(deserialize_buffer *buf, genesis_context *gen);

#endif //SEGA_MAPPER_H_
