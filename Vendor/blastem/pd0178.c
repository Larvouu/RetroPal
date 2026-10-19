#include <string.h>
#include "pd0178.h"

#define LEADIN_SECTORS 11780

static uint8_t pd0178_calc_checksum(uint8_t *buffer)
{
	uint8_t checksum = 0xFF;
	for (int i = 0; i < 11; i++)
	{
		checksum ^= buffer[i];
	}
	return checksum;
}

void pd0178_init(pd0178 *mecha, system_media *media)
{
	memset(mecha, 0, sizeof(*mecha));
	mecha->media = media;
	mecha->next_shake += 12000000 / 50; // 20ms for now
	mecha->shake_high = mecha->next_shake + 36; // ~3 us
}

uint8_t pd0178_transfer_byte(pd0178 *mecha, uint8_t to_mecha)
{
	uint8_t ret = 0xFF;
	if (mecha->comm_index < sizeof(mecha->cmd)) {
		mecha->cmd[mecha->comm_index] = to_mecha;
		ret = mecha->status[mecha->comm_index++];
		if (mecha->comm_index == sizeof(mecha->cmd)) {
			fputs("PD0178 received:", stdout);
			for (int i = 0; i < sizeof(mecha->cmd); i++)
			{
				printf(" %02X", mecha->cmd[i]);
			}
			printf(", computed checksum: %02X\n", pd0178_calc_checksum(mecha->cmd));
		}
	} else {
		printf("pd0178_transfer_bytes: Too many bytes %d, %02X\n", mecha->comm_index, to_mecha);
	}
	return ret;
}

static uint8_t to_bcd(uint8_t val)
{
	uint8_t out = val % 10;
	out += (val / 10) << 4;
	return out;
}

static void next_shake(pd0178 *mecha, uint8_t from_transition)
{
	if ((!mecha->comm_index) || mecha->comm_index == sizeof(mecha->cmd)) {
		mecha->next_shake = mecha->cycle + 12000000 / 50; // 20ms for now
		mecha->comm_index = 0;
		uint32_t lba;
		if (mecha->head_pba >= LEADIN_SECTORS) {
			lba = mecha->head_pba - LEADIN_SECTORS;
		} else {
			lba = LEADIN_SECTORS - mecha->head_pba;
		}
		mecha->status[0] = mecha->cmd[0] == 5 ? 5 : 4;//disc loaded?
		mecha->status[7] = 3;//CD Present hopefully
		mecha->status[6] = to_bcd(lba % 75);
		lba /= 75;
		mecha->status[5] = to_bcd(lba % 60);
		mecha->status[4] = to_bcd(lba / 60);
		mecha->status[3] = 0x40;
		mecha->status[11] = pd0178_calc_checksum(mecha->status);
		if (mecha->cmd[0] == 5) {
			mecha->head_pba++;
		}
	} else if (from_transition){
		mecha->next_shake = mecha->cycle + 36; //~3 us
	} else {
		mecha->next_shake = 0xFFFFFFFF;
	}
}

void pd0178_shake_high(pd0178 *mecha)
{
	next_shake(mecha, 1);
	mecha->shake_high = mecha->next_shake + 36; // ~3 us
	printf("pd0178_shake_high - next_shake: %u, next_high: %u\n", mecha->next_shake, mecha->shake_high);
}

void pd0178_run(pd0178 *mecha, uint32_t to_cycle)
{
	while (to_cycle > mecha->cycle) {
		if (to_cycle >= mecha->next_shake && mecha->cycle < mecha->next_shake) {
			mecha->cycle = mecha->next_shake;
			mecha->shake = 0;
			next_shake(mecha, 0);
		} else if (to_cycle >= mecha->shake_high && mecha->cycle < mecha->shake_high) {
			printf("pd0178_run shake_high @ %u\n", mecha->shake_high);
			mecha->shake = 1;
			mecha->cycle = mecha->shake_high;
			mecha->shake_high = mecha->next_shake + 36; // ~3 us
		} else {
			mecha->cycle = to_cycle;
		}
	}
}
