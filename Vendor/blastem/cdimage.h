#ifndef CUE_H_
#define CUE_H_

uint8_t parse_cue(system_media *media);
uint8_t parse_toc(system_media *media);
uint32_t make_iso_media(system_media *media, const char *filename);
uint32_t make_chd_media(system_media *media, const char *filename);
void cdimage_serialize(system_media *media, serialize_buffer *buf);
void cdimage_deserialize(deserialize_buffer *buf, void *vmedia);
uint8_t cdrom_scramble(uint16_t *lsfr, uint8_t data);
void cdimage_free(system_media *media);

#endif //CUE_H_
