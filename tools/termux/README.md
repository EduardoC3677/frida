# Frida para Termux / Android arm64 (modo remoto)

Objetivo: usar **frida + frida-tools dentro de Termux** (prefix de Termux),
conectándose por TCP a un **frida-server que corre con root** en el lado
Android. Esta es la arquitectura recomendada y soportada oficialmente.

```
  [ Lado Android, root/su ]                 [ Lado Termux, tu usuario ]
  frida-server (arm64)                       frida / frida-ps / frida-trace ...
    -l 127.0.0.1:27042   <===== TCP =====>   se conectan con  -H 127.0.0.1:27042
```

Por qué remoto: `frida-server` necesita **root** para instrumentar otras apps,
pero Termux corre sin privilegios. Por eso el server vive en el lado Android
(root) y frida-tools en Termux se conecta por TCP (`-H host:puerto`).

### Auto-elevación con `su` (KernelSU / Magisk / APatch)

Este fork modifica `frida-server` y `frida-inject` para que, en Android, se
**re-ejecuten automáticamente con `su`** si los lanzas sin root (lo normal en
Termux). Esto resuelve el error clásico:

```
Unable to load SELinux policy from the kernel: Failed to open file
"/sys/fs/selinux/policy": Permission denied
```

que ocurre cuando el server corre como tu usuario de app y no puede leer la
política SELinux, hacer ptrace ni escribir en `/data/local/tmp`.

Al arrancar buscan un `su` usable en este orden: `/data/adb/ksu/bin/su`
(KernelSU), `/data/adb/ap/bin/su` (APatch), `/data/adb/magisk/su` (Magisk),
`/sbin/su`, `/system/bin/su`, `/system/xbin/su`, y por último `su` en el PATH.
Encontrado uno, hacen `su -c "<binario> <args>"` y el server real corre como
uid 0. Un guard interno evita bucles de re-exec.

Así, desde Termux basta con:

```bash
frida-server            # se auto-eleva con su; KernelSU pedirá permiso una vez
frida-server -l 127.0.0.1:27042
```

Para desactivar la auto-elevación (correr sin privilegios a propósito):

```bash
FRIDA_NO_SU=1 frida-server
```


---

## La vía más fácil — instalar desde un GitHub Release

No hace falta compilar nada en el teléfono. El workflow
`.github/workflows/termux-release.yml` cross-compila todo en CI (NDK r29) y
publica un **Release** con el `.deb`, el wheel del binding, los binarios crudos
y este instalador. En el teléfono, una sola línea:

```bash
# instala binding + frida-tools + frida-server (root) desde el último release:
curl -fsSL https://github.com/EduardoC3677/frida/releases/latest/download/termux-install-release.sh | bash
```

O, si ya clonaste el repo en Termux:

```bash
bash tools/termux/termux-install-release.sh            # último release
bash tools/termux/termux-install-release.sh --tag termux-v17.12.1
bash tools/termux/termux-install-release.sh --no-server # solo tools en Termux
```

El instalador descarga los assets vía la API de GitHub, verifica los
`SHA256SUMS.txt`, instala con pip **ambos wheels del release** (el binding
`frida` y `frida-tools` con sus agentes JS — sin descargar nada de PyPI ni
compilar en el teléfono), comprueba que `import frida` funciona, coloca
`frida-server` con `su` y crea `frida-server-start` / `frida-remote`. Luego:

```bash
frida-server-start                 # arranca frida-server como root en :27042
frida-ps -H 127.0.0.1:27042        # o: frida-remote ps
```

### Generar el release (mantenedor)

En GitHub: pestaña **Actions → Termux release (arm64) → Run workflow**, o empuja
un tag `termux-v*`:

```bash
git tag termux-v17.12.1 && git push origin termux-v17.12.1
```

El job corre en `ubuntu-24.04`, descarga el NDK r29, ejecuta
`build-deb-cross.sh` + `build-python-binding-cross.sh` y sube los artefactos al
release. Requiere el permiso `contents: write` (ya declarado en el workflow).

---

## Por qué `pip install frida` falla en Termux

`frida-tools` es Python puro, pero depende del módulo `frida`, que es la
extensión C `_frida`. Al hacer `pip install frida` en el teléfono, pip intenta
**compilar** `_frida` desde fuente y necesita el *devkit* de frida-core
(`frida-core.h` + `libfrida-core.a`), que no puede generar en aislamiento:

```
frida/_frida/extension.c:8:10: fatal error: 'frida-core.h' file not found
```

Solución: **cross-compilamos** el binding en un PC (con el NDK) y producimos un
**wheel** ya construido. La extensión usa `Py_LIMITED_API` (abi3), así que un
único `.so` sirve para cualquier Python 3.x de Termux.

