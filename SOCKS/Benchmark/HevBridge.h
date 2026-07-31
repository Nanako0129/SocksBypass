#ifndef HevBridge_h
#define HevBridge_h

#ifdef __cplusplus
extern "C" {
#endif

int hev_socks5_server_main_from_str(const unsigned char *config_str, unsigned int config_len);
void hev_socks5_server_quit(void);

#ifdef __cplusplus
}
#endif

#endif /* HevBridge_h */
