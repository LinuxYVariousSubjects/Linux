# Lekcja: Windows App (iPad) wisi na „Securing connection to remote PC” (GNOME Remote Desktop)

**Cel:** iPad z Microsoft Windows App łączy się przez RDP z pulpitem Ubuntu (GNOME Remote Desktop, tryb Desktop Sharing), także przez Tailscale.

**Konfiguracja:** Ubuntu 24.04, GNOME Shell 46 na Waylandzie, `gnome-remote-desktop` 46.3 jako demon użytkownika z NLA (login i hasło), `libfreerdp-server3-3` 3.32.0 / 3.32.1 z noble-updates, Tailscale z nazwą MagicDNS `<host>.<tailnet>.ts.net`, Windows App na iPadOS.

**Objaw:** Windows App zostaje na „Securing connection to remote PC”. W logu serwera (`journalctl --user -u gnome-remote-desktop`) każda próba kończy się tak:

```
[ERROR][com.freerdp.core.transport] - [transport_read_layer]: BIO_read retries exceeded
[ERROR][com.freerdp.core.peer] - [transport_read_layer]: ERRCONNECT_CONNECT_TRANSPORT_FAILED [0x0002000D]
[WARN][com.freerdp.core.rdp] - [rdp_send_deactivate_all]: rdpMcs::userId == 0, skip sending PDU_TYPE_DEACTIVATE_ALL
[RDP] Network or intentional disconnect, stopping session
```

Nie ma przy tym błędu TLS (`BIO_do_handshake failed`) ani NLA (`nla_recv() error`). Szyfrowanie i logowanie przechodzą, a połączenie staje dopiero po nich.

## Działające rozwiązanie

Shim `LD_PRELOAD` dla `gnome-remote-desktop`. Wymusza `FreeRDP_ExtSecurity = FALSE`, więc serwer negocjuje zwykły PROTOCOL_HYBRID zamiast HYBRID_EX. NLA (CredSSP) dalej jest wymagane, a poprawki bezpieczeństwa z FreeRDP 3.32 zostają. Nie trzeba sudo ani downgrade'u.

```bash
mkdir -p ~/.local/src/grd-no-hybrid-ex ~/.local/lib ~/.config/systemd/user/gnome-remote-desktop.service.d
# zapisz kod z sekcji "Kod: shim" jako ~/.local/src/grd-no-hybrid-ex/grd-no-hybrid-ex.c
gcc -O2 -Wall -shared -fPIC -o ~/.local/lib/grd-no-hybrid-ex.so \
    ~/.local/src/grd-no-hybrid-ex/grd-no-hybrid-ex.c -ldl -lpthread

cat > ~/.config/systemd/user/gnome-remote-desktop.service.d/no-hybrid-ex.conf <<'EOF'
# Workaround for FreeRDP 3.32.x HYBRID_EX regression (FreeRDP #13549, LP #2168823).
[Service]
Environment=LD_PRELOAD=%h/.local/lib/grd-no-hybrid-ex.so
EOF

systemctl --user daemon-reload && systemctl --user restart gnome-remote-desktop
```

Restart zrywa trwającą sesję RDP. Drop-in działa też po reboocie.

### Kluczowe pliki

| Plik | Rola |
|---|---|
| `~/.local/src/grd-no-hybrid-ex/grd-no-hybrid-ex.c` | źródło shima |
| `~/.local/lib/grd-no-hybrid-ex.so` | zbudowany shim |
| `~/.config/systemd/user/gnome-remote-desktop.service.d/no-hybrid-ex.conf` | drop-in z `LD_PRELOAD` dla usługi użytkownika |
| `probe_tls.py` (sekcja „Kod: sonda”) | sonda negocjacji RDP, działa bez iPada |

### Przydatne komendy

```bash
# Czy shim jest załadowany (jedna linia po każdym starcie usługi)
journalctl --user -u gnome-remote-desktop | grep grd-no-hybrid-ex
#   grd-no-hybrid-ex: forcing FreeRDP_ExtSecurity=FALSE (key 1091)

# Sonda: który protokół wybiera serwer
python3 -I probe_tls.py 127.0.0.1
#   selected=0x2  -> HYBRID, shim działa
#   selected=0x8  -> HYBRID_EX, shim nie działa albo nie jest załadowany

# Stan połączenia z iPadem: ile bajtów przeszło w każdą stronę
ss -tni state established '( sport = :3389 )'

# Status serwera RDP
grdctl status

# Wycofanie shima
rm ~/.config/systemd/user/gnome-remote-desktop.service.d/no-hybrid-ex.conf
systemctl --user daemon-reload && systemctl --user restart gnome-remote-desktop
```

---

## Dlaczego tak się działo

