// Apple ID 登录 + IPA 签名 — C interface.
// Implemented in rust/idevice-ffi/src/sideload_auth.rs (isideload sign-only path).
#ifndef SIDELOAD_AUTH_H
#define SIDELOAD_AUTH_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque signing session built from the Settings account; freed with
// si_sign_session_free.
typedef struct SignSession SignSession;

// Signs the IPA at ipa_path, writing the signed .app bundle's path to
// out_signed_path. Blocks. udid is registered with the team first; pass NULL to
// skip that (may fail with developer error 8220). Returns 0 on success.
int si_sign_ipa(SignSession *session, const char *ipa_path, const char *udid,
                const char *device_name, char **out_signed_path, char **out_error);

// Registers the device with the signing session's selected team immediately
// (SideStore approach): call right after sign-in / account switch so Apple's
// registration-to-provisioning propagation window is over before signing
// (root cause of developer error 8220). Blocks. Unlike the sign path, an
// empty/NULL udid is an error (2), never a silent skip. Returns 0 on success.
int si_register_device(SignSession *session, const char *udid,
                       const char *device_name, char **out_error);

// Restores a signing session from the Settings account (dsid + xcode.auth token
// + imported machine identity) — no login, no 2FA, no provisioning. Returns 0
// on success.
int si_signin_with_session(const char *email, const char *dsid,
                           const char *auth_token, const char *anisette_url,
                           const char *storage_dir, const char *machine_name,
                           SignSession **out_session, char **out_summary,
                           char **out_error);

// Frees a SignSession (NULL is a no-op).
void si_sign_session_free(SignSession *session);

// Frees a heap C string previously returned by si_signin_with_session / si_sign_ipa.
void si_string_free(char *p);

#ifdef __cplusplus
}
#endif

#endif /* SIDELOAD_AUTH_H */
