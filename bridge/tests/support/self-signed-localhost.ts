// A throwaway self-signed certificate for `localhost`, valid for a century, so
// a test can stand up a TLS listener the way a dev server with its own dev
// certificate does. It secures nothing: the key is published right here.
export const SELF_SIGNED_LOCALHOST_CERT = `-----BEGIN CERTIFICATE-----
MIIBfjCCASWgAwIBAgIUDBpRHg9jGIpN1P6Yg3LdbqG6NuwwCgYIKoZIzj0EAwIw
FDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDkyOTAyMjkwOFoYDzIxMjYwOTA1
MDIyOTA4WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO
PQMBBwNCAASS5GBZRkgsiFFJd2JrBpubW2Wm79P0u2uoz3IRwiOKmFHU10+TwkYL
RjdrpVZEzoLhg9NvXHWe0MVz7GotOJ6fo1MwUTAdBgNVHQ4EFgQUcGRuI7HroOwI
2ybeUn+RACmVz8wwHwYDVR0jBBgwFoAUcGRuI7HroOwI2ybeUn+RACmVz8wwDwYD
VR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiAZ5oZx2NpJZUpcI2aG8dTr
zgsvIRhdSxHRJBEXUfrCbwIgQIij8x1WgEWmF5y8foOOO0ktnhsx3FD+i3aKxkU1
4PA=
-----END CERTIFICATE-----
`;

export const SELF_SIGNED_LOCALHOST_KEY = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgVJHO93hyF1pRSv0o
eS6CYdJ1BXP/cznRPgsZkbL/NKShRANCAASS5GBZRkgsiFFJd2JrBpubW2Wm79P0
u2uoz3IRwiOKmFHU10+TwkYLRjdrpVZEzoLhg9NvXHWe0MVz7GotOJ6f
-----END PRIVATE KEY-----
`;
