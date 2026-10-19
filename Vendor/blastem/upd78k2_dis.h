#ifndef UPD78K2_DIS_H_
#define UPD78K2_DIS_H_
#include <stdint.h>
#include "disasm.h"

enum {
	UPD_REF_NONE,
	UPD_REF_OP,
	UPD_REF_2OP,
	UPD_REF_BRANCH,
	UPD_REF_COND_BRANCH,
	UPD_REF_OP_BRANCH,
	UPD_REF_CALL,
	UPD_REF_CALL_TABLE
};

typedef struct {
	uint16_t address;
	uint16_t address2;
	uint8_t  ref_type;
} upd_address_ref;

typedef uint8_t (*upd_fetch_fun)(uint16_t address, void *data);

uint16_t upd78k2_disasm(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context);


#endif //UPD78K2_DIS_H_
