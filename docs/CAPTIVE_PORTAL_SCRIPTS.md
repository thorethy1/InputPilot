# Captive Portal Scripts

InputPilot 0.9.2 can keep up to five HTTP workflows on the ESP32, each bound to
an exact Wi-Fi SSID. After joining that network, the firmware waits for the
configured delay and runs the workflow once. This avoids depending on iOS
background execution and continues to work while the companion app is closed.

The editor is under **Devices → Device Details → Captive Portal → Wi-Fi Portal
Scripts**. It validates the workflow before an authenticated, checksummed upload.
The same screen shows the most recent state and stable failure code and supports
a manual run while InputPilot is connected to the assigned network.

## Why this is an HTTP workflow, not `/bin/sh`

Neither an iOS app nor ESP32 firmware has a supported POSIX shell with `curl`
and `python3`. Allowing opaque native code would also make validation and bounded
execution impossible. InputPilot therefore uses a small HTTP-focused language.
User workflows are data stored on their device; no hotel, provider, or portal-
specific script is bundled with InputPilot.

## Format

The optional first line is `INPUTPILOT-CAPTIVE/1`. Blank lines and lines starting
with `#` are ignored. A workflow can use at most 2,304 UTF-8 bytes, 200 executed
steps, ten redirects per request, a 32 KiB response body, and 60 seconds per
`WAIT`. Network requests have finite connect and response timeouts.

| Command | Meaning |
|---|---|
| `ADDRESS_FAMILY AUTO` / `ADDRESS_FAMILY IPV4` | Select normal address-family resolution (the default) or resolve and connect only over IPv4 for every following request and redirect. |
| `GET <url>` | Send a GET; follow redirects and retain the portal cookie. |
| `POST_FORM <url> <body>` | POST an URL-encoded form body. |
| `POST_JSON <url> <body>` | POST a JSON body. |
| `HEADER <name>: <value>` | Add a persistent request header. A `User-Agent` value replaces the InputPilot default rather than adding a second header. |
| `WAIT <milliseconds>` | Wait without exceeding 60 seconds. |
| `EXPECT_STATUS <code>` | Fail unless the last status matches. |
| `EXPECT_BODY <text>` | Fail unless the last body contains text. |
| `REQUIRE_HOST_SUFFIX <suffix>` | Require a leading-dot suffix, verify the last response host, then restrict every later request and redirect to its subdomains. |
| `SET_ORIGIN <name>` | Save the last response URL's scheme and authority. |
| `CAPTURE_JSON <name> <dot.path>` | Read a scalar from the last JSON response. |
| `CAPTURE_JSON_FIRST <name> <path1> \|\| <path2> [...]` | Parse the last response once and save the first non-empty scalar found at the listed dot-paths. |
| `CAPTURE_OBJECT_STRING <name> <key>` | Read a quoted string for an exact key from JSON-/JavaScript-like response text, allowing whitespace around `:`. |
| `CAPTURE_BETWEEN <name> <prefix> \|\| <suffix>` | Capture text between two literal delimiters. |
| `LABEL <name>` / `GOTO <name>` | Define or jump to a label. |
| `IF_STATUS <code> GOTO <name>` | Branch on the last HTTP status. |
| `IF_BODY_CONTAINS <text> GOTO <name>` | Branch when the last body contains text. |
| `IF_BODY_EQUALS <text> GOTO <name>` | Trim leading/trailing body whitespace, then branch on an exact match. |
| `IF_VAR_EQUALS <variable> <value> GOTO <name>` | Branch when an existing variable exactly equals the expanded value. |
| `SUCCESS [message]` | Finish successfully. |
| `ALREADY_CONNECTED [message]` | Finish without logging in because access already works. |
| `FAIL <code> [message]` | Finish with a stable error code. |

Every request updates `${URL}` and `${STATUS}`. `${SSID}` is set at launch.
Captured variables use `${NAME}`; `${url:NAME}` applies form-safe percent
encoding. Redirect locations may be absolute, scheme-relative, root-relative,
or relative to the current path.

`CAPTURE_JSON_FIRST` accepts the same string, Boolean, and number scalars as
`CAPTURE_JSON`. Missing, object, array, `null`, and empty-string candidates are
skipped so a compatible fallback path can be tried. It fails if no usable path
exists with `JSON_VALUE_MISSING`. `CAPTURE_OBJECT_STRING` fails with
`CAPTURE_MISSING` when the key or a valid quoted value is absent. It is
intentionally a small bounded extractor, not
a JavaScript parser; keys and variable names use ASCII letters, numbers, `_`, or `-`,
and standard JSON string escapes are decoded. All captures retain the 1,024-byte
value limit. `IF_VAR_EQUALS` fails with `MISSING_VARIABLE` if its left-hand
variable or a variable referenced by its comparison value does not exist.

## New command examples

```text
CAPTURE_JSON_FIRST SESSION session || payload.session
CAPTURE_OBJECT_STRING CSRF_TOKEN csrfToken
IF_VAR_EQUALS LOGIN_STATE ready GOTO authenticated
IF_BODY_EQUALS online GOTO internet_available
```

These patterns are provider-neutral: they cover compatible API response shapes,
configuration embedded in HTML, exact state checks, and strict connectivity
probe responses.

## Minimal example

```text
INPUTPILOT-CAPTIVE/1
ADDRESS_FAMILY IPV4
GET http://detectportal.firefox.com/success.txt
IF_BODY_EQUALS success GOTO online
REQUIRE_HOST_SUFFIX .portal.example
SET_ORIGIN BASE
CAPTURE_OBJECT_STRING TOKEN token
POST_FORM ${BASE}/api/login token=${url:TOKEN}&terms=1
EXPECT_STATUS 200
CAPTURE_JSON_FIRST LOGGED_IN loggedIn || result.loggedIn
IF_VAR_EQUALS LOGGED_IN true GOTO logged_in
FAIL LOGIN_NOT_CONFIRMED Login was not confirmed
LABEL logged_in
SUCCESS Portal login succeeded
LABEL online
ALREADY_CONNECTED Internet is already available
```

This is deliberately provider-neutral and is not installed as a default.

In `IPV4` mode the firmware resolves each request hostname with an `AF_INET`
DNS query and connects TCP to that address. The original hostname remains the
HTTP `Host` value, the redirect base, and the TLS SNI name for HTTPS. This is
useful on captive networks that advertise IPv6 but intercept only IPv4 HTTP.
`AUTO` retains the normal Arduino-ESP32 resolver behavior for existing scripts.
TCP and TLS setup are retried with a short bounded backoff before a request is
sent. This tolerates portal endpoints that briefly refuse connections just
after issuing their discovery redirect without replaying a submitted form.

An enabled script also gates WireGuard for its matching Wi-Fi association.
WireGuard remains stopped while the script is waiting or running, starts only
after `SUCCESS` or `ALREADY_CONNECTED`, and stays stopped after a failure. A
disconnect, reconnect, or SSID change creates a fresh gate. Starting a manual
run stops an active tunnel first and applies the same success/failure rules.

## Security

Workflows can transmit data over the selected Wi-Fi network. Review every
workflow before saving it. Put `REQUIRE_HOST_SUFFIX` after portal discovery and
before sending a token or credential. Workflow content is transferred only over
InputPilot's authenticated encrypted control protocol. HTTPS is supported, but
certificate verification cannot be relied on before a captive network grants
normal Internet access; host allow-list checks are therefore especially
important. Status and diagnostics never include captured variable values or
response bodies.