---

## Parte 1 — En el PC Linux x86_64 (cross-compile)

Requisitos: `python3`, `ninja`, `dpkg-deb`, y el **Android NDK r29**
(`export ANDROID_NDK_ROOT=$HOME/Android/ndk/29.0.14206865`).

```bash
git clone --recurse-submodules https://github.com/EduardoC3677/frida.git
cd frida
export ANDROID_NDK_ROOT=$HOME/Android/ndk/29.0.14206865

# (a) El binding Python (frida) como wheel arm64 instalable:
bash tools/termux/build-python-binding-cross.sh --arch arm64 --py-tag 3.13
#   -> dist/frida-<ver>-cp37-abi3-android_24_aarch64.whl

# (b) frida-tools (CLI: frida, frida-ps, frida-trace...) como wheel universal,
#     construido desde fuente con sus agentes JS empaquetados (necesita node+npm):
bash tools/termux/build-tools-wheel.sh
#   -> dist/frida_tools-<ver>-py3-none-any.whl

# (c) frida-server / inject / gadget arm64 (para el lado root):
bash tools/termux/build-deb-cross.sh --arch arm64
#   -> dist/frida_<ver>_aarch64.deb   (contiene bin/frida-server, etc.)
```

Copia al teléfono los dos `.whl` y el binario `frida-server` (lo puedes sacar
del `.deb` con `dpkg-deb -x`, queda en `.../usr/bin/frida-server`). Instálalos
con pip sin tocar PyPI:

```bash
pip install --force-reinstall --no-deps frida-*-aarch64.whl       # binding
pip install --force-reinstall --no-deps frida_tools-*-any.whl     # CLI
pip install colorama prompt-toolkit pygments 'websockets<14'      # deps puras
```

Notas:
- `build-python-binding-cross.sh` descarga automáticamente el `python_*.deb`
  de Termux para obtener los headers + `libpython` del target. Usa
  `--python-deb RUTA_O_URL` para fijar otra versión, y `--py-tag 3.x` para
  alinear el nombre.
- Con `--so-only` produce solo `dist/_frida.abi3.so` (sin wheel).

## Parte 2 — En el teléfono (Termux)

```bash
# Instala binding + frida-tools y configura el modo remoto:
bash tools/termux/termux-setup-remote.sh \
     --wheel frida-*-aarch64.whl \
     --server frida-server \
     --port 27042
```

Eso:
1. Instala el wheel (`frida`) y `frida-tools` en el Python de Termux.
2. Verifica que el módulo `frida` **importa** de verdad.
3. Coloca `frida-server` en `/data/local/tmp` vía `su` (root).
4. Crea dos ayudantes: `frida-server-start` y `frida-remote`.

### Uso diario

```bash
frida-server-start                 # arranca frida-server como root en :27042
frida-ps -H 127.0.0.1:27042        # lista procesos (modo remoto)
frida-remote ps                    # equivalente abreviado
frida-remote trace -n com.app -i 'open*'
frida-remote -U com.app            # REPL (o: frida -H 127.0.0.1:27042 com.app)
```

Si tu `frida` es una versión `*.dev*` y pip se queja al instalar `frida-tools`,
usa `pip install --pre frida-tools` o fija una versión de tools compatible
(frida-tools 14.x pide `frida>=17.10,<18`).

---

## Alternativas

### Camino on-device (experimental, sin NDK)

Compila Frida **dentro** de Termux con su propio clang (parches en `releng/`):

```bash
bash tools/termux/termux-build-install.sh --jobs $(nproc)
```

Puede tardar horas y fallar en componentes que asumen glibc. El modo remoto
(cross en PC) es mucho más fiable.

### Empaquetar el servidor como .deb

`build-deb.sh` (on-device) y `build-deb-cross.sh` (cross en PC) generan un
`.deb` aarch64 con `frida-server`, `frida-inject` y `frida-gadget.so`.

---

## Sobre `termux/ndk-toolchain-clang-with-flang`

Ese repo empaqueta el clang del NDK de Android (más Flang) compilado para
**host x86_64**: es el toolchain LLVM que Termux usa en su CI para
cross-compilar. Corre en un PC x86_64 y emite binarios arm64; **no** arranca
dentro del teléfono. Además trae solo el LLVM del host (`package-install`),
**no** el sysroot de Bionic ni la estructura `toolchains/llvm/prebuilt/...`
que Frida espera en `ANDROID_NDK_ROOT`. Por eso, para el cross-build usa el
**NDK r29 oficial** de Google (incluye el sysroot); ese repo solo es útil si
ya tienes el sysroot aparte y quieres el clang/Flang más nuevo.
