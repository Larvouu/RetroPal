#ifndef SFT_MAPPER_H_
#define SFT_MAPPER_H_

void* sft_wukong_write_b(uint32_t address, void *context, uint8_t value);
void* sft_wukong_write_w(uint32_t address, void *context, uint16_t value);

#endif // SFT_MAPPER_H_
