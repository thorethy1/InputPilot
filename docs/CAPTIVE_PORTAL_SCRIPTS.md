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
with `#` are ignored. A workflow can use at most 1,800 UTF-8 bytes, 200 executed
steps, ten redirects per request, a 32 KiB response body, and 60 seconds per
`WAIT`. Network requests have finite connect and response timeouts.

| Command | Meaning |
|---|---|
| `GET <url>` | Send a GET; follow redirects and retain the portal cookie. |
| `POST_FORM <url> <body>` | POST an URL-encoded form body. |
| `POST_JSON <url> <body>` | POST a JSON body. |
| `HEADER <name>: <value>` | Add a persistent request header. |
| `WAIT <milliseconds>` | Wait without exceeding 60 seconds. |
| `EXPECT_STATUS <code>` | Fail unless the last status matches. |
| `EXPECT_BODY <text>` | Fail unless the last body contains text. |
| `REQUIRE_HOST_SUFFIX <suffix>` | Require a leading-dot suffix, verify the last response host, then restrict every later request and redirect to its subdomains. |
| `SET_ORIGIN <name>` | Save the last response URL's scheme and authority. |
| `CAPTURE_JSON <name> <dot.path>` | Read a scalar from the last JSON response. |
| `CAPTURE_BETWEEN <name> <prefix> \|\| <suffix>` | Capture text between two literal delimiters. |
| `LABEL <name>` / `GOTO <name>` | Define or jump to a label. |
| `IF_STATUS <code> GOTO <name>` | Branch on the last HTTP status. |
| `IF_BODY_CONTAINS <text> GOTO <name>` | Branch when the last body contains text. |
| `SUCCESS [message]` | Finish successfully. |
| `ALREADY_CONNECTED [message]` | Finish without logging in because access already works. |
| `FAIL <code> [message]` | Finish with a stable error code. |

Every request updates `${URL}` and `${STATUS}`. `${SSID}` is set at launch.
Captured variables use `${NAME}`; `${url:NAME}` applies form-safe percent
encoding. Redirect locations may be absolute, scheme-relative, root-relative,
or relative to the current path.

## Minimal example

```text
INPUTPILOT-CAPTIVE/1
GET http://detectportal.firefox.com/success.txt
IF_BODY_CONTAINS success GOTO online
REQUIRE_HOST_SUFFIX .portal.example
SET_ORIGIN BASE
CAPTURE_BETWEEN TOKEN "token":" || "
POST_FORM ${BASE}/api/login token=${url:TOKEN}&terms=1
EXPECT_STATUS 200
CAPTURE_JSON LOGGED_IN loggedIn
EXPECT_BODY "loggedIn":true
SUCCESS Portal login succeeded
LABEL online
ALREADY_CONNECTED Internet is already available
```

This is deliberately provider-neutral and is not installed as a default.

## Security

Workflows can transmit data over the selected Wi-Fi network. Review every
workflow before saving it. Put `REQUIRE_HOST_SUFFIX` after portal discovery and
before sending a token or credential. Workflow content is transferred only over
InputPilot's authenticated encrypted control protocol. HTTPS is supported, but
certificate verification cannot be relied on before a captive network grants
normal Internet access; host allow-list checks are therefore especially
important. Status and diagnostics never include captured variable values or
response bodies.
