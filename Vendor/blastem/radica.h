#ifndef RADICA_H_
#define RADICA_H_

#include "genesis.h"

void radica_reset(genesis_context *gen);
void radica_serialize(genesis_context *gen, serialize_buffer *buf);
void radica_deserialize(deserialize_buffer *buf, genesis_context *gen);
void *radica_write_b(uint32_t address, void *context, uint8_t value);
void *radica_write_w(uint32_t address, void *context, uint16_t value);
uint8_t radica_read_b(uint32_t address, void *context);
uint16_t radica_read_w(uint32_t address, void *context);

#endif //RADICA_H_