- **FreeRDP 3.32.0 zmienił domyślne ustawienie serwera.** `ExtSecurity` jest domyślnie `TRUE`, więc gdy klient prosi o `SSL|HYBRID|HYBRID_EX` (Windows App prosi), serwer wybiera HYBRID_EX i włącza Early User Authorization Result PDU.
- **Serwer wysyła ten PDU w złej kolejności:** `AUTHZ_SUCCESS` idzie do klienta, zanim serwer odbierze jego poświadczenia (TSCredentials, `auth info`). Windows App po CredSSP nie wysyła już MCS Connect Initial i wisi, a serwer po ~30–60 s zamyka połączenie z wpisami z sekcji „Objaw”. Fragment logu z debugiem:

  ```
  Negotiated Security: RDSTLS:0 NLA:0 EXT:1 TLS:0 RDP:0
  Early User Auth active: true
  Authentication complete (output token size: 0 bytes)
  ----->> sending AUTHZ_SUCCESS
     <<----- auth info
  CONNECTION_STATE_NEGO --> CONNECTION_STATE_MCS_CREATE_REQUEST
  ```

- **3.32.1 tego nie naprawia, 3.31.x działa.** Klienci, którzy proszą tylko o HYBRID (np. Thincast), łączą się bez problemu. Zgłoszenia: [FreeRDP #13549](https://github.com/FreeRDP/FreeRDP/issues/13549), [FreeRDP #13583](https://github.com/FreeRDP/FreeRDP/issues/13583), [Ubuntu LP #2168823](https://bugs.launchpad.net/ubuntu/+source/freerdp3/+bug/2168823).
- **Dlaczego shim wystarcza:** GRD 46 w ogóle nie ustawia `ExtSecurity`, więc działa domyślne `TRUE` z biblioteki. GRD wywołuje za to `freerdp_settings_set_bool` dla innych ustawień. Shim owija tę funkcję i po każdym takim wywołaniu ustawia `ExtSecurity = FALSE` na tym samym obiekcie ustawień. Klucz bierze w runtime z `freerdp_settings_get_key_for_name`, więc nie potrzebuje nagłówków FreeRDP.

## Jak to udowodniono

1. **Sonda X.224 + TLS** (`probe_tls.py`) na adresie lokalnym, LAN i tailnetu: handshake działa wszędzie, a serwer wybiera `selected=0x8` (HYBRID_EX).
2. **`ss -tni` na połączeniu z iPadem:** po ~2,4 KB w każdą stronę (TLS i CredSSP), potem cisza. Stan socketu mówi więc, na którym etapie połączenie stoi.
3. **Debug FreeRDP w GRD** (sekcja „Pułapki”) z prawdziwą próbą z iPada: `AUTHZ_SUCCESS` przed `auth info`, potem brak MCS.
4. **Po shimie:** sonda daje `selected=0x2`, a w logu jest `Negotiated Security: … NLA:1 EXT:0` i `Early User Auth active: false`. Próba z iPada: `Accepted client: iPad`, RDPGFX po 6 s, pulpit widoczny.

## Co NIE było przyczyną

- **Tailscale / MTU.** ICMP 1252 B przez tunel wraca, a logi pokazują, że TLS i NLA przechodzą. Gdyby duże pakiety ginęły, stałby już TLS.
- **Konflikt portu z demonem systemowym (Remote Login).** Na 3389 jest jeden listener (`ss -ltnp`).
- **Certyfikat TLS.** Handshake działa, fingerprint zgadza się z `grdctl status`.
- **`tailscale serve`.** Przechwytuje tylko skonfigurowane porty, a 3389 do nich nie należy (`tailscale serve status`).

## Pułapki

- **iPadOS usypia Windows App** po przełączeniu do innej aplikacji. Połączenie zostaje otwarte, ale stoi jeszcze PRZED TLS: `ss -tni` pokazuje `bytes_received:19 bytes_sent:19` (tylko X.224 Connection Request / Confirm). Testuj z Windows App na pierwszym planie albo w Split View.
- **Restart GRD zrywa sesję**, a Windows App sam łączy się ponownie w tle. Ta próba też może utknąć z powodu powyżej, więc po restarcie zamknij aplikację i połącz od nowa.
- **Debug GRD wymaga appendera syslog.** Sam `WLOG_FILTER` nie wystarczy: linie DEBUG idą na stdout, który pod systemd jest buforowany blokowo, i nie docierają do journala. Drop-in tymczasowy:

  ```ini
  # ~/.config/systemd/user/gnome-remote-desktop.service.d/debug.conf
  [Service]
  Environment=WLOG_FILTER=com.freerdp.core.*:DEBUG
  Environment=WLOG_APPENDER=SYSLOG
  ```

  Nie włączaj `com.winpr.*`, bo moduł NTLM loguje szczegóły uwierzytelnienia. Po teście usuń plik i zrób `daemon-reload`. Działający proces zachowuje debug do najbliższego restartu.
- **Szybkie kolejne połączenia** (sonda zaraz po sondzie) potrafią dostać EOF w TLS. To wyścig w GRD, nie skutek shima. Zrób 2–3 s odstępu.
- **Downgrade zamiast shima:** apt widzi tylko 3.32.1 i 3.5.0. Wersję 3.31.0 da się zainstalować z migawki archiwum (`apt install --snapshot <YYYYMMDDTHHMMSSZ> pakiet=wersja`, apt ≥ 2.7) albo z pakietów `.deb` na Launchpadzie, potem `apt-mark hold`. Koszt: wracają podatności łatane w 3.32.x na serwerze wystawionym w sieci.

## Kiedy usunąć shim

Gdy poprawiony `libfreerdp-server3-3` trafi do noble-updates (śledź zgłoszenia wyżej). Po aktualizacji FreeRDP:

1. Sonda z shimem pokazuje `0x8`: shim przestał działać, więc sprawdź log `grd-no-hybrid-ex`.
2. Usuń drop-in, zrób restart i sprawdź połączenie z iPada. Jeśli działa przy `selected=0x8`, poprawka upstream jest na miejscu i shim można skasować.

---

## Kod: shim

`~/.local/src/grd-no-hybrid-ex/grd-no-hybrid-ex.c`

```c
/*
 * grd-no-hybrid-ex: LD_PRELOAD shim for gnome-remote-desktop.
 *
 * FreeRDP 3.32.x defaults FreeRDP_ExtSecurity to TRUE in server mode, so the
 * server negotiates PROTOCOL_HYBRID_EX and sends the Early User Authorization
 * Result PDU. Microsoft Windows App (iOS/macOS) then hangs on "Securing
 * connection to remote PC" (FreeRDP #13549, #13583; Ubuntu LP #2168823).
 *
 * gnome-remote-desktop 46 never touches ExtSecurity, so every time it sets a
 * boolean setting we force ExtSecurity back to FALSE on the same settings
 * object. NLA (PROTOCOL_HYBRID / CredSSP) stays required.
 *
 * Remove once a fixed libfreerdp-server3-3 lands in noble-updates.
 *
 * Build: gcc -O2 -Wall -shared -fPIC -o ~/.local/lib/grd-no-hybrid-ex.so \
 *            grd-no-hybrid-ex.c -ldl -lpthread
 * Use:   ~/.config/systemd/user/gnome-remote-desktop.service.d/no-hybrid-ex.conf
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/types.h>

typedef int BOOL;
typedef struct rdp_settings rdpSettings;
typedef BOOL (*set_bool_fn) (rdpSettings *settings, int id, BOOL val);
typedef ssize_t (*get_key_fn) (const char *name);

static set_bool_fn real_set_bool;
static int ext_security_key = -1;
static pthread_once_t init_once = PTHREAD_ONCE_INIT;

static void
init (void)
{
  get_key_fn get_key;

  real_set_bool = (set_bool_fn) dlsym (RTLD_NEXT, "freerdp_settings_set_bool");
  get_key = (get_key_fn) dlsym (RTLD_DEFAULT, "freerdp_settings_get_key_for_name");
  if (get_key)
    ext_security_key = (int) get_key ("FreeRDP_ExtSecurity");

  fprintf (stderr, "grd-no-hybrid-ex: forcing FreeRDP_ExtSecurity=FALSE (key %d)\n",
           ext_security_key);
}

BOOL
freerdp_settings_set_bool (rdpSettings *settings, int id, BOOL val)
{
  BOOL ret;

  pthread_once (&init_once, init);
  if (!real_set_bool)
    return 0;

  if (ext_security_key < 0)
    return real_set_bool (settings, id, val);

  if (id == ext_security_key)
    val = 0;

  ret = real_set_bool (settings, id, val);
  real_set_bool (settings, ext_security_key, 0);
  return ret;
}
```

## Kod: sonda

`probe_tls.py`: wysyła X.224 Connection Request z `SSL|HYBRID|HYBRID_EX` (jak Windows App), wypisuje wybrany protokół i robi handshake TLS. Nie loguje się, więc w logu GRD zostawia `nla_recv() error` (to normalne).

```python
import socket, ssl, struct, sys, time, hashlib
def probe(host, port=3389, proto=0x0B):
    t0 = time.time()
    s = socket.create_connection((host, port), timeout=8)
    neg = struct.pack('<BBHI', 0x01, 0x00, 8, proto)
    x224 = bytes([6 + len(neg), 0xE0, 0, 0, 0, 0, 0]) + neg
    s.sendall(struct.pack('>BBH', 3, 0, 4 + len(x224)) + x224)
    hdr = s.recv(4); body = s.recv(struct.unpack('>H', hdr[2:4])[0] - 4)
    neg_rsp = body[7:]
    typ, flags, ln, sel = struct.unpack('<BBHI', neg_rsp[:8])
    print(f"  X.224 CC ok {time.time()-t0:.3f}s  neg type={typ:#x} flags={flags:#x} selected={sel:#x}")
    if typ != 0x02:
        print("  NEG FAILURE code", sel); return
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    t1 = time.time(); ts = ctx.wrap_socket(s, server_hostname=host)
    der = ts.getpeercert(binary_form=True)
    print(f"  TLS ok {time.time()-t1:.3f}s  {ts.version()} {ts.cipher()[0]}  sha256={hashlib.sha256(der).hexdigest()[:23]}  certlen={len(der)}")
    ts.close()
for h in sys.argv[1:]:
    print(h)
    try: probe(h)
    except Exception as e: print("  FAIL", type(e).__name__, e)
```
